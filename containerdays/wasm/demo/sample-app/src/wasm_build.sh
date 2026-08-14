#!/bin/bash

set -euo pipefail

GOOS=wasip1 GOARCH=wasm go build -o main.wasm

wkg oci push localhost:3000/wasm-sample-app:$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 7) main.wasm
