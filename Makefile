SHELL := /bin/bash
PYTHON ?= $(or $(wildcard /opt/homebrew/bin/python3),python3)
.DEFAULT_GOAL := help
.SILENT:

# Once rhacs-login creates this file, every later Make invocation exports the
# presenter-side RHACS connection automatically to all recipes.
-include .rhacs.env
export ROX_ENDPOINT ROX_API_TOKEN ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY

.PHONY: help test setup setup-kubernetes setup-rhacs setup-full cleanup cleanup-reinstall cleanup-artifacts \
	demo-reset demo-reset-runtime demo-reset-delivery demo-run email-injection email-callback external-setup \
	credentials receiver-evidence document-agent-url document-agent-test egress-restrict egress-restore \
	rhacs-login rhacs-shell rhacs-policies rhacs-baselines rhacs-exceptions rhacs-gate \
	rhacs-baseline-status rhacs-network-status \
	rhacs-registry rhacs-base-images rhacs-platform-components rhacs-file-policy rhacs-sensitive-policy \
	rhacs-enforce-deploy \
	rhacs-install signing-key sign prepare prepare-resign show sboms spdx-sboms image-sbom-attestation verify-versions \
	pipelines-setup pipeline-run pipeline-status promote-v2 devspaces-status devspaces-tools devspaces-open

help:
	@printf '%s\n' \
	  'AI workload demo' \
	  '' \
	  'Prepare the environment' \
	  '  make setup                  Build and deploy the OpenShift application' \
	  '  make setup-kubernetes       Deploy to Kubernetes (requires registry and domain)' \
	  '  make setup-rhacs            Configure RHACS without reinstalling it' \
	  '  make setup-full             Prepare applications, RHACS, and cached evidence' \
	  '  make external-setup         Prepare the separate receiver namespace' \
	  '  make pipelines-setup        Install Dev Spaces, Gitea, and OpenShift Pipelines' \
	  '' \
	  'Prepare the presentation evidence' \
	  '  make prepare                Verify the single v1 candidate and cache evidence' \
	  '  make prepare-resign         Recreate the v1 signature and cached evidence' \
	  '  make verify-versions        Verify the single v1 dependency candidate' \
	  '  make sboms                  Generate Syft CycloneDX JSON SBOMs for all image tags' \
	  '  make spdx-sboms             Generate SPDX 2.3 JSON SBOMs for openclaw:v1 and v2' \
	  '  make image-sbom-attestation Verify and extract the CycloneDX SBOM from openclaw:v2' \
	  '  make signing-key            Generate the local demo signing key' \
	  '  make sign                   Sign the immutable OpenClaw v1 image digest' \
	  '  make show                   Display cached evidence; no build or scan' \
	  '' \
	  'Run and reset the live demo' \
	  '  make demo-reset             Full clean-room reset; preserve the RHACS installation' \
	  '  make demo-reset-runtime     Reset mailbox, agent sessions, receiver, alerts, and egress' \
	  '  make demo-reset-delivery    Reset Gitea, Dev Spaces, PipelineRuns, and archives' \
	  '  make demo-run               Run the guided end-to-end demo sequence' \
	  '  make email-injection        Send the external HTML workflow email' \
	  '  make email-callback         Send the bounded callback-simulation email' \
	  '  make receiver-evidence      Show the latest receiver events in presenter format' \
	  '  make document-agent-url     Show the PDF-summary application URL' \
	  '  make document-agent-test    Test the demonstration PDF summary end to end' \
	  '  make credentials            Show credentials and approve pending v2 browser devices' \
	  '  make egress-restrict        Apply the contained runtime network state' \
	  '  make egress-restore         Restore the permissive runtime network state' \
	  '  make pipeline-run           Start the release pipeline without a Git push' \
	  '  make pipeline-status        Show recent release pipeline runs' \
	  '  make promote-v2             Admit the staged v2 digest and start the runtime act' \
	  '  make devspaces-status       Show the Dev Spaces browser entry point' \
	  '  make devspaces-tools        Verify the presenter tools inside Dev Spaces' \
	  '  make devspaces-open         Open Dev Spaces in an isolated CRC demo browser' \
	  '' \
	  'Configure and inspect RHACS' \
	  '  make rhacs-login            Create or refresh credentials used by Make targets' \
	  '  make rhacs-shell            Open a shell with RHACS credentials already loaded' \
	  '  make rhacs-install          Install RHACS when it is not already present' \
	  '  make rhacs-registry         Configure internal-registry image enrichment' \
	  '  make rhacs-policies         Configure signature and release policies' \
	  '  make rhacs-enforce-deploy   Enable deployment admission after the remediation demo' \
	  '  make rhacs-base-images      Configure approved base-image ownership' \
	  '  make rhacs-platform-components Classify supporting demo namespaces as platform' \
	  '  make rhacs-file-policy      Configure the File Activity policy' \
	  '  make rhacs-sensitive-policy Configure the sensitive-transfer process policy' \
	  '  make rhacs-baselines        Configure process and network baselines' \
	  '  make rhacs-exceptions       Configure documented demo exceptions' \
	  '  make rhacs-gate             Run live image and deployment policy checks' \
	  '  make rhacs-baseline-status  Show OpenClaw process baseline and history' \
	  '  make rhacs-network-status   Show declared workload network baselines' \
	  '' \
	  'Maintenance and validation' \
	  '  make cleanup                Remove demo applications; preserve RHACS' \
	  '  make cleanup-artifacts      Remove stale failed builds, workspaces, and pipeline runs' \
	  '  make cleanup-reinstall      Remove demo applications and RHACS installation' \
	  '  make test                   Run the local test suite'

test:
	$(PYTHON) -m pytest

setup:
	./scripts/setup.sh openshift

setup-kubernetes:
	@test -n "$(REGISTRY_PROJECT)" || (echo "REGISTRY_PROJECT is required" && exit 2)
	@test -n "$(DOMAIN)" || (echo "DOMAIN is required" && exit 2)
	./scripts/setup.sh kubernetes "$(REGISTRY_PROJECT)" "$(DOMAIN)" "$(or $(INGRESS_CLASS),nginx)"

setup-rhacs:
	./scripts/setup-rhacs-demo.sh --skip-install

setup-full:
	./scripts/setup-full-demo.sh

cleanup:
	./scripts/cleanup-full-demo.sh

cleanup-artifacts:
	./scripts/cleanup-demo-artifacts.sh

cleanup-reinstall:
	./scripts/cleanup-full-demo.sh --reinstall-rhacs

demo-reset:
	./scripts/reset-full-demo.sh

demo-reset-runtime:
	./scripts/reset-runtime-demo.sh

demo-reset-delivery:
	./scripts/reset-delivery-demo.sh

demo-run:
	./scripts/run-demo.sh

email-injection:
	./scripts/send-external-html-email.sh

email-callback:
	./scripts/send-callback-html-email.sh

receiver-evidence:
	./scripts/show-receiver-evidence.sh

document-agent-url:
	@echo "https://$$(oc -n ai-email-demo get route document-agent -o jsonpath='{.spec.host}')"

document-agent-test:
	@host=$$(oc -n ai-email-demo get route document-agent -o jsonpath='{.spec.host}'); \
	tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	curl -kfsS "https://$$host/demo.pdf" -o "$$tmp"; \
	curl -kfsS -F "file=@$$tmp;type=application/pdf;filename=community-update-demo.pdf" "https://$$host/api/summarize" | jq '{summary, pages, characters, workflow}'

external-setup:
	./scripts/setup-external-demo.sh

credentials:
	./scripts/show-demo-credentials.sh

egress-restrict:
	./scripts/restrict-egress.sh

egress-restore:
	./scripts/restore-permissive-egress.sh

rhacs-login:
	./scripts/rhacs-login.sh

rhacs-shell: rhacs-login
	set -a; source .rhacs.env; set +a; \
	echo "RHACS environment loaded. Exit this shell to return."; \
	exec "$${SHELL:-/bin/bash}" -i

rhacs-policies:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-signature-policy.sh

rhacs-enforce-deploy:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-signature-policy.sh

rhacs-baselines:
	./scripts/rhacs-baselines.sh

rhacs-baseline-status:
	set -a; source .rhacs.env; set +a; source scripts/rhacs-baselines.sh; \
	rhacs-pb-list ai-email-demo/openclaw; \
	rhacs-pb-history ai-email-demo/openclaw; \
	rhacs-pb-audit ai-email-demo/openclaw; \
	rhacs-pb-audit demo-webhook/demo-webhook

rhacs-network-status:
	set -a; source .rhacs.env; set +a; source scripts/rhacs-baselines.sh; \
	for deployment in openclaw mail-server mail-api webmail unauthorized-demo-service approved-internal-service; do \
	  rhacs-nb-list "ai-email-demo/$$deployment"; \
	done; \
	rhacs-nb-list demo-webhook/demo-webhook

rhacs-exceptions:
	./scripts/rhacs-exceptions.sh

rhacs-gate:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs-ci-gate.sh

rhacs-registry:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-internal-registry.sh

rhacs-base-images:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-base-images.sh

rhacs-platform-components:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-platform-components.sh

rhacs-file-policy:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-file-activity-policy.sh

rhacs-sensitive-policy:
	set -a; source .rhacs.env; set +a; ./scripts/rhacs/configure-sensitive-transfer-policy.sh

rhacs-install:
	./scripts/rhacs/deploy.sh --install

signing-key:
	./scripts/generate-signing-key.sh

sign:
	./scripts/sign-release-v2.sh

prepare: verify-versions
	./scripts/prepare-supply-chain-demo.sh

prepare-resign: verify-versions
	./scripts/prepare-supply-chain-demo.sh --resign

show:
	./scripts/show-supply-chain-demo.sh

sboms:
	./scripts/generate-sboms.sh

spdx-sboms:
	./scripts/generate-spdx-sboms.sh

image-sbom-attestation:
	./scripts/show-image-sbom-attestation.sh

verify-versions:
	diff -B -q versions/v1/requirements.txt services/openclaw/v1/requirements.txt
	diff -B -q versions/v1/package.json services/openclaw/v1/package.json
	diff -B -q versions/v1/package-lock.json services/openclaw/v1/package-lock.json
	grep -q 'Remediation target: `openclaw@2026.8.2`' versions/v1/README.md
	test -s versions/v2/package-lock.json
	grep -q '"openclaw": "2026.8.2"' versions/v2/package.json
	test ! -d services/openclaw/v2
	echo 'OpenClaw candidates verified: v1 is 2026.2.13; v2 is 2026.8.2.'

pipelines-setup:
	./scripts/setup-pipelines.sh

pipeline-run:
	./scripts/run-pipeline.sh

pipeline-status:
	oc -n demo-platform get pipelineruns -l app.kubernetes.io/name=openclaw-release \
	  --sort-by=.metadata.creationTimestamp

promote-v2:
	./scripts/promote-v2.sh

devspaces-status:
	@echo "Dev Spaces status: $$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.chePhase}')"
	@echo "Dev Spaces URL:    $$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.cheURL}')"

devspaces-tools:
	pod=$$(oc -n developer-devspaces get pod -l controller.devfile.io/devworkspace_name=demo-app -o jsonpath='{.items[0].metadata.name}'); \
	oc -n developer-devspaces exec "$$pod" -c tools -- bash -lc \
	  'for tool in oc kubectl kustomize jq yq git podman cosign syft tkn; do command -v "$$tool" >/dev/null && printf "%-12s READY\n" "$$tool" || { printf "%-12s MISSING\n" "$$tool"; exit 1; }; done; \
	   for helper in roxctl rox-check rox-scan rox-deploy; do type "$$helper" >/dev/null && printf "%-12s READY\n" "$$helper" || { printf "%-12s MISSING\n" "$$helper"; exit 1; }; done; \
	   test -n "$$ROX_ENDPOINT" && test -n "$$ROX_API_TOKEN" && printf "%-12s READY\n" RHACS-auth'

devspaces-open:
	./scripts/open-devspaces.sh
