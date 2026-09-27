#!/usr/bin/env python3
"""Exercise the PWA verifier through real local HTTP responses, without Docker."""

from contextlib import contextmanager
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import threading
import unittest
from urllib.parse import urlsplit
import zlib


SCRIPT = Path(__file__).resolve().parents[1] / "verify-pwa.py"
SPEC = importlib.util.spec_from_file_location("verify_pwa", SCRIPT)
pwa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pwa)


def png(size):
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload +
                struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\x7f\xff" * size) * size)) +
            chunk(b"IEND", b""))


def fixtures():
    manifest = {
        "id": "/index.html", "start_url": "/index.html", "scope": "/", "name": "OnTrack",
        "short_name": "OnTrack", "description": "Learning and feedback", "display": "standalone",
        "icons": [{"src": f"/assets/{size}.png", "sizes": f"{size}x{size}", "type": "image/png"}
                  for size in (192, 512)],
        "shortcuts": [{"name": "Home", "url": "/home"}],
    }
    files = {
        "/index.html": ("text/html", b'<!doctype html><html><head><base href="/">'
                        b'<link rel="manifest" href="/manifest.webmanifest">'
                        b'<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Inter">'
                        b'<link rel="stylesheet" href="styles.abc.css"></head>'
                        b'<body><script src="main.abc.js"></script></body></html>'),
        "/manifest.webmanifest": ("application/manifest+json", json.dumps(manifest).encode()),
        "/ngsw-worker.js": ("text/javascript", b"/* ngsw Angular service-worker fixture */ self.onfetch = () => {};"),
        "/main.abc.js": ("application/javascript", b"console.log('fixture');"),
        "/styles.abc.css": ("text/css", b"body { color: black; }"),
    }
    for size in (192, 512):
        files[f"/assets/{size}.png"] = ("image/png", png(size))
    files["/ngsw.json"] = ("application/json", json.dumps({
        "configVersion": 1, "index": "/index.html", "assetGroups": [{"name": "app"}],
        "hashTable": {path: hashlib.sha1(body).hexdigest() for path, (_, body) in files.items()
                      if path != "/ngsw-worker.js"},
    }).encode())
    return {path: {"status": 200, "body": body, "headers": {
        "Content-Type": kind, "Cache-Control": "no-cache, max-age=0, must-revalidate"}}
        for path, (kind, body) in files.items()}


@contextmanager
def server(files):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            response = files.get(self.path, files.get(urlsplit(self.path).path))
            if response is None:
                self.send_error(404)
                return
            self.send_response(response["status"])
            for key, value in response["headers"].items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(response["body"])

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}"
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join()


class PwaVerificationTest(unittest.TestCase):
    def setUp(self):
        self.files = fixtures()

    def check(self):
        with server(self.files) as origin:
            pwa.Verifier(origin, timeout=2, report=lambda line: None).run()

    def reject(self, expected):
        with self.assertRaisesRegex(pwa.VerificationError, expected):
            self.check()

    def change_json(self, path, mutate):
        obj = json.loads(self.files[path]["body"])
        mutate(obj)
        self.files[path]["body"] = json.dumps(obj).encode()

    def test_complete_release_and_cli_pass(self):
        self.check()
        with server(self.files) as origin:
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), origin, "--timeout", "2"],
                                    capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("public-asset checks passed", result.stdout)

    def test_https_except_loopback_and_root_origin_only(self):
        for origin in ("https://ontrack.example.edu", "http://localhost:8080",
                       "http://127.0.0.1:8080", "http://[::1]:8080"):
            with self.subTest(origin=origin):
                self.assertTrue(pwa.origin_url(origin).endswith("/"))
        for origin in ("http://ontrack.example.edu", "http://192.168.1.1", "file:///tmp/site",
                       "https://name:password@example.edu", "https://example.edu/app",
                       "https://example.edu?token=secret", "https://example.edu#fragment",
                       "https://example.edu:99999", "https://example.edu:0", "https://example.edu\\@other.edu"):
            with self.subTest(origin=origin), self.assertRaises(pwa.VerificationError):
                pwa.origin_url(origin)

    def test_identity_start_scope_and_display_are_preserved(self):
        for field, wrong in (("id", "/"), ("start_url", "/home"), ("scope", "/home/"),
                             ("display", "browser"), ("id", "https://other.example/id")):
            with self.subTest(field=field, value=wrong):
                self.files = fixtures()
                self.change_json("/manifest.webmanifest", lambda obj: obj.update({field: wrong}))
                self.reject("manifest|origin")

    def test_missing_manifest_link_fails(self):
        self.files["/index.html"]["body"] = self.files["/index.html"]["body"].replace(b'rel="manifest"', b'rel="alternate"')
        self.reject("must link")

    def test_spa_fallback_under_asset_urls_fails(self):
        for path in ("/manifest.webmanifest", "/ngsw.json", "/ngsw-worker.js", "/assets/192.png", "/main.abc.js"):
            with self.subTest(path=path):
                self.files = fixtures()
                self.files[path] = copy.deepcopy(self.files["/index.html"])
                self.reject("Content-Type")

    def test_html_disguised_as_javascript_fails(self):
        self.files["/ngsw-worker.js"]["body"] = b"<!doctype html><html>ngsw</html>"
        self.reject("resolved to HTML")

    def test_missing_worker_http_errors_and_redirects_fail(self):
        for status in (301, 302, 404, 503):
            with self.subTest(status=status):
                self.files = fixtures()
                self.files["/ngsw-worker.js"]["status"] = status
                self.files["/ngsw-worker.js"]["headers"]["Location"] = "https://other.example/worker.js"
                self.reject("redirected|HTTP")

    def test_stale_cache_policy_and_query_bypass_fail(self):
        for policy in ("public, max-age=3600", "no-cache, s-maxage=600", "no-store, immutable", "public"):
            with self.subTest(policy=policy):
                self.files = fixtures()
                self.files["/ngsw.json"]["headers"]["Cache-Control"] = policy
                self.reject("cache|Cache-Control")
        self.files = fixtures()
        path = "/ngsw-worker.js?ontrack-pwa-check=1"
        self.files[path] = copy.deepcopy(self.files["/ngsw-worker.js"])
        self.files[path]["headers"]["Cache-Control"] = "public, max-age=86400"
        self.reject("cache")

    def test_icon_content_not_just_extension_or_header(self):
        for bad in (b"not a PNG", png(192)[:33], png(192)[:-1], png(192).replace(b"IDAT", b"JUNK")):
            with self.subTest(length=len(bad)):
                self.files = fixtures()
                self.files["/assets/192.png"]["body"] = bad
                self.reject("PNG")

    def test_header_dimensions_without_matching_pixels_fail(self):
        data = bytearray(png(192))
        data[16:24] = struct.pack(">II", 512, 512)
        data[29:33] = struct.pack(">I", zlib.crc32(data[12:29]) & 0xffffffff)
        self.files["/assets/512.png"]["body"] = bytes(data)
        self.reject("pixel data does not match")

    def test_declared_dimensions_and_general_purpose_sizes(self):
        self.files["/assets/192.png"]["body"] = png(96)
        self.reject("dimensions")
        self.files = fixtures()
        self.change_json("/manifest.webmanifest", lambda obj: obj["icons"][0].update({"purpose": "maskable"}))
        self.reject("general-purpose")

    def test_cross_origin_icons_and_shortcuts_fail_before_fetch(self):
        self.change_json("/manifest.webmanifest", lambda obj: obj["icons"][0].update({"src": "https://elsewhere.example/icon.png"}))
        self.reject("origin")
        self.files = fixtures()
        self.change_json("/manifest.webmanifest", lambda obj: obj["shortcuts"][0].update({"url": "https://elsewhere.example/home"}))
        self.reject("origin")
        self.files = fixtures()
        self.change_json("/manifest.webmanifest", lambda obj: obj["icons"][0].update({"src": "https://[broken/icon.png"}))
        self.reject("invalid asset URL")

    def test_invalid_json_and_control_schema_fail(self):
        self.files["/manifest.webmanifest"]["body"] = b"<html>"
        self.reject("invalid JSON")
        self.files = fixtures()
        self.change_json("/ngsw.json", lambda obj: obj.update({"configVersion": 2}))
        self.reject("unsupported")

    def test_mixed_release_and_missing_ngsw_hashes_fail(self):
        self.files["/main.abc.js"]["body"] = b"console.log('different release');"
        self.reject("mismatched ngsw hash")
        self.files = fixtures()
        self.change_json("/ngsw.json", lambda obj: obj["hashTable"].pop("/manifest.webmanifest"))
        self.reject("mismatched ngsw hash")

    def test_invalid_timeout_cli_fails(self):
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "https://example.edu", "--timeout", "0"],
                                capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn("between 1 and 300", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
