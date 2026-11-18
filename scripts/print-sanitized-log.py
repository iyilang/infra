#!/usr/bin/env python3
"""Print a bounded, redacted Terraform diagnostic without executing runner commands."""

from pathlib import Path
import re
import secrets
import sys

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_CHARS = 16 * 1024

PEM = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.I | re.S)
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)")
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
AUTH_HEADER = re.compile(r"(?im)(\b(?:proxy-)?authorization\s*:\s*)[^\r\n]*")
BEARER = re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/-]+=*")
ASSIGNMENT = re.compile(
    r"(?i)(\b(?:[a-z][a-z0-9_.-]*[_-])?(?:private[_-]?key(?:[_-]?id)?|client[_-]?secret|"
    r"access[_-]?token|refresh[_-]?token|id[_-]?token|subject[_-]?token|"
    r"secret[_-]?access[_-]?key|secret[_-]?data|secret[_-]?value|api[_-]?key|"
    r"password|passwd|credentials?|authorization|token|secret)"
    r"[\"']?[ \t]*[:=][ \t]*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,;}\]]+)"
)
URL_SECRET = re.compile(
    r"(?i)([?&](?:access_token|id_token|token|key|sig|signature|"
    r"x-goog-signature|x-goog-credential)=)[^&\s]+"
)
URL_PASSWORD = re.compile(r"(?i)(\b[a-z][a-z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(@)")
TOKEN_PATTERNS = (
    re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"),
    re.compile(r"\bya29\.[A-Za-z0-9._~+/-]+=*"),
    re.compile(r"\b1//0[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b"),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
)


def sanitize(text):
    text = CONTROL.sub("", ANSI.sub("", text.replace("\r\n", "\n").replace("\r", "\n")))
    text = PEM.sub("[REDACTED PRIVATE KEY]", text)
    text = AUTH_HEADER.sub(r"\1[REDACTED]", text)
    text = BEARER.sub(r"\1[REDACTED]", text)
    text = ASSIGNMENT.sub(r"\1[REDACTED]", text)
    text = URL_SECRET.sub(r"\1[REDACTED]", text)
    text = URL_PASSWORD.sub(r"\1[REDACTED]\2", text)
    for pattern in TOKEN_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    if len(text) > MAX_OUTPUT_CHARS:
        text = "[Earlier output truncated after redaction]\n" + text[-MAX_OUTPUT_CHARS:]
    return text


def main(path):
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError("input too large to sanitize safely")
    text = sanitize(data.decode("utf-8", errors="replace"))
    token = secrets.token_hex(16)
    while token in text:
        token = secrets.token_hex(16)
    if text and not text.endswith("\n"):
        text += "\n"
    # An untrusted diagnostic may contain GitHub workflow commands, including
    # legacy commands embedded mid-line. Disable command processing around it.
    sys.stdout.write(f"::stop-commands::{token}\n{text}::{token}::\n")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected one path")
        main(sys.argv[1])
    except (OSError, ValueError, UnicodeError):
        print("Diagnostic output withheld: it could not be sanitized.", file=sys.stderr)
        sys.exit(1)
