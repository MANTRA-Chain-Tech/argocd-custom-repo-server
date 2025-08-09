FROM quay.io/argoproj/argocd:v2.12.3

USER root

ENV ARGOCD_USER_ID=999

# Install envsubst utility
RUN apt-get update && \
    apt-get install -y gettext-base && \
    rm -rf /var/lib/apt/lists/*

COPY render-kustomize.sh /usr/local/bin/render-kustomize.sh
RUN chmod +x /usr/local/bin/render-kustomize.sh

USER $ARGOCD_USER_ID