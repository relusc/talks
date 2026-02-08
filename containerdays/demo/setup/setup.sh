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
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Login to GitHub Container Registry (make sure to set or provide working credentials for your account)
docker login ghcr.io

# Label default namespace so it's being watched by the sigstore policy controller
# This is (as of 07.02.2026p) required according to https://docs.sigstore.dev/policy-controller/overview/
kubectl label ns default policy.sigstore.dev/include=true
