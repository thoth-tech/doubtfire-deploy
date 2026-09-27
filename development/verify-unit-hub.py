#!/usr/bin/env python3
"""Read-only Unit Hub release smoke check. Never prints credentials or content."""

import argparse
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url", help="OnTrack origin, for example https://ontrack.example.edu")
    parser.add_argument("--expected-unit-id", type=int, required=True)
    parser.add_argument("--excluded-unit-id", type=int, required=True)
    args = parser.parse_args()
    base = urlparse(args.base_url)
    if (base.scheme != "https" and not (base.scheme == "http" and base.hostname in ("localhost", "127.0.0.1", "::1"))) or base.username or base.password or base.query or base.fragment or base.path not in ("", "/"):
        parser.error("Use an HTTPS origin (HTTP is allowed only on loopback).")
    if args.expected_unit_id == args.excluded_unit_id:
        parser.error("Expected and excluded unit IDs must differ.")
    username = os.environ.get("UNIT_HUB_USERNAME")
    token = os.environ.get("UNIT_HUB_AUTH_TOKEN")
    if not username or not token:
        parser.error("Set UNIT_HUB_USERNAME and UNIT_HUB_AUTH_TOKEN for a student test account.")
    opener = build_opener(NoRedirects())

    def request(path, authenticated=True):
        headers = {"Accept": "application/json"}
        if authenticated:
            headers.update({"Username": username, "Auth-Token": token})
        req = Request(args.base_url.rstrip("/") + "/api" + path, headers=headers)
        try:
            response = opener.open(req, timeout=30)
        except HTTPError as error:
            response = error
        with response:
            payload = response.read(5_000_001)
            if len(payload) > 5_000_000:
                raise ValueError("Unexpectedly large response")
            return response.status, response.headers, payload

    status, _, _ = request("/unit_hub", authenticated=False)
    if status not in (401, 403, 419):
        raise ValueError("Unauthenticated hub access was not rejected")
    print("PASS: sign-in is required")
    status, headers, payload = request("/unit_hub")
    if status != 200:
        raise ValueError(f"Authenticated hub returned HTTP {status}")
    if "no-store" not in headers.get("Cache-Control", ""):
        raise ValueError("Hub response is missing no-store cache protection")
    hub = json.loads(payload)
    units = {unit["id"] for unit in hub["units"]}
    if args.expected_unit_id not in units or args.excluded_unit_id in units:
        raise ValueError("Hub unit list does not match the expected student enrolment boundary")
    if any(unit.get("can_manage") for unit in hub["units"]):
        raise ValueError("Use a student-only account for this access check")
    for records in (hub["announcements"], hub["sessions"]):
        if any(record["unit_id"] not in units for record in records):
            raise ValueError("Hub content contains a unit outside the authorised list")
    print("PASS: feed respects the selected enrolment boundary and disables shared caching")
    for unit_id in (args.expected_unit_id, args.excluded_unit_id):
        for resource in ("announcements", "sessions"):
            status, _, _ = request(f"/units/{unit_id}/{resource}")
            if status not in (403, 404):
                raise ValueError("Student access to teaching-staff content was not rejected")
    print("PASS: student cannot read staff drafts for either unit")
    print("Read-only smoke check passed. No records or calendar preferences were changed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, URLError, TimeoutError):
        # Error response bodies may contain personal data; do not echo them.
        print("FAIL: Unit Hub smoke check did not pass. Check the configured origin, student account, unit IDs and server logs.", file=sys.stderr)
        sys.exit(1)
