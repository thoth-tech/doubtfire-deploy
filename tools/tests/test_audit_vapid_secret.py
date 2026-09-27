import base64
from contextlib import redirect_stderr, redirect_stdout
import gzip
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "audit-vapid-secret.py"
SPEC = importlib.util.spec_from_file_location("audit_vapid_secret", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)
RAW = bytes(range(1, 33))
KEY = base64.urlsafe_b64encode(RAW).rstrip(b"=")


def tar_bytes(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()


class AuditTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.key = self.root / "protected-key"
        self.key.write_bytes(KEY + b"\n")
        self.key.chmod(0o600)

    def cli(self, *args, key_args=None):
        output, error = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(error):
            code = AUDIT.main([*(key_args or ["--key-file", str(self.key)]), *map(str, args)],
                              stdin=io.BytesIO(KEY + b"\n"))
        text = output.getvalue() + error.getvalue()
        self.assertNotIn(KEY.decode(), text)
        self.assertNotIn(base64.b64encode(RAW).decode(), text)
        return code, json.loads(output.getvalue())

    def archive(self, name, *, leak=False, history=False, missing=False):
        layer1 = tar_bytes({"private.env": b"VAPID=" + KEY if leak else b"public fixture"})
        layer2 = tar_bytes({".wh.private.env": b""})
        config = {"history": [{"created_by": "ENV VAPID=" + KEY.decode() if history else "COPY fixture"}]}
        files = {"manifest.json": json.dumps([{"Config": "config.json", "Layers": ["one/layer.tar", "two/layer.tar"]}]).encode(),
                 "config.json": json.dumps(config).encode(), "one/layer.tar": layer1}
        if not missing:
            files["two/layer.tar"] = gzip.compress(layer2)
        result = self.root / name
        result.write_bytes(tar_bytes(files))
        return result

    def test_clean_archive_and_log_pass_with_counts(self):
        log = self.root / "clean.log"
        log.write_text("Notification delivered without credentials\n")
        code, report = self.cli("--image-archive", self.archive("clean.tar"), "--file", log)
        self.assertEqual(0, code)
        self.assertTrue(report["complete_for_selected_inputs"])
        self.assertEqual(0, report["match_count"])
        self.assertGreater(report["scanned_items"], 0)

    def test_image_detects_deleted_layer_file_and_build_history(self):
        code, report = self.cli("--image-archive", self.archive("leaking.tar", leak=True, history=True))
        self.assertEqual(1, code)
        locations = [finding["location"] for finding in report["findings"]]
        self.assertTrue(any("one/layer.tar:private.env" in path for path in locations))
        self.assertTrue(any("metadata:config.json" in path for path in locations))
        self.assertEqual(2, report["match_count"])

    def test_missing_image_layer_is_incomplete_not_clean(self):
        code, report = self.cli("--image-archive", self.archive("broken.tar", missing=True))
        self.assertEqual(2, code)
        self.assertFalse(report["complete_for_selected_inputs"])
        self.assertEqual(1, len(report["errors"]))

    def test_streaming_boundary_counts_a_padded_key_once(self):
        scanner = AUDIT.Scanner(KEY, RAW)
        data = b"x" * (65536 - 20) + KEY + b"=" + b"end"
        matches, length = scanner.count(io.BytesIO(data))
        self.assertEqual(1, matches)
        self.assertEqual(len(data), length)

    def test_binary_and_encoded_forms_are_detected(self):
        scanner = AUDIT.Scanner(KEY, RAW)
        for form in [RAW, RAW.hex().encode(), base64.b64encode(RAW), base64.b64encode(KEY)]:
            with self.subTest(length=len(form)):
                self.assertEqual(1, scanner.count(io.BytesIO(form))[0])

    def test_compressed_log_and_secret_bearing_location_are_redacted(self):
        log = self.root / (KEY.decode() + ".log.gz")
        log.write_bytes(gzip.compress(b"private value: " + KEY))
        code, report = self.cli("--file", log, key_args=["--key-stdin"])
        self.assertEqual(1, code)
        self.assertIn("[REDACTED].log.gz", report["findings"][0]["location"])

    def test_world_readable_key_file_is_rejected(self):
        self.key.chmod(0o644)
        code, report = self.cli("--file", self.key)
        self.assertEqual(2, code)
        self.assertFalse(report["complete_for_selected_inputs"])

    def test_symlink_key_file_is_rejected(self):
        link = self.root / "key-link"
        link.symlink_to(self.key)
        code, _ = self.cli("--file", self.key, key_args=["--key-file", str(link)])
        self.assertEqual(2, code)

    def test_unknown_argument_does_not_echo_a_mistaken_key_value(self):
        output = io.StringIO()
        with redirect_stderr(output), self.assertRaises(SystemExit) as error:
            AUDIT.main(["--key-value", KEY.decode()])
        self.assertEqual(2, error.exception.code)
        self.assertNotIn(KEY.decode(), output.getvalue())

    def test_interactive_key_input_is_rejected(self):
        class Terminal(io.BytesIO):
            def isatty(self):
                return True
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.read_key(None, Terminal(KEY))

    def test_malformed_archive_diagnostics_do_not_echo_secret_content(self):
        archive = self.root / "invalid.tar"
        archive.write_bytes(tar_bytes({"manifest.json": b"invalid " + KEY}))
        code, report = self.cli("--image-archive", archive)
        self.assertEqual(2, code)
        self.assertFalse(report["complete_for_selected_inputs"])

    def test_layer_paths_are_scanned_without_extracting_files(self):
        scanner = AUDIT.Scanner(KEY, RAW)
        archive = tar_bytes({"../../outside-audit": KEY})
        scanner.layer(io.BytesIO(archive), "synthetic-layer")
        self.assertEqual(1, len(scanner.report["findings"]))
        self.assertEqual(1, scanner.report["findings"][0]["matches"])
        self.assertFalse((self.root / "outside-audit").exists())

    def test_unreadable_or_invalid_input_is_not_reported_clean(self):
        code, report = self.cli("--file", self.root / "missing.log")
        self.assertEqual(2, code)
        self.assertFalse(report["complete_for_selected_inputs"])
        self.key.write_text("invalid " + KEY.decode())
        code, _ = self.cli("--file", self.key)
        self.assertEqual(2, code)

    def test_git_scans_deleted_history_and_commit_messages(self):
        repository = self.root / "repo"
        repository.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repository), "-c", "user.name=Audit Fixture",
                                            "-c", "user.email=audit@example.invalid", *args], stderr=subprocess.DEVNULL)
        git("init", "--quiet")
        tracked = repository / "removed.env"
        tracked.write_bytes(KEY)
        git("add", "removed.env")
        git("commit", "--quiet", "-m", "synthetic " + KEY.decode())
        tracked.unlink()
        git("add", "-u")
        git("commit", "--quiet", "-m", "remove synthetic fixture")
        code, report = self.cli("--repo", repository)
        self.assertEqual(1, code)
        locations = [item["location"] for item in report["findings"]]
        self.assertTrue(any(":blob:" in path for path in locations))
        self.assertTrue(any(":commit:" in path for path in locations))
        self.assertEqual(2, report["match_count"])

    def test_shallow_repository_cannot_pass_the_audit(self):
        repository = self.root / "empty-repo"
        subprocess.run(["git", "init", "--quiet", str(repository)], check=True, capture_output=True)
        # Git recognizes a shallow file as a shallow clone. No object values
        # need to be invented or read from a production repository.
        (repository / ".git/shallow").write_text(40 * "0" + "\n")
        code, report = self.cli("--repo", repository)
        self.assertEqual(2, code)
        self.assertFalse(report["complete_for_selected_inputs"])


if __name__ == "__main__":
    unittest.main()
