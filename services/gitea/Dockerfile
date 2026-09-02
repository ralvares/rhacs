FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG GITEA_VERSION=1.24.6

USER 0
RUN microdnf install -y ca-certificates curl git git-lfs openssh-clients && \
    microdnf clean all && \
    arch="$(uname -m)" && \
    case "$arch" in \
      x86_64) gitea_arch=amd64 ;; \
      aarch64) gitea_arch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://dl.gitea.com/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-${gitea_arch}" \
      -o /usr/local/bin/gitea && \
    chmod 0755 /usr/local/bin/gitea && \
    mkdir -p /data/gitea /data/git /etc/gitea && \
    chgrp -R 0 /data /etc/gitea && chmod -R g=u /data /etc/gitea

ENV USER=demo \
    HOME=/data/gitea \
    GITEA_WORK_DIR=/data/gitea

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/gitea"]
CMD ["web"]
