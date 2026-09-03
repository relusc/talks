#!/bin/bash

set -euo pipefail

# Generate random image tag
IMAGE_TAG=$(uuidgen | tr -d '-' | tr A-F a-f | cut -c1-7)

#####################################
## Build WASM component (./src/wasm)
#####################################
cd wasm

# Fetch WASI dependencies
# see https://github.com/bytecodealliance/wasm-pkg-tools for more information about `wkg`
wkg fetch

# Use tinygo as it is specialized on WASM/WASI support
# standard go build supports WASI preview 1 only
# see https://github.com/tinygo-org/tinygo
tinygo build \
	-target=wasip2 \
	-no-debug \
	-gc=leaking \
	-scheduler=none \
 	--wit-package ./wit \
	--wit-world relusc:containerdays/simpleweb \
	-o main.wasm \
	.

# Push WASM module as OCI artifact into registry
wkg oci push --insecure="localhost:4000" localhost:4000/sample-app-wasm:"${IMAGE_TAG}" main.wasm

#####################################
## Deploy component
#####################################
export IMAGE_TAG

envsubst < ../../manifests/spin.yaml.tpl > ../../manifests/spin.yaml
kubectl apply -f ../../manifests/spin.yaml
