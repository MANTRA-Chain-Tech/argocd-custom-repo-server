# argocd-custom-repo-server Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the `argocd-custom-repo-server` across four independent areas: shell script resilience, Dockerfile reproducibility, plugin.yaml config quality, and README accuracy.

**Architecture:** Four independent file-level changes with no interdependencies. Each task modifies a single file and can be committed and validated on its own. No new files are created.

**Tech Stack:** Bash, Docker (Debian-based), Kustomize, ArgoCD CMP (v2.6+ sidecar model)

## Global Constraints

- Base image must remain `quay.io/argoproj/argocd:v3.4.4` — do not change
- Plugin name `kustomize-env-plugin` must not change (breaking for existing ApplicationSets)
- No CI/CD changes (out of scope)
- Script must run inside the ArgoCD sidecar container (Debian/Ubuntu-based, bash available)

---

### Task 1: Fix render-kustomize.sh — Error Propagation, Cleanup Trap, Atomic Substitution

**Files:**
- Modify: `render-kustomize.sh`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: a hardened script callable by the ArgoCD CMP `generate` phase; behavior-compatible with the original (same stdout output: rendered manifests)

- [ ] **Step 1: Replace render-kustomize.sh with the hardened version**

Replace the entire file with the following. Keep the existing GPL copyright header block (lines 1–17 of the current file) at the top, then replace everything after it:

```bash
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

VARS_TO_SUBSTITUTE=$(env | grep '^ARGOCD_ENV_' | sed -e 's/=.*//' -e 's/^/\$/g' | tr '\n' ' ')

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
```

**Key changes from original:**
- `#!/bin/bash` replaces `#!/bin/sh` — required for `set -o pipefail` and `< <(...)` process substitution
- `set -euo pipefail` replaces `set -e` — `-u` catches unset vars, `-o pipefail` catches pipe failures
- `STAGE_DIR` + `trap 'rm -rf "$STAGE_DIR"' EXIT` guarantees cleanup on any exit path
- All substitutions write to `$STAGE_DIR` first; copy-back only after all files succeed
- `while IFS= read -r ... done < <(find ...)` avoids the pipe-subshell `set -e` bypass

- [ ] **Step 2: Verify script syntax**

```bash
bash -n render-kustomize.sh
echo "PASS: syntax ok"
```

Expected output: `PASS: syntax ok` (exit code 0, no errors)

- [ ] **Step 3: Smoke-test substitution locally**

```bash
TESTDIR=$(mktemp -d)
cat > "$TESTDIR/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF
cat > "$TESTDIR/values.yaml" << 'EOF'
cluster: ${ARGOCD_ENV_CLUSTER}
EOF

SCRIPT=$(pwd)/render-kustomize.sh
cd "$TESTDIR"
export ARGOCD_ENV_CLUSTER=my-test-cluster
bash "$SCRIPT" >/dev/null 2>&1 || true

grep -q "cluster: my-test-cluster" values.yaml && echo "PASS: substitution worked" || echo "FAIL: substitution did not work"
cd - >/dev/null
rm -rf "$TESTDIR"
```

Expected output: `PASS: substitution worked`

- [ ] **Step 4: Verify cleanup trap removes temp dir on exit**

```bash
TESTDIR=$(mktemp -d)
cat > "$TESTDIR/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF

SCRIPT=$(pwd)/render-kustomize.sh
cd "$TESTDIR"
BEFORE=$(ls /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')
bash "$SCRIPT" >/dev/null 2>/dev/null || true
AFTER=$(ls /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')
cd - >/dev/null
rm -rf "$TESTDIR"

[ "$BEFORE" -eq "$AFTER" ] && echo "PASS: no temp dirs leaked" || echo "FAIL: temp dirs were leaked (before=$BEFORE, after=$AFTER)"
```

Expected output: `PASS: no temp dirs leaked`

- [ ] **Step 5: Commit**

```bash
git add render-kustomize.sh
git commit -m "fix: harden render-kustomize.sh with bash, pipefail, staged substitution, and cleanup trap"
```

---

### Task 2: Harden Dockerfile — OCI Labels, Pinned Package, ARG vs ENV

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: a Dockerfile that builds an OCI-labelled image with pinned dependencies and correct ARG/ENV usage

- [ ] **Step 1: Determine the exact gettext-base version available in the base image**

```bash
docker run --rm quay.io/argoproj/argocd:v3.4.4 apt-cache show gettext-base | grep '^Version:' | head -1
```

Note the version string exactly as printed (e.g., `0.21-12`). You will use it in Step 2.

- [ ] **Step 2: Replace Dockerfile with the hardened version**

Replace the entire file content with the following, substituting `<GETTEXT_VERSION>` with the exact version string obtained in Step 1:

```dockerfile
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

FROM quay.io/argoproj/argocd:v3.4.4

ARG VERSION=dev
ARG COMMIT=unknown
ARG ARGOCD_USER_ID=999

LABEL org.opencontainers.image.title="argocd-custom-repo-server" \
      org.opencontainers.image.description="ArgoCD CMP for envsubst-enhanced Kustomize builds" \
      org.opencontainers.image.source="https://github.com/MANTRA-Chain-Tech/argocd-custom-repo-server" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.licenses="GPL-3.0"

USER root

# Pin gettext-base to a specific version for reproducible builds.
RUN apt-get update && \
    apt-get install -y gettext-base=<GETTEXT_VERSION> && \
    rm -rf /var/lib/apt/lists/*

COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
COPY render-kustomize.sh /usr/local/bin/render-kustomize.sh
RUN chmod +x /usr/local/bin/render-kustomize.sh

USER $ARGOCD_USER_ID
```

**Key changes from original:**
- `ENV ARGOCD_USER_ID=999` → `ARG ARGOCD_USER_ID=999` — build-time only; not leaked into runtime environment
- `ARG VERSION`, `ARG COMMIT` — consumed by `LABEL` block; populated by CI via `--build-arg`
- OCI-standard `LABEL` block for image provenance (version, commit, source, license)
- `gettext-base=<GETTEXT_VERSION>` — pinned for reproducible builds

- [ ] **Step 3: Build the image locally to verify**

```bash
docker build \
  --build-arg VERSION=test \
  --build-arg COMMIT=$(git rev-parse --short HEAD) \
  -t argocd-custom-repo-server:test \
  .
```

Expected: build completes with exit code 0, no errors in output

- [ ] **Step 4: Verify OCI labels are present on the built image**

```bash
docker inspect argocd-custom-repo-server:test \
  --format '{{json .Config.Labels}}' | python3 -m json.tool
```

Expected: JSON output includes all six `org.opencontainers.image.*` labels with non-empty values

- [ ] **Step 5: Verify ARGOCD_USER_ID is not present as a runtime environment variable**

```bash
docker run --rm argocd-custom-repo-server:test env | grep ARGOCD_USER_ID \
  && echo "FAIL: variable leaked into runtime env" \
  || echo "PASS: ARGOCD_USER_ID not in runtime env"
```

Expected output: `PASS: ARGOCD_USER_ID not in runtime env`

- [ ] **Step 6: Commit**

```bash
git add Dockerfile
git commit -m "fix: pin gettext-base version, add OCI labels, use ARG for build-time UID"
```

---

### Task 3: Improve plugin.yaml — Init Diagnostics and Tighter Discovery

**Files:**
- Modify: `plugin.yaml`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: an improved CMP plugin config — init logs dependency versions, discovery validates exactly one kustomization file exists

- [ ] **Step 1: Replace plugin.yaml with the improved version**

Replace the entire file content with:

```yaml
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

apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: kustomize-env-plugin
spec:
  init:
    command: [sh]
    args:
      - -c
      - |
        echo "--- kustomize-env-plugin init ---"
        kustomize version
        envsubst --version
        echo "--- init complete ---"
  discover:
    find:
      command:
        - sh
        - -c
        - |
          set -e
          count=$(find . -maxdepth 1 -iname 'kustomization.y*ml' | wc -l | tr -d ' ')
          if [ "$count" -ne 1 ]; then
            echo "kustomize-env-plugin: expected exactly 1 kustomization file, found ${count}" >&2
            exit 1
          fi
          find . -maxdepth 1 -iname 'kustomization.y*ml'
  generate:
    command: ["render-kustomize.sh"]
```

**Key changes from original:**
- `init`: now runs `kustomize version` and `envsubst --version`, making dependency versions visible in ArgoCD sidecar logs on startup
- `discover`: validates `count == 1` before returning the file path; exits non-zero (causing discovery to fail explicitly) if no file or multiple files exist; `tr -d ' '` strips leading whitespace that `wc -l` produces on some systems
- `generate`: unchanged

Note: A `parameters` block is intentionally omitted. This plugin accepts arbitrary `ARGOCD_ENV_*` variables by naming convention; a static parameters list would falsely imply only listed vars are accepted. The convention is documented in README instead.

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('plugin.yaml')); print('PASS: valid YAML')"
```

Expected output: `PASS: valid YAML`

- [ ] **Step 3: Verify init and discover commands are structurally correct**

```bash
python3 - << 'EOF'
import yaml
doc = yaml.safe_load(open('plugin.yaml'))
spec = doc['spec']
assert doc['apiVersion'] == 'argoproj.io/v1alpha1', "wrong apiVersion"
assert doc['kind'] == 'ConfigManagementPlugin', "wrong kind"
assert doc['metadata']['name'] == 'kustomize-env-plugin', "plugin name changed"
init_script = spec['init']['args'][1]
assert 'kustomize version' in init_script, "kustomize version missing from init"
assert 'envsubst --version' in init_script, "envsubst --version missing from init"
discover_script = spec['discover']['find']['command'][2]
assert 'wc -l' in discover_script, "wc -l missing from discover"
assert 'tr -d' in discover_script, "tr -d missing from discover"
assert 'exit 1' in discover_script, "exit 1 missing from discover"
print('PASS: structure verified')
EOF
```

Expected output: `PASS: structure verified`

- [ ] **Step 4: Commit**

```bash
git add plugin.yaml
git commit -m "fix: improve plugin.yaml init diagnostics and tighten kustomization discovery"
```

---

### Task 4: Update README.md — Correct CMP Registration, Sync Script, Add Troubleshooting

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: an accurate README with correct sidecar CMP setup, current script example, and troubleshooting guidance

- [ ] **Step 1: Replace "### 2. Configure Argo CD" section**

Find and replace the entire "### 2. Configure Argo CD" section (currently showing the deprecated `argocd-cm configManagementPlugins` approach) with the following:

```markdown
### 2. Configure Argo CD

Deploy the custom image as a **sidecar container** on the `argocd-repo-server` Deployment. This is the supported CMP installation method for ArgoCD v2.6+. The deprecated `configManagementPlugins` field in `argocd-cm` is no longer supported.

**A. Create a ConfigMap for the plugin configuration**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kustomize-env-plugin
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: kustomize-env-plugin
    spec:
      init:
        command: [sh]
        args: [-c, "kustomize version && envsubst --version"]
      discover:
        find:
          command: ["sh", "-c", "find . -maxdepth 1 -iname 'kustomization.y*ml' | head -n 1"]
      generate:
        command: ["render-kustomize.sh"]
```

Apply it:

```bash
kubectl apply -f kustomize-env-plugin-configmap.yaml
```

**B. Patch `argocd-repo-server` to add the sidecar**

Add this sidecar container entry to the `argocd-repo-server` Deployment under `spec.template.spec.containers`:

```yaml
- name: kustomize-env-plugin
  image: <your-registry>/argocd-custom-repo-server:<tag>
  command: [/var/run/argocd/argocd-cmp-server]
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
  volumeMounts:
    - name: var-files
      mountPath: /var/run/argocd
    - name: plugins
      mountPath: /home/argocd/cmp-server/plugins
    - name: kustomize-env-plugin-config
      mountPath: /home/argocd/cmp-server/config
```

Add this volume entry under `spec.template.spec.volumes`:

```yaml
- name: kustomize-env-plugin-config
  configMap:
    name: kustomize-env-plugin
```

The `var-files` and `plugins` volumes already exist on the default `argocd-repo-server` Deployment.

For the complete sidecar CMP reference, see the [official ArgoCD documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/#installing-a-cmp).
```

- [ ] **Step 2: Sync the script example in the "📜 The Plugin Script" section**

Find the `## 📜 The Plugin Script` section. The code block there shows an outdated version of the script. Replace the script code block with the current content of `render-kustomize.sh` as it now exists after Task 1.

- [ ] **Step 3: Add Troubleshooting section before "## 📄 License"**

Insert the following section immediately before `## 📄 License`:

```markdown
## 🔧 Troubleshooting

**Variables are not being substituted**

ArgoCD automatically prefixes all plugin env vars with `ARGOCD_ENV_`. If your ApplicationSet passes `CLUSTER_NAME`, the script receives `ARGOCD_ENV_CLUSTER_NAME`. Reference it in your YAML files as `${ARGOCD_ENV_CLUSTER_NAME}`.

**Plugin is not discovered for my application**

The plugin activates only when exactly one `kustomization.yaml` or `kustomization.yml` exists in the application's configured source path (root of the path, not subdirectories). Verify the `source.path` in your Application or ApplicationSet points to the directory containing the kustomization file.

**How to read plugin logs**

```bash
kubectl logs -n argocd \
  -l app.kubernetes.io/name=argocd-repo-server \
  -c kustomize-env-plugin \
  --tail=50
```

**`kustomize build` fails with Helm-related errors**

The script runs `kustomize build . --enable-helm`. Ensure Helm is available in the sidecar container. The base ArgoCD image bundles Helm — verify your image is built `FROM quay.io/argoproj/argocd:*` and that the version supports the Helm charts you are using.
```

- [ ] **Step 4: Verify stale content is removed**

```bash
grep -n "configManagementPlugins" README.md \
  && echo "FAIL: old registration method still referenced" \
  || echo "PASS: deprecated method removed"

grep -n "kustomization.tmp.yaml" README.md \
  && echo "FAIL: old script example still present" \
  || echo "PASS: old script example removed"
```

Expected: both lines print `PASS`

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README with sidecar CMP setup, sync script example, add troubleshooting"
```
