#!/usr/bin/env python3
"""Check for the Terraform state object without reading or creating its data."""

import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

BUCKET = "iyi-lang-tfstate"
OBJECT = "iyi/default.tfstate"
LIST_URL = f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o"
MAX_RESPONSE_BYTES = 1024 * 1024


class StateProbeError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def state_exists(token, opener=None):
    if not token or any(ord(char) < 33 or ord(char) > 126 for char in token):
        raise StateProbeError("The state-check access token is missing or invalid.")
    if opener is None:
        opener = build_opener(NoRedirect())
    seen = set()
    page = None
    while True:
        query = {"prefix": OBJECT, "maxResults": "1000", "fields": "items(name),nextPageToken"}
        if page is not None:
            query["pageToken"] = page
        request = Request(f"{LIST_URL}?{urlencode(query)}", headers={"Authorization": f"Bearer {token}"})
        try:
            with opener.open(request, timeout=20) as response:
                data = response.read(MAX_RESPONSE_BYTES + 1)
        except HTTPError as exc:
            raise StateProbeError(f"Cloud Storage state listing returned HTTP {exc.code}.") from None
        except (URLError, OSError):
            raise StateProbeError("Cloud Storage state listing could not be reached.") from None
        if len(data) > MAX_RESPONSE_BYTES:
            raise StateProbeError("Cloud Storage state listing exceeded the response limit.")
        try:
            payload = json.loads(data)
        except (ValueError, UnicodeError):
            raise StateProbeError("Cloud Storage returned invalid state-listing JSON.") from None
        if (not isinstance(payload, dict) or set(payload) - {"items", "nextPageToken"}
                or not isinstance(payload.get("items", []), list)):
            raise StateProbeError("Cloud Storage returned an invalid state listing.")
        for item in payload.get("items", []):
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                raise StateProbeError("Cloud Storage returned an invalid state-listing item.")
            if item["name"] == OBJECT:
                return True
        if "nextPageToken" not in payload:
            return False
        page = payload["nextPageToken"]
        if not isinstance(page, str) or not page or page in seen or len(seen) >= 100:
            raise StateProbeError("Cloud Storage returned an invalid state-listing page token.")
        seen.add(page)


def main():
    exists = state_exists(os.environ.get("IYI_STATE_TOKEN", ""))
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        raise StateProbeError("GitHub Actions output path is missing.")
    with open(output, "a", encoding="utf-8") as stream:
        print(f"state={'present' if exists else 'absent'}", file=stream)
    print(f"Terraform state object: {'present' if exists else 'absent'}.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, StateProbeError) as exc:
        if isinstance(exc, StateProbeError):
            print(f"::error::{exc}", file=sys.stderr)
        else:
            print("::error::Could not write the Terraform state-check result.", file=sys.stderr)
        sys.exit(1)
