#!/bin/bash

set -euo pipefail

CERTMANAGER_VERSION=1.21.1
SPIN_VERSION=0.6.1

kind create cluster --config cluster/config.yaml

WASM_NODE=cd-demo-worker
REGISTRY_NODE=cd-demo-worker3

# Apply manifests
kubectl apply -f "./cluster/assets/**.yaml"

# Install Spin operator
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v${CERTMANAGER_VERSION}/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v${SPIN_VERSION}/spin-operator.runtime-class.yaml

kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v${SPIN_VERSION}/spin-operator.crds.yaml

helm upgrade --install spin-operator \
  --namespace spin-operator \
  --create-namespace \
  --version "${SPIN_VERSION}" \
  --wait \
  oci://ghcr.io/spinframework/charts/spin-operator

kubectl patch runtimeclass wasmtime-spin-v2 \
  --type=merge \
  -p '{"scheduling":{"nodeSelector":{"type":"wasm"}}}'

kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v${SPIN_VERSION}/spin-operator.shim-executor.yaml

docker cp cluster/assets/containerd-shim-spin-v2 \
  "$WASM_NODE:/usr/local/bin/containerd-shim-spin-v2"

docker exec "$WASM_NODE" \
  chmod +x /usr/local/bin/containerd-shim-spin-v2

# Local registry setup

REGISTRY_IP=$(kubectl -n registry get svc registry -o jsonpath='{.spec.clusterIP}')

for NODE in $(kind get nodes --name cd-demo); do
  docker exec "$NODE" \
    mkdir -p /etc/containerd/certs.d/registry.local:5000

  cat <<EOF | docker exec -i "$NODE" \
    tee /etc/containerd/certs.d/registry.local:5000/hosts.toml
[host."http://${REGISTRY_IP}:5000"]
  capabilities = ["pull", "resolve"]
EOF
done

# WASM setup 
# using wasmtime
docker cp cluster/assets/containerd-shim-wasmtime-v1 \
  "$WASM_NODE:/usr/local/bin/containerd-shim-wasmtime-v1"

docker exec "$WASM_NODE" \
  chmod +x /usr/local/bin/containerd-shim-wasmtime-v1


