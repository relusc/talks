apiVersion: core.spinkube.dev/v1alpha1
kind: SpinApp
metadata:
  name: wasm-webserver
spec:
  image: localhost:4000/sample-app-wasm:${IMAGE_TAG}
  replicas: 1
  executor: containerd-shim-spin
