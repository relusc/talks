#!/bin/bash

set -euo pipefail

kubectl create secret docker-registry ghcr --docker-username=relusc --docker-password="$(cat ./demo/scripts/gittoken)" --docker-server=ghcr.io

kubectl apply -f ./demo/scripts/svc-acc.yaml
