#!/usr/bin/env python3
"""Exercise the real production proxy template with disposable Docker fixtures."""

import http.client
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
NGINX_IMAGE = os.environ.get(
    "UPLOAD_TEST_NGINX_IMAGE",
    "nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46",
)
SINK_IMAGE = os.environ.get("UPLOAD_TEST_SINK_IMAGE", "python:3.13-alpine")
LIMIT = 32 * 1024 * 1024


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True, stderr=subprocess.STDOUT).strip()


class UploadProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prefix = "upload-boundary-" + uuid.uuid4().hex[:12]
        cls.resources = []
        cls.fixture = tempfile.TemporaryDirectory(prefix="upload-boundary-")
        cls.addClassCleanup(cls.cleanup)
        fixture = Path(cls.fixture.name)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=ontrack.test.invalid", "-keyout", str(fixture / "privkey.pem"),
            "-out", str(fixture / "fullchain.pem"),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        docker("network", "create", cls.prefix)
        cls.network_created = True
        cls.sink = cls.prefix + "-sink"
        cls.resources.append(cls.sink)
        docker("run", "-d", "--name", cls.sink, "--network", cls.prefix,
               "--network-alias", "apiserver", "--network-alias", "webserver",
               "-v", f"{ROOT / 'tests/upload_sink.py'}:/sink.py:ro",
               SINK_IMAGE, "python", "/sink.py")
        cls.proxy = cls.prefix + "-proxy"
        cls.resources.append(cls.proxy)
        docker("run", "-d", "--name", cls.proxy, "--network", cls.prefix,
               "-p", "127.0.0.1::443", "-e", "SERVER_NAME=ontrack.test.invalid",
               "-e", "CLIENT_MAX_BODY_SIZE=32m",
               "-e", "NGINX_ENVSUBST_FILTER=^(SERVER_NAME|CLIENT_MAX_BODY_SIZE)$",
               "-v", f"{ROOT / 'proxy-nginx.conf.template'}:/etc/nginx/templates/default.conf.template:ro",
               "-v", f"{fixture / 'fullchain.pem'}:/etc/nginx/tls/fullchain.pem:ro",
               "-v", f"{fixture / 'privkey.pem'}:/etc/nginx/tls/private.key:ro",
               NGINX_IMAGE)
        cls.port = int(docker("port", cls.proxy, "443/tcp").rsplit(":", 1)[1])
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                status, _, _ = cls.request("GET", "/healthz")
                if status == 200:
                    break
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.2)
        else:
            raise RuntimeError("Proxy did not start: " + docker("logs", cls.proxy))
        docker("exec", cls.proxy, "nginx", "-t")

    @classmethod
    def cleanup(cls):
        for name in reversed(cls.resources):
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        if getattr(cls, "network_created", False):
            subprocess.run(["docker", "network", "rm", cls.prefix],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        cls.fixture.cleanup()

    @classmethod
    def request(cls, method, path, body=b"", content_type="application/octet-stream"):
        # Only the ephemeral, self-signed localhost fixture disables TLS checking.
        connection = http.client.HTTPSConnection(
            "127.0.0.1", cls.port, timeout=30, context=ssl._create_unverified_context())
        try:
            connection.request(method, path, body, {
                "Host": "ontrack.test.invalid", "Content-Type": content_type})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_permitted_chat_boundary_reaches_api_with_multipart_overhead(self):
        boundary = "upload-boundary-fixture"
        for size in (0, 1024, 29_999_999, 30_000_000):
            with self.subTest(file_size=size):
                body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; "
                        f"filename=\"boundary.csv\"\r\nContent-Type: text/csv\r\n\r\n").encode()
                body += b"x" * size + f"\r\n--{boundary}--\r\n".encode()
                status, headers, payload = self.request(
                    "POST", "/api/projects/1/task_def_id/1/comments", body,
                    "multipart/form-data; boundary=" + boundary)
                self.assertEqual(200, status)
                self.assertEqual("true", headers.get("X-Upstream-Reached"))
                self.assertEqual(len(body), json.loads(payload)["received_bytes"])

    def test_total_request_limit_includes_exact_boundary(self):
        status, headers, payload = self.request(
            "POST", "/api/projects/1/task_def_id/1/comments", b"x" * LIMIT)
        self.assertEqual(200, status)
        self.assertEqual("true", headers.get("X-Upstream-Reached"))
        self.assertEqual(LIMIT, json.loads(payload)["received_bytes"])

    def test_over_limit_returns_json_without_reaching_api(self):
        status, headers, payload = self.request(
            "POST", "/api/projects/1/task_def_id/1/comments", b"x" * (LIMIT + 1))
        self.assertEqual(413, status)
        self.assertNotIn("X-Upstream-Reached", headers)
        self.assertIn("application/json", headers.get("Content-Type", ""))
        self.assertEqual("request_too_large", json.loads(payload)["code"])
        self.assertIn("smaller file", json.loads(payload)["error"])
        self.assertEqual("nosniff", headers.get("X-Content-Type-Options"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
