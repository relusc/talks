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
IMAGE_TAG=$(uuidgen | tr -d '-' | tr A-F a-f | cut -c1-7)

###################################################
## Build traditional container image (./src/native)
###################################################
cd native

CGO_ENABLED=0 GOOS=linux GOARCH="arm64" go build -ldflags="-s -w" -trimpath -o main .

docker build -t localhost:4000/sample-app-container:"${IMAGE_TAG}" .

docker push localhost:4000/sample-app-container:"${IMAGE_TAG}"

#####################################
## Deploy image
#####################################
export IMAGE_TAG

envsubst < ../../manifests/container.yaml.tpl > ../../manifests/container.yaml
kubectl apply -f ../../manifests/container.yaml
