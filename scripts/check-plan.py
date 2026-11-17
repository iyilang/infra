#!/usr/bin/env python3
"""Reject destructive and out-of-scope Terraform plans."""
import json
import sys

ALLOWED = {
    "google_artifact_registry_repository",
    "google_billing_budget",
    "google_cloud_run_v2_service",
    "google_cloud_run_v2_service_iam_member",
    "google_firebase_hosting_custom_domain",
    "google_firebase_hosting_release",
    "google_firebase_hosting_site",
    "google_firebase_hosting_version",
    "google_logging_project_exclusion",
    "google_secret_manager_secret",
    "google_secret_manager_secret_iam_member",
    "google_secret_manager_secret_version",
    "google_storage_bucket",
    "google_storage_bucket_iam_member",
    "tls_private_key",
}


def check(plan):
    errors = []
    for resource in plan.get("resource_changes", []):
        if resource.get("mode") != "managed":
            continue
        address = resource["address"]
        if resource["type"] not in ALLOWED:
            errors.append(f"{address}: unexpected resource type")
        actions = resource["change"]["actions"]
        if "delete" in actions:
            errors.append(f"{address}: deletion or replacement is forbidden")
        if resource["type"] == "google_cloud_run_v2_service":
            name = (resource["change"].get("after") or {}).get("name", "")
            if not name.startswith("iyi-"):
                errors.append(f"{address}: service is outside the iyi namespace")
        if resource["type"] == "google_firebase_hosting_site":
            name = (resource["change"].get("after") or {}).get("site_id", "")
            if name not in {"iyi-proxy", "iyi-sum", "iyi-newsletter", "iyi-probe"}:
                errors.append(f"{address}: unexpected Hosting site")
    return errors


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-plan.py PLAN_JSON")
    with open(sys.argv[1], encoding="utf-8") as source:
        errors = check(json.load(source))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print("Plan contains no forbidden resource types, deletes, or replacements.")


if __name__ == "__main__":
    main()
