#!/bin/sh

# Copyright (C) 2025 MANTRA Chain Tech
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

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