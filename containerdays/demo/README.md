# ContainerDays demo - cosign

This folder contains the demo setup shown in the ContainerDays talk. The test scenario is running on a local `kind` cluster. [`colima`](https://github.com/abiosoft/colima) is used to be able to run `docker`.

The setup is split up into three folders:

- `kyverno`: includes a Kyverno `ClusterPolicy` to verify the signature of images
- `sample-app`: contains the code and Dockerfile of the sample app that displays the pod name
- `setup`: contains all files necessary for setting up the test scenario

## Running the test cases

Just execute the `./setup/setup.sh` script. This will start colima, create the `kind` cluster, install Kyverno and initiate a login to `ghcr.io`.

Afterwards, you can build and push the sample app to your personal GitHub Container registry as well as try to replay the test scenarios with `cosign`:

- signing with and without key
- push a change to the app which triggers the GitHub Actions pipeline (make sure to change the registry locally, as you cannot push into my personal registry :wink: )
- verify images using the `Kvyerno` policy
