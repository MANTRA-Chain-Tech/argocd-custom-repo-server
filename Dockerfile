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

FROM quay.io/argoproj/argocd:v2.12.3

USER root

ENV ARGOCD_USER_ID=999

# Install envsubst utility
RUN apt-get update && \
    apt-get install -y gettext-base && \
    rm -rf /var/lib/apt/lists/*

COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
COPY render-kustomize.sh /usr/local/bin/render-kustomize.sh
RUN chmod +x /usr/local/bin/render-kustomize.sh

USER $ARGOCD_USER_ID