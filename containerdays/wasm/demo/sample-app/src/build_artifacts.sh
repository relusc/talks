#!/bin/bash

set -euo pipefail

image_tag=$(uuidgen | tr -d '-' | cut -c1-7)

cd wasm

wkg fetch --config wkg-config.toml

go generate ./...

# Use tinygo as it is specialized on WASM/WASI support
# standard go build supports WASI preview 1 only
tinygo build \
	-target=wasip2 \
	-no-debug \
	--wit-package ./wit \
	--wit-world relusc:containerdays/simpleweb \
	-o main.wasm \
	.

# Push WASM module as OCI artifact into registry
wkg oci push --insecure="localhost:5000" localhost:5000/sample-app-wasm:"${image_tag}" main.wasm

cd ../native

# Build "standard" container
docker build -t localhost:5000/sample-app-container:"${image_tag}" .

docker push localhost:5000/sample-app-container:"${image_tag}"
