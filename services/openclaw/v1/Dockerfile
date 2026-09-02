# Intentionally affected OpenClaw release. Build and scan it; never run it.
# openclaw@2026.2.13 is affected by the Critical host-environment supply-chain
# redirection issue fixed in openclaw@2026.3.22. The demo detects but never exploits it.
FROM registry.access.redhat.com/ubi9/nodejs-22:latest
LABEL org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/nodejs-22:latest" \
      demo.rhacs.ai/base-image-owner="platform-engineering" \
      demo.rhacs.ai/application-owner="ai-email-demo" \
      demo.rhacs.ai/release="v1-scan-only" \
      demo.rhacs.ai/do-not-deploy="true"
WORKDIR /opt/app-root/src
COPY v1/package.json v1/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
CMD ["node", "-e", "console.error('scan-only v1 image: deployment is intentionally disabled'); process.exit(1)"]
