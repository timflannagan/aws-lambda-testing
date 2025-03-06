# AWS Authentication Testing Guide

This guide covers testing AWS authentication methods with KGateway in a real AWS environment. While the upstream project leverages LocalStack for basic testing, IAM enforcement is not supported in the free tier, and requires spinning up a real EKS cluster.

## Prerequisites

- `aws` CLI configured with valid credentials
- `kubectl` configured to access your cluster
- `helm` installed for deploying KG
- `eksctl` installed for creating the EKS cluster

## Authentication Method Comparison

Here's a summary of the three authentication methods available:

1. **Static AWS Credentials (Simple Setup)**
   - Uses AWS credentials stored in a Kubernetes secret
   - Good for testing and non-EKS environments
   - Not recommended for production
2. **Node Group Role (Simple but Less Secure)**
   - Uses the EKS node group's IAM role
   - Requires adding Lambda permissions to node group role
   - Not recommended for production
3. **Pod Identity (Recommended for Production)**
   - Uses IAM Roles for Service Accounts (IRSA)
   - Requires EKS with OIDC provider
   - Best practice for production environments

## Known Limitations

- Adding extra environment variables to the deployed Envoy proxy is not supported. This prevents users from configuring a GatewayParameters resource with the AWS_* credential environment variables.
- Adding extra volumes to the deployed Envoy proxy is not supported. This prevents users from mounting the AWS_WEB_IDENTITY_TOKEN_FILE or AWS_SHARED_CREDENTIALS_FILE.
- Having the control plane make API calls to assume a role and return temporary credentials is not supported.

See <https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/aws_lambda_filter> for list of supported authentication methods that Envoy supports.

## Setup

The following steps are required to setup the EKS cluster and deploy the KG project.

### Prerequisites

1. Optional: Install eksctl

```bash
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"

# (Optional) Verify checksum
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check

tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz

sudo mv /tmp/eksctl /usr/local/bin
```

2. Optional: Configure AWS credentials

```bash
aws configure
```

3. Create an EKS cluster

```bash
eksctl create cluster \
  --name kgateway-lambda-test \
  --region us-east-1 \
  --version 1.31 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 \
  --tags developer=tim
```

4. Deploy the Kubernetes Gateway API CRDs

```bash
kubectl apply --kustomize "https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.2.1"
```

5. Development Only: Build and publish custom KG images to your own registry

```bash
# Login to your registry
docker login ghcr.io -u timflannagan --password $(echo $GITHUB_TOKEN)
# Build and publish the images
make release IMAGE_REGISTRY=ghcr.io/timflannagan VERSION="v2.0.0-lambda" GORELEASER_ARGS="--clean --skip=validate"
# Build and publish the helm chart
make package-kgateway-chart VERSION=v2.0.0-lambda
helm push _test/kgateway-v2.0.0-lambda.tgz oci://ghcr.io/timflannagan/charts
```

6. Deployment: Install KG with custom values

For development, override the default values with the following:

```bash
helm upgrade -i kgateway oci://ghcr.io/timflannagan/charts/kgateway \
  --create-namespace \
  --namespace kgateway-system \
  --version v2.0.0-lambda \
  --set image.registry=ghcr.io/timflannagan \
  --set image.tag=v2.0.0-lambda-amd64 \
  --set image.pullPolicy=Always
```

When support for [AWS Lambda](https://github.com/kgateway-dev/kgateway/pull/10720) has been merged, you can install KG with the following:

```bash
helm install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --create-namespace \
  --namespace kgateway-system \
  --version v2.0.0-beta1
```

7. Optional: Validate the installation

```bash
# verify the GC was reconciled by the controller
kubectl -n kgateway-system get gatewayclass kgateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")]}'
# verify the GW was reconciled by the controller
kubectl -n gwtest get gateway http-gw -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
```

8. Add the following env vars to your shell

```bash
export AWS_CLUSTER_NAME=kgateway-lambda-test
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Authentication Method 1: Static AWS Credentials

1. Create a namespace for the test

```bash
kubectl create namespace gwtest
```

2. Create a secret with AWS credentials

```bash
kubectl -n gwtest create secret generic aws-creds \
  --from-literal=accessKey=$AWS_ACCESS_KEY_ID \
  --from-literal=secretKey=$AWS_SECRET_ACCESS_KEY \
  --from-literal=sessionToken=$AWS_SESSION_TOKEN
```

3. Apply the CRs

```bash
envsubst < docs/aws-static.yaml | kubectl apply -f -
```

See [aws-static.yaml](./aws-static.yaml) for the CRs used in this test.

5. Test the Lambda invocation

See [Routing to Lambda Function](#routing-to-lambda-function) for the test.

6. Cleanup

```bash
kubectl delete -f docs/aws-static.yaml
kubectl delete secret aws-creds -n gwtest
kubectl delete ns gwtest
```

### Authentication Method 2: Node Group Role

This method uses the EKS node group's IAM role to authenticate with AWS services. This is the simplest method but requires granting permissions to all nodes in the cluster.

1. Get the Node Instance Role

```bash
export NODE_ROLE_NAME=$(aws iam list-roles --no-cli-pager --query "Roles[?contains(RoleName, 'NodeInstanceRole') && contains(RoleName, '${AWS_CLUSTER_NAME}')].RoleName" --output text)
echo "Node role: $NODE_ROLE_NAME"
```

2. Add Lambda Invoke Permissions to the EKS Node Instance Role

```bash
export AWS_POLICY_NAME=kgateway-lambda-node-policy
aws iam put-role-policy \
  --role-name $NODE_ROLE_NAME \
  --policy-name $AWS_POLICY_NAME \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "lambda:InvokeFunction",
          "lambda:GetFunction"
        ],
        "Resource": "*"
      }
    ]
  }'
```

3. Optional: Verify the policy was attached

```bash
aws iam list-role-policies \
  --role-name $NODE_ROLE_NAME \
  --no-cli-pager
```

```bash
aws iam get-role-policy \
  --role-name $NODE_ROLE_NAME \
  --policy-name $AWS_POLICY_NAME \
  --no-cli-pager
```

4. Optional: Debugging Node Role Auth

```bash
# Check Envoy logs
kubectl -n gwtest logs -l app.kubernetes.io/instance=http-gw --tail 100

# Verify the identity being used (should show the node role)
kubectl -n gwtest exec -it deploy/http-gw -- aws sts get-caller-identity

# Check if AWS env vars are set (they shouldn't be if using node role)
kubectl -n gwtest exec -it deploy/http-gw -- env | grep AWS_
```

5. Deploy the CRs

```bash
envsubst < docs/aws-default.yaml | kubectl apply -f -
```

See [aws-default.yaml](./aws-default.yaml) for the CRs used in this test.

6. Cleanup

Delete the test resources:

```bash
kubectl delete -f docs/aws-default.yaml
```

Delete the namespace:

```bash
kubectl delete ns gwtest
```

Remove the Lambda invoke policy from the node role:

```bash
aws iam delete-role-policy \
  --role-name $NODE_ROLE_NAME \
  --policy-name $AWS_POLICY_NAME
```

### Authentication Method 3: Pod Identity (IRSA)

1. Add the following env vars to your shell

```bash
export AWS_ROLE_NAME=kgateway-lambda-invoker-role
export AWS_POLICY_NAME=kgateway-lambda-invoker-policy
```

2. Associate the OIDC provider with the cluster

```bash
eksctl utils associate-iam-oidc-provider \
  --region us-east-1 \
  --cluster $AWS_CLUSTER_NAME \
  --approve
```

3. Create a policy for the lambda invoker role

```bash
aws iam create-policy \
  --tags Key=developer,Value=tim \
  --policy-name $AWS_POLICY_NAME \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "lambda:InvokeFunction",
          "lambda:GetFunction"
        ],
        "Resource": "*"
      }
    ]
  }'
```

4. Create an IAM role for the lambda invoker

```bash
export OIDC_PROVIDER=$(aws eks describe-cluster --name $AWS_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
aws iam create-role \
  --tags Key=developer,Value=tim \
  --role-name $AWS_ROLE_NAME \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::'"${AWS_ACCOUNT_ID}"':oidc-provider/'"${OIDC_PROVIDER}"'"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "'"${OIDC_PROVIDER}":sub'": "system:serviceaccount:gwtest:http-gw"
          }
        }
      }
    ]
  }'
```

5. Attach the policy to the role

```bash
aws iam attach-role-policy \
  --role-name $AWS_ROLE_NAME \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME
```

6. Apply example KG CRs to test IRSA

```bash
envsubst < docs/aws-pod-identity.yaml | kubectl apply -f -
```

See [aws-pod-identity.yaml](./aws-pod-identity.yaml) for the CRs used in this test.

7. Test the Lambda invocation

See [Routing to Lambda Function](#routing-to-lambda-function) for the test.

8. Cleanup

Delete the test resources:

```bash
kubectl delete -f docs/aws-pod-identity.yaml
kubectl delete ns gwtest
```

Delete the OIDC provider if you're done with the testing.

```bash
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}
```

Delete the IAM resources if you're done with the testing.

```bash
# First detach the policy from any roles
aws iam detach-role-policy \
  --role-name $AWS_ROLE_NAME \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
  --no-cli-pager

# List all policy versions
aws iam list-policy-versions \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
  --no-cli-pager

# Delete all non-default versions (if any exist)
for version in $(aws iam list-policy-versions \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
  --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
  --output text); do
  aws iam delete-policy-version \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
    --version-id $version \
    --no-cli-pager
done

# Now we can delete the policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
  --no-cli-pager

# List and detach all attached policies
aws iam list-attached-role-policies \
  --role-name $AWS_ROLE_NAME \
  --no-cli-pager

for policy_arn in $(aws iam list-attached-role-policies \
  --role-name $AWS_ROLE_NAME \
  --query 'AttachedPolicies[*].PolicyArn' \
  --output text); do
  echo "Detaching policy: $policy_arn"
  aws iam detach-role-policy \
    --role-name $AWS_ROLE_NAME \
    --policy-arn $policy_arn \
    --no-cli-pager
done

# List and delete all inline policies
aws iam list-role-policies \
  --role-name $AWS_ROLE_NAME \
  --no-cli-pager

for policy_name in $(aws iam list-role-policies \
  --role-name $AWS_ROLE_NAME \
  --query 'PolicyNames[*]' \
  --output text); do
  echo "Deleting inline policy: $policy_name"
  aws iam delete-role-policy \
    --role-name $AWS_ROLE_NAME \
    --policy-name $policy_name \
    --no-cli-pager
done

# Now we can delete the role
aws iam delete-role \
  --role-name $AWS_ROLE_NAME \
  --no-cli-pager

# validate the role was deleted
aws iam get-role \
  --role-name $AWS_ROLE_NAME \
  --no-cli-pager

# validate the policy was deleted
aws iam get-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$AWS_POLICY_NAME \
  --no-cli-pager
```

### Routing to Lambda Function

```bash
# Get the LoadBalancer address
export LOAD_BALANCER_ADDR=$(kubectl -n gwtest get svc http-gw -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test the Lambda invocation
curl -X POST http://$LOAD_BALANCER_ADDR:8080/lambda \
-H "Host: www.example.com" \
-H "Content-Type: application/json" \
-d '{"name": "Tim"}'
```

### Additional Cleanup

Delete the EKS cluster if you're done with the testing.

```bash
eksctl delete cluster --name $AWS_CLUSTER_NAME --region $AWS_REGION
```

## Debugging

For credential-based authentication, you can validate the credentials are valid:

```bash
# Unset any existing AWS credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Get the credentials from the secret and validate the identity from the AWS CLI
AWS_ACCESS_KEY_ID=$(kubectl -n gwtest get secret aws-creds -o jsonpath='{.data.accessKey}' | base64 -d) \
AWS_SECRET_ACCESS_KEY=$(kubectl -n gwtest get secret aws-creds -o jsonpath='{.data.secretKey}' | base64 -d) \
AWS_SESSION_TOKEN=$(kubectl -n gwtest get secret aws-creds -o jsonpath='{.data.sessionToken}' | base64 -d) \
aws sts get-caller-identity --no-cli-pager
```

If you need to debug the deployed Envoy proxy, you can start by viewing the logs:

```bash
kubectl -n gwtest logs -l app.kubernetes.io/instance=http-gw --tail 100
```

If nothing is showing up, you can try to get the Envoy config dump:

```bash
kubectl -n gwtest port-forward $(kubectl -n gwtest get deploy -l app.kubernetes.io/instance=http-gw -o name) 19000:19000 &
curl http://localhost:19000/config_dump > envoy-config.json
```

Then you can get the config dump from the local port:

```bash
curl http://localhost:19000/config_dump
```

If the configuration is not what you expect, you can try to bump the log level. There's two ways to do this:

1. Update the GatewayParameters resource

```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.kgateway.dev/v1alpha1
kind: GatewayParameters
metadata:
  name: http-gw
  namespace: gwtest
spec:
  kube:
    envoyContainer:
      bootstrap:
        logLevel: debug
EOF

cat <<EOF | kubectl apply -f -
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: http-gw
  namespace: gwtest
  annotations:
    gateway.kgateway.dev/gateway-parameters-name: http-gw
spec:
  gatewayClassName: kgateway
  listeners:
  - protocol: HTTP
    port: 8080
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
```

2. Update the Envoy config directly

```bash
kubectl -n gwtest port-forward deploy/http-gw 19000:19000 &
curl -X POST "localhost:19000/logging?level=debug"
```
