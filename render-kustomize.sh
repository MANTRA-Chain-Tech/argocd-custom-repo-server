#!/bin/sh
# Exit immediately if a command fails.
set -e

echo "--- Starting Kustomize CMP ---"

# Use envsubst to replace variables in the kustomization file
# and create a temporary, processed version.
envsubst < kustomization.yaml > kustomization.tmp.yaml

echo "--- Generated temporary kustomization file ---"
cat kustomization.tmp.yaml
echo "------------------------------------------"

# Tell kustomize to build using the temporary file.
kustomize build . -f kustomization.tmp.yaml

echo "--- Kustomize CMP Finished ---"