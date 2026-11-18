#!/usr/bin/env python3
"""Check diagnostic redaction and fail-closed GitHub Actions output."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "print-sanitized-log.py"


def run(path):
    return subprocess.run([sys.executable, str(SCRIPT), str(path)], text=True, capture_output=True)


def main():
    jwt = "eyJ" + "A" * 22 + "." + "eyJ" + "B" * 22 + "." + "C" * 32
    oauth = "ya" + "29." + "sample_access_value_12345"
    refresh = "1//0" + "a" * 24
    api_key = "AI" + "za" + "b" * 35
    gh_token = "gh" + "p_" + "c" * 36
    aws_key = "AK" + "IA" + "A" * 16
    private = "synthetic-secret-key-material"
    begin_key = "-----" + "BEGIN PRIVATE KEY" + "-----"
    end_key = "-----" + "END PRIVATE KEY" + "-----"
    payload = ("Terraform initialization failed: storage.objects.create denied for "
               "gs://iyi-lang-tfstate/iyi/default.tflock\n"
               f"Authorization: Bearer {oauth}\n"
               f"access_token={oauth}\nsubject_token: {jwt}\n"
               f"refresh_token: {refresh}\napi_key={api_key}\n"
               f"github credential: {gh_token}\naws access id: {aws_key}\n"
               "AWS_SECRET_ACCESS_KEY=synthetic-aws-secret\n"
               'GOOGLE_OAUTH_ACCESS_TOKEN="synthetic-nonstandard-token"\n'
               f"{begin_key}\n{private}\n{end_key}\n"
               "https://storage.googleapis.com/object?X-Goog-Signature=synthetic-signature&x=1\n"
               "postgres://user:synthetic-password@example.test/db\n"
               "image sha256:" + "d" * 64 + "\n"
               "::error::injected\ntext ##[error]legacy injection\n")
    with tempfile.TemporaryDirectory(prefix="iyi-sanitizer-") as directory:
        path = Path(directory) / "terraform.log"
        path.write_text(payload)
        first = run(path)
        second = run(path)
        assert first.returncode == 0 and second.returncode == 0, first.stderr
        for secret in (jwt, oauth, refresh, api_key, gh_token, aws_key, private,
                       "synthetic-signature", "synthetic-password", "synthetic-aws-secret",
                       "synthetic-nonstandard-token"):
            assert secret not in first.stdout, f"leaked: {secret}"
        assert "storage.objects.create denied" in first.stdout
        assert "gs://iyi-lang-tfstate/iyi/default.tflock" in first.stdout
        assert "sha256:" + "d" * 64 in first.stdout
        match = re.match(r"::stop-commands::([0-9a-f]{32})\n", first.stdout)
        assert match and first.stdout.endswith(f"::{match.group(1)}::\n")
        assert "::error::injected" in first.stdout and "##[error]legacy injection" in first.stdout
        assert first.stdout != second.stdout, "command-stop tokens must be unique"

        path.write_text("BEGIN\n-----BEGIN RSA PRIVATE KEY-----\n" + private)
        assert private not in run(path).stdout, "unterminated key material leaked"
        path.write_text("a" * 20_000 + "\nError: final failure\n")
        truncated = run(path)
        assert truncated.returncode == 0 and "[Earlier output truncated after redaction]" in truncated.stdout
        assert len(truncated.stdout) < 17_000 and "Error: final failure" in truncated.stdout
        path.write_bytes(b"x" * (8 * 1024 * 1024 + 1))
        oversized = run(path)
        assert oversized.returncode != 0 and not oversized.stdout and "withheld" in oversized.stderr
        missing = run(Path(directory) / "missing")
        assert missing.returncode != 0 and not missing.stdout and "withheld" in missing.stderr
    print("Terraform diagnostics redact credential and key samples, bound output, and disable runner commands.")


if __name__ == "__main__":
    main()
