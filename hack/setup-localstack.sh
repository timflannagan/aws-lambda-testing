#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && cd .. && pwd)"

endpoint=""

setup_kind_cluster() {
  echo "Setting up kind cluster with OIDC support..."

  if kind get clusters | grep -q "kind"; then
    echo "Kind cluster already exists. Skipping setup."
    return
  fi

  # Generate OIDC keys
  "${ROOT_DIR}/hack/setup-oidc.sh"

  # Verify OIDC files exist
  echo "Verifying OIDC files..."
  ls -la "${ROOT_DIR}/oidc"

  kind create cluster --wait 30s --config "${ROOT_DIR}/hack/kind-config.yaml"

  # Verify API server configuration
  echo "Verifying API server configuration..."
  kubectl get --raw /openid/v1/jwks

  echo "Kind cluster created successfully"
}

install_cert_manager() {
  echo "Installing cert-manager..."

  # Add the Jetstack Helm repository
  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  # Create the namespace for cert-manager
  kubectl create namespace cert-manager || true

  # Install cert-manager with CRDs
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --set installCRDs=true \
    --version v1.13.3

  # Wait for cert-manager to be ready
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=webhook -n cert-manager --timeout=120s
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cainjector -n cert-manager --timeout=120s

  echo "cert-manager installed successfully"
}

install_localstack() {
  # Create namespace for LocalStack
  kubectl create namespace localstack || true

  # Install LocalStack using Helm
  helm repo add localstack-repo https://helm.localstack.cloud
  helm repo update
  helm upgrade --install localstack localstack-repo/localstack \
    --namespace localstack \
    --values "${ROOT_DIR}/hack/localstack-values.yaml"

  # Wait for LocalStack pod to be ready
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=localstack -n localstack --timeout=120s
}

install_pod_identity_webhook() {
  echo "Installing AWS EKS Pod Identity Webhook..."

  TMPDIR=$(mktemp -d)
  cd "${TMPDIR}"

  git clone https://github.com/aws/amazon-eks-pod-identity-webhook.git && pushd amazon-eks-pod-identity-webhook
  make cluster-up IMAGE=amazon/amazon-eks-pod-identity-webhook:latest

  popd
  rm -rf "${TMPDIR}"
  echo "Pod Identity Webhook installed successfully"
}

install_gateway_crds() {
  echo "Installing GW API CRDs..."
  kubectl apply -k https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.2.1
}

install_kgateway() {
  echo "Installing KGateway..."
  helm upgrade -i kgateway oci://ghcr.io/kgateway-dev/charts/kgateway \
    --version v2.0.0-main \
    --create-namespace \
    --namespace kgateway-system \

  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kgateway -n kgateway-system --timeout=120s
  echo "KGateway installed successfully"
}

override_kgateway_image() {
  echo "Overriding kgateway image with local images..."
  pushd /work/kgateway
  make VERSION=v2.0.0-main CLUSTER_NAME=kind kind-reload-kgateway -B
  make VERSION=v2.0.0-main CLUSTER_NAME=kind kind-build-and-load-envoy-wrapper -B
  popd
  echo "kgateway image overridden successfully"
}

override_kgateway_crds () {
  echo "Overriding kgateway CRDs..."
  pushd /work/kgateway && kubectl apply -f install/helm/kgateway/crds && popd
  echo "kgateway CRDs overridden successfully"
}

extract_localstack_endpoint() {
  # Get LocalStack endpoint
  local node_port=$(kubectl get --namespace "localstack" -o jsonpath="{.spec.ports[0].nodePort}" services localstack)
  local node_ip=$(kubectl get nodes --namespace "localstack" -o jsonpath="{.items[0].status.addresses[0].address}")
  endpoint="http://$node_ip:$node_port"
}

setup_iam_role() {
  echo "Setting up IAM roles for IRSA testing..."

  # Create the IAM role with trust relationship for IRSA
  cat <<EOF > /tmp/trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID:-000000000000}:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/test"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-west-2.amazonaws.com/id/test:sub": "system:serviceaccount:default:lambda-invoker-sa"
        }
      }
    }
  ]
}
EOF

  # Create role with trust policy
  aws --endpoint-url $endpoint iam create-role \
    --role-name lambda-invoker-role \
    --assume-role-policy-document file:///tmp/trust-policy.json

  # Create policy document with least privilege permissions
  cat <<EOF > /tmp/lambda-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction",
        "lambda:GetFunction"
      ],
      "Resource": [
        "arn:aws:lambda:${AWS_REGION:-us-east-1}:${AWS_ACCOUNT_ID:-000000000000}:function:*"
      ]
    }
  ]
}
EOF

  # Create the IAM policy
  aws --endpoint-url $endpoint iam create-policy \
    --policy-name lambda-invoker-policy \
    --policy-document file:///tmp/lambda-policy.json

  # Attach the policy to the role
  aws --endpoint-url $endpoint iam attach-role-policy \
    --role-name lambda-invoker-role \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID:-000000000000}:policy/lambda-invoker-policy

  # Clean up temporary files
  rm -f /tmp/trust-policy.json /tmp/lambda-policy.json

  echo "IAM role and policy created successfully"
}

create_lambda_function() {
  # Lambda function source code path
  local dir="${ROOT_DIR}/lambda-functions"
  # Lambda configuration
  local function_handler="index.handler"
  local function_names=("tim-test" "echo-test")
  local function_role="arn:aws:iam::000000000000:role/lambda-invoker-role"
  local function_runtime="nodejs18.x"

  # Create each test function
  for function_name in "${function_names[@]}"; do
    echo "Creating Lambda function: $function_name"
    local function_file="${dir}/${function_name}.js"

    if [[ ! -f "$function_file" ]]; then
      echo "Error: Function file not found: $function_file"
      continue
    fi

    # Create a temporary directory for packaging
    local temp_dir=$(mktemp -d)
    cp "$function_file" "${temp_dir}/index.js"

    # Create ZIP file
    (cd "${temp_dir}" && zip -r "../${function_name}.zip" .)

    # Create Lambda function with ZIP file
    aws --endpoint-url $endpoint lambda create-function \
      --no-cli-pager \
      --region us-east-1 \
      --function-name $function_name \
      --handler $function_handler \
      --role $function_role \
      --runtime $function_runtime \
      --zip-file "fileb://${temp_dir}/../${function_name}.zip" || true

    # Clean up
    rm -rf "${temp_dir}" "${function_name}.zip"
  done
}

verify_lambda_functions() {
  echo "Verifying Lambda functions..."
  local function_names=("tim-test" "echo-test")
  for function_name in "${function_names[@]}"; do
    echo "Testing Lambda function: $function_name"
    TEST_PAYLOAD=$(echo -n '{"body": "{\"num1\": \"10\", \"num2\": \"10\"}" }' | base64)
    aws --endpoint-url $endpoint lambda invoke \
      --no-cli-pager \
      --region us-east-1 \
      --function-name $function_name \
      --payload "$TEST_PAYLOAD" \
      /dev/stdin
  done
}

# Create AWS credentials secret for KGateway
create_aws_secret() {
  kubectl create namespace httpbin > /dev/null 2>&1 || true

  kubectl -n httpbin create secret generic aws-secret \
    --from-literal=accessKey=test \
    --from-literal=secretKey=test \
    --from-literal=sessionToken=test 2>/dev/null || true
}

# Main execution
setup_kind_cluster
install_localstack
install_cert_manager
install_pod_identity_webhook
extract_localstack_endpoint
setup_iam_role
install_gateway_crds
install_kgateway
override_kgateway_image
override_kgateway_crds
create_lambda_function
create_aws_secret
verify_lambda_functions

echo "LocalStack setup complete. You can now:"
echo "0. Set the ENDPOINT environment variable:"
echo "   export ENDPOINT=$endpoint"
echo "1. Manually build and load the kgateway images"
echo "   make VERSION=v2.0.0-main CLUSTER_NAME=kind kind-reload-kgateway kind-reload-envoyinit -B"
echo "1. Test the Lambda functions directly:"
echo "   TEST_PAYLOAD=\$(echo -n '{\"body\":\"{\\\"num1\\\":\\\"10\\\",\\\"num2\\\":\\\"20\\\"}\"}')"
echo "   aws --endpoint-url \$ENDPOINT --no-cli-pager lambda invoke --function-name tim-test --payload \"\$TEST_PAYLOAD\" /dev/stdin"
echo "2. Apply the KGateway configuration:"
echo "   kubectl apply -f $ROOT_DIR/hack/example-aws-upstream.yaml"
echo "3. Test IRSA configuration:"
echo "   kubectl apply -f $ROOT_DIR/hack/example-aws-upstream-irsa.yaml"
