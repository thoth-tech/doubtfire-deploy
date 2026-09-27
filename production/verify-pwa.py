#!/usr/bin/env python3
"""Read-only public-asset checks for OnTrack's root-hosted desktop PWA.

Uses only Python's standard library. No login, API calls, browser installation,
server changes, or TLS bypass. A passing result still needs browser acceptance.
"""

import argparse
import hashlib
from html.parser import HTMLParser
import ipaddress
import json
import re
import struct
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import zlib


MAX_RESPONSE = 32 * 1024 * 1024
JS_TYPES = {"application/javascript", "text/javascript"}


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def origin_url(value):
    """Accept a single root origin; HTTP is limited to local browser testing."""
    try:
        parsed = urlsplit(value)
        port = parsed.port
        host = (parsed.hostname or "").lower().rstrip(".")
        require(bool(host) and not parsed.username and not parsed.password,
                "provide a URL with a hostname and no credentials")
        require(not re.search(r"[\s\\]", value), "URL contains whitespace or a backslash")
        require(parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
                "provide the root origin, without a path, query, or fragment")
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = host == "localhost"
        require(parsed.scheme == "https" or (parsed.scheme == "http" and loopback),
                "HTTPS is required except for localhost or a loopback IP")
        # Access .port above to validate malformed/out-of-range ports.
        require(port is None or port > 0, "URL port must be positive")
        return urlunsplit((parsed.scheme, parsed.netloc, "/", "", ""))
    except ValueError as error:
        raise VerificationError("invalid origin URL") from error


def same_origin(base, reference):
    require(isinstance(reference, str) and bool(reference), "asset URL must be a non-empty string")
    require(not re.search(r"[\s\\]", reference), "asset URL contains whitespace or a backslash")
    try:
        resolved = urljoin(base, reference)
        parsed, expected = urlsplit(resolved), urlsplit(base)
        parsed.port
    except ValueError as error:
        raise VerificationError("invalid asset URL") from error
    require(not parsed.username and not parsed.password, "asset URL contains credentials")
    require((parsed.scheme, parsed.netloc) == (expected.scheme, expected.netloc),
            "PWA assets and routes must stay on the supplied origin")
    return resolved


def check_cache(headers, label):
    value = headers.get("Cache-Control", "").lower()
    directives = {part.strip().split("=", 1)[0] for part in value.split(",")}
    ages = re.findall(r"(?:^|,)\s*(?:s-maxage|max-age)\s*=\s*\"?(\d+)", value)
    require("immutable" not in directives and all(int(age) == 0 for age in ages),
            f"{label}: control files must not have a positive cache lifetime or immutable")
    require("no-store" in directives or "no-cache" in directives or
            ("must-revalidate" in directives and bool(ages)),
            f"{label}: Cache-Control must prevent stale control files")


def png_dimensions(data, label):
    """Check PNG chunks, CRCs and decompressed scanlines, not just a file name."""
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), f"{label}: expected PNG signature")
    position, chunks, compressed = 8, [], bytearray()
    width = height = depth = colour = interlace = None
    while position + 12 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        end = position + 12 + length
        require(end <= len(data), f"{label}: truncated PNG chunk")
        payload = data[position + 8:end - 4]
        checksum = struct.unpack(">I", data[end - 4:end])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == checksum,
                f"{label}: invalid PNG chunk checksum")
        if kind == b"IHDR":
            require(not chunks and length == 13, f"{label}: invalid PNG header")
            width, height, depth, colour, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload)
            valid_depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                            4: (8, 16), 6: (8, 16)}
            require(0 < width <= 4096 and 0 < height <= 4096 and
                    depth in valid_depths.get(colour, ()) and compression == 0 and
                    filtering == 0 and interlace in (0, 1), f"{label}: unsupported PNG header")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            require(length == 0 and end == len(data), f"{label}: invalid PNG end")
        chunks.append(kind)
        position = end
    require(position == len(data) and chunks and chunks[0] == b"IHDR" and
            chunks[-1] == b"IEND" and compressed, f"{label}: incomplete PNG")
    require(colour != 3 or b"PLTE" in chunks, f"{label}: indexed PNG has no palette")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    passes = [(0, 0, 1, 1)] if not interlace else [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    rows = []
    for x, y, dx, dy in passes:
        columns = max(0, (width - x + dx - 1) // dx)
        count = max(0, (height - y + dy - 1) // dy)
        if columns:
            rows.extend([1 + (columns * channels * depth + 7) // 8] * count)
    expected = sum(rows)
    require(expected <= MAX_RESPONSE, f"{label}: decoded PNG exceeds 32 MiB")
    try:
        decoder = zlib.decompressobj()
        pixels = decoder.decompress(compressed, expected + 1)
        require(len(pixels) == expected and decoder.eof and not decoder.unused_data,
                f"{label}: PNG pixel data does not match its dimensions")
    except zlib.error as error:
        raise VerificationError(f"{label}: invalid PNG pixel data") from error
    offset = 0
    for row in rows:
        require(pixels[offset] <= 4, f"{label}: invalid PNG scanline filter")
        offset += row
    return width, height


class IndexLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.manifests, self.scripts, self.styles, self.bases = [], [], [], []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and "manifest" in attrs.get("rel", "").lower().split():
            self.manifests.append(attrs.get("href"))
        if tag == "link" and "stylesheet" in attrs.get("rel", "").lower().split():
            self.styles.append(attrs.get("href"))
        if tag == "script" and attrs.get("src"):
            self.scripts.append(attrs["src"])
        if tag == "base":
            self.bases.append(attrs.get("href"))


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise VerificationError("asset redirected; use the final public origin and serve assets directly")


class Verifier:
    def __init__(self, origin, timeout=30, report=print):
        self.origin = origin_url(origin)
        self.timeout = timeout
        self.report = report
        self.downloaded = {}
        self.opener = build_opener(ProxyHandler({}), NoRedirects())

    def fetch(self, reference, types, control=False):
        url = same_origin(self.origin, reference)
        label = urlsplit(url).path
        request = Request(url, headers={"User-Agent": "OnTrack-PWA-Verifier/1.0",
                                       "Accept-Encoding": "identity"})
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                require(response.status == 200, f"{label}: expected HTTP 200")
                require(response.headers.get_content_type() in types,
                        f"{label}: incorrect Content-Type (possible SPA fallback)")
                require(response.headers.get("Content-Encoding", "identity") == "identity",
                        f"{label}: server ignored Accept-Encoding: identity")
                if control:
                    check_cache(response.headers, label)
                data = response.read(MAX_RESPONSE + 1)
                require(0 < len(data) <= MAX_RESPONSE, f"{label}: empty or oversized response")
        except HTTPError as error:
            error.close()
            raise VerificationError(f"{label}: HTTP {error.code}, expected 200") from error
        except (URLError, OSError) as error:
            raise VerificationError(f"{label}: request failed ({error.reason if isinstance(error, URLError) else error})") from error
        if types & JS_TYPES:
            require(not re.search(br"<!doctype\s+html|<html(?:\s|>)", data[:4096], re.I),
                    f"{label}: JavaScript resolved to HTML")
        self.downloaded[label] = data
        self.report(f"ok - {label}")
        return data

    def json(self, reference, types):
        try:
            parsed = json.loads(self.fetch(reference, types, control=True))
        except (ValueError, UnicodeError) as error:
            raise VerificationError(f"{reference}: invalid JSON") from error
        require(isinstance(parsed, dict), f"{reference}: expected JSON object")
        return parsed

    def run(self):
        index = self.fetch("/index.html", {"text/html"}, control=True)
        require(re.search(br"<!doctype\s+html|<html(?:\s|>)", index, re.I), "index is not HTML")
        links = IndexLinks()
        try:
            links.feed(index.decode("utf-8"))
        except UnicodeError as error:
            raise VerificationError("index is not UTF-8 HTML") from error
        require(links.bases == ["/"], "index must declare one root base href")
        require(len(links.manifests) == 1 and
                same_origin(self.origin, links.manifests[0]) == self.origin + "manifest.webmanifest",
                "index must link /manifest.webmanifest")
        manifest = self.json("/manifest.webmanifest", {"application/manifest+json", "application/json"})
        for field in ("name", "short_name", "description"):
            require(isinstance(manifest.get(field), str) and bool(manifest[field].strip()),
                    f"manifest must include {field}")
        require(manifest.get("display") == "standalone", "manifest display must be standalone")
        for field, path in (("id", "/index.html"), ("start_url", "/index.html"), ("scope", "/")):
            require(same_origin(self.origin, manifest.get(field)) == self.origin.rstrip("/") + path,
                    f"manifest {field} must resolve to {path} to preserve existing installations")
        icons = manifest.get("icons")
        require(isinstance(icons, list) and 1 <= len(icons) <= 12, "manifest must include 1–12 icons")
        general_sizes = set()
        for icon in icons:
            require(isinstance(icon, dict) and icon.get("type") == "image/png", "icon must declare image/png")
            data = self.fetch(icon.get("src"), {"image/png"})
            width, height = png_dimensions(data, "manifest icon")
            size = f"{width}x{height}"
            require(size in str(icon.get("sizes", "")).split(), "PNG dimensions differ from manifest sizes")
            purpose = icon.get("purpose", "any")
            require(isinstance(purpose, str), "icon purpose must be a string")
            if "any" in purpose.split():
                general_sizes.add(size)
        require({"192x192", "512x512"} <= general_sizes, "manifest needs general-purpose 192px and 512px PNGs")
        shortcuts = manifest.get("shortcuts", [])
        require(isinstance(shortcuts, list) and len(shortcuts) <= 10, "invalid manifest shortcuts")
        for shortcut in shortcuts:
            require(isinstance(shortcut, dict) and isinstance(shortcut.get("name"), str) and
                    bool(shortcut["name"].strip()), "shortcut must have a name")
            same_origin(self.origin, shortcut.get("url"))
        worker = self.fetch("/ngsw-worker.js", JS_TYPES, control=True)
        require(b"ngsw" in worker, "worker is missing the Angular service-worker runtime")
        control = self.json("/ngsw.json", {"application/json"})
        require(control.get("configVersion") == 1 and control.get("index") == "/index.html" and
                isinstance(control.get("assetGroups"), list) and bool(control["assetGroups"]),
                "ngsw.json has an unsupported Angular worker configuration")
        hashes = control.get("hashTable")
        require(isinstance(hashes, dict) and bool(hashes), "ngsw.json has no asset hashes")
        require(links.scripts and len(links.scripts) + len(links.styles) <= 24,
                "index needs entry scripts and at most 24 entry assets")
        for source in links.scripts:
            self.fetch(source, JS_TYPES)
        for source in links.styles:
            parsed = urlsplit(urljoin(self.origin, source))
            if (parsed.scheme, parsed.netloc) == (urlsplit(self.origin).scheme, urlsplit(self.origin).netloc):
                self.fetch(source, {"text/css"})
            else:
                # Existing Google Fonts stylesheets are outside the app-shell
                # hash table. No requests are made to third-party origins.
                require(parsed.scheme == "https", "external stylesheet must use HTTPS")
                self.report("skip - external stylesheet (browser acceptance required)")
        # Check every fetched app-shell asset against the released worker manifest.
        # Worker/control JSON intentionally are not members of their own hash table.
        for path, data in self.downloaded.items():
            if path not in ("/ngsw-worker.js", "/ngsw.json"):
                require(hashes.get(path) == hashlib.sha1(data).hexdigest(),
                        f"{path}: missing/mismatched ngsw hash; release may contain mixed assets")
        for path in ("/index.html", "/manifest.webmanifest", "/ngsw.json", "/ngsw-worker.js"):
            kind = {"/index.html": {"text/html"}, "/manifest.webmanifest": {"application/manifest+json", "application/json"},
                    "/ngsw.json": {"application/json"}, "/ngsw-worker.js": JS_TYPES}[path]
            original = self.downloaded[path]
            query_data = self.fetch(path + "?ontrack-pwa-check=1", kind, control=True)
            require(query_data == original, f"{path}: query string changed the released control file")
        self.report("Desktop PWA public-asset checks passed. Complete the real-browser checks in DESKTOP-PWA.md.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("origin", help="public root origin, e.g. https://ontrack.example.edu")
    parser.add_argument("--timeout", type=int, default=30, help="per-request timeout in seconds (1–300)")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("timeout must be between 1 and 300 seconds")
    try:
        Verifier(args.origin, args.timeout).run()
    except VerificationError as error:
        print(f"Desktop PWA verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
