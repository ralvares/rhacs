FROM registry.access.redhat.com/ubi9/nodejs-22:latest
LABEL org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/nodejs-22:latest" \
      demo.rhacs.ai/base-image-owner="ai-platform" \
      demo.rhacs.ai/application-owner="ai-email-demo"

USER 0
RUN python3 --version && curl --version
WORKDIR /opt/openclaw
COPY v2/package.json v2/package-lock.json ./
RUN npm ci --omit=dev && \
    cp -a node_modules/openclaw/. /opt/openclaw/ && \
    chmod 0755 ./openclaw.mjs
COPY v2/patch-presentation-ui.mjs /tmp/patch-presentation-ui.mjs
RUN node /tmp/patch-presentation-ui.mjs && rm -f /tmp/patch-presentation-ui.mjs
COPY workspace/ /opt/openclaw-workspace/
RUN chmod -R a+rX /opt/openclaw /opt/openclaw-workspace && \
    chgrp -R 0 /opt/openclaw /opt/openclaw-workspace && \
    chmod -R g=u /opt/openclaw /opt/openclaw-workspace
USER 1001
