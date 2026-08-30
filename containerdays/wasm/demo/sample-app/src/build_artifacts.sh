#!/bin/bash

#########################################################################
## Builds the sample webserver application located in ./src as
## - WASM module
## - container image
## 
## Both the image are pushed as OCI artifacts into the registry
#########################################################################

set -euo pipefail

# Generate random image tag
image_tag=$(uuidgen | tr -d '-' | tr A-F a-f | cut -c1-7)

###################################################
## Build traditional container image (./src/native)
###################################################
cd native

CGO_ENABLED=0 GOOS=linux GOARCH="arm64" go build -ldflags="-s -w" -trimpath -o main .

docker build -t localhost:5000/sample-app-container:"${image_tag}" .

docker push localhost:5000/sample-app-container:"${image_tag}"

#####################################
## Build WASM component (./src/wasm)
#####################################
cd ../wasm

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
wkg oci push --insecure="localhost:5000" localhost:5000/sample-app-wasm:"${image_tag}" main.wasm
