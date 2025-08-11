#!/bin/sh
set -e

# Redirect all echo statements to stderr for logging purposes.
echo "--- Running Kustomize Renderer Plugin ---" >&2

VARS_TO_SUBSTITUTE=$(env | grep '^ARGOCD_ENV_' | sed -e 's/=\(.*\)//' -e 's/^/\$/g' | tr '\n' ' ')

if [ -n "$VARS_TO_SUBSTITUTE" ]; then
    echo "Found variables to substitute: ${VARS_TO_SUBSTITUTE}" >&2
else
    echo "No ARGOCD_ENV_ variables found to substitute." >&2
fi

echo "--- Finding and processing all YAML files for environment substitution ---" >&2
find . -type f \( -name "*.yaml" -o -name "*.yml" \) | while IFS= read -r file; do
  echo "Processing file: $file" >&2
  tmp_file=$(mktemp)
  envsubst "${VARS_TO_SUBSTITUTE}" < "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
done

echo "--- Building manifests from processed files ---" >&2
kustomize build . --enable-helm
echo "--- Kustomize Renderer Plugin Finished ---" >&2