# Syft SBOM set for Red Hat Trusted Profile Analyzer

These documents were generated from the immutable OpenShift internal-registry digests by `make sboms`. Syft emits CycloneDX 1.5 JSON because that format is accepted by Red Hat Trusted Profile Analyzer.

| File | Built ImageStreamTag |
|---|---|
| `openclaw-v1.cdx.json` | `openclaw:v1` |
| `openclaw-latest.cdx.json` | `openclaw:latest` |
| `mail-api-latest.cdx.json` | `mail-api:latest` |
| `demo-sink-latest.cdx.json` | `demo-sink:latest` |

`index.json` records the exact digest, source reference, output filename, package count, and file-component count for every document. `openclaw:v1` is the single candidate and `openclaw:latest` is its promoted alias.

The browser-first release pipeline generates a separate CycloneDX document from its commit-specific final image before signing or promotion. That file is retained in the PipelineRun workspace, attached to the same immutable digest as a Cosign attestation, and copied into the demonstrative TPA publication bundle. The checked-in files in this directory are preparation and fallback evidence; they are not a substitute for the PipelineRun artifact.

The generated registry login is temporary and removed when the Make target exits. No registry credential is stored under `sboms/`.

To refresh after rebuilding an image:

```sh
make sboms
```

Upload any `.cdx.json` file directly to TPA. Do not upload `index.json`; it is the local provenance map for the set.
