# Cosign image-SBOM demonstration

## Purpose

This use case proves that the build SBOM is attached to the same immutable image digest that was approved by the delivery pipeline. The public key establishes who signed the attestation. The registry credentials authorize reading the internal OpenShift registry; they do not establish trust.

## Prepared Dev Spaces terminal

Every new terminal automatically refreshes registry authentication from its short-lived ServiceAccount token, exports the currently deployed digest as `IMAGE`, and copies the current public key from the `demo-platform/cosign-signing-key` Secret. Confirm the values:

```bash
echo "$IMAGE"
echo "$COSIGN_PUBLIC_KEY"
test -s /tmp/cosign.pub && echo "public key ready"
```

If the terminal was already open before setup changed, initialize it once:

```bash
source scripts/cosign-demo-env.sh
```

## Verify the signed SBOM attestation

```bash
cosign verify-attestation \
  --allow-insecure-registry \
  --insecure-ignore-tlog \
  --type cyclonedx \
  --key "$COSIGN_PUBLIC_KEY" \
  "$IMAGE"
```

Expected result: Cosign reports that its claims were validated and its signature was verified against the supplied public key. This CRC demo uses a local key and no transparency log, which is why `--insecure-ignore-tlog` is explicit.

## Download and extract the SBOM

```bash
cosign download attestation \
  --allow-insecure-registry \
  "$IMAGE" \
| jq -r '.payload' \
| base64 -d \
| jq '.predicate' \
> sboms/openclaw-attached.cdx.json
```

Inspect the evidence:

```bash
jq -r '"format=\(.bomFormat) \(.specVersion) components=\(.components | length)"' \
  sboms/openclaw-attached.cdx.json

jq -r '.components[] | select(.name == "openclaw") | "\(.name)@\(.version)"' \
  sboms/openclaw-attached.cdx.json \
| sort -u
```

For the short presentation path, the following target performs the same verification and extraction:

```bash
make image-sbom-attestation
```

The presenter uses the readable release reference
`image-registry.openshift-image-registry.svc:5000/ai-email-demo/openclaw:v2`.
Cosign resolves that tag to the image digest before it verifies the signature
and CycloneDX attestation. The signature itself remains bound to the immutable
digest; the tag is only the simpler presentation handle.

Inside Dev Spaces the helper uses the internal registry service. When the same
Make target is run from the CRC host, it automatically uses the internal
registry Route. Both forms still address the `openclaw:v2` tag.

Do not describe `cosign download attestation` alone as verification. Download proves that an OCI attachment can be retrieved. `cosign verify-attestation` proves that the signed statement matches the expected public key.
