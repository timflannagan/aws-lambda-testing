#!/bin/bash -ex

# This script sets up LocalStack in a kind cluster and creates test Lambda functions
# for development and testing of the KGateway AWS Lambda integration.

# Get directory this script is located in to access script local files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

install_localstack() {
  # Create namespace for LocalStack
  kubectl create namespace localstack || true

  # Install LocalStack using Helm
  helm repo add localstack-repo https://helm.localstack.cloud
  helm repo update
  helm upgrade --install localstack localstack-repo/localstack \
    --namespace localstack \
    --values "${SCRIPT_DIR}/localstack-values.yaml"

  # Wait for LocalStack pod to be ready
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=localstack -n localstack --timeout=120s
}

create_lambda_function() {
  # Lambda function source code path
  local dir="${SCRIPT_DIR}/lambda-functions"

  # Lambda configuration
  local function_handler="index.handler"
  local function_names=("tim-test" "echo-test")
  local function_role="arn:aws:iam::000000000000:role/localstack-does-not-care"
  local function_runtime="nodejs18.x"

  # Get LocalStack endpoint
  export NODE_PORT=$(kubectl get --namespace "localstack" -o jsonpath="{.spec.ports[0].nodePort}" services localstack)
  export NODE_IP=$(kubectl get nodes --namespace "localstack" -o jsonpath="{.items[0].status.addresses[0].address}")
  export ENDPOINT=http://$NODE_IP:$NODE_PORT

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

    # Delete function if it exists
    aws --endpoint-url $ENDPOINT --no-cli-pager lambda delete-function --function-name $function_name --region us-east-1 || true

    # Create Lambda function with ZIP file
    aws --endpoint-url $ENDPOINT --no-cli-pager lambda create-function \
      --region us-east-1 \
      --function-name $function_name \
      --handler $function_handler \
      --role $function_role \
      --runtime $function_runtime \
      --zip-file "fileb://${temp_dir}/../${function_name}.zip" || true

    # Clean up
    rm -rf "${temp_dir}" "${function_name}.zip"

    # Verify function was created with a test invocation
    echo "Testing Lambda function: $function_name"
    TEST_PAYLOAD=$(echo -n '{"body": "{\"num1\": \"10\", \"num2\": \"10\"}" }' | base64)
    aws --endpoint-url $ENDPOINT --no-cli-pager lambda invoke \
      --region us-east-1 \
      --function-name $function_name \
      --payload "$TEST_PAYLOAD" \
      "${function_name}-output.txt"
    echo "Function output:"
    cat "${function_name}-output.txt"
    rm -f "${function_name}-output.txt"
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
install_localstack
create_lambda_function
create_aws_secret

echo "LocalStack setup complete. You can now:"
echo "1. Test the Lambda functions directly:"
echo "   TEST_PAYLOAD=\$(echo -n '{\"body\": \"{\\\"num1\\\": \\\"10\\\", \\\"num2\\\": \\\"20\\\"}\" }' | base64)"
echo "   aws --endpoint-url \$ENDPOINT --no-cli-pager lambda invoke --function-name tim-test --payload \"\$TEST_PAYLOAD\" output.txt"
echo "2. Apply the KGateway configuration:"
echo "   kubectl apply -f ../../examples/example-aws-upstream.yaml"
