#!/usr/bin/env python3
"""Verify the offline bootstrap preview against the installed gcloud CLI help."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

# Fail closed on a new command until its positional contract has been reviewed.
# Each value is the inclusive minimum and maximum number of positional args.
COMMANDS = {
    "artifacts repositories add-iam-policy-binding": (1, 1),
    "artifacts repositories create": (1, 1),
    "artifacts repositories describe": (1, 1),
    "artifacts repositories get-iam-policy": (1, 1),
    "artifacts repositories set-cleanup-policies": (1, 1),
    "auth list": (0, 0),
    "auth print-access-token": (0, 0),
    "billing budgets create": (0, 0),
    "billing budgets list": (0, 0),
    "billing budgets update": (1, 1),
    "config list": (0, 0),
    "iam roles create": (1, 1),
    "iam roles describe": (1, 1),
    "iam service-accounts add-iam-policy-binding": (1, 1),
    "iam service-accounts create": (1, 1),
    "iam service-accounts describe": (1, 1),
    "iam service-accounts get-iam-policy": (1, 1),
    "iam workload-identity-pools create": (1, 1),
    "iam workload-identity-pools describe": (1, 1),
    "iam workload-identity-pools providers create-oidc": (1, 1),
    "iam workload-identity-pools providers describe": (1, 1),
    "iam workload-identity-pools providers list": (0, 0),
    "projects add-iam-policy-binding": (1, 1),
    "projects describe": (1, 1),
    "projects get-iam-policy": (1, 1),
    "secrets add-iam-policy-binding": (1, 1),
    "secrets create": (1, 1),
    "secrets describe": (1, 1),
    "secrets get-iam-policy": (1, 1),
    "services enable": (1, 1),
    "services list": (0, 0),
    "storage buckets add-iam-policy-binding": (1, 1),
    "storage buckets create": (1, 1),
    "storage buckets describe": (1, 1),
    "storage buckets get-iam-policy": (1, 1),
    "storage buckets update": (1, 1),
}


def preview_commands():
    # The preview prints shell-escaped arguments but never invokes gcloud.
    sentinel = "A1B2C3-D4E5F6-012345"
    env = dict(os.environ, PATH="/usr/bin:/bin", IYI_BILLING_ACCOUNT=sentinel)
    result = subprocess.run(
        ["/bin/bash", "bootstrap/bootstrap.sh", "--dry-run"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=True,
    )
    if sentinel in result.stdout or sentinel in result.stderr:
        raise RuntimeError("bootstrap preview exposed the billing account")
    commands = []
    for line in result.stdout.splitlines():
        if not (line.startswith("  + gcloud ") or line.startswith("  ? gcloud ")
                or line.startswith("  gcloud ")
                or line.startswith("CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true gcloud ")):
            continue
        words = shlex.split(line)
        words = words[words.index("gcloud") + 1:]
        # Budget templates document shell redirections. They are not arguments.
        words = [word for word in words if word not in (">/dev/null", "2>&1")]
        commands.append(words)
    if not commands:
        raise RuntimeError("bootstrap preview returned no gcloud commands")
    return commands


def command_name(words):
    for name in sorted(COMMANDS, key=lambda item: -len(item.split())):
        prefix = name.split()
        if words[:len(prefix)] == prefix:
            return name, words[len(prefix):]
    raise RuntimeError(f"unknown gcloud command in preview: {shlex.join(words)}")


def documented_flags(name):
    env = dict(os.environ, CLOUDSDK_CORE_DISABLE_FILE_LOGGING="true",
               CLOUDSDK_PAGER="cat", PAGER="cat")
    result = subprocess.run(["gcloud", *name.split(), "--help"], cwd=ROOT,
                            env=env, text=True, capture_output=True, check=True)
    synopsis = re.search(r"(?ms)^SYNOPSIS\n(.*?)(?=^[A-Z][A-Z ]*\n)", result.stdout)
    wide = re.search(r"(?ms)^GCLOUD WIDE FLAGS\n(.*?)(?=^[A-Z][A-Z ]*\n|\Z)", result.stdout)
    if not synopsis or not wide:
        raise RuntimeError(f"could not parse installed gcloud help for {name}")
    result_flags = set()
    for match in re.finditer(r"--(\[no-\])?([a-z][a-z0-9-]*)", synopsis.group(1) + wide.group(1)):
        result_flags.add("--" + match.group(2))
        if match.group(1):
            result_flags.add("--no-" + match.group(2))
    # Calliope automatically supplies a hidden inverse for this bool flag.
    # The SDK's set_cleanup_policies.yaml declares it type: bool, and
    # parser_arguments.py registers --no-* for store_true actions. Omitting
    # the inverse would leave an existing dry-run policy enabled.
    if (name == "artifacts repositories set-cleanup-policies"
            and "--dry-run" in result_flags):
        result_flags.add("--no-dry-run")
    return result_flags


def main():
    commands = preview_commands()
    parsed = [(command_name(words), words) for words in commands]
    used = {name for ((name, _), _) in parsed}
    if used != set(COMMANDS):
        raise RuntimeError(f"preview is missing reviewed gcloud commands: {sorted(set(COMMANDS) - used)}")
    flags = {name: documented_flags(name) for name in sorted(used)}
    errors = set()
    for ((name, args), _) in parsed:
        positional = []
        values = {arg.split("=", 1)[0]: arg.split("=", 1)[1]
                  for arg in args if arg.startswith("--") and "=" in arg}
        for arg in args:
            if arg.startswith("--"):
                flag = arg.split("=", 1)[0]
                if flag not in flags[name]:
                    errors.add(f"gcloud {name}: undocumented flag {flag}")
            else:
                positional.append(arg)
        minimum, maximum = COMMANDS[name]
        if not minimum <= len(positional) <= maximum:
            errors.add(f"gcloud {name}: expected {minimum}..{maximum} positional arguments, got {positional!r}")
        if name == "iam workload-identity-pools providers create-oidc":
            mapping = ("google.subject=assertion.sub,attribute.repository=assertion.repository,"
                       "attribute.repo_event=assertion.repository + ':' + assertion.event_name")
            condition = ("assertion.repository == 'iyilang/infra' && assertion.repository_id == '1461001280'"
                         " && assertion.repository_owner_id == '327116875'"
                         " && (assertion.event_name == 'pull_request' || (assertion.event_name == 'push'"
                         " && assertion.ref == 'refs/heads/main'))"
                         " && assertion.workflow_ref.startsWith('iyilang/infra/.github/workflows/terraform.yml@')")
            if values.get("--attribute-mapping") != mapping or values.get("--attribute-condition") != condition:
                errors.add("OIDC mapping or condition was changed or split by shell quoting")
        if name in ("storage buckets create", "storage buckets update") and any(
                not item.startswith("gs://") for item in positional):
            errors.add(f"gcloud {name}: expected gs:// bucket URL, got {positional!r}")
    if errors:
        raise RuntimeError("\n".join(sorted(errors)))
    for name in sorted(used):
        print(f"verified gcloud {name}")
    print(f"Verified {len(commands)} preview commands across {len(used)} gcloud command forms.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
