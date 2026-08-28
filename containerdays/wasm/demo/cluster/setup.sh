#!/bin/bash

#########################################################################
## Sets up the demo environment
## Cluster + Spin operator for WASM workloads + Local OCI registry setup
#########################################################################

set -euo pipefail

CERTMANAGER_VERSION=1.21.1
SPIN_VERSION=0.6.1
SHIM_VERSION=0.25.1

WASM_NODE=cd-demo-worker
REGISTRY_NODE=cd-demo-worker3

##################################
## Create cluster
##################################
kind create cluster --config cluster/config.yaml

####################################################################
## Install Spin operator
## see https://www.spinkube.dev/docs/install/installing-with-helm/
####################################################################
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v${CERTMANAGER_VERSION}/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

# Install Runtime Class Manager
helm upgrade --install runtime-class-manager  \
  --namespace runtime-class-manager \
  --create-namespace \
  --version 0.2.0 \
  oci://ghcr.io/spinframework/charts/runtime-class-manager

# Create Shim resource for installing the containerd-shim-spin binary
kubectl apply -f https://github.com/spinframework/containerd-shim-spin/releases/download/v${SHIM_VERSION}/runtime-class-manager-shim-v1alpha1-v${SHIM_VERSION}.yaml

# Install the actual operator
kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v${SPIN_VERSION}/spin-operator.crds.yaml

helm upgrade --install spin-operator \
  --namespace spin-operator \
  --create-namespace \
  --version "${SPIN_VERSION}" \
  --wait \
  oci://ghcr.io/spinframework/charts/spin-operator

# Create SpinAppExecutor; tells the Spin Operator to use the RuntimeClass we just created to run Spin Apps
kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v${SPIN_VERSION}/spin-operator.shim-executor.yaml

# Copy WASM spin shim to WASM-enabled node and make it executable
# docker cp cluster/containerd-shim-spin-v2 \
#   "$WASM_NODE:/usr/local/bin/containerd-shim-spin-v2"

# docker exec "$WASM_NODE" \
#   chmod +x /usr/local/bin/containerd-shim-spin-v2

##################################
## Local registry setup
##################################
kubectl apply -f "./cluster/registry.yaml"

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
