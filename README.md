# AWS Lambda Testing with LocalStack

This directory contains scripts and configuration for testing AWS Lambda functionality using LocalStack in a kind cluster. This setup is particularly useful for developing and testing the KGateway AWS Lambda integration without requiring access to real AWS resources.

## Prerequisites

- kind cluster running
- kubectl configured to use the kind cluster
- Helm installed
- AWS CLI installed
- AWS credentials configured for LocalStack:
  ```bash
  # Configure AWS CLI with dummy credentials for LocalStack
  aws configure set aws_access_key_id test
  aws configure set aws_secret_access_key test
  aws configure set region us-east-1

  # Optional: Set up a separate profile for LocalStack
  aws configure set aws_access_key_id test --profile localstack
  aws configure set aws_secret_access_key test --profile localstack
  aws configure set region us-east-1 --profile localstack
  ```

## Setup

1. Run the setup script:
   ```bash
   ./setup-localstack.sh
   ```

This will:
- Create a namespace for LocalStack
- Install LocalStack via Helm
- Create test Lambda functions

## Test Functions

### tim-test
A simple function that adds two numbers:
```bash
# Test the function directly via LocalStack
aws --endpoint-url http://localhost:31566 lambda invoke \
  --function-name tim-test \
  --payload '{"body": "{\"num1\": \"10\", \"num2\": \"20\"}" }' \
  output.txt

# Test via KGateway (after setting up the Upstream and HTTPRoute)
curl -H "Host: www.example.com" localhost:8080/lambda/1
```

### echo-test
A function that echoes back the input:
```bash
# Test the function directly via LocalStack
aws --endpoint-url http://localhost:31566 lambda invoke \
  --function-name echo-test \
  --payload '{"test": "data"}' \
  output.txt

# Test via KGateway (after setting up the Upstream and HTTPRoute)
curl -H "Host: www.example.com" localhost:8080/lambda/2
```

## Configuration

### LocalStack Configuration
The LocalStack configuration is in `localstack-values.yaml`. Key settings:
- NodePort service type for access from the host
- Lambda service enabled
- Debug mode enabled
- Persistence enabled to maintain state between restarts

### KGateway Configuration
To use the LocalStack Lambda functions with KGateway:

1. Create AWS credentials secret:
```bash
kubectl -n httpbin create secret generic aws-secret \
  --from-literal=accessKey=test \
  --from-literal=secretKey=test \
  --from-literal=sessionToken=test
```

2. Apply the example configuration:
```bash
kubectl apply -f ../../examples/example-aws-upstream.yaml
```

## Directory Structure
```
.
├── README.md
├── setup-localstack.sh
├── localstack-values.yaml
└── lambda-functions/
    ├── tim-test.js
    └── echo-test.js
```

## Development Workflow

1. Start the kind cluster with LocalStack:
   ```bash
   ./setup-localstack.sh
   ```

2. Set up KGateway with the AWS Lambda configuration

3. Test the functions through KGateway:
   ```bash
   # Port-forward the gateway
   kubectl -n kgateway-system port-forward deploy/gloo-proxy-http 8080:8080

   # Test the functions
   curl -H "Host: www.example.com" localhost:8080/lambda/1
   curl -H "Host: www.example.com" localhost:8080/lambda/2
   ```

4. View LocalStack logs if needed:
   ```bash
   kubectl -n localstack logs -f deploy/localstack
   ```
