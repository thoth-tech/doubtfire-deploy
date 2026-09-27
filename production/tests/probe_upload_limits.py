#!/usr/bin/env python3
"""Measure chat upload limits against a disposable, authenticated API project.

Successful test comments are deleted immediately. Requires the generic CSV
attachment API and a test user authorized to comment on the specified task.
Credentials are read from the environment and never written to the report.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Do not forward authentication headers to a redirected endpoint.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(opener, url, headers, method, data=None):
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--direct-url", required=True, help="Full direct API comments endpoint")
    parser.add_argument("--proxy-url", required=True, help="Same comments endpoint through Nginx")
    parser.add_argument("--proxy-limit-bytes", type=int,
                        help="Optionally also send one byte above this total request limit")
    args = parser.parse_args()
    if args.proxy_limit_bytes is not None and not 1 <= args.proxy_limit_bytes <= 128 * 1024 * 1024:
        parser.error("Use a disposable proxy with a limit from 1 byte to 128 MiB for this probe")
    for url in (args.direct_url, args.proxy_url):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.query or parsed.fragment or parsed.username:
            parser.error("Use an HTTP(S) endpoint without credentials, query string or fragment")
    headers = {"Username": os.environ["UPLOAD_TEST_USERNAME"],
               "Auth-Token": os.environ["UPLOAD_TEST_AUTH_TOKEN"]}
    opener = urllib.request.build_opener(NoRedirect())
    failures = []
    for label, endpoint in (("direct", args.direct_url), ("proxy", args.proxy_url)):
        for size, expected in ((0, 400), (1024, 201), (29_999_999, 201), (30_000_000, 413)):
            boundary = "upload-probe-" + uuid.uuid4().hex
            prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"client_request_id\"\r\n\r\n"
                      f"{uuid.uuid4()}\r\n--{boundary}\r\nContent-Disposition: form-data; "
                      "name=\"attachment\"; filename=\"upload-limit-probe.csv\"\r\n"
                      "Content-Type: text/csv\r\n\r\n").encode()
            payload = prefix + (b"value\n" + b"x" * size)[:size] + f"\r\n--{boundary}--\r\n".encode()
            status, body = request(opener, endpoint, {
                **headers, "Content-Type": "multipart/form-data; boundary=" + boundary}, "POST", payload)
            print(json.dumps({"path": label, "file_bytes": size, "request_bytes": len(payload),
                              "status": status, "expected": expected}))
            if 200 <= status < 300:
                comment_id = json.loads(body)["id"]
                if not isinstance(comment_id, int) or isinstance(comment_id, bool):
                    raise ValueError("API returned no integer comment ID for cleanup")
                deleted, _ = request(opener, endpoint.rstrip("/") + "/" + str(comment_id), headers, "DELETE")
                if not 200 <= deleted < 300:
                    failures.append(f"{label}: test comment {comment_id} could not be deleted ({deleted})")
            if status != expected:
                failures.append(f"{label}: {size} file bytes returned {status}, expected {expected}")
    if args.proxy_limit_bytes is not None:
        status, body = request(opener, args.proxy_url, {
            **headers, "Content-Type": "application/octet-stream"}, "POST",
            b"x" * (args.proxy_limit_bytes + 1))
        result = json.loads(body)
        print(json.dumps({"path": "proxy", "request_bytes": args.proxy_limit_bytes + 1,
                          "status": status, "code": result.get("code")}))
        if status != 413 or result.get("code") != "request_too_large":
            failures.append("Oversized request did not receive the proxy JSON 413")
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError) as error:
        # Credential values and response bodies must never be emitted on failure.
        sys.exit(f"Upload probe could not complete ({type(error).__name__}). Check test credentials and endpoints.")
