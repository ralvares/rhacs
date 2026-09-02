# Live CRC validation report

Validated on 2026-08-31 against OpenShift Local 4.22.7 and RHACS 4.11.3.

## Application path

- The final `ai-agent:v2` image built from Red Hat UBI 9 Node.js 22 and ran OpenClaw 2026.7.1.
- Every repository-built image uses Red Hat UBI 9: Python 3.12 for the mail API and receiver, Python 3.9 for the obsolete v1 scan target, and Node.js 22 for the personal-agent runtime.
- A normal turn read two SMTP/IMAP messages and returned a Markdown summary.
- After SMTP delivery of the external multipart HTML message, the same request read three messages. The remote `deepseek-v4-flash:cloud` model selected the general `exec` tool, which launched `curl` in the agent container.
- The receiver recorded the complete 56-byte synthetic `.env` file. Two independent repeat sessions produced two receiver events.
- With restricted egress, the same action timed out and the receiver count remained unchanged.

## RHACS evidence

| Image | Components | Vulnerabilities | Critical | Important | Moderate | Low |
|---|---:|---:|---:|---:|---:|---:|
| `ai-agent:v1` | 94 | 420 | 0 | 39 | 168 | 213 |
| `ai-agent:v2` | 88 | 408 | 0 | 37 | 158 | 213 |
| `mail-api:latest` | 90 | 404 | 0 | 33 | 158 | 213 |
| `demo-sink:latest` | 90 | 404 | 0 | 33 | 158 | 213 |

The larger v2 inventory is expected: it is the real OpenClaw/npm workload, while v1 is a deliberately small obsolete scanner input. Counts are a live database snapshot, not stable promises.

- Bad deployment: 4 deploy-time policy violations.
- Clean deployment: 0 deploy-time policy violations.
- Runtime alerts captured: `Unauthorized Process Execution` and `Unauthorized Network Flow`.
- The deterministic process template permits Node/OpenClaw, Python/IMAP, reset-time `rm`, and the UBI shell-initialization helpers. It explicitly excludes `curl`.
- After stale rehearsal alerts were resolved, a fresh controlled run produced one unexpected process: `/usr/bin/curl` with the receiver URL. The receiver waits three seconds so Collector can observe this otherwise short-lived process reliably.
- The scoped `Demo - Sensitive File Transfer via curl` policy was live-tested and generated an active alert by matching both process `curl` and arguments containing `@.env`.
- The network baseline excludes `demo-webhook:8080`, producing the corresponding cross-namespace flow deviation.

File Activity Monitoring is enabled in the SecuredCluster and deployed the `fact` container. RHACS 4.11 documents this Technology Preview feature as x86-only for violation reporting, while CRC is ARM64; it also documents writable/modification operations rather than read-only opens. The process-argument policy is therefore the verified evidence for this particular `.env` read/transfer attempt.

## Admission status

Static deployment evaluation works, but live admission blocking is **not verified** on this CRC installation. RHACS detected the privileged manifest, while Admission Control continued to report zero enforceable deploy-time policies after the policy API update. The attempted policy mutations were disabled and cleared. Do not claim live admission rejection until the RHACS console shows an enforced policy and a controlled server-side dry run is denied.

Raw evidence is stored beside this report. It contains no real credentials.
