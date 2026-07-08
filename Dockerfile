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
    apt-get install -y gettext-base=0.23.1-2build2 && \
    rm -rf /var/lib/apt/lists/*

COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
COPY render-kustomize.sh /usr/local/bin/render-kustomize.sh
RUN chmod +x /usr/local/bin/render-kustomize.sh

USER $ARGOCD_USER_ID