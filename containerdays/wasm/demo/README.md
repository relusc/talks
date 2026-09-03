# WASM on Kubernetes demo

This setup runs on a local [`kind`](https://kind.sigs.k8s.io/) cluster and uses [`SpinKube`](https://www.spinkube.dev/) to run WASM components on it.

## Structure

There are three main folders:

- [`cluster`](./cluster/): All assets needed for provisioning the demo cluster
- [`sample-app`](./sample-app/): Contains a Golang webserver implemented the traditional container image (`native` subdirectory) way and the WASM component way (`wasm` subdirectory)
- [`scripts`](./scripts/): Utility scripts used during the live showcase

## Run it

- Run [./cluster/setup.sh](./cluster/setup.sh) to setup the local kind cluster with SpinKube, the local registry and the container webserver. Inspect the script for more details.
- Execute [./sample-app/src/deploy_container.sh](./sample-app/src/deploy_container.sh) to build the "traditional" container image for the webserver and deploy it as `Deployment`
- Execute [./sample-app/src/deploy_wasm.sh](./sample-app/src/deploy_wasm.sh) to build the WASM component and to deploy it as `SpinApp`
- Run the [scripts](./scripts/) to replay the demo showcases and to check artifact sizes and startup times
