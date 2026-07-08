#!/bin/bash

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

set -euo pipefail

# Redirect all echo statements to stderr for logging purposes.
echo "--- Running Kustomize Renderer Plugin ---" >&2

VARS_TO_SUBSTITUTE=$(env | grep '^ARGOCD_ENV_' | sed -e 's/=.*//' -e 's/^/\$/g' | tr '\n' ' ') || true

if [ -n "$VARS_TO_SUBSTITUTE" ]; then
    echo "Found variables to substitute: ${VARS_TO_SUBSTITUTE}" >&2
else
    echo "No ARGOCD_ENV_ variables found to substitute." >&2
fi

# Create a staging directory; trap ensures it is removed on any exit (success or failure).
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "--- Staging all YAML files for environment substitution ---" >&2

# Process substitution avoids the `find | while` pipe, which would swallow errors from set -e.
# IFS= read -r handles filenames with spaces correctly.
while IFS= read -r file; do
    rel="${file#./}"
    stage_file="$STAGE_DIR/$rel"
    mkdir -p "$(dirname "$stage_file")"
    envsubst "${VARS_TO_SUBSTITUTE}" < "$file" > "$stage_file"
    echo "Staged: $rel" >&2
done < <(find . -type f \( -name "*.yaml" -o -name "*.yml" \))

# Copy substituted files back only after ALL files have been successfully staged.
# This ensures either all substitutions apply or none do (rollback semantics).
echo "--- Copying substituted files back ---" >&2
while IFS= read -r file; do
    rel="${file#./}"
    cp "$STAGE_DIR/$rel" "$file"
done < <(find . -type f \( -name "*.yaml" -o -name "*.yml" \))

echo "--- Building manifests from processed files ---" >&2
kustomize build . --enable-helm
echo "--- Kustomize Renderer Plugin Finished ---" >&2