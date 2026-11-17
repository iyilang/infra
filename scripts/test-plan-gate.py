#!/usr/bin/env python3
"""Check that the plan gate rejects representative destructive changes."""
import importlib.util
from pathlib import Path

path = Path(__file__).with_name('check-plan.py')
spec = importlib.util.spec_from_file_location('check_plan', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def plan(kind, actions, after):
    return {'resource_changes': [{
        'mode': 'managed',
        'type': kind,
        'address': f'{kind}.example',
        'change': {'actions': actions, 'after': after},
    }]}


assert not module.check(plan('google_firebase_hosting_site', ['create'], {'site_id': 'iyi-proxy'}))
assert not module.check(plan('google_project_service', ['create'], {'project': 'iyi-lang', 'service': 'run.googleapis.com'}))
for candidate in [
    plan('google_firebase_hosting_site', ['delete'], {'site_id': 'iyi-proxy'}),
    plan('google_firebase_hosting_site', ['delete', 'create'], {'site_id': 'iyi-proxy'}),
    plan('google_firebase_hosting_site', ['create'], {'site_id': 'unrelated-site'}),
    plan('google_cloud_run_v2_service', ['create'], {'name': 'unrelated-service'}),
    plan('google_project_iam_member', ['create'], {}),
    plan('google_project_service', ['create'], {'project': 'another-project', 'service': 'run.googleapis.com'}),
    plan('google_project_service', ['create'], {'project': 'iyi-lang', 'service': 'firebase.googleapis.com'}),
]:
    assert module.check(candidate), candidate
print('Plan gate accepts a valid creation and rejects deletes, replacements, foreign names, and IAM types.')
