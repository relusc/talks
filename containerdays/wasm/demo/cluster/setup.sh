#!/bin/bash

set -euo pipefail

kind create cluster --config cluster/config.yaml

WASM_NODE=cd-demo-worker
REGISTRY_NODE=cd-demo-worker3

# Apply manifests
kubectl apply -f "./cluster/assets/**.yaml"

# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch -n kube-system deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

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


