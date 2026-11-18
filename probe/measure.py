#!/usr/bin/env python3
"""Measure delivery and caching through a deployed iyi-probe Hosting site."""
import argparse
import hashlib
import http.client
import json
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

MIB = 1024 * 1024
CHUNK = bytes(64 * 1024)


def fetch(url, max_bytes):
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    try:
        response = urllib.request.urlopen(request, timeout=90)
    except urllib.error.HTTPError as error:
        response = error
    digest = hashlib.sha256()
    length = 0
    content = bytearray() if max_bytes <= 4096 else None
    with response:
        while True:
            data = response.read(min(len(CHUNK), max_bytes + 1 - length))
            if not data:
                break
            length += len(data)
            if length > max_bytes:
                raise ValueError("response exceeds expected length")
            digest.update(data)
            if content is not None:
                content.extend(data)
        return {
            "status": response.status,
            "length": length,
            "sha256": digest.hexdigest(),
            "body": bytes(content) if content is not None else None,
            "instance": response.headers.get("X-Probe-Instance"),
            "service": response.headers.get("X-Probe-Service"),
            "robots": response.headers.get("X-Robots-Tag", "").lower(),
        }


def expected_zero_hash(length):
    digest = hashlib.sha256()
    while length:
        size = min(length, len(CHUNK))
        digest.update(CHUNK[:size])
        length -= size
    return digest.hexdigest()


def counter(base, route, token):
    result = fetch(f"{base}/{route}/_probe/count?fresh={token}", 4096)
    if result["status"] != 200 or result["body"] is None:
        raise ValueError(f"counter returned HTTP {result['status']}")
    data = json.loads(result["body"])
    if data.get("instance") != result["instance"] or data.get("service") != result["service"]:
        raise ValueError("counter response identity mismatch")
    return data


def measure(base, route, label, path, expected_status, size, digest, nonce, expected_service):
    url = f"{base}/{route}/_probe/{path}?run={nonce}"
    try:
        before = counter(base, route, secrets.token_hex(16))
        first = fetch(url, size)
        middle = counter(base, route, secrets.token_hex(16))
        second = fetch(url, size)
        after = counter(base, route, secrets.token_hex(16))
    except (OSError, ValueError, http.client.HTTPException) as error:
        return label, "unknown", "unknown", f"inconclusive: {error}"

    identities = [before["instance"], middle["instance"], after["instance"], first["instance"], second["instance"]]
    services = [before["service"], middle["service"], after["service"], first["service"], second["service"]]
    if not identities[0] or any(instance != identities[0] for instance in identities):
        return label, "unknown", "unknown", "inconclusive: origin instance changed"
    if any(service != expected_service for service in services):
        return label, "unknown", "unknown", "inconclusive: rewrite reached an unexpected service"
    if any("noindex" not in response["robots"] or "nofollow" not in response["robots"] for response in (first, second)):
        return label, "unknown", "unknown", "inconclusive: noindex header missing"

    intact = all(response["status"] == expected_status and response["length"] == size and response["sha256"] == digest for response in (first, second))
    if not intact:
        return label, "no", "unknown", f"status {first['status']}/{second['status']}, bytes {first['length']}/{second['length']}"
    first_delta = middle["count"] - before["count"]
    second_delta = after["count"] - middle["count"]
    if first_delta != 1 or second_delta not in (0, 1):
        return label, "yes", "unknown", f"inconclusive: counter deltas {first_delta}/{second_delta}"
    cached = "yes" if second_delta == 0 else "no"
    return label, "yes", cached, f"origin deltas {first_delta}/{second_delta}; SHA-256 verified"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="origin of the deployed probe Hosting site")
    parser.add_argument("--allow-http", action="store_true", help="permit a loopback HTTP origin for local checks")
    parser.add_argument("--sizes", default="1,10,32,64,256", help="comma-separated MiB sizes")
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.url)
    local_http = args.allow_http and parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if not (parsed.scheme == "https" or local_http) or not parsed.netloc or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username:
        parser.error("URL must be an HTTPS origin (or loopback HTTP with --allow-http)")
    try:
        sizes = [int(item) for item in args.sizes.split(",")]
    except ValueError:
        parser.error("sizes must be comma-separated integers")
    if not sizes or any(size not in {1, 10, 32, 64, 256} for size in sizes):
        parser.error("sizes must be chosen from 1, 10, 32, 64, 256")
    base = args.url.rstrip("/")
    nonce = secrets.token_hex(16)
    print(f"{'route':<10} {'case':<18} {'delivered':<10} {'cached':<8} evidence")
    inconclusive = False
    for route in ("public", "internal"):
        expected_service = f"iyi-probe-{route}"
        if local_http:
            expected_service = "local"
        cases = [(f"{size} MiB", f"body/{size}", 200, size * MIB, expected_zero_hash(size * MIB)) for size in sizes]
        missing_hash = hashlib.sha256(b"missing\n").hexdigest()
        cases.extend([("404 default", "missing", 404, 8, missing_hash), ("404 cacheable", "missing-cacheable", 404, 8, missing_hash)])
        for label, path, status, length, digest in cases:
            row = measure(base, route, label, path, status, length, digest, nonce, expected_service)
            print(f"{route:<10} {row[0]:<18} {row[1]:<10} {row[2]:<8} {row[3]}", flush=True)
            if row[1] == "unknown" or row[2] == "unknown":
                inconclusive = True
    return 1 if inconclusive else 0


if __name__ == "__main__":
    sys.exit(main())
