#!/bin/bash

set -euo pipefail

# Stop colima on failure
cleanup() {
    colima stop
}

trap cleanup ERR

# Start colima for docker
colima start

# Create kind cluster
kind create cluster --config=./demo/setup/kind.yaml 

# Complex setup: install Kyverno via Helm
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
