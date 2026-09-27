#!/usr/bin/env python3
"""Find a supplied VAPID private key without printing its value or matching content."""

import argparse
import base64
import gzip
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


class AuditError(Exception):
    """A static, non-sensitive description of an incomplete audit."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        # argparse normally echoes unrecognized arguments, which could include
        # a key mistakenly supplied on the command line.
        self.exit(2, "Invalid audit arguments; use --help. Never pass a key value as an argument.\n")


def read_key(path, stdin):
    if path:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                    raise AuditError("Key file must be a regular, owner-only file owned by this user")
                value = source.read(4097).strip()
        except OSError:
            raise AuditError("Cannot open protected key file (symlinks are not accepted)") from None
    else:
        if stdin.isatty():
            raise AuditError("Pipe the key from its secret manager; interactive terminal input is disabled")
        value = stdin.read(4097).strip()
    if not re.fullmatch(rb"[A-Za-z0-9_-]{43}=?", value):
        raise AuditError("Expected one base64url-encoded, 32-byte VAPID private key")
    raw = base64.urlsafe_b64decode(value.rstrip(b"=") + b"=")
    if len(raw) != 32:
        raise AuditError("Expected one base64url-encoded, 32-byte VAPID private key")
    return value.rstrip(b"="), raw


class Scanner:
    def __init__(self, value, raw):
        forms = {value, value + b"=", raw, raw.hex().encode(), raw.hex().upper().encode(),
                 base64.b64encode(raw), base64.b64encode(raw).rstrip(b"="),
                 base64.b64encode(value), base64.b64encode(value + b"=")}
        self.patterns = sorted(forms, key=len, reverse=True)
        self.overlap = max(map(len, self.patterns)) - 1
        self.report = {"format_version": 1, "complete_for_selected_inputs": True,
                       "coverage": "Local Git objects, supplied Docker archives/images, and explicit files only",
                       "targets": [], "images": [], "scanned_items": 0,
                       "scanned_bytes": 0, "findings": [], "errors": []}

    def redact(self, text):
        for pattern in self.patterns:
            try:
                text = text.replace(pattern.decode("ascii"), "[REDACTED]")
            except UnicodeDecodeError:
                pass
        return text

    def count(self, source, size=None):
        tail, count, read = b"", 0, 0
        while size is None or read < size:
            chunk = source.read(min(65536, size - read) if size is not None else 65536)
            if not chunk:
                if size is not None and read != size:
                    raise AuditError("Input ended before its declared size")
                break
            read += len(chunk)
            data = tail + chunk
            limit = max(0, len(data) - self.overlap)
            count += self.count_starts(data, limit)
            tail = data[limit:]
        count += self.count_starts(tail, len(tail))
        return count, read

    def count_starts(self, data, limit):
        starts = set()
        for pattern in self.patterns:
            position = data.find(pattern)
            while 0 <= position < limit:
                starts.add(position)
                position = data.find(pattern, position + 1)
        return len(starts)

    def scan(self, source, location, size=None):
        matches, length = self.count(source, size)
        self.report["scanned_items"] += 1
        self.report["scanned_bytes"] += length
        if matches:
            self.report["findings"].append({"location": self.redact(location), "matches": matches})

    def scan_metadata(self, metadata, location):
        self.scan(io.BytesIO(json.dumps(metadata, ensure_ascii=False).encode()), location)

    def git(self, repository):
        result = subprocess.run(["git", "-C", repository, "rev-parse", "--is-shallow-repository"],
                                capture_output=True, check=False)
        if result.returncode or result.stdout.strip() != b"false":
            raise AuditError("Repository unavailable or shallow; obtain full authorized history first")
        # All available objects includes deleted historical files, unreachable
        # objects, commit/tag messages and alternate object databases.
        process = subprocess.Popen(["git", "-C", repository, "cat-file", "--batch-all-objects", "--batch"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            while header := process.stdout.readline():
                match = re.fullmatch(rb"([a-f0-9]{40,64}) (blob|tree|commit|tag) ([0-9]+)\n", header)
                if not match:
                    raise AuditError("Git returned an invalid object stream")
                object_id, kind, length = match.groups()
                self.scan(process.stdout, f"git:{repository}:{kind.decode()}:{object_id.decode()}", int(length))
                if process.stdout.read(1) != b"\n":
                    raise AuditError("Git object stream was truncated")
            if process.wait():
                raise AuditError("Git did not finish reading all objects")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()

    def layer(self, source, location):
        # Never unpack files to the filesystem or apply whiteouts. Each original
        # layer is scanned separately, including files deleted by later layers.
        with tarfile.open(fileobj=source, mode="r|*") as archive:
            for member in archive:
                item = f"{location}:{member.name}"
                self.scan_metadata({"name": member.name, "link": member.linkname,
                                    "user": member.uname, "group": member.gname,
                                    "pax": member.pax_headers}, item + ":metadata")
                if member.isfile():
                    with archive.extractfile(member) as content:
                        self.scan(content, item, member.size)

    def image_archive(self, path, label=None):
        location = "image:" + (label or str(path))
        with tarfile.open(path, mode="r:*") as archive:
            manifest_info = archive.getmember("manifest.json")
            if not manifest_info.isfile() or manifest_info.size > 16 * 1024 * 1024:
                raise AuditError("Docker save manifest is missing or invalid")
            with archive.extractfile(manifest_info) as source:
                manifest = json.load(source)
            if not isinstance(manifest, list) or not manifest:
                raise AuditError("Expected a non-empty Docker image save archive")
            layers, configs = set(), set()
            for entry in manifest:
                if not isinstance(entry, dict) or not isinstance(entry.get("Layers"), list):
                    raise AuditError("Docker save manifest has invalid layer references")
                configs.add(entry["Config"])
                layers.update(entry["Layers"])
            found = set()
            for member in archive:
                self.scan_metadata({"name": member.name, "link": member.linkname,
                                    "pax": member.pax_headers}, location + ":archive-metadata")
                if not member.isfile():
                    continue
                with archive.extractfile(member) as source:
                    if member.name in layers:
                        self.layer(source, f"{location}:layer:{member.name}")
                    else:
                        # Image configuration includes Env and complete history
                        # (CreatedBy/build instructions), without docker history output.
                        self.scan(source, f"{location}:metadata:{member.name}", member.size)
                found.add(member.name)
            if (layers | configs) - found:
                raise AuditError("Docker save archive is missing referenced configuration or layers")

    def image(self, reference):
        if reference.startswith("-"):
            raise AuditError("Invalid Docker image reference")
        result = subprocess.run(["docker", "image", "inspect", "--format={{.Id}}", reference],
                                capture_output=True, check=False)
        image_id = result.stdout.strip().decode("ascii")
        if result.returncode or not re.fullmatch(r"sha256:[a-f0-9]{64}", image_id):
            raise AuditError("Docker could not resolve the selected local image")
        self.report["images"].append({"reference": self.redact(reference), "id": image_id})
        with tempfile.TemporaryDirectory(prefix="vapid-image-audit-") as directory:
            path = Path(directory) / "image.tar"
            result = subprocess.run(["docker", "image", "save", "--output", str(path), image_id],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if result.returncode:
                raise AuditError("Docker could not save the selected local image")
            self.image_archive(path, reference)

    def file(self, path):
        path = Path(path)
        if path.is_symlink() or not path.is_file():
            raise AuditError("Explicit log/source input must be a regular file, not a symlink")
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rb") as source:
            self.scan(source, f"file:{path}")

    def run_target(self, operation, target):
        self.report["targets"].append({"kind": operation.__name__, "target": self.redact(str(target))})
        try:
            operation(target)
        except Exception:
            # Never print exception text: parsers and Docker/Git errors can
            # contain secret-bearing file names, metadata, or input fragments.
            self.report["complete_for_selected_inputs"] = False
            self.report["errors"].append({"target": self.redact(str(target)),
                                          "message": "Input could not be fully scanned; verify format, access and full Git history"})


def main(argv=None, stdin=None):
    parser = SafeArgumentParser(description=__doc__)
    key = parser.add_mutually_exclusive_group(required=True)
    key.add_argument("--key-file", help="Owner-only file containing the private key; never the value itself")
    key.add_argument("--key-stdin", action="store_true", help="Read private key from a non-interactive pipe")
    parser.add_argument("--repo", action="append", default=[], help="Full local Git repository (repeatable)")
    parser.add_argument("--image", action="append", default=[], help="Local Docker image ID/digest (repeatable)")
    parser.add_argument("--image-archive", action="append", default=[], help="Archive from docker image save (repeatable)")
    parser.add_argument("--file", action="append", default=[], help="Explicit source/log file, optionally gzip (repeatable)")
    args = parser.parse_args(argv)
    if not any((args.repo, args.image, args.image_archive, args.file)):
        parser.error("Select at least one repository, image, image archive or file")
    try:
        value, raw = read_key(args.key_file, stdin or sys.stdin.buffer)
    except (AuditError, OSError) as error:
        message = str(error) if isinstance(error, AuditError) else "Cannot read protected key input"
        print(json.dumps({"complete_for_selected_inputs": False, "error": message}))
        return 2
    scanner = Scanner(value, raw)
    for targets, operation in [(args.repo, scanner.git), (args.image, scanner.image),
                               (args.image_archive, scanner.image_archive), (args.file, scanner.file)]:
        for target in targets:
            scanner.run_target(operation, target)
    report = scanner.report
    report["match_count"] = sum(item["matches"] for item in report["findings"])
    print(scanner.redact(json.dumps(report, indent=2)))
    return 2 if report["errors"] else 1 if report["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
