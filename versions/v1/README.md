# OpenClaw release candidate

This is the only dependency candidate used by the demonstration pipeline.

- Opening version: `openclaw@2026.2.13`
- Remediation target: `openclaw@2026.8.2`

'''
{
  "name": "rhacs-ai-demo-agent-runtime",
  "private": true,
  "version": "1.0.1",
  "dependencies": {
    "openclaw": "2026.8.2"
  },
  "overrides": {
    "openclaw": {
      "p-limit": "7.3.1"
    }
  }
}
'''

During the presentation, update `package.json` and `package-lock.json` in this
directory from the opening version to the remediation target. Commit and push
that in-place change. The pipeline builds this same v1 candidate, generates an
SBOM from the resulting image, signs its digest, applies the RHACS gates, and
promotes the approved digest as `openclaw:v1` and `openclaw:latest`.

There is no v2 source or v2 pipeline path.
