# Dev Spaces and OpenShift Pipelines rehearsal — 2 September 2026

## Scope

This report records the live CRC verification of the browser-first delivery act. It does not replace the runtime evidence in `reports/rehearsal-2026-08-31/REPORT.md`.

## Opening proof

- `make demo-reset` removed old PipelineRuns, TaskRuns, and Tekton Results without reinstalling RHACS.
- Gitea was recreated with one SSH-signed seed commit containing exact `openclaw@2026.2.13`.
- Dev Spaces reached `Running` with the repository checked out in `/projects/demo-app`.
- The `developer` user could see `ai-email-demo`, `demo-platform`, `demo-webhook`, and `developer-devspaces`.
- The Dev Spaces service account could read Routes and pod logs in `demo-webhook` and authenticate to RHACS through its mounted Secret.
- The staged opening PipelineRun failed in `rhacs-image-check` because the final image contained `openclaw@2026.2.13` and violated **Demo - Critical OpenClaw release blocked**.

## Remediation proof

The same `versions/v1` source stream was updated to exact `openclaw@2026.8.2`. The dependency and lockfile were committed with the configured SSH signing key and pushed over SSH from the Dev Spaces tools container. Gitea's authenticated webhook created PipelineRun `openclaw-release-xxwd2`.

All thirteen Tasks succeeded:

1. clone the immutable Git revision;
2. verify the developer commit signature;
3. test the exact dependency contract;
4. build a commit-specific image with the OpenShift BuildConfig;
5. generate the final-image CycloneDX SBOM;
6. run the RHACS image scan;
7. render the digest-pinned deployment manifest;
8. sign the digest and attach the SBOM attestation;
9. pass the RHACS component-version and approved-signature gates;
10. prepare the demonstrative TPA publication bundle;
11. pass the RHACS deployment-manifest check;
12. render the compact release-evidence card;
13. promote the immutable digest.

The evidence card reported:

```text
Component/version policy   PASS
Cosign signature policy    PASS
CycloneDX SBOM attestation ATTACHED
TPA publication bundle     PREPARED (demo; no TPA endpoint)
Deployment manifest gate   PASS
Decision                   APPROVED FOR PROMOTION
```

The promoted Deployment ran image digest `sha256:cf60728b24a2d445407d54dec661c81dfb85aea38c67533b10020c1bbf61b078` and reached Ready. This digest is rehearsal evidence, not a value to hardcode into the presentation; every build produces a new immutable identity.

## Contract learned during rehearsal

The dependency must be exact. `npm install` without `--save-exact` wrote `^2026.8.2`, and the test Task rejected the floating range before the image build. The documented presenter command now uses `--save-exact`, ensuring the source manifest and lockfile record the reviewed release precisely.

## Product boundary

TPA was not installed. The successful Task prepared the real CycloneDX and digest metadata and explicitly recorded that no endpoint was configured. No documentation or audience script claims that an upload occurred.
