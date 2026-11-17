#!/usr/bin/env python3
"""Exercise the first-plan and non-destructive plan policies."""
import importlib.util
from pathlib import Path

path = Path(__file__).with_name("check-plan.py")
spec = importlib.util.spec_from_file_location("check_plan", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def plan(kind, actions, after, *, existing=False):
    result = {"resource_changes": [{
        "mode": "managed",
        "type": kind,
        "address": f"{kind}.example",
        "change": {"actions": actions, "after": after},
    }]}
    if existing:
        result["prior_state"] = {
            "values": {"root_module": {"resources": [{"mode": "managed"}]}}
        }
    return result


site = {"site_id": "iyi-proxy"}
initial_create = plan("google_firebase_hosting_site", ["create"], site)
initial_noop = plan("google_firebase_hosting_site", ["no-op"], site)
initial_update = plan("google_firebase_hosting_site", ["update"], site)
later_update = plan("google_firebase_hosting_site", ["update"], site, existing=True)
assert not module.check(initial_create)
assert not module.check(initial_noop)
assert module.check(initial_update)
assert not module.check(later_update)
assert "initial creation-only" in module.summary(initial_create, [])
assert "subsequent non-destructive" in module.summary(later_update, [])
assert not module.check(plan("google_project_service", ["create"], {
    "project": "iyi-lang", "service": "run.googleapis.com",
}))
assert not module.check(plan("google_cloud_run_v2_job", ["create"], {"name": "iyi-ingest"}))

# Hosting site IDs must never be deleted or replaced in either order.
for existing in (False, True):
    for site_id in ("iyi-proxy", "iyi-sum", "iyi-probe"):
        for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
            candidate = plan("google_firebase_hosting_site", actions, {"site_id": site_id}, existing=existing)
            assert module.check(candidate), (existing, site_id, actions)
    for actions in (["forget"], ["read"]):
        assert module.check(plan("google_firebase_hosting_site", actions, site, existing=existing))
    for kind, after in (
        ("google_cloud_run_v2_service", {"name": "iyi-probe-public"}),
        ("google_firebase_hosting_custom_domain", {}),
        ("google_secret_manager_secret_version", {}),
    ):
        for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
            assert module.check(plan(kind, actions, after, existing=existing)), (kind, actions)
    for kind, after in (
        ("google_firebase_hosting_site", {"site_id": "unrelated-site"}),
        ("google_cloud_run_v2_service", {"name": "unrelated-service"}),
        ("google_cloud_run_v2_job", {"name": "unrelated-job"}),
        ("google_project_iam_member", {}),
        ("google_firebase_hosting_release", {}),
        ("google_secret_manager_secret_version", {}),
        ("tls_private_key", {}),
        ("google_billing_budget", {}),
        ("google_project_service", {"project": "iyi-lang", "service": "cloudbilling.googleapis.com"}),
        ("google_project_service", {"project": "iyi-lang", "service": "billingbudgets.googleapis.com"}),
        ("google_project_service", {"project": "another-project", "service": "run.googleapis.com"}),
        ("google_project_service", {"project": "iyi-lang", "service": "artifactregistry.googleapis.com"}),
    ):
        assert module.check(plan(kind, ["create"], after, existing=existing)), (kind, after)

imported = plan("google_firebase_hosting_site", ["no-op"], site, existing=True)
imported["resource_changes"][0]["change"]["importing"] = {"id": "existing"}
assert module.check(imported)
incomplete = plan("google_firebase_hosting_site", ["create"], site)
incomplete["complete"] = False
assert module.check(incomplete)
assert module.check({"prior_state": {"values": {"root_module": []}}, "resource_changes": []})
assert module.check({})

# Data-only state is still an initial plan. A managed child module is not.
data_only = plan("google_firebase_hosting_site", ["update"], site)
data_only["prior_state"] = {
    "values": {"root_module": {"resources": [{"mode": "data"}]}}
}
assert module.check(data_only)
child_state = plan("google_firebase_hosting_site", ["update"], site)
child_state["prior_state"] = {
    "values": {"root_module": {"child_modules": [{"resources": [{"mode": "managed"}]}]}}
}
assert not module.check(child_state)
print("Plan gate rejects initial updates, deletes, replacements, imports, and unexpected resources.")
