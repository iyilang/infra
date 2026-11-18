#!/usr/bin/env python3
"""Exercise the state preflight with fake Cloud Storage responses."""

import importlib.util
import io
import json
import os
import re
import subprocess
import tempfile
import textwrap
from contextlib import redirect_stdout
from unittest.mock import patch
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse

SCRIPT = Path(__file__).resolve().parent / "check-terraform-state.py"
spec = importlib.util.spec_from_file_location("state_probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return io.BytesIO(response if isinstance(response, bytes) else json.dumps(response).encode())


def test_absent_verdict():
    workflow = (SCRIPT.parent.parent / ".github/workflows/terraform.yml").read_text()
    plan = workflow.split("\n  plan:\n", 1)[1].split("\n  apply:\n", 1)[0]
    for name in ("Initialize and validate", "Create plan", "Check plan policy"):
        match = re.search(rf"(?ms)^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", plan)
        assert match and "if: ${{ steps.state.outputs.state == 'present' }}" in match.group(1), name
    auth = re.search(r"(?ms)^      - uses: .*?\n        id: plan_auth\n(.*?)(?=^      - |\Z)", plan)
    assert auth and "if: ${{ steps.state.outputs.state == 'present' }}" in auth.group(1)
    comment = re.search(r"(?ms)^      - name: Comment plan verdict\n.*?^        run: \|\n((?:          .*\n)+)", plan)
    assert comment, "plan verdict step not found"
    script = textwrap.dedent(comment.group(1))
    with tempfile.TemporaryDirectory(prefix="iyi-state-test-") as directory:
        output = Path(directory) / "output"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output), "IYI_STATE_TOKEN": "fake"}), \
                patch.object(probe, "state_exists", return_value=False), redirect_stdout(io.StringIO()):
            probe.main()
        assert output.read_text() == "state=absent\n"
        capture = Path(directory) / "comment"
        gh = Path(directory) / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$GH_CAPTURE"\n')
        gh.chmod(0o755)
        env = dict(os.environ, PATH=f"{directory}:/usr/bin:/bin", GH_CAPTURE=str(capture),
                   GH_TOKEN="fake", GITHUB_REPOSITORY="iyilang/infra", PR_NUMBER="1",
                   PROVIDER_STATUS="ok", AUTH_OUTCOME="success", PREINIT_AUTH_OUTCOME="success",
                   PLAN_AUTH_OUTCOME="skipped", STATE_STATUS="absent", PLAN_SUMMARY="")
        result = subprocess.run(["/bin/bash", "-e", "-c", script], env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert "body=No Terraform state yet: the first apply on main creates it; PR plans work after that\n" in capture.read_text()


def main():
    token = "test-access-token"
    empty = FakeOpener({})
    assert probe.state_exists(token, empty) is False
    parsed = urlparse(empty.requests[0].full_url)
    assert parsed.scheme == "https" and parsed.netloc == "storage.googleapis.com"
    assert parsed.path == "/storage/v1/b/iyi-lang-tfstate/o"
    assert parse_qs(parsed.query)["prefix"] == ["iyi/default.tfstate"]
    assert empty.requests[0].get_header("Authorization") == f"Bearer {token}"
    assert probe.state_exists(token, FakeOpener({"items": [{"name": probe.OBJECT}]})) is True
    assert probe.state_exists(token, FakeOpener({"items": [{"name": probe.OBJECT + ".backup"}]})) is False
    paged = FakeOpener({"items": [], "nextPageToken": "next"}, {"items": [{"name": probe.OBJECT}]})
    assert probe.state_exists(token, paged) is True
    assert parse_qs(urlparse(paged.requests[1].full_url).query)["pageToken"] == ["next"]
    for response in (
        HTTPError("https://storage.googleapis.com", 403, "Forbidden", {}, None),
        HTTPError("https://storage.googleapis.com", 404, "Not found", {}, None),
        URLError("network failure"),
        b"not json",
        {"items": None},
        {"items": [{}]},
        {"error": {"message": "hidden error"}},
        {"nextPageToken": ""},
    ):
        try:
            probe.state_exists(token, FakeOpener(response))
        except probe.StateProbeError:
            pass
        else:
            raise AssertionError(f"invalid or inaccessible listing treated as absent: {response!r}")
    try:
        probe.state_exists("", FakeOpener({}))
    except probe.StateProbeError:
        pass
    else:
        raise AssertionError("missing access token accepted")
    test_absent_verdict()
    print("State preflight distinguishes absent, present, and unreadable without requesting state contents.")


if __name__ == "__main__":
    main()
