#!/usr/bin/env python3
"""Exercise --check against a local, read-only fake gcloud command."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "bootstrap" / "bootstrap.sh"
MARKER = "managed-by: iyilang/infra bootstrap"
PROVIDER = "projects/477913052471/locations/global/workloadIdentityPools/iyi-github/providers/github"
LABELS = {"stack": "iyi", "managed_by": "iyi_infra"}


def arguments(words):
    return dict(word[2:].split("=", 1) for word in words if word.startswith("--") and "=" in word)


def build_fixture():
    # Derive role permissions and expected bindings from the script's offline
    # preview, so this fixture follows the policy the operator actually checks.
    env = dict(os.environ, PATH="/usr/bin:/bin", IYI_BILLING_ACCOUNT="")
    preview = subprocess.run(["/bin/bash", str(SCRIPT), "--dry-run"], cwd=ROOT,
                             env=env, text=True, capture_output=True, check=True).stdout
    fixture = {"roles": {}, "policies": {}}
    for line in preview.splitlines():
        if not line.startswith("  + gcloud "):
            continue
        words = shlex.split(line)[2:]
        flags = arguments(words)
        if words[:3] == ["iam", "roles", "create"]:
            fixture["roles"][words[3]] = flags["permissions"].split(",")
        if words[:4] == ["iam", "workload-identity-pools", "providers", "create-oidc"]:
            fixture["condition"] = flags["attribute-condition"]
        if "add-iam-policy-binding" in words:
            index = words.index("add-iam-policy-binding")
            key = " ".join(words[:index]) + " " + words[index + 1]
            fixture["policies"].setdefault(key, []).append(
                {"role": flags["role"], "members": [flags["member"]]})
    return fixture


def fake_gcloud(words):
    state = json.loads(Path(os.environ["IYI_FAKE_STATE"]).read_text())
    scenario = os.environ["IYI_FAKE_SCENARIO"]
    if words[:2] == ["config", "list"]:
        result = {"auth": "not an object"} if scenario == "malformed-config" else {}
    elif words[:2] == ["auth", "list"]:
        print("operator@example.test")
        return
    elif words[:2] == ["auth", "print-access-token"]:
        print("local-fake-token")
        return
    elif words[:2] == ["projects", "describe"]:
        print("477913052471")
        return
    elif words[:2] == ["services", "list"]:
        print("\n".join(["iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
                         "cloudresourcemanager.googleapis.com", "artifactregistry.googleapis.com",
                         "secretmanager.googleapis.com", "storage.googleapis.com", "billingbudgets.googleapis.com"]))
        return
    elif words[:3] == ["billing", "budgets", "list"]:
        result = [{"displayName": "iyi-lang monthly alert", "budgetFilter": {"projects": ["projects/477913052471"]},
                   "amount": {"specifiedAmount": {"currencyCode": "USD", "units": "200"}},
                   "thresholdRules": [{"thresholdPercent": x} for x in (0.5, 0.9, 1)]}]
    elif words[:3] == ["iam", "workload-identity-pools", "describe"]:
        result = {"description": MARKER, "state": "ACTIVE"}
    elif words[:4] == ["iam", "workload-identity-pools", "providers", "list"]:
        result = [{"name": PROVIDER, "state": "ACTIVE"}]
    elif words[:4] == ["iam", "workload-identity-pools", "providers", "describe"]:
        result = {"description": MARKER, "state": "ACTIVE", "oidc": {"issuerUri": "https://token.actions.githubusercontent.com"},
                  "attributeCondition": state["condition"], "attributeMapping": {
                      "google.subject": "assertion.sub", "attribute.repository": "assertion.repository",
                      "attribute.repo_event": "assertion.repository + ':' + assertion.event_name"}}
    elif words[:3] == ["iam", "service-accounts", "describe"]:
        result = {"description": MARKER}
    elif words[:3] == ["storage", "buckets", "describe"]:
        result = {"projectNumber": "477913052471", "location": "US-CENTRAL1", "labels": LABELS,
                  "iamConfiguration": {"uniformBucketLevelAccess": {"enabled": True},
                                       "publicAccessPrevention": "enforced"}, "versioning": {"enabled": True}}
    elif words[:3] == ["artifacts", "repositories", "describe"]:
        if scenario == "registry-permission-denied":
            print("ERROR: PERMISSION_DENIED 403: repository not found or forbidden", file=sys.stderr)
            raise SystemExit(1)
        if scenario == "registry-not-found":
            print("ERROR: NOT_FOUND 404: repository not found", file=sys.stderr)
            raise SystemExit(1)
        if scenario == "registry-stdout-banner":
            print("Encryption: Google-managed key")
        labels = dict(LABELS)
        if scenario == "wrong-label":
            labels["managed_by"] = "someone_else"
        result = {"format": "MAVEN" if scenario == "wrong-format" else "DOCKER", "labels": labels,
                  "cleanupPolicyDryRun": False, "cleanupPolicies": {
                      "retain-recent-images": {"action": "KEEP", "mostRecentVersions": {"keepCount": 5}},
                      "remove-older-images": {"action": "DELETE", "condition": {"olderThan": "2592000s"}}}}
        print("Encryption: Google-managed key\nRepository Size: 0.000MB", file=sys.stderr)
    elif words[:2] == ["secrets", "describe"]:
        result = {"labels": LABELS}
    elif words[:3] == ["iam", "roles", "describe"]:
        result = {"description": MARKER, "stage": "GA", "includedPermissions": state["roles"][words[3]]}
    elif "get-iam-policy" in words:
        index = words.index("get-iam-policy")
        key = " ".join(words[:index]) + " " + words[index + 1]
        result = {"bindings": [{"role": "roles/owner", "members": "not an array"}]} if scenario == "malformed-policy" else {
            "bindings": state["policies"].get(key, [])}
    else:
        raise SystemExit(f"fake gcloud rejected non-read or unknown command: {words!r}")
    if scenario == "all-warnings":
        print("WARNING: fake diagnostic on stderr", file=sys.stderr)
    print(json.dumps(result))


def run_check(fake_dir, scenario):
    env = dict(os.environ, PATH=f"{fake_dir}:/usr/bin:/bin",
               IYI_BILLING_ACCOUNT="ABC123-DEF456-ABC123", IYI_FAKE_SCENARIO=scenario,
               IYI_FAKE_STATE=str(Path(fake_dir) / "state.json"))
    for name in ("GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_OAUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE",
                 "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT", "CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
                 "CLOUDSDK_AUTH_DISABLE_CREDENTIALS", "CLOUDSDK_CORE_ACCOUNT", "CI", "GITHUB_ACTIONS"):
        env.pop(name, None)
    return subprocess.run(["/bin/bash", str(SCRIPT), "--check"], cwd=ROOT, env=env, text=True, capture_output=True)


def main():
    with tempfile.TemporaryDirectory(prefix="iyi-bootstrap-check-") as directory:
        fake = Path(directory) / "gcloud"
        fake.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(__file__)} --fake-gcloud \"$@\"\n")
        fake.chmod(0o755)
        (Path(directory) / "state.json").write_text(json.dumps(build_fixture()))
        for scenario in ("registry-warning", "all-warnings"):
            result = run_check(directory, scenario)
            if result.returncode != 0:
                raise AssertionError(f"{scenario}: expected a clean check, got exit {result.returncode}\n{result.stderr}\n{result.stdout}")
            if "Bootstrap check: all required resources are present and compatible." not in result.stdout:
                raise AssertionError(f"{scenario}: missing clean summary")
        for scenario in ("wrong-format", "wrong-label"):
            result = run_check(directory, scenario)
            if result.returncode == 0 or "wrong format or ownership labels" not in result.stderr:
                raise AssertionError(f"{scenario}: registry drift was accepted\n{result.stderr}\n{result.stdout}")
        for scenario, expected in (
            ("malformed-config", "UNREADABLE (invalid auth section)"),
            ("malformed-policy", "UNREADABLE (invalid IAM policy bindings)"),
            ("registry-stdout-banner", "UNREADABLE (expected a single JSON object)"),
            ("registry-permission-denied", "UNREADABLE (authorization or authentication error)"),
            ("registry-not-found", "Artifact Registry repository iyi: ABSENT"),
        ):
            result = run_check(directory, scenario)
            if result.returncode == 0 or expected not in result.stderr + result.stdout:
                raise AssertionError(f"{scenario}: failed to reject or classify the response\n{result.stderr}\n{result.stdout}")
            if "Bootstrap check: all required resources are present and compatible." in result.stdout:
                raise AssertionError(f"{scenario}: failed check claimed success")
    print("Bootstrap check accepts stderr diagnostics and rejects wrong registry format and ownership labels.")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake-gcloud":
        fake_gcloud(sys.argv[2:])
    else:
        main()
