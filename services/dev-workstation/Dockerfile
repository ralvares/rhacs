FROM quay.io/stackrox-io/roxctl:4.11.3 AS roxctl
FROM ghcr.io/sigstore/cosign/cosign:v2.4.3 AS cosign
FROM docker.io/anchore/syft:v1.30.0 AS syft

FROM registry.redhat.io/devspaces/udi-rhel9:latest
USER 0
COPY --from=roxctl /usr/bin/roxctl /usr/local/bin/roxctl
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY --from=syft /syft /usr/local/bin/syft
COPY services/dev-workstation/kustomize /usr/local/bin/kustomize
COPY scripts/rhacs/alias.sh /etc/profile.d/rhacs-demo.sh
RUN chmod 0755 /usr/local/bin/roxctl /usr/local/bin/cosign /usr/local/bin/syft /usr/local/bin/kustomize && \
    chmod 0644 /etc/profile.d/rhacs-demo.sh
COPY services/mail-api/requirements.txt /tmp/demo-python-requirements.txt
RUN python3 -m venv /opt/demo-venv && \
    /opt/demo-venv/bin/python -m pip install --no-cache-dir -r /tmp/demo-python-requirements.txt && \
    chmod -R a+rX /opt/demo-venv && \
    rm -f /tmp/demo-python-requirements.txt
COPY services/openclaw/v1/package.json services/openclaw/v1/package-lock.json /tmp/demo-node/v1/
RUN cd /tmp/demo-node/v1 && npm ci --omit=dev --ignore-scripts && \
    mkdir -p /tmp/demo-node/maintained && cd /tmp/demo-node/maintained && \
    npm install --omit=dev --ignore-scripts --no-save openclaw@2026.8.2 && \
    mkdir -p /opt/demo-dependencies && \
    mv /tmp/demo-node/v1/node_modules /opt/demo-dependencies/openclaw-2026.2.13 && \
    mv /tmp/demo-node/maintained/node_modules /opt/demo-dependencies/openclaw-2026.8.2 && \
    chmod -R a+rX /opt/demo-dependencies && rm -rf /tmp/demo-node
USER 1001
ENV PATH="/opt/demo-venv/bin:${PATH}" \
    NPM_CONFIG_CACHE=/tmp/npm-cache
