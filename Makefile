SHELL := /bin/bash
PYTHON ?= $(or $(wildcard /opt/homebrew/bin/python3),python3)
.DEFAULT_GOAL := help
.SILENT:

# Once rhacs-login creates this file, every later Make invocation exports the
# presenter-side RHACS connection automatically to all recipes.
-include .rhacs.env
export ROX_ENDPOINT ROX_API_TOKEN ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY

.PHONY: help test setup setup-kubernetes setup-rhacs setup-full cleanup cleanup-reinstall \
	demo-reset demo-run email-injection email-callback external-setup \
	credentials receiver-evidence egress-restrict egress-restore \
	rhacs-login rhacs-shell rhacs-policies rhacs-baselines rhacs-exceptions rhacs-gate \
	rhacs-baseline-status rhacs-network-status \
	rhacs-registry rhacs-base-images rhacs-file-policy rhacs-sensitive-policy \
	rhacs-install signing-key sign prepare prepare-resign show sboms verify-versions \
	pipelines-setup pipeline-run pipeline-status devspaces-status

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
	  '  make prepare                Verify v1/v2 and cache presentation evidence' \
	  '  make prepare-resign         Recreate the v2 signature and cached evidence' \
	  '  make verify-versions        Verify presentation and OpenClaw v1/v2 projects match' \
	  '  make sboms                  Generate Syft CycloneDX JSON SBOMs for all image tags' \
	  '  make signing-key            Generate the local demo signing key' \
	  '  make sign                   Sign the immutable OpenClaw v2 image digest' \
	  '  make show                   Display cached evidence; no build or scan' \
	  '' \
	  'Run and reset the live demo' \
	  '  make demo-reset             Recreate all apps and restore a clean RHACS state' \
	  '  make demo-run               Run the guided end-to-end demo sequence' \
	  '  make email-injection        Send the external HTML workflow email' \
	  '  make email-callback         Send the bounded callback-simulation email' \
	  '  make receiver-evidence      Show the latest receiver events in presenter format' \
	  '  make credentials            Show browser, mailbox, and demo access details' \
	  '  make egress-restrict        Apply the contained runtime network state' \
	  '  make egress-restore         Restore the permissive runtime network state' \
	  '  make pipeline-run           Start the release pipeline without a Git push' \
	  '  make pipeline-status        Show recent release pipeline runs' \
	  '  make devspaces-status       Show the Dev Spaces browser entry point' \
	  '' \
	  'Configure and inspect RHACS' \
	  '  make rhacs-login            Create or refresh credentials used by Make targets' \
	  '  make rhacs-shell            Open a shell with RHACS credentials already loaded' \
	  '  make rhacs-install          Install RHACS when it is not already present' \
	  '  make rhacs-registry         Configure internal-registry image enrichment' \
	  '  make rhacs-policies         Configure signature and release policies' \
	  '  make rhacs-base-images      Configure approved base-image ownership' \
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

cleanup-reinstall:
	./scripts/cleanup-full-demo.sh --reinstall-rhacs

demo-reset:
	./scripts/reset-full-demo.sh

demo-run:
	./scripts/run-demo.sh

email-injection:
	./scripts/send-external-html-email.sh

email-callback:
	./scripts/send-callback-html-email.sh

receiver-evidence:
	./scripts/show-receiver-evidence.sh

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

verify-versions:
	diff -B -q versions/v1/requirements.txt services/openclaw/v1/requirements.txt
	diff -B -q versions/v1/package.json services/openclaw/v1/package.json
	diff -B -q versions/v1/package-lock.json services/openclaw/v1/package-lock.json
	diff -B -q versions/v2/package.json services/openclaw/v2/package.json
	diff -B -q versions/v2/package-lock.json services/openclaw/v2/package-lock.json
	echo 'OpenClaw v1/v2 dependency projects match the presentation copies.'

pipelines-setup:
	./scripts/setup-pipelines.sh

pipeline-run:
	./scripts/run-pipeline.sh

pipeline-status:
	oc -n ai-email-cicd get pipelineruns -l app.kubernetes.io/name=openclaw-release \
	  --sort-by=.metadata.creationTimestamp

devspaces-status:
	@echo "Dev Spaces status: $$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.chePhase}')"
	@echo "Dev Spaces URL:    $$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.cheURL}')"
