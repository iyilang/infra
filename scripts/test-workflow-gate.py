#!/usr/bin/env python3
"""Check the actual job guard and its truth table without external packages."""
from pathlib import Path
import re

workflow = Path('.github/workflows/terraform.yml').read_text(encoding='utf-8')
match = re.search(r'(?ms)^  apply:\n    if: \$\{\{ (.*?) \}\}', workflow)
if not match:
    raise SystemExit('apply job guard is absent')
guard = match.group(1)
expected = "github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.IYI_APPLY_ENABLED == 'true'"
if guard != expected:
    raise SystemExit(f'unexpected apply job guard: {guard}')
if 'pull_request_target:' in workflow:
    raise SystemExit('pull_request_target is forbidden')

bootstrap = Path('bootstrap/bootstrap.sh').read_text(encoding='utf-8')
for required in (
    'PLAN_POOL="iyi-plan-github"',
    'PLAN_ACCOUNT="iyi-terraform-plan"',
    "assertion.ref == 'refs/heads/main' && assertion.event_name == 'push'",
    'workloadIdentityPools/${PLAN_POOL}/attribute.repository/iyilang/infra',
):
    if required not in bootstrap:
        raise SystemExit(f'identity isolation condition missing: {required}')
if 'vars.IYI_PLAN_SERVICE_ACCOUNT' not in workflow or 'vars.IYI_PLAN_WIF_PROVIDER' not in workflow:
    raise SystemExit('pull request plan does not use its own identity')

# The exact checked expression requires all three clauses. A fork PR has
# pull_request as its event name, independently of its branch or opt-in flag.
for event, ref, enabled, allowed in [
    ('pull_request', 'refs/heads/main', 'true', False),
    ('pull_request', 'refs/pull/1/merge', 'true', False),
    ('workflow_dispatch', 'refs/heads/main', 'true', False),
    ('push', 'refs/heads/feature', 'true', False),
    ('push', 'refs/heads/main', 'false', False),
    ('push', 'refs/heads/main', 'true', True),
]:
    actual = event == 'push' and ref == 'refs/heads/main' and enabled == 'true'
    if actual != allowed:
        raise SystemExit(f'apply guard failed for {(event, ref, enabled)}')
print('Apply guard denies fork PRs, dispatches, non-main pushes, and disabled pushes.')
