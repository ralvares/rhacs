from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_dev_spaces_repository_contract_is_present():
    devfile = (ROOT / "devfile.yaml").read_text()
    extensions = (ROOT / ".vscode/extensions.json").read_text()

    assert "schemaVersion: 2.2.2" in devfile
    assert "demo-platform/demo-workstation:latest" in devfile
    workstation = (ROOT / "services/dev-workstation/Dockerfile").read_text()
    assert "registry.redhat.io/devspaces/udi-rhel9:latest" in workstation
    for tool in ("roxctl", "cosign", "syft", "kustomize"):
        assert f"/usr/local/bin/{tool}" in workstation
    assert "/opt/demo-venv" in workstation
    assert '"openclaw": "2026.2.13"' in (ROOT / "versions/v1/package.json").read_text()
    assert '"openclaw": "2026.8.2"' in (ROOT / "versions/v2/package.json").read_text()
    assert not (ROOT / "services/openclaw/v2").exists()
    assert "cleanup-demo-artifacts.sh" in (ROOT / "scripts/setup-pipelines.sh").read_text()
    workspace_setup = (ROOT / "scripts/create-devspaces-workspace.sh").read_text()
    assert "disabled-extensions" not in workspace_setup
    assert 'init-che-code-command' in workspace_setup
    assert 'nohup /checode/entrypoint-volume.sh' in workspace_setup
    assert "/etc/profile.d/rhacs-demo.sh" in workstation
    assert "rhacs-cli-env" in (ROOT / "scripts/setup-pipelines.sh").read_text()
    assert "TRUSTIFY_DA_PYTHON_VIRTUAL_ENV" in devfile
    assert "TRUSTIFY_DA_PYTHON3_PATH" in devfile
    assert "commandLine: exec /bin/bash --login" in devfile
    assert 'require("./versions/v1/package.json")' in devfile
    assert "npm --prefix versions/v1" in devfile
    assert "npm --prefix versions/v2" in devfile
    assert "services/openclaw/v2/node_modules" not in devfile
    assert "controller.devfile.io/merge-contribution: true" in devfile
    assert "redhat.fabric8-analytics" in extensions


def test_release_pipeline_orders_security_before_promotion():
    pipeline = (ROOT / "deploy/pipelines/20-pipeline.yaml").read_text()
    scan = pipeline.index("- name: rhacs-image-scan")
    sbom = pipeline.index("- name: sbom")
    image_check = pipeline.index("- name: rhacs-image-check")
    deployment_check = pipeline.index("- name: rhacs-deployment-check")
    tpa_publication = pipeline.index("- name: prepare-tpa-publication")
    release_evidence = pipeline.index("- name: release-evidence")
    promote = pipeline.index("- name: promote")

    assert sbom < scan < image_check < tpa_publication < deployment_check < release_evidence < promote
    assert "runAfter: [build]" in pipeline[sbom:scan]
    assert "$(tasks.build.results.image-reference)" in pipeline[sbom:scan]
    assert "runAfter: [rhacs-image-check, sbom]" in pipeline[tpa_publication:deployment_check]
    assert "runAfter: [prepare-tpa-publication, render-manifests]" in pipeline[deployment_check:release_evidence]
    assert "runAfter: [rhacs-deployment-check]" in pipeline[release_evidence:promote]
    assert "runAfter: [release-evidence]" in pipeline[promote:]
    assert "$(tasks.build.results.image-reference)" in pipeline
    assert '{name: sign-candidate, type: string, default: "true"}' in pipeline
    assert '{name: promote-candidate, type: string, default: "true"}' in pipeline
    assert '{name: source-version, type: string, default: "v2"}' in pipeline
    assert "input: $(params.sign-candidate)" in pipeline
    assert "input: $(params.promote-candidate)" in pipeline
    assert 'DEMO_SIGN_CANDIDATE=false' in (ROOT / "scripts/stage-affected-pipeline.sh").read_text()
    assert 'DEMO_SOURCE_VERSION=v2' in (ROOT / "scripts/stage-approved-pipeline.sh").read_text()
    assert 'DEMO_PROMOTE_CANDIDATE=false' in (ROOT / "scripts/stage-approved-pipeline.sh").read_text()


def test_source_commit_and_sbom_publication_contracts_are_explicit():
    tasks = (ROOT / "deploy/pipelines/10-tasks.yaml").read_text()
    pipeline = (ROOT / "deploy/pipelines/20-pipeline.yaml").read_text()
    devfile = (ROOT / "devfile.yaml").read_text()

    assert "verify-commit HEAD" in tasks
    assert "commit-signing-trust" in tasks
    assert "demonstration-only-no-endpoint-configured" in tasks
    assert "attest" in tasks
    assert "--type" in tasks and "cyclonedx" in tasks
    assert 'syft scan "registry:$(params.image)"' in tasks
    assert 'Path(f"versions/{source_version}/package.json")' in tasks
    assert 'buildconfig openclaw-v1' in tasks
    assert 'start-build openclaw-v1' in tasks
    assert '$build_context/v1/package.json' in tasks
    assert 'buildconfig openclaw-v2' not in tasks
    assert 'start-build openclaw-v2' not in tasks
    assert "openclaw-image.cdx.json" in tasks
    assert "APPROVED FOR PROMOTION" in tasks
    assert "taskRef: {name: verify-commit-signature}" in pipeline
    assert "taskRef: {name: prepare-tpa-publication}" in pipeline
    assert "git config --global commit.gpgsign true" in devfile


def test_release_baseline_and_platform_classification_are_explicit():
    package = (ROOT / "versions/v1/package.json").read_text()
    policies = "\n".join(
        path.read_text()
        for path in sorted((ROOT / "deploy/rhacs/policies").glob("*.yaml"))
    )
    platform = (ROOT / "scripts/rhacs/configure-platform-components.sh").read_text()

    assert '"openclaw": "2026.2.13"' in package
    assert "Remediation target: `openclaw@2026.8.2`" in (ROOT / "versions/v1/README.md").read_text()
    assert policies.count("severity: CRITICAL_SEVERITY") >= 2
    assert "fieldName: Image Component" in policies
    assert "fieldName: Image Signature Verified By" in policies
    assert "policyName: Demo - Unexpected Runtime Artifact" in policies
    assert "fieldName: File Path" in policies
    assert "fieldName: File Operation" in policies
    assert "ai-email-demo" not in platform.split("namespace_regex=", 1)[1].split("\n", 1)[0]
    for namespace in ("demo-platform", "demo-webhook", "developer-devspaces", "external-sender"):
        assert namespace in platform


def test_opening_v1_is_deliberately_unsigned():
    setup = (ROOT / "scripts/setup-rhacs-demo.sh").read_text()
    stage = (ROOT / "scripts/stage-affected-pipeline.sh").read_text()

    assert '"$repo_dir/scripts/sign-release-v2.sh"' not in setup
    assert '"$repo_dir/scripts/generate-signing-key.sh"' in setup
    assert 'delete istag "$v1_signature_tag"' in setup
    assert "Demo - Critical OpenClaw release blocked" in stage
    assert "Demo - Unsigned OpenClaw release blocked" in stage


def test_rhacs_catalog_tasks_and_yaml_controls_are_present():
    tasks = (ROOT / "deploy/pipelines/10-tasks.yaml").read_text()
    pipeline = (ROOT / "deploy/pipelines/20-pipeline.yaml").read_text()
    unsafe = (ROOT / "deploy/rhacs/bad-workload-security.yaml").read_text()
    clean = (ROOT / "deploy/rhacs/clean-openclaw.yaml").read_text()

    assert "bad-workload-security.yaml" in tasks
    assert "clean-openclaw.yaml" in tasks
    assert "taskRef: {name: rhacs-image-scan}" in pipeline
    assert "taskRef: {name: rhacs-image-check}" in pipeline
    assert "taskRef: {name: rhacs-deployment-check}" in pipeline
    for name in ("rhacs-image-scan", "rhacs-image-check", "rhacs-deployment-check"):
        catalog = (ROOT / f"deploy/pipelines/catalog/{name}-4.0.yaml").read_text()
        assert "tekton.dev/v1" in catalog
        assert "version: \"4.0\"" in catalog
    assert "privileged: true" in unsafe
    assert "hostNetwork: true" in unsafe
    assert "runAsNonRoot: true" in clean
    assert 'capabilities: {drop: ["ALL"]}' in clean


def test_no_custom_code_server_or_pipeline_emptydir():
    pipeline_files = "\n".join(
        path.read_text() for path in (ROOT / "deploy/pipelines").glob("*.yaml")
    )

    assert not (ROOT / "services/code-server").exists()
    assert "code-server" not in pipeline_files
    assert "emptyDir" not in pipeline_files
    assert "pipeline-evidence" not in pipeline_files


def test_neutral_platform_names_are_used():
    files = [
        ROOT / "deploy/pipelines/01-platform.yaml",
        ROOT / "deploy/pipelines/02-builds.yaml",
        ROOT / "deploy/pipelines/03-gitea.yaml",
        ROOT / "deploy/pipelines/10-tasks.yaml",
        ROOT / "deploy/pipelines/20-pipeline.yaml",
        ROOT / "deploy/pipelines/30-trigger.yaml",
        ROOT / "scripts/setup-pipelines.sh",
        ROOT / "scripts/run-pipeline.sh",
    ]
    content = "\n".join(path.read_text() for path in files)
    assert "demo-platform" in content
    assert "demo-app" in content
    assert "developer/demo-app" in content
    assert "demo/demo-app" not in content
    assert "ai-email-cicd" not in content
    assert "ai-email-demo-app" not in content


def test_git_push_trigger_and_full_reset_contracts_are_explicit():
    gitea = (ROOT / "deploy/pipelines/03-gitea.yaml").read_text()
    setup = (ROOT / "scripts/setup-pipelines.sh").read_text()
    reset = (ROOT / "scripts/reset-full-demo.sh").read_text()

    assert "ALLOWED_HOST_LIST = private" in gitea
    assert "http://el-gitea.${cicd_namespace}.svc.cluster.local:8080" in setup
    assert '"authorization_header"' in setup
    assert "cleanup-demo-artifacts.sh\" --all" in reset
    assert "stage-affected-pipeline.sh" in reset
    assert "stage-approved-pipeline.sh" in reset
    signature_policy = (ROOT / "deploy/rhacs/policies/openclaw-signature.yaml").read_text()
    assert "FAIL_BUILD_ENFORCEMENT" in signature_policy
    assert "SCALE_TO_ZERO_ENFORCEMENT" in signature_policy
    assert "FAIL_DEPLOYMENT_CREATE_ENFORCEMENT" in signature_policy
    assert "FAIL_DEPLOYMENT_UPDATE_ENFORCEMENT" in signature_policy
    cleanup = (ROOT / "scripts/cleanup-demo-artifacts.sh").read_text()
    assert "DELETE FROM results WHERE parent" in cleanup


def test_developer_admin_is_scoped_to_the_demo_application_namespace():
    platform = (ROOT / "deploy/pipelines/01-platform.yaml").read_text()

    assert "name: developer-application-admin" in platform
    assert "namespace: ai-email-demo" in platform
    assert "name: admin" in platform


def test_openclaw_exec_is_preapproved_for_the_isolated_runtime_demo():
    config = (ROOT / "deploy/base/29-openclaw-config.yaml").read_text()
    deployment = (ROOT / "deploy/base/30-openclaw.yaml").read_text()

    assert '"security": "full", "ask": "off"' in config
    assert '"askFallback": "full"' in config
    assert "exec-approvals.json" in deployment
    assert "configure-exec-approvals" in deployment
    assert "approvals set --stdin" in deployment
    assert "{name: HOME, value: /tmp}" in deployment
    assert "emptyDir" not in deployment
