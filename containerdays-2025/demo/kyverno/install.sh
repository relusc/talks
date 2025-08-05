#!/bin/bash

# Complex setup script: install Kyverno via Helm
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
