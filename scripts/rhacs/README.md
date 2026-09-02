# RHACS automated deployment and demo integration

For presenter-oriented, independently runnable security stories after RHACS and the applications already exist, use [`../../docs/INDEPENDENT-USE-CASES.md`](../../docs/INDEPENDENT-USE-CASES.md). It explains `.rhacs.env`, the evidence and claim for each control, minimum preparation, and the smallest reset between use cases.

This repository provides a zero-touch, Kustomize-based deployment for **Red Hat Advanced Cluster Security (RHACS)** on OpenShift.

It automates the installation of the Operator and Central services, and establishes trust using the **Cluster Registration Secret (CRS)** method—eliminating the need for manual "init-bundle" downloads.

## 📂 Project Structure

```text
.
├── deploy.sh                  # Main deployment orchestrator script
├── operator/                  # Operator installation (Namespace, Sub, OG)
└── service/                   # RHACS Instance & CRS Automation
    ├── central.yaml           # Central Service Custom Resource
    ├── securedcluster.yaml    # Secured Cluster Custom Resource
    ├── create-cluster-crs-sa.yaml  # RBAC for automation Job
    └── create-cluster-crs-job.yaml # Automation Job for CRS generation

```

---

## Complete demo setup

From the repository root, the normal entry point is:

```bash
make setup-full
```

It deploys the application, installs RHACS when needed, connects Central to the OpenShift internal registry with a read-only service account scoped to `ai-email-demo`, enables the runtime deviation policies, and locks the application process/network baselines.

For a reproducible rebuild, preserve RHACS and Scanner data by default:

```bash
make cleanup
make setup-full
```

The cleanup resolves demo-owned alerts and removes only the three application
namespaces and their retained volumes. The explicit
`--reinstall-rhacs` cleanup option is reserved for installer testing because it
deletes RHACS state and forces the vulnerability database to rebuild.

For an application that is already running:

```bash
make setup-rhacs
```

The generated `.rhacs.env` contains the Central endpoint and API token. It is ignored by source control and created with mode 600.

For an existing deployment, prepare an independent CLI session with:

```bash
make rhacs-login
make rhacs-shell
```

The RHACS deployment separately creates `stackrox/stackrox-image-puller`, a
namespace-scoped `system:image-puller` binding in `ai-email-demo`, and a stable declarative
ServiceAccount token Secret. An in-cluster Job installs that identity into the
OpenShift internal-registry integration. This happens during RHACS/demo setup;
presenters do not copy or refresh a registry credential before image scans.

This is based on the Red Hat CoP `internal-registry-integration` overlay. The
local adaptation uses a namespace RoleBinding instead of a ClusterRoleBinding
and a declarative non-expiring ServiceAccount token Secret instead of depending
on `oc sa get-token`. The updater Job does not print the credential.

If that deployment-time integration must be reconciled independently, run
`make rhacs-registry` once. It recreates only the
scoped updater Job and does not reinstall RHACS or rebuild applications.

The setup declares and locks stable process paths for every demo deployment,
then runs `rhacs-pb-audit` to compare actual process history with each baseline.
The receiver's normal `/opt/app-root/bin/python` reset helper is included;
agent-side `curl` is explicitly excluded. A missing ordinary process therefore
fails setup instead of appearing as noise during the presentation.

The same setup declares and locks the full network contract for all seven
workloads. It includes OpenShift Route ingress, `dns-default` UDP/TCP 5353,
SMTP 3025, IMAP 3143, the CRC-host model API as `INTERNAL_ENTITIES:11434`, and
the approved internal service. It forbids direct external-source peers and
keeps both `openclaw -> demo-webhook:8080` and
`openclaw -> unauthorized-demo-service:8080` outside the baseline.

Inspect the live contract with the public Make interface:

```bash
make rhacs-network-status
```

## RHACS installation only

To deploy the entire stack, including the Operator, Central, and the automated CRS generation, simply run the deployment script:

```bash
make rhacs-install

```

### What the script does:

1. **Operator Deployment:** Applies the Kustomize manifests for the RHACS Operator.
2. **Health Check:** Waits for the `ClusterServiceVersion` (CSV) to reach the **Succeeded** phase.
3. **API Verification:** Ensures the `centrals` and `securedclusters` CRDs are established.
4. **Service Deployment:** Applies the Central and SecuredCluster resources.
5. **Automation Monitoring:** Automatically streams the logs from the `create-cluster-init-bundle` Job.
6. **Credential Output:** Once complete, it prints the Central URL and the `admin` password.

The `SecuredCluster` enables Admission Control, but admission policy enforcement must still be configured and tested in Central. A successful static `roxctl deployment check` is detection evidence; it is not proof that the Kubernetes API rejected a request.

The same manifest enables File Activity Monitoring with
`spec.perNode.fileActivityMonitoring.mode: Enabled`. `setup-rhacs-demo.sh`
verifies both that field and that the Collector DaemonSet contains a ready
`fact` container before installing the demo file-activity policy. RHACS 4.11
file-activity violation reporting is x86-only; an ARM CRC can run `fact` but
does not emit those violations.

---

## 🔍 Manual Verification

If you need to verify components individually:

**1. Check Operator Pods:**

```bash
oc get pods -n rhacs-operator

```

**2. Check Central Status:**

```bash
oc get central -n stackrox

```

**3. Check Secured Cluster Status:**

```bash
oc get securedcluster stackrox-secured-cluster-services -n stackrox

```
