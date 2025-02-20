# AWS Lambda Testing

This directory contains scripts and configuration for testing the KGateway AWS Lambda integration using LocalStack.

## Setup

Run the setup script to create the test environment:

```bash
./hack/setup-localstack.sh
```

This will:
- Create a kind cluster with OIDC support for IRSA
- Install LocalStack in your kind cluster
- Install cert-manager for TLS certificate management
- Install the AWS EKS Pod Identity Webhook for IRSA support
- Install KGateway from a local Helm chart
- Create test Lambda functions (tim-test and echo-test)
- Create AWS credentials secret for KGateway

Then apply the KGateway configuration:

```bash
kubectl apply -f hack/example-aws-upstream.yaml
```

## Using Custom KGateway Builds

To test with a custom build of KGateway:

1. Package the local Helm chart:
    ```bash
    pushd /work/kgateway && make package-kgateway-chart VERSION="v2.0.0-main" && kubectl apply -f install/helm/kgateway/crds && popd
    ```

2. Reload KGateway in the cluster:
    ```bash
    pushd /work/kgateway && make VERSION=v2.0.0-main CLUSTER_NAME=kind kind-reload-kgateway -B && popd
    ```

This will rebuild and reload KGateway with your local changes.

## Testing

### Direct Lambda Testing

Test the Lambda functions directly through LocalStack:

```bash
# Get the LocalStack endpoint
export NODE_PORT=$(kubectl get --namespace "localstack" -o jsonpath="{.spec.ports[0].nodePort}" services localstack)
export NODE_IP=$(kubectl get nodes --namespace "localstack" -o jsonpath="{.items[0].status.addresses[0].address}")
export ENDPOINT=http://$NODE_IP:$NODE_PORT

# Test the tim-test function (adds two numbers)
aws --endpoint-url $ENDPOINT \
  --cli-binary-format raw-in-base64-out \
  lambda invoke \
  --function-name tim-test \
  --payload '{"num1": "10", "num2": "20"}' \
  output.txt

# Test the echo-test function (echoes back the request)
aws --endpoint-url $ENDPOINT \
  --cli-binary-format raw-in-base64-out \
  lambda invoke \
  --function-name echo-test \
  --payload '{"test": "value"}' \
  output.txt
```

### Testing via KGateway

1. Port-forward the KGateway proxy:

    ```bash
    # Find an available port if 8080 is in use
    kubectl -n kgateway-system port-forward deploy/gloo-proxy-http 8080:8080
    ```

2. Test the endpoints:

    ```bash
    # Test tim-test function (adds two numbers)
    curl -X POST -H "Host: www.example.com" \
      -H "Content-Type: application/json" \
      -d '{"num1": "10", "num2": "20"}' \
      localhost:8080/lambda/1

    # Test echo-test function
    curl -X POST -H "Host: www.example.com" \
      -H "Content-Type: application/json" \
      -d '{"test": "value"}' \
      localhost:8080/lambda/2
    ```

## Function Details

### tim-test

A simple function that adds two numbers:

```javascript
exports.handler = async (event) => {
  const num1 = parseInt(event.num1);
  const num2 = parseInt(event.num2);
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: `The sum of ${num1} and ${num2} is ${num1 + num2}`,
      result: num1 + num2
    })
  };
};
```

### echo-test

A simple function that echoes back the request:

```javascript
exports.handler = async (event) => {
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: "Echo response",
      input: event
    })
  };
};
```

## Troubleshooting

1. If port 8080 is in use, try a different port:

    ```bash
    kubectl -n kgateway-system port-forward deploy/gloo-proxy-http 8081:8080
    ```

2. Verify LocalStack is running:

    ```bash
    kubectl -n localstack get pods
    ```

3. Check Lambda function logs:

    ```bash
    kubectl -n localstack logs -l app.kubernetes.io/name=localstack
    ```

4. Check KGateway logs:

    ```bash
    kubectl -n kgateway-system logs -l app=gateway
    ```
