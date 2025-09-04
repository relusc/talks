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

# Complex setup: Install sigstore policy controller
# More on how to use it for signature validation can be found here: https://docs.sigstore.dev/policy-controller/overview/
helm repo add sigstore https://sigstore.github.io/helm-charts
helm install policy-controller -n cosign-system sigstore/policy-controller --create-namespace

# Login to GitHub Container Registry (make sure to set or provide working credentials for your account)
docker login ghcr.io

# Create Kyverno secret with public key (make sure to create keypair first)
kubectl create secret generic cosign-public -n cosign-system --from-file=./cosign.pub

# Label default namespace so it's being watched by the sigstore policy controller
# This is (as of 04.09.2025) required according to https://docs.sigstore.dev/policy-controller/overview/
kubectl label ns default policy.sigstore.dev/include=true
