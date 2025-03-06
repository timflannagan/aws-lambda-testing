# AWS Authentication Testing Guide

This guide covers testing AWS authentication methods with KGateway in a real AWS environment. While the upstream project leverages LocalStack for basic testing, IAM enforcement is not supported in the free tier, and requires spinning up a real EKS cluster.

## Prerequisites

- Access to an EKS cluster (for IRSA testing)
- A test Lambda function in your AWS account
- Access to the KG source code repository
- `aws` CLI configured with valid credentials
- `kubectl` configured to access your cluster
- `kind` installed for local testing
- `helm` installed for deploying KG
- `eksctl` installed for creating the EKS cluster

## Authentication Method Comparison

Here's a summary of the three authentication methods available:

1. **Static AWS Credentials (Simple Setup)**
   - Uses AWS credentials stored in a Kubernetes secret
   - Good for testing and non-EKS environments
   - Not recommended for production
2. **Pod Identity (Recommended for Production)**
   - Uses IAM Roles for Service Accounts (IRSA)
   - Requires EKS with OIDC provider
   - Best practice for production environments
3. **Node Role (Simple but Less Secure)**
   - Uses the EKS node's IAM role
   - Requires adding Lambda permissions to node role
   - Not recommended for production

## Setup

### IRSA (via EKS)

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

4. Associate the OIDC provider with the cluster

    ```bash
    eksctl utils associate-iam-oidc-provider \
      --region us-east-1 \
      --cluster kgateway-lambda-test \
      --approve
    ```

5. Create a policy for the lambda invoker role

    ```bash
    aws iam create-policy \
      --tags Key=developer,Value=tim \
      --policy-name lambda-invoker-policy \
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

6. Create a role for the lambda invoker

    Add the following env vars to your shell

    ```bash
    export AWS_CLUSTER_NAME=kgateway-lambda-test
    export AWS_ROLE_NAME=kgateway-lambda-invoker-role
    export AWS_REGION=us-east-1
    export OIDC_PROVIDER=$(aws eks describe-cluster --name $AWS_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ```

    Create the role

    ```bash
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

7. Attach the policy to the role

    ```bash
    aws iam attach-role-policy \
      --role-name $AWS_ROLE_NAME \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy
    ```

8. Deploy the Kubernetes Gateway API CRDs

    ```bash
    kubectl apply --kustomize "https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.2.1"
    ```

9. Development: Build and publish custom KG images to your own registry

    ```bash
    # Login to your registry
    docker login ghcr.io -u timflannagan --password $(echo $GITHUB_TOKEN)
    # Build and publish the images
    make release IMAGE_REGISTRY=ghcr.io/timflannagan VERSION="v2.0.0-lambda" GORELEASER_ARGS="--clean --skip=validate"
    # Build and publish the helm chart
    make package-kgateway-chart VERSION=v2.0.0-lambda
    helm push _test/kgateway-v2.0.0-lambda.tgz oci://ghcr.io/timflannagan/charts
    ```

10. Deployment: Install KG with custom values

    ```bash
    helm upgrade -i kgateway oci://ghcr.io/timflannagan/charts/kgateway \
      --create-namespace \
      --namespace kgateway-system \
      --version v2.0.0-lambda \
      --set image.registry=ghcr.io/timflannagan \
      --set image.tag=v2.0.0-lambda-amd64 \
      --set image.pullPolicy=Always
    ```

11. Optional: Validate the installation

    ```bash
    # verify the GC was reconciled by the controller
    kubectl -n kgateway-system get gatewayclass kgateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")]}'
    # verify the GW was reconciled by the controller
    kubectl -n gwtest get gateway http-gw -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
    ```

12. Apply example KG CRs to test IRSA

    Deploy the CRs

    ```bash
    envsubst < docs/aws-pod-identity.yaml | kubectl apply -f -
    ```

13. Optional: Verify the installation

    Verify the Gateway was accepted

    ```bash
    kubectl -n gwtest get gateway http-gw -o jsonpath='{.status.conditions[?(@.type=="Accepted")]}'
    ```

    Verify the Envoy proxy is running

    ```bash
    kubectl -n gwtest get po -l app.kubernetes.io/instance=http-gw
    ```

    Verify the AWS_* env vars are set correctly

    ```bash
    kubectl -n gwtest get $(kubectl -n gwtest get po -l app.kubernetes.io/instance=http-gw -o name) -o jsonpath='{.spec.containers[0].env}' | grep AWS_
    ```

14. Verify routing to lambda backend works

    ```bash
    export LOAD_BALANCER_ADDR=$(kubectl -n gwtest get svc http-gw -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    curl -X POST http://$LOAD_BALANCER_ADDR:8080/lambda \
      -H "Host: www.example.com" \
      -H "Content-Type: application/json" \
      -d '{"name": "Tim"}'
    ```

    You should see the following output:

    ```bash
    "tim - Hello from Lambda"
    ```

15. Cleanup

    ```bash
    kubectl delete ns gwtest
    ```

    Re-set environment variables

    ```bash
    export AWS_REGION=us-east-1
    export OIDC_PROVIDER=$(aws eks describe-cluster --name kgateway-test --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ```

    Delete the OIDC provider if you're done with the testing.

    ```bash
    aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}
    ```

    Delete the policy if you're done with the testing.

    ```bash
    # First detach the policy from any roles
    aws iam detach-role-policy \
      --role-name lambda-invoker-role \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy

    # List all policy versions
    aws iam list-policy-versions \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy \
      --no-cli-pager

    # Delete all non-default versions (if any exist)
    for version in $(aws iam list-policy-versions \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
      --output text); do
      aws iam delete-policy-version \
        --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy \
        --version-id $version
    done

    # Now we can delete the policy
    aws iam delete-policy \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/lambda-invoker-policy
    ```

    Delete the role if you're done with the testing.

    ```bash
    # List and detach all attached policies
    aws iam list-attached-role-policies \
      --role-name lambda-invoker-role \
      --no-cli-pager

    for policy_arn in $(aws iam list-attached-role-policies \
      --role-name lambda-invoker-role \
      --query 'AttachedPolicies[*].PolicyArn' \
      --output text); do
      echo "Detaching policy: $policy_arn"
      aws iam detach-role-policy \
        --role-name lambda-invoker-role \
        --policy-arn $policy_arn
    done

    # List and delete all inline policies
    aws iam list-role-policies \
      --role-name lambda-invoker-role \
      --no-cli-pager

    for policy_name in $(aws iam list-role-policies \
      --role-name lambda-invoker-role \
      --query 'PolicyNames[*]' \
      --output text); do
      echo "Deleting inline policy: $policy_name"
      aws iam delete-role-policy \
        --role-name lambda-invoker-role \
        --policy-name $policy_name
    done

    # Now we can delete the role
    aws iam delete-role --role-name lambda-invoker-role
    ```

    Delete the EKS cluster if you're done with the testing.

    ```bash
    eksctl delete cluster --name kgateway-test --region us-east-1
    ```

### Default: Node Role (via EKS)

This method uses the EKS node's IAM role to authenticate with AWS services. This is the simplest method but requires granting permissions to all nodes in the cluster.

Follow the same EKS setup steps outlined above, but instead of using IRSA, use the node role.

1. Get the Node Role Name

```bash
# Get the node role name. You may need to copy/paste if more than one role is returned.
NODE_ROLE_NAME=$(aws iam list-roles --query 'Roles[?contains(RoleName, `NodeInstanceRole`)].RoleName' --output text)
echo "Node role: $NODE_ROLE_NAME"
```

2. Add Lambda Invoke Permissions to Node Role

    ```bash
    # Create an inline policy for Lambda invoke
    aws iam put-role-policy \
    --role-name $NODE_ROLE_NAME \
    --policy-name lambda-invoke \
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

    # Verify the policy was attached
    aws iam get-role-policy \
    --role-name $NODE_ROLE_NAME \
    --policy-name lambda-invoke \
    --no-cli-pager
    ```

3. (Optional) Debugging Node Role Auth

    ```bash
    # Check Envoy logs
    kubectl -n gwtest logs -l app.kubernetes.io/instance=http-gw --tail 100

    # Verify the identity being used (should show the node role)
    kubectl -n gwtest exec -it deploy/http-gw -- aws sts get-caller-identity

    # Check if AWS env vars are set (they shouldn't be if using node role)
    kubectl -n gwtest exec -it deploy/http-gw -- env | grep AWS_
    ```

3. Deploy the GW API CRs

    ```bash
    kubectl apply -f docs/aws-default.yaml
    ```

4. Test the Lambda Function

    ```bash
    # Get the LoadBalancer address
    export LOAD_BALANCER_ADDR=$(kubectl -n gwtest get svc http-gw -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

    # Test the Lambda invocation
    curl -X POST http://$LOAD_BALANCER_ADDR:8080/lambda \
    -H "Host: www.example.com" \
    -H "Content-Type: application/json" \
    -d '{"name": "Tim"}'
    ```

5. Clean Up Node Role Auth

    ```bash
    # Remove the Lambda invoke policy from the node role
    aws iam delete-role-policy \
    --role-name $NODE_ROLE_NAME \
    --policy-name lambda-invoke

    # Delete test resources
    kubectl delete ns gwtest
    ```

6. Additional Cleanup

Follow the same cleanup steps outlined above for IRSA.

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

If the configuration is not what you expect, you can try to bump the log level:

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
