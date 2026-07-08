# Hardening Design: argocd-custom-repo-server

**Date:** 2026-07-08  
**Scope:** Full Hardening (Option B) — resilience, security, config quality, documentation accuracy  
**CI/CD:** Excluded from scope (per user decision)

---

## 1. Overview

This document captures the proposed improvements for the `argocd-custom-repo-server` repository. The project is a small, focused ArgoCD Config Management Plugin (CMP) that enables `envsubst`-based environment variable substitution in Kustomize manifests. Despite its small surface area, several issues exist across the shell script, Dockerfile, plugin config, and README.

---

## 2. render-kustomize.sh — Resilience & Safety

### Problems

**Error swallowing in `find | while` pipe:**  
In POSIX `sh`, `set -e` does not apply inside the body of a `while` loop that reads from a pipe. A failed `envsubst` or `mv` command inside the loop is silently ignored. The script gives a false impression of safety via `set -e` at the top.

**No cleanup trap:**  
`mktemp` creates temporary files. If the script exits mid-loop (due to a non-pipe error), these temp files are orphaned. In a long-running CMP sidecar that syncs many apps, this could accumulate disk usage.

**In-place mutation without rollback:**  
Files are substituted in-place (write to temp, `mv` back). If substitution succeeds on some files and then fails on others, the working directory is left in a partially-mutated state. There is no mechanism to restore the originals.

### Proposed Changes

1. **Replace `find | while` with a `while IFS= read -r` loop** over process substitution, so `set -e` applies to each `envsubst` and `mv` call and file paths with spaces are handled correctly:
   ```sh
   while IFS= read -r file; do
     ...
   done < <(find . -type f \( -name "*.yaml" -o -name "*.yml" \))
   ```
   Note: `< <(...)` process substitution requires bash; the script shebang is `#!/bin/sh`. Either switch the shebang to `#!/bin/bash` or capture `find` output to a temp file for strict POSIX compliance.

2. **Add a cleanup trap** using a temp directory:
   ```sh
   TMPDIR_WORK=$(mktemp -d)
   trap 'rm -rf "$TMPDIR_WORK"' EXIT
   ```

3. **Stage-then-commit substitution:** Write all substituted files into `$TMPDIR_WORK` first. Only copy back to the working directory after all files are processed successfully. This ensures either all substitutions apply or none do.

---

## 3. Dockerfile — Hygiene & Reproducibility

### Problems

**No OCI image labels:**  
The image has no `LABEL` metadata. Registries, audit tools, and operators have no way to determine the image version, source repository, or maintainer from the image itself.

**Unpinned `apt-get` package:**  
`apt-get install -y gettext-base` installs whatever version is available in the Debian repos at build time. Builds on different days may silently pick up different `envsubst` binary versions, breaking reproducibility. This is a supply chain hygiene issue.

**`ENV` used where `ARG` is correct:**  
`ENV ARGOCD_USER_ID=999` sets a runtime environment variable, but this value is only used at build time (`USER $ARGOCD_USER_ID`). Using `ENV` unnecessarily exposes an internal implementation detail in the image's environment at runtime.

### Proposed Changes

1. **Add OCI-standard LABEL block** using build-time `ARG`s:
   ```dockerfile
   ARG VERSION=dev
   ARG COMMIT=unknown
   LABEL org.opencontainers.image.title="argocd-custom-repo-server" \
         org.opencontainers.image.description="ArgoCD CMP for envsubst-enhanced Kustomize" \
         org.opencontainers.image.source="https://github.com/MANTRA-Chain-Tech/argocd-custom-repo-server" \
         org.opencontainers.image.version="${VERSION}" \
         org.opencontainers.image.revision="${COMMIT}" \
         org.opencontainers.image.licenses="GPL-3.0"
   ```

2. **Pin the `gettext-base` package** to a specific version:
   ```dockerfile
   RUN apt-get update && \
       apt-get install -y gettext-base=0.21-12 && \
       rm -rf /var/lib/apt/lists/*
   ```
   (Exact version should be confirmed against the base image's Debian release.)

3. **Change `ENV ARGOCD_USER_ID` to `ARG ARGOCD_USER_ID`** to avoid leaking it as a runtime env var.

---

## 4. plugin.yaml — Config Quality

### Problems

**`init` command is a no-op:**  
The init phase logs `"Initializing kustomize-env-plugin"` and exits. This is useless for debugging. The init phase runs once per plugin sidecar connection and is the ideal place to surface dependency version information in logs.

**No `parameters` schema:**  
ArgoCD v2.6+ supports documenting expected plugin parameters via `spec.parameters`. Without this, operators have no ArgoCD-native way to discover what env vars the plugin expects; they must read the script source.

**Discovery fails silently on edge cases:**  
`find . -maxdepth 1 -iname 'kustomization.y*ml' | head -n 1` returns zero output (and exit 0) if no kustomization file exists. This would cause plugin discovery to silently fail rather than report an error. The `head -n 1` also silently ignores duplicates.

### Proposed Changes

1. **Make `init` emit useful diagnostic information:**
   ```yaml
   init:
     command: [sh]
     args:
       - -c
       - |
         echo "--- kustomize-env-plugin init ---"
         kustomize version
         envsubst --version
         echo "--- init complete ---"
   ```

2. **Add a `parameters` section** with a note documenting the `ARGOCD_ENV_*` convention. (Since this plugin uses arbitrary env vars by convention rather than declared params, a static example with a description comment is appropriate.)

3. **Tighten the `discover` command** to validate exactly one kustomization file exists:
   ```yaml
   discover:
     find:
       command:
         - sh
         - -c
         - |
           set -e
           count=$(find . -maxdepth 1 -iname 'kustomization.y*ml' | wc -l | tr -d ' ')
           if [ "$count" -ne 1 ]; then exit 1; fi
           find . -maxdepth 1 -iname 'kustomization.y*ml'
   ```

---

## 5. README.md — Documentation Accuracy

### Problems

**Outdated plugin registration method:**  
Section "B. Register the Config Management Plugin" instructs operators to add `configManagementPlugins` to the `argocd-cm` ConfigMap. This approach was deprecated in ArgoCD v2.6 and removed in later versions. The project itself correctly uses the sidecar CMP approach, but the README teaches the old method.

**Script example in README doesn't match actual script:**  
The README shows an old version of `render-kustomize.sh` that substitutes only `kustomization.yaml` and uses `kustomize build . -f kustomization.tmp.yaml`. The actual script now processes all YAML files in the directory and uses `kustomize build . --enable-helm`. Operators debugging sync issues would be misled.

**No troubleshooting section:**  
There is no guidance on common failure modes.

### Proposed Changes

1. **Replace the `argocd-cm` registration section** with the correct sidecar CMP deployment approach: configuring the ArgoCD repo-server deployment to include this image as a sidecar container with the appropriate `plugin.yaml` volume mount. Reference the official ArgoCD CMP sidecar documentation.

2. **Sync the README script example** with the actual current `render-kustomize.sh` content, ensuring the documented and actual behavior match.

3. **Add a Troubleshooting section** covering:
   - Why variables aren't being substituted (missing `ARGOCD_ENV_` prefix)
   - How ArgoCD prefixes ApplicationSet plugin env vars
   - How to read plugin logs (`kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c kustomize-env-plugin`)
   - What discovery failure looks like in ArgoCD UI

---

## 6. Implementation Order

Changes are independent across files and can be applied in any order, but the following sequence is recommended to allow incremental testing:

1. `render-kustomize.sh` — highest impact on correctness; testable locally with a mock directory
2. `plugin.yaml` — low risk; makes debugging easier immediately
3. `Dockerfile` — reproducibility; requires confirming `gettext-base` version in the base image
4. `README.md` — documentation only; no runtime impact

---

## 7. Out of Scope

- CI/CD pipeline changes (excluded per user decision)
- BATS test harness for `render-kustomize.sh` (deferred to a follow-up)
- Kustomize version pinning (managed by the upstream ArgoCD base image)
