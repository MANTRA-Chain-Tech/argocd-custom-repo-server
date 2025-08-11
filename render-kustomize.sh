#!/bin/sh
set -e

# Redirect all echo statements to stderr for logging purposes
echo "--- Running Kustomize Renderer Plugin ---" >&2
echo "Received Cluster Name: $ARGOCD_ENV_CLUSTER_NAME" >&2

# Find all .yaml and .yml files in the current directory and all subdirectories
echo "--- Finding and processing all YAML files for environment substitution ---" >&2
find . -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 | while IFS= read -r -d '' file; do
  echo "Processing file: $file" >&2
  tmp_file=$(mktemp)
  cat "$file" | envsubst > "$tmp_file"
  mv "$tmp_file" "$file"
done

echo "--- Building manifests from processed files ---" >&2
kustomize build . --enable-helm
echo "--- Kustomize Renderer Plugin Finished ---" >&2