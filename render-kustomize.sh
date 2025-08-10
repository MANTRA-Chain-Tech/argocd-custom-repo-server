#!/bin/sh
set -e

# Redirect all echo statements to stderr, so they appear in logs but not in the final output.
echo "--- Running Kustomize Renderer Plugin ---" >&2
echo "Received Cluster Name: $ARGOCD_ENV_CLUSTER_NAME" >&2

KUSTOMIZATION_FILE=$(find . -maxdepth 1 -iname 'kustomization.y*ml' | head -n 1)

if [ -z "$KUSTOMIZATION_FILE" ]; then
  echo "Error: No kustomization.yaml or kustomization.yml found." >&2
  exit 1
fi

echo "Found kustomization file: $KUSTOMIZATION_FILE" >&2

cat "$KUSTOMIZATION_FILE" | envsubst > kustomization.tmp.yaml

mv kustomization.tmp.yaml "$KUSTOMIZATION_FILE"

echo "--- Building manifests from processed kustomization file ---" >&2
# The final output of this command is the only thing sent to stdout
kustomize build . --enable-helm

echo "--- Kustomize Renderer Plugin Finished ---" >&2