# Base images and vulnerability ownership

## Why this is part of the demonstration

An image scan can identify a vulnerable package, but a useful remediation workflow must also answer where that package entered the image and who can replace it. RHACS base-image detection separates inherited base layers from layers added by the application build. That distinction routes work; it does not remove the application owner's responsibility to release a rebuilt workload.

## Demo base-image catalogue

| Base image | Workload consumers | Base-image owner | Application owner |
|---|---|---|---|
| `registry.access.redhat.com/ubi9/nodejs-22:latest` | `openclaw:v2` | AI platform | AI email workload |
| `registry.access.redhat.com/ubi9/python-312:latest` | `mail-api`, `demo-sink` | Messaging platform | Respective service owner |
| `registry.access.redhat.com/ubi9/nodejs-22:latest` | scan-only `openclaw:v1` and running `openclaw:v2` | Platform engineering | AI email workload |

`make rhacs-base-images` registers these repositories and tag patterns with RHACS. The OCI labels in each Dockerfile record the same ownership intent on the built artifact. In production, replace mutable `latest` references with the organization's supported release pattern and build by immutable digest.

## Who owns a CVE?

| Finding origin | Accountable for the fix | Required handoff |
|---|---|---|
| Package inherited from a declared base image | Base-image owner refreshes, tests, and republishes the approved base | Application owner rebuilds from the fixed digest, tests, signs, and promotes the workload |
| RPM added by the application Dockerfile | Application owner | Update the Dockerfile/build, rebuild, and promote |
| Direct Python or npm dependency | Application/dependency owner | Update the lock file or package version, test, rebuild, and promote |
| Transitive application dependency | Application owner coordinates with the direct dependency or upstream | Track the upstream fix; rebuild when available or document a time-bound exception |
| No fixed version is available | Product risk owner | Record compensating controls, expiry, and acceptance; continue monitoring |
| Vulnerability is exercised at runtime | Workload owner and incident response | Contain the workload while the owning build team prepares the permanent fix |

The short version for the presentation is:

> Platform owns producing the repaired base. The application team owns consuming it. Security owns the policy and evidence, not the patch itself.

## RHACS walkthrough

1. Go to **Platform Configuration → Base Images** and show the three registered UBI repositories.
2. Open the `openclaw:v2` image under **Vulnerability Management → Results**.
3. Show its base-image assessment, matched digest, and age.
4. Filter findings by **Layer type = Base image**. Assign those remediation actions to the AI platform team.
5. Filter by **Layer type = Application layer**. Assign those actions to the AI workload team.
6. Explain the shared release gate: a repaired base image is not production remediation until the application has rebuilt and promoted a new immutable image.

If RHACS does not detect a declared base image, it treats the layers as application layers. Verify the repository/tag pattern, registry access, and that the workload really inherited the matching layers before using the ownership classification.

## Feature boundary

Standardized base-image definition and layer detection are generally available in RHACS 4.11. Policy filtering that differentiates CVE origin between base and application layers remains Technology Preview in that release. Use the GA layer evidence for triage; do not promise admission enforcement based on layer origin unless the feature flag and environment have been explicitly tested.

