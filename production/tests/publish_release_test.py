#!/usr/bin/env python3
"""Exercise publisher arguments with real local Git sources and a fake registry."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


PUBLISHER = Path(__file__).resolve().parents[1] / "publish-release.sh"
REGISTRY = "registry.example.edu/ontrack"
VERSION = "11.0.2-recovery.1"


class PublishReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="df-publisher-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.fixture = Path(cls.temporary.name)
        cls.repository = cls.fixture / "release"
        cls.binary_directory = cls.fixture / "bin"
        cls.binary_directory.mkdir()
        cls.docker_calls = cls.fixture / "docker-calls.jsonl"
        cls.environment = dict(
            os.environ,
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            PUBLISH_RELEASE_CONFIRM="1",
            PUBLISHER_TEST_DOCKER_CALLS=str(cls.docker_calls),
            PATH=str(cls.binary_directory) + os.pathsep + os.environ["PATH"],
        )
        for name, files in (
            ("api", ("deployApi.Dockerfile", "deployAppSvr.Dockerfile",
                     "texlive.Dockerfile", "jplag.Dockerfile")),
            ("web", ("deploy.Dockerfile",)),
        ):
            source = cls.fixture / name
            source.mkdir()
            cls.git(source, "init", "-q")
            for filename in files:
                (source / filename).write_text("FROM scratch\n", encoding="utf-8")
            cls.git(source, "add", ".")
            cls.git(source, "commit", "-qm", "Fixture source")

        cls.repository.mkdir()
        cls.git(cls.repository, "init", "-q")
        (cls.repository / "production").mkdir()
        cls.script = cls.repository / "production" / "publish-release.sh"
        shutil.copy2(PUBLISHER, cls.script)
        for name in ("api", "web"):
            cls.git(cls.repository, "submodule", "add", "-q",
                    str(cls.fixture / name), "doubtfire-" + name)
        cls.git(cls.repository, "add", ".")
        cls.git(cls.repository, "commit", "-qm", "Pin fixture sources")

        # Every Docker invocation is captured; unsupported commands fail closed.
        # The fixture never calls an actual Docker daemon or registry.
        docker = cls.binary_directory / "docker"
        docker.write_text("#!" + sys.executable + "\n" + textwrap.dedent("""\
            import hashlib
            import json
            import os
            from pathlib import Path
            import sys

            arguments = sys.argv[1:]
            with open(os.environ["PUBLISHER_TEST_DOCKER_CALLS"], "a") as calls:
                calls.write(json.dumps(arguments) + "\\n")
            if arguments == ["buildx", "version"]:
                print("buildx publisher test fixture")
            elif arguments[:2] == ["buildx", "build"]:
                image = arguments[arguments.index("--tag") + 1]
                if image == os.environ.get("PUBLISHER_TEST_FAIL_IMAGE"):
                    print("Fixture build failure", file=sys.stderr)
                    raise SystemExit(23)
                digest = "sha256:" + hashlib.sha256(image.encode()).hexdigest()
                metadata = Path(arguments[arguments.index("--metadata-file") + 1])
                metadata.write_text(json.dumps({"containerimage.digest": digest}))
            elif arguments[:3] == ["buildx", "imagetools", "inspect"]:
                print(arguments[3].split("@", 1)[1])
            else:
                raise SystemExit("Unexpected Docker command: " + repr(arguments))
            """), encoding="utf-8")
        docker.chmod(0o755)

    @classmethod
    def git(cls, directory, *arguments):
        subprocess.run(
            ["git", "-c", "user.name=Publisher Test", "-c",
             "user.email=publisher@example.invalid", "-c", "commit.gpgsign=false",
             "-c", "protocol.file.allow=always", *arguments],
            cwd=directory, env=cls.environment, check=True, capture_output=True,
        )

    def invoke(self, *arguments, confirmed=True, fail_image=None):
        self.docker_calls.unlink(missing_ok=True)
        environment = dict(self.environment)
        if fail_image is not None:
            environment["PUBLISHER_TEST_FAIL_IMAGE"] = fail_image
        if not confirmed:
            environment.pop("PUBLISH_RELEASE_CONFIRM")
        result = subprocess.run(
            ["bash", str(self.script), *arguments],
            env=environment, capture_output=True, text=True, timeout=30,
        )
        calls = [json.loads(line) for line in self.docker_calls.read_text().splitlines()] \
            if self.docker_calls.exists() else []
        return result, calls

    def assert_publication(self, result, calls, platforms, recovery):
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[:2] == ["buildx", "build"]]
        self.assertEqual(len(builds), 5)
        self.assertEqual(len([line for line in result.stdout.splitlines()
                              if "_IMAGE=" in line]), 5)
        for build in builds:
            image = build[build.index("--tag") + 1]
            self.assertEqual(build[build.index("--platform") + 1], platforms)
            self.assertIn("--push", build)
            self.assertIn("--sbom=true", build)
            self.assertIn("--provenance=mode=max", build)
            self.assertEqual("--no-cache" in build,
                             recovery and image == f"{REGISTRY}/doubtfire-web:{VERSION}")

    def test_normal_publication_preserves_cache_and_default_platforms(self):
        result, calls = self.invoke(REGISTRY, VERSION)
        self.assert_publication(result, calls, "linux/amd64,linux/arm64", recovery=False)

    def test_recovery_bypasses_only_web_cache_and_accepts_option_positions(self):
        for arguments in (
            ("--no-cache-web", REGISTRY, VERSION, "linux/amd64"),
            (REGISTRY, VERSION, "linux/amd64", "--no-cache-web"),
            (REGISTRY, VERSION, "--no-cache-web"),
        ):
            with self.subTest(arguments=arguments):
                result, calls = self.invoke(*arguments)
                platforms = "linux/amd64" if "linux/amd64" in arguments \
                    else "linux/amd64,linux/arm64"
                self.assert_publication(result, calls, platforms, recovery=True)

    def test_invalid_arguments_fail_before_docker(self):
        for arguments, message in (
            (("--no-cache", REGISTRY, VERSION), "unknown option"),
            (("--no-cache-web", "--no-cache-web", REGISTRY, VERSION),
             "may only be specified once"),
            (("--no-cache-web",), "Usage:"),
            (("--no-cache-web", REGISTRY, VERSION, "linux/amd64", "extra"), "Usage:"),
            (("--no-cache-web", REGISTRY, VERSION, "windows/amd64"), "platforms must"),
            (("--no-cache-web", REGISTRY, "latest"), "release version"),
        ):
            with self.subTest(arguments=arguments):
                result, calls = self.invoke(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(calls, [])

    def test_recovery_does_not_bypass_publication_confirmation(self):
        result, calls = self.invoke("--no-cache-web", REGISTRY, VERSION, confirmed=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("set PUBLISH_RELEASE_CONFIRM=1", result.stderr)
        self.assertEqual(calls, [])

    def test_failed_web_build_preserves_failure_and_emits_no_partial_manifest(self):
        result, calls = self.invoke(
            "--no-cache-web", REGISTRY, VERSION,
            fail_image=f"{REGISTRY}/doubtfire-web:{VERSION}",
        )
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("Fixture build failure", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len([call for call in calls
                              if call[:2] == ["buildx", "build"]]), 3)


if __name__ == "__main__":
    unittest.main()
