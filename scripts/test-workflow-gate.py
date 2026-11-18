#!/usr/bin/env python3
"""Check workflow trust boundaries without cloud credentials or extra packages."""
from pathlib import Path
import re

workflow = Path(".github/workflows/terraform.yml").read_text(encoding="utf-8")
deploy = Path("scripts/deploy.sh").read_text(encoding="utf-8")


def job(name):
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", workflow)
    if not match:
        raise SystemExit(f"{name} job is absent")
    return match.group(1)


def guard(body):
    match = re.search(r"(?m)^    if: \$\{\{ (.*?) \}\}$", body)
    if not match:
        raise SystemExit("job guard is absent")
    return match.group(1)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


validate = job("validate")
plan = job("plan")
apply = job("apply")
require(not re.search(r"(?m)^\s*(pull_request_target|workflow_dispatch):", workflow),
        "privileged PR or manual dispatch trigger is forbidden")
require(guard(plan) == "github.repository == 'iyilang/infra' && github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository",
        "plan must be restricted to same-repository pull requests in iyilang/infra")
require(guard(apply) == "github.repository == 'iyilang/infra' && github.event_name == 'push' && github.ref == 'refs/heads/main'",
        "apply must be restricted to pushes to main in iyilang/infra")

# The exact guard above must refuse fork repositories, PRs and non-main events.
for repo, event, ref, allowed in (
    ("iyilang/infra", "pull_request", "refs/heads/main", False),
    ("iyilang/infra", "pull_request", "refs/pull/1/merge", False),
    ("iyilang/infra", "workflow_dispatch", "refs/heads/main", False),
    ("iyilang/infra", "push", "refs/heads/feature", False),
    ("someone/infra", "push", "refs/heads/main", False),
    ("iyilang/infra", "push", "refs/heads/main", True),
):
    require((repo == "iyilang/infra" and event == "push" and ref == "refs/heads/main") == allowed,
            f"apply guard truth table failed for {repo} {event} {ref}")
for repo, event, head_repo, allowed in (
    ("iyilang/infra", "pull_request", "someone/infra", False),
    ("someone/infra", "pull_request", "someone/infra", False),
    ("iyilang/infra", "pull_request", "iyilang/infra", True),
    ("iyilang/infra", "push", "iyilang/infra", False),
):
    require((repo == "iyilang/infra" and event == "pull_request" and head_repo == repo) == allowed,
            f"plan guard truth table failed for {repo} {event} {head_repo}")

require("id-token: write" not in validate and "google-github-actions/auth" not in validate,
        "credential-free validation must not request a cloud identity")
require("id-token: write" in plan and "pull-requests: write" in plan,
        "plan needs OIDC and pull request comment permissions")
require("google-github-actions/auth@" in plan and "service_account:" not in plan,
        "plan must authenticate directly through workload identity")
require("workload_identity_provider: ${{ vars.IYI_WIF_PROVIDER }}" in plan,
        "plan must use the shared provider")
require("service_account: ${{ vars.IYI_DEPLOYER_SERVICE_ACCOUNT }}" in apply,
        "apply must impersonate the deployer")
require("workload_identity_provider: ${{ vars.IYI_WIF_PROVIDER }}" in apply,
        "apply must use the shared provider")
require("IYI_APPLY_ENABLED" not in workflow, "main apply must not silently skip")
require("terraform_wrapper: false" in plan and "terraform_wrapper: false" in apply,
        "Terraform wrapper must be disabled")
require('-chdir=terraform plan -input=false -lock=false' in plan,
        "plan must use the read-only state path without a lock")

# Every captured Terraform failure must print only its sanitized diagnostic.
def checked_failure_logs(body, expected):
    branches = re.findall(
        r'(?ms)^[ \t]*if ! terraform -chdir=terraform (init|validate|plan|show|apply) '
        r'[^\n]*>"\$RUNNER_TEMP/iyi-(init|validate|plan|show|apply)\.log"[^\n]*; then\n'
        r'(.*?)(?=^[ \t]*fi[ \t]*$)', body)
    return (len(branches) == len(expected) and {name for name, _, _ in branches} == set(expected) and
            all(name == log and f'python3 scripts/print-sanitized-log.py "$RUNNER_TEMP/iyi-{log}.log"' in branch
                and "exit 1" in branch for name, log, branch in branches))


require(checked_failure_logs(plan, ("init", "validate", "plan", "show")),
        "every PR Terraform failure must print its sanitized diagnostic and fail")
require(checked_failure_logs(apply, ("init", "validate", "plan", "show", "apply")),
        "every apply Terraform failure must print its sanitized diagnostic and fail")
require(not checked_failure_logs(plan.replace(
    'python3 scripts/print-sanitized-log.py "$RUNNER_TEMP/iyi-init.log"', "true", 1),
    ("init", "validate", "plan", "show")), "failure-log guard must detect a missing sanitizer")
require(not re.search(r'\b(?:cat|head|tail|tee|less)\b[^\n]*\$RUNNER_TEMP/iyi-(?:init|validate|plan|show|apply)\.log', workflow),
        "raw Terraform diagnostic files must not be printed")
require(not re.search(r'\b(?:cat|head|tail|tee|less)\b[^\n]*\$RUNNER_TEMP/iyi(?:-plan\.json|\.tfplan)', workflow),
        "saved plans and JSON plans must not be printed")
require("TF_LOG" not in workflow, "Terraform debug logging may expose credentials")
require("python3 scripts/test-sanitized-log.py" in validate and "python3 scripts/test-terraform-state.py" in validate,
        "credential-free validation must exercise log redaction and state preflight")
require("python3 scripts/check-terraform-state.py" in plan and
        "IYI_STATE_TOKEN: ${{ steps.preinit_auth.outputs.auth_token }}" in plan,
        "PR state preflight must use the existing direct-WIF identity")
for body in (plan, apply):
    require('IYI_WIF_PROVIDER is missing' in body,
            "missing provider must fail explicitly")
    require('terraform -chdir=terraform show -json' in body and '\"$RUNNER_TEMP/iyi-plan.json\"' in body,
            "plan JSON must stay in RUNNER_TEMP")
    require('python3 scripts/check-plan.py \"$RUNNER_TEMP/iyi-plan.json\"' in body,
            "saved plan must pass the policy gate")
    for block in re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", body):
        require("${{" not in block, "workflow expressions must not be interpolated into shell code")
require("gh api --method POST" in plan and 'body=\"$message\"' in plan,
        "plan must post a quoted verdict comment")
require("gcloud " not in plan, "PR plan must not run gcloud commands")
require('IYI_BILLING_ACCOUNT' not in workflow and 'TF_VAR_billing_account' not in workflow,
        "CI must not receive the billing account identifier")

action_lines = re.findall(r"(?m)^\s*- uses: ([^\n]+)$", workflow)
require(action_lines, "workflow has no actions")
for action in action_lines:
    require(re.fullmatch(r"[^@\s]+@[0-9a-f]{40} # v[0-9]+", action) is not None,
            f"action is not pinned to a commit with a version comment: {action}")
require('$GITHUB_SHA-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT' in apply,
        "probe tag must identify the revision and run attempt")
require('probe@$digest' in apply and 'value(image_summary.digest)' in apply,
        "probe services must use the pushed immutable digest")
require('"iyi-probe-public": $image, "iyi-probe-internal": $image' in apply,
        "both probe services must use the resolved image")

key_step = re.search(r"(?ms)^      - name: Ensure staging signing key exists\n(.*?)(?=^      - |\Z)", apply)
require(key_step is not None, "staging signing key initialization is absent")
key_step = key_step.group(1)
require("genpkey" not in plan and "genpkey" not in validate,
        "staging key generation must run only in the guarded apply job")
require("set -o pipefail" in key_step and "secret=iyi-sum-staging-signing-key" in key_step,
        "key initialization must use pipefail and the staging secret")
require('if ! enabled=$(gcloud secrets versions list "$secret"' in key_step and
        "--filter='state=ENABLED'" in key_step and 'if [[ -n "$enabled" ]]' in key_step,
        "key initialization must check enabled versions and fail on list errors")
key_operations = (
    '["openssl", "genpkey", "-algorithm", "ED25519"]',
    '["openssl", "pkey", "-check", "-noout"]',
    '["gcloud", "secrets", "versions", "add", "iyi-sum-staging-signing-key"',
)
key_positions = [key_step.find(operation) for operation in key_operations]
require(all(position >= 0 for position in key_positions) and key_positions == sorted(key_positions),
        "key generation and validation must precede the Secret Manager write")
require("key = subprocess.run(" in key_step and "stdout=subprocess.PIPE" in key_step and
        key_step.count("check=True") == 3 and key_step.count("input=key") == 2 and
        "stderr=subprocess.DEVNULL" in key_step and '"--data-file=-"' in key_step and
        "tee " not in key_step and "set -x" not in key_step,
        "validated key bytes must stay in memory and pass to Secret Manager over stdin")
require('gcloud_env["CLOUDSDK_CORE_DISABLE_FILE_LOGGING"] = "true"' in key_step and
        'gcloud_env["CLOUDSDK_CORE_LOG_HTTP"] = "false"' in key_step and
        key_step.find("env=gcloud_env") > key_positions[2],
        "gcloud secret upload must disable file and HTTP logging")

ordered = (
    "google-github-actions/auth@",
    "google-github-actions/setup-gcloud@",
    "gcloud secrets versions list",
    "gcloud artifacts repositories describe",
    'docker build --tag \"$image\" probe',
    'docker push \"$PROBE_IMAGE_TAG\"',
    "gcloud artifacts docker images describe",
    "terraform -chdir=terraform plan",
    "python3 scripts/check-plan.py",
    "terraform -chdir=terraform apply",
    "bash scripts/deploy.sh",
    "bash scripts/set-hosting-retention.sh",
)
positions = [apply.find(phrase) for phrase in ordered]
require(all(position >= 0 for position in positions) and positions == sorted(positions),
        "apply must push the probe image, gate and apply Terraform, then deploy Hosting and retention")
require("firebase-tools@15.36.0" in deploy and "hosting:sites:list" in deploy,
        "Hosting deployment must use the pinned CLI and check site existence")
require("GITHUB_REPOSITORY" in deploy and "iyilang/infra" in deploy and
        "GITHUB_EVENT_NAME" in deploy and "refs/heads/main" in deploy,
        "Hosting script must refuse forks and non-main or non-push execution")
for required in ("iyi-probe-public", "iyi-probe-internal", "probe/firebase.json",
                 "hosting/proxy.firebase.json", "hosting/sum.firebase.json", "noindex"):
    require(required in deploy, f"Hosting deployment is missing {required}")
print("Workflow guards reject fork and non-main applies and isolate PR plans from the deployer.")
