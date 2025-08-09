#!/bin/sh
# Exit immediately if a command fails.
set -e

echo "--- Running Kustomize Renderer Plugin ---"

KUSTOMIZATION_FILE=$(find . -maxdepth 1 -iname 'kustomization.y*ml' | head -n 1)

if [ -z "$KUSTOMIZATION_FILE" ]; then
  echo "Error: No kustomization.yaml or kustomization.yml found."
  exit 1
fi

echo "Found kustomization file: $KUSTOMIZATION_FILE"

cat "$KUSTOMIZATION_FILE" | envsubst > kustomization.tmp.yaml

mv kustomization.tmp.yaml "$KUSTOMIZATION_FILE"

echo "--- Building manifests from processed kustomization file ---"
kustomize build . --enable-helm

echo "--- Kustomize Renderer Plugin Finished ---"