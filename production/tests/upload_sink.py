"""Transport-only fixture: records that Nginx forwarded a request.

This deliberately does not emulate Rails validation. Application authorization,
format and file-size checks belong to the API suite and the live boundary probe.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        remaining = size
        while remaining:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                break
            remaining -= len(chunk)
        body = json.dumps({"received_bytes": size - remaining}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Upstream-Reached", "true")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 3000), Handler).serve_forever()
