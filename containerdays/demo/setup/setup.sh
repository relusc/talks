#!/bin/bash

set -euo pipefail

# Stop colima on failure
cleanup() {
    kind delete clusters --all
    colima stop
}

trap cleanup ERR

# Start colima for docker
colima start

# Create kind cluster
kind create cluster --config=./setup/kind.yaml 

# Complex setup: Install Kyverno
# Documentation about verifying images with Kyverno: https://kyverno.io/policies/other/verify-image/verify-image/
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Login to GitHub Container Registry (make sure to set or provide working credentials for your account)
docker login ghcr.io
