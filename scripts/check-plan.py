#!/usr/bin/env python3
"""Check a saved Terraform plan without printing its contents."""
import json
import sys
from collections import Counter

ALLOWED = {
    "google_cloud_run_v2_job",
    "google_cloud_run_v2_service",
    "google_firebase_hosting_custom_domain",
    "google_firebase_hosting_site",
    "google_logging_project_exclusion",
    "google_project_service",
}
SERVICES = {
    "run.googleapis.com",
}


def _has_managed_resources(module):
    if not isinstance(module, dict):
        raise ValueError("invalid prior state")
    resources = module.get("resources", [])
    children = module.get("child_modules", [])
    if not isinstance(resources, list) or not isinstance(children, list):
        raise ValueError("invalid prior state")
    for resource in resources:
        if not isinstance(resource, dict) or resource.get("mode") not in {"managed", "data"}:
            raise ValueError("invalid prior state")
        if resource["mode"] == "managed":
            return True
    return any(_has_managed_resources(child) for child in children)


def first_plan(plan):
    """An empty managed state gets the creation-only policy."""
    if not isinstance(plan, dict):
        raise ValueError("invalid plan")
    prior = plan.get("prior_state")
    if prior is None:
        prior = {}
    if not isinstance(prior, dict):
        raise ValueError("invalid prior state")
    values = prior.get("values")
    if values is None:
        values = {}
    if not isinstance(values, dict):
        raise ValueError("invalid prior state")
    root = values.get("root_module")
    return root is None or not _has_managed_resources(root)


def check(plan):
    if not isinstance(plan, dict):
        return ["invalid plan"]
    try:
        creation_only = first_plan(plan)
    except ValueError:
        return ["invalid prior state"]
    errors = []
    if plan.get("errored") is True or plan.get("complete") is False:
        errors.append("plan is incomplete or errored")
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        return errors + ["missing resource changes"]
    for resource in changes:
        if not isinstance(resource, dict) or resource.get("mode") not in {"managed", "data"}:
            errors.append("invalid resource change")
            continue
        if resource["mode"] == "data":
            continue
        kind = resource.get("type")
        change = resource.get("change")
        if not isinstance(change, dict):
            errors.append("invalid resource change")
            continue
        actions = change.get("actions")
        if change.get("importing") is not None:
            errors.append("import is forbidden")
        if actions not in (["create"], ["no-op"], ["update"]):
            errors.append("deletion, replacement or unsupported action")
        elif creation_only and actions == ["update"]:
            errors.append("initial plan contains an update")
        if kind not in ALLOWED:
            errors.append("unexpected resource type")
        after = change.get("after")
        if after is None:
            after = {}
        if not isinstance(after, dict):
            errors.append("invalid resource values")
            continue
        if kind in {"google_cloud_run_v2_service", "google_cloud_run_v2_job"}:
            if not isinstance(after.get("name"), str) or not after["name"].startswith("iyi-"):
                errors.append("Cloud Run resource outside the iyi namespace")
        if kind == "google_firebase_hosting_site":
            if after.get("site_id") not in {"iyi-proxy", "iyi-sum", "iyi-probe"}:
                errors.append("unexpected Hosting site")
        if kind == "google_project_service":
            if after.get("project") != "iyi-lang" or after.get("service") not in SERVICES:
                errors.append("API or project outside the intended scope")
    return errors


def summary(plan, errors):
    mode = "initial creation-only" if first_plan(plan) else "subsequent non-destructive"
    counts = Counter()
    changes = plan.get("resource_changes", [])
    if isinstance(changes, list):
        for resource in changes:
            if isinstance(resource, dict) and resource.get("mode") == "managed":
                change = resource.get("change")
                actions = change.get("actions") if isinstance(change, dict) else None
                if actions == ["create"]:
                    counts["create"] += 1
                elif actions == ["update"]:
                    counts["update"] += 1
                elif actions == ["no-op"]:
                    counts["no-op"] += 1
                else:
                    counts["other"] += 1
    verdict = "rejected" if errors else "accepted"
    return (
        f"Terraform plan {verdict} ({mode}): {counts['create']} create, "
        f"{counts['update']} update, {counts['no-op']} no-op, {counts['other']} other."
    )


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-plan.py PLAN_JSON")
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            plan = json.load(source)
        errors = check(plan)
        print(summary(plan, errors))
    except (OSError, ValueError, TypeError):
        print("Terraform plan rejected: invalid or unavailable plan data.")
        raise SystemExit(1)
    if errors:
        print("Plan policy: " + "; ".join(sorted(set(errors))), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
