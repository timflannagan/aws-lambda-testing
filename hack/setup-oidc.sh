#!/bin/bash -ex

# Get directory this script is located in to access script local files
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && cd .. && pwd)"
OIDC_DIR="${ROOT_DIR}/oidc"

mkdir -p $OIDC_DIR

# Generate private key
openssl genrsa -out ${OIDC_DIR}/private.key 2048

# Generate public key in PKCS8 format
openssl rsa -in ${OIDC_DIR}/private.key -pubout -out ${OIDC_DIR}/public.key

echo "OIDC keys created in ${OIDC_DIR}"
