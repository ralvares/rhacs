# Intentionally affected opening release for the remediation demonstration.
# It runs the normal mailbox workload; the disclosed flaw is never exercised.
FROM registry.access.redhat.com/ubi9/nodejs-22:latest
LABEL org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/nodejs-22:latest" \
      demo.rhacs.ai/base-image-owner="platform-engineering" \
      demo.rhacs.ai/application-owner="ai-email-demo" \
      demo.rhacs.ai/release="v1-remediation-start"

USER 0
RUN python3 --version && curl --version
WORKDIR /opt/openclaw
COPY v1/package.json v1/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && \
    cp -a node_modules/openclaw/. /opt/openclaw/ && \
    chmod 0755 ./openclaw.mjs
COPY workspace/ /opt/openclaw-workspace/
RUN chmod -R a+rX /opt/openclaw /opt/openclaw-workspace && \
    chgrp -R 0 /opt/openclaw /opt/openclaw-workspace && \
    chmod -R g=u /opt/openclaw /opt/openclaw-workspace
USER 1001
