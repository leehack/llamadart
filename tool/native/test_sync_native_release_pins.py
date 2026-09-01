from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

import sync_native_release_pins as pins  # noqa: E402
from sync_native_release_pins import (  # noqa: E402
    ReleaseError,
    LEGACY_SCHEMA1_RELEASES,
    atomic_write_many,
    fetch_release,
    litert_lm_bundle_names,
    litert_schema2_bundle_required_libraries,
    litert_lm_runtime_version,
    normalize_litert_lm_release_tag,
    prepare_litert_lm_package_swift,
    replace_litert_lm_bundle_required_libraries,
    require_exact_keys,
    required_litert_release_asset_names,
    validate_litert_lm_transition,
    validate_litert_lm_release_manifest,
    validate_litert_release_asset_inventory,
)


UPSTREAM_COMMIT = "ba82499873945908bf8bcfc96e955d0677eb1fa1"
NATIVE_COMMIT = "451ba0ce7c366972b4dc0e58f08ffe590958f943"
DEVELOPMENT_TAG = "gba8249987394"

SIGNED_URL = "https://objects.example.invalid/asset?token=super-secret"


class _FakeResponse:
    def __init__(
        self, payload: bytes = b"", read_error: BaseException | None = None
    ) -> None:
        self._payload = payload
        self._read_error = read_error

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, *args: object) -> bytes:
        if self._read_error is not None:
            raise self._read_error
        payload, self._payload = self._payload, b""
        return payload


def _release_with_asset(asset_name: str, tag: str = "v0.16.0") -> dict:
    return {
        "tag_name": tag,
        "assets": [
            {"name": asset_name, "browser_download_url": SIGNED_URL},
        ],
    }


PROBE_TOKEN = "ghp-llamadart-transport-probe-9f2c4e"


class GithubAuthTransportTest(unittest.TestCase):
    """The real token must reach GitHub while staying out of every diagnostic."""

    def setUp(self) -> None:
        self.seen: list[str | None] = []
        self.status = 200
        test = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                test.seen.append(self.headers.get("Authorization"))
                body = json.dumps({"tag_name": "v0.16.0", "assets": []}).encode()
                self.send_response(test.status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: object) -> None:
                return

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{server.server_address[1]}/release.json"

    def _env(self, name: str = "") -> dict[str, str]:
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("GH_TOKEN", "GITHUB_TOKEN")
        }
        if name:
            env[name] = PROBE_TOKEN
        return env

    def test_auth_header_carries_the_real_token(self) -> None:
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            with self.subTest(variable=name), patch.dict(
                os.environ, self._env(name), clear=True
            ):
                self.assertEqual(
                    pins.github_auth_header(),
                    {"Authorization": f"Bearer {PROBE_TOKEN}"},
                )
                self.assertEqual(
                    pins.github_api_headers()["Authorization"],
                    f"Bearer {PROBE_TOKEN}",
                )

    def test_no_auth_header_without_a_token(self) -> None:
        with patch.dict(os.environ, self._env(), clear=True):
            self.assertEqual(pins.github_auth_header(), {})

    def test_transport_sends_the_real_token(self) -> None:
        with patch.dict(os.environ, self._env("GH_TOKEN"), clear=True):
            payload = pins.read_release_url(
                self.url, context="probe", headers=pins.github_api_headers()
            )
        self.assertEqual(self.seen, [f"Bearer {PROBE_TOKEN}"])
        self.assertEqual(json.loads(payload)["tag_name"], "v0.16.0")

    def test_failures_never_echo_the_token(self) -> None:
        self.status = 404
        with patch.dict(os.environ, self._env("GH_TOKEN"), clear=True):
            with self.assertRaises(ReleaseError) as raised:
                pins.read_release_url(
                    self.url, context="probe", headers=pins.github_api_headers()
                )
        self.assertEqual(self.seen, [f"Bearer {PROBE_TOKEN}"])
        cause = raised.exception.__cause__
        message = f"{raised.exception}{cause}"
        if isinstance(cause, urllib.error.HTTPError):
            cause.close()
        self.assertIn("HTTP 404", message)
        self.assertNotIn(PROBE_TOKEN, message)
        self.assertNotIn(self.url, str(raised.exception))


class ReleaseTransportFailureTest(unittest.TestCase):
    def setUp(self) -> None:
        for name, value in (
            ("HTTP_RETRY_DELAY_SECONDS", 0.0),
            ("HTTP_SOCKET_TIMEOUT_SECONDS", 0.25),
        ):
            patcher = patch.object(pins, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _http_error(self, code: int) -> urllib.error.HTTPError:
        error = urllib.error.HTTPError(SIGNED_URL, code, SIGNED_URL, {}, None)
        self.addCleanup(error.close)
        return error

    def _assert_actionable(self, message: str, *expected: str) -> None:
        for fragment in expected:
            self.assertIn(fragment, message)
        self.assertNotIn("Traceback", message)
        self.assertNotIn("objects.example.invalid", message)
        self.assertNotIn("super-secret", message)

    def test_dns_failure_is_retried_and_reported_without_the_url(self) -> None:
        error = urllib.error.URLError(socket.gaierror(SIGNED_URL))
        with patch.object(
            pins.urllib.request, "urlopen", side_effect=error
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0")

        self._assert_actionable(
            str(raised.exception),
            "Failed to fetch release owner/repo@v0.16.0",
            "DNS lookup failed",
        )
        self.assertEqual(urlopen.call_count, pins.HTTP_MAX_ATTEMPTS)
        self.assertEqual(
            {call.kwargs["timeout"] for call in urlopen.call_args_list},
            {pins.HTTP_SOCKET_TIMEOUT_SECONDS},
        )

    def test_permanent_http_error_is_not_retried(self) -> None:
        error = self._http_error(404)
        with patch.object(
            pins.urllib.request, "urlopen", side_effect=error
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0")

        self._assert_actionable(
            str(raised.exception), "owner/repo@v0.16.0", "HTTP 404"
        )
        urlopen.assert_called_once()

    def test_transient_http_error_is_retried_then_reported(self) -> None:
        error = self._http_error(503)
        with patch.object(
            pins.urllib.request, "urlopen", side_effect=error
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0")

        self._assert_actionable(str(raised.exception), "HTTP 503")
        self.assertEqual(urlopen.call_count, pins.HTTP_MAX_ATTEMPTS)

    def test_nontransient_os_error_is_not_retried(self) -> None:
        with patch.object(
            pins.urllib.request, "urlopen", side_effect=OSError(SIGNED_URL)
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0")
        self._assert_actionable(str(raised.exception), "network error")
        urlopen.assert_called_once()

    def test_connection_timeout_is_reported_with_the_bound(self) -> None:
        with patch.object(
            pins.urllib.request, "urlopen", side_effect=TimeoutError(SIGNED_URL)
        ):
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0")

        self._assert_actionable(
            str(raised.exception),
            f"timed out (socket {pins.HTTP_SOCKET_TIMEOUT_SECONDS:g}s, "
            f"total {pins.HTTP_TOTAL_TIMEOUT_SECONDS:g}s)",
        )

    def test_interrupted_asset_download_is_reported(self) -> None:
        with patch.object(
            pins.urllib.request,
            "urlopen",
            side_effect=lambda *a, **k: _FakeResponse(
                read_error=http.client.IncompleteRead(b"partial")
            ),
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                pins.release_asset_bytes(
                    _release_with_asset("bundle.tar.gz"),
                    "bundle.tar.gz",
                    repo="owner/repo",
                    tag="v0.16.0",
                    release_json_dir="",
                )

        self._assert_actionable(
            str(raised.exception),
            "Failed to read release asset bundle.tar.gz (owner/repo@v0.16.0)",
            "interrupted download",
        )
        self.assertEqual(urlopen.call_count, pins.HTTP_MAX_ATTEMPTS)

    def test_invalid_manifest_payloads_are_release_errors(self) -> None:
        for payload in (b"{not json", b"\xff\xfe", b'"a string"'):
            with self.subTest(payload=payload), patch.object(
                pins.urllib.request,
                "urlopen",
                return_value=_FakeResponse(payload),
            ):
                with self.assertRaises(ReleaseError) as raised:
                    pins.release_asset_json(
                        _release_with_asset("assets.json"), "assets.json"
                    )
                self._assert_actionable(str(raised.exception), "assets.json")

        release = _release_with_asset("assets.json")
        release["assets"][0]["fixture_json"] = []
        with self.assertRaisesRegex(ReleaseError, "must be a JSON object"):
            pins.release_asset_json(release, "assets.json")

    def test_checksum_fallback_download_failure_names_the_asset(self) -> None:
        error = self._http_error(403)
        with patch.object(pins.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(ReleaseError) as raised:
                pins.release_asset_checksum(
                    _release_with_asset("SHA256SUMS"),
                    "SHA256SUMS",
                    repo="owner/repo",
                )

        self._assert_actionable(
            str(raised.exception),
            "Failed to read release asset SHA256SUMS (owner/repo@v0.16.0)",
            "HTTP 403",
        )

    def test_missing_fixture_is_actionable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ReleaseError) as raised:
                fetch_release("owner/repo", "v0.16.0", temp)

        self._assert_actionable(
            str(raised.exception),
            "Failed to fetch release owner/repo@v0.16.0",
            "cannot read fixture",
        )

    def test_transient_failure_recovers_on_retry(self) -> None:
        payload = json.dumps({"tag_name": "v0.16.0", "assets": []}).encode("utf-8")
        with patch.object(
            pins.urllib.request,
            "urlopen",
            side_effect=[
                urllib.error.URLError(ConnectionResetError("reset")),
                _FakeResponse(payload),
            ],
        ) as urlopen:
            release = fetch_release("owner/repo", "v0.16.0")

        self.assertEqual(release["tag_name"], "v0.16.0")
        self.assertEqual(urlopen.call_count, 2)

    def test_invalid_url_is_typed_and_redacted(self) -> None:
        secret_url = "not-a-url?token=super-secret"
        with self.assertRaises(ReleaseError) as raised:
            pins.read_release_url(secret_url, context="Failed to read asset")
        self._assert_actionable(
            str(raised.exception), "Failed to read asset", "invalid download URL"
        )

    def test_streaming_read_cannot_exceed_the_overall_deadline(self) -> None:
        with patch.object(
            pins.time,
            "monotonic",
            side_effect=[
                0.0,
                0.0,
                0.0,
                pins.HTTP_TOTAL_TIMEOUT_SECONDS + 1,
                pins.HTTP_TOTAL_TIMEOUT_SECONDS + 1,
            ],
        ), patch.object(
            pins.urllib.request, "urlopen", return_value=_FakeResponse(b"payload")
        ) as urlopen:
            with self.assertRaises(ReleaseError) as raised:
                pins.read_release_url(SIGNED_URL, context="Failed to read asset")

        self._assert_actionable(str(raised.exception), "timed out")
        urlopen.assert_called_once()

    def test_invalid_digest_and_asset_inventory_are_rejected(self) -> None:
        release = _release_with_asset("bundle.tar.gz")
        release["assets"][0]["digest"] = "sha512:abcd"
        with self.assertRaisesRegex(ReleaseError, "invalid GitHub SHA-256 digest"):
            pins.release_asset_checksum(release, "bundle.tar.gz")

        duplicate = _release_with_asset("bundle.tar.gz")
        duplicate["assets"].append(dict(duplicate["assets"][0]))
        with self.assertRaisesRegex(ReleaseError, "duplicates asset"):
            pins.release_asset_checksum(duplicate, "bundle.tar.gz")


def _schema2_fixture_payloads() -> tuple[dict, dict]:
    fixture_root = Path(__file__).resolve().parent / "fixtures"
    manifest = json.loads(
        (fixture_root / "litert_lm_schema2_owner_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    release = json.loads(
        (fixture_root / "litert_lm_schema2_owner_release.json").read_text(
            encoding="utf-8"
        )
    )
    return manifest, release


def _set_release_asset_digest(release: dict, name: str, digest: str) -> None:
    asset = next(asset for asset in release["assets"] if asset["name"] == name)
    asset["digest"] = f"sha256:{digest}"


def _materialize_schema2_release_fixtures(
    fixture_dir: Path,
    manifest: dict,
    release: dict,
) -> None:
    repo = "leehack/litert-lm-native"
    tag = manifest["release"]["tag"]
    manifest_bytes = json.dumps(manifest).encode("utf-8")
    (fixture_dir / f"{repo.replace('/', '__')}__{tag}__manifest.json").write_bytes(
        manifest_bytes
    )
    _set_release_asset_digest(
        release,
        "manifest.json",
        hashlib.sha256(manifest_bytes).hexdigest(),
    )
    checksum_text = "".join(
        f"{artifact['sha256']}  {artifact['path']}\n"
        for artifact in manifest["artifacts"]
    ).encode("utf-8")
    (fixture_dir / f"{repo.replace('/', '__')}__{tag}__SHA256SUMS").write_bytes(
        checksum_text
    )
    _set_release_asset_digest(
        release,
        "SHA256SUMS",
        hashlib.sha256(checksum_text).hexdigest(),
    )
    (fixture_dir / f"google-ai-edge__LiteRT-LM__v0.16.0__commit.json").write_text(
        json.dumps({"sha": manifest["upstream"]["commit"]}),
        encoding="utf-8",
    )
    (fixture_dir / f"{repo.replace('/', '__')}__{tag}__commit.json").write_text(
        json.dumps({"sha": manifest["native"]["commit"]}),
        encoding="utf-8",
    )
    (fixture_dir / f"{repo.replace('/', '__')}__{tag}.json").write_text(
        json.dumps(release),
        encoding="utf-8",
    )


def _run_schema2_sync(
    temp_dir: Path,
    manifest: dict,
    release: dict,
    *,
    include_runtime_dependencies: bool = False,
) -> subprocess.CompletedProcess[str]:
    repo_root = temp_dir / "repo"
    source_root = Path(__file__).resolve().parents[2]
    if include_runtime_dependencies:
        shutil.copytree(source_root / "lib", repo_root / "lib")
        (repo_root / ".dart_tool").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            source_root / ".dart_tool/package_config.json",
            repo_root / ".dart_tool/package_config.json",
        )
        shutil.copyfile(source_root / "pubspec.yaml", repo_root / "pubspec.yaml")
    for relative_path in (
        "hook/build.dart",
        "lib/src/backends/litert_lm/litert_lm_runtime.dart",
        "tool/macos_litert_lm_prepare_app.sh",
        "README.md",
        "CHANGELOG.md",
        "website/docs/getting-started/installation.md",
        "website/docs/platforms/support-matrix.md",
        "packages/llamadart_litert_lm_flutter/darwin/"
        "llamadart_litert_lm_flutter/Package.swift",
        "packages/llamadart_litert_lm_flutter/pubspec.yaml",
        "packages/llamadart_litert_lm_flutter/README.md",
        "packages/llamadart_litert_lm_flutter/CHANGELOG.md",
    ):
        target = repo_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_root / relative_path, target)
    release_dir = temp_dir / "releases"
    release_dir.mkdir()
    _materialize_schema2_release_fixtures(release_dir, manifest, release)
    script = Path(__file__).resolve().parent / "sync_native_release_pins.py"
    return subprocess.run(
        [
            sys.executable,
            str(script),
            "--repo-root",
            str(repo_root),
            "--release-json-dir",
            str(release_dir),
            "--llama-cpp-tag",
            "keep",
            "--litert-lm-tag",
            manifest["release"]["tag"],
            "--litert-lm-package-swift",
            "packages/llamadart_litert_lm_flutter/darwin/"
            "llamadart_litert_lm_flutter/Package.swift",
            "--litert-lm-macos-prepare-script",
            "tool/macos_litert_lm_prepare_app.sh",
        ],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )


def _run_generated_macos_prepare(
    repo_root: Path,
    library_dir: Path,
    app_dir: Path,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "LLAMADART_LITERT_LM_ARCH": "arm64",
            "LLAMADART_LITERT_LM_LIB_DIR": str(library_dir),
        }
    )
    return subprocess.run(
        [
            "bash",
            str(repo_root / "tool/macos_litert_lm_prepare_app.sh"),
            str(app_dir),
        ],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )


def _run_dart_inventory_checks(
    repo_root: Path,
) -> tuple[
    subprocess.CompletedProcess[str],
    subprocess.CompletedProcess[str],
    subprocess.CompletedProcess[str],
]:
    generated = repo_root / "tool/native/generated_litert_lm_inventory.dart"
    generated.parent.mkdir(parents=True, exist_ok=True)
    generated.write_text(
        """import 'dart:ffi';

import '../../lib/src/backends/litert_lm/litert_lm_runtime.dart';

void _expectList(String label, List<String> actual, List<String> expected) {
  if (actual.length != expected.length ||
      !actual.asMap().entries.every(
        (entry) => entry.value == expected[entry.key],
      )) {
    throw StateError('$label: $actual != $expected');
  }
}

void main() {
  _expectList(
    'macOS arm64 libraries',
    liteRtLmMacOsRequiredLibrariesForAbi(Abi.macosArm64),
    <String>['libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'],
  );
  _expectList(
    'macOS x64 libraries',
    liteRtLmMacOsRequiredLibrariesForAbi(Abi.macosX64),
    <String>['libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'],
  );
  _expectList(
    'macOS arm64 frameworks',
    liteRtLmMacOsRequiredFrameworksForAbi(Abi.macosArm64),
    <String>[
      'CLiteRTLM_mac.framework/Versions/A/CLiteRTLM_mac',
      'LiteRtLm.framework/Versions/A/LiteRtLm',
    ],
  );
  _expectList(
    'macOS x64 frameworks',
    liteRtLmMacOsRequiredFrameworksForAbi(Abi.macosX64),
    <String>[
      'CLiteRTLM_mac.framework/Versions/A/CLiteRTLM_mac',
      'LiteRtLm.framework/Versions/A/LiteRtLm',
    ],
  );
  _expectList(
    'macOS arm64 native SPM files',
    liteRtLmMacOsRequiredNativeSpmFilesForAbi(Abi.macosArm64),
    <String>[
      'LiteRtLm.framework/Versions/A/LiteRtLm',
      'libCLiteRTLM_mac.dylib',
    ],
  );
  _expectList(
    'macOS x64 native SPM files',
    liteRtLmMacOsRequiredNativeSpmFilesForAbi(Abi.macosX64),
    <String>[
      'LiteRtLm.framework/Versions/A/LiteRtLm',
      'libCLiteRTLM_mac.dylib',
    ],
  );
}
""",
        encoding="utf-8",
    )
    format_result = subprocess.run(
        [
            "dart",
            "format",
            "--output=none",
            "--set-exit-if-changed",
            str(repo_root / "lib/src/backends/litert_lm/litert_lm_runtime.dart"),
        ],
        check=False,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    analyze_result = subprocess.run(
        [
            "dart",
            "analyze",
            str(repo_root / "lib/src/backends/litert_lm/litert_lm_runtime.dart"),
        ],
        check=False,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    run_result = subprocess.run(
        [
            "dart",
            f"--packages={repo_root / '.dart_tool/package_config.json'}",
            str(generated),
        ],
        check=False,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    return format_result, analyze_result, run_result


class SyncNativeReleasePinsTest(unittest.TestCase):
    def test_exact_keys_rejects_non_object_json(self) -> None:
        with self.assertRaisesRegex(ReleaseError, "must be an object"):
            require_exact_keys([], {"expected"}, "test payload")

    def test_release_fixture_errors_are_typed_and_tag_bound(self) -> None:
        repo = "leehack/litert-lm-native"
        tag = "v0.16.0-3"
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp) / f"leehack__litert-lm-native__{tag}.json"
            fixture.write_bytes(b"\xff")
            with self.assertRaisesRegex(ReleaseError, "Failed to fetch release"):
                fetch_release(repo, tag, temp)

            fixture.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "must be a JSON object"):
                fetch_release(repo, tag, temp)

            fixture.write_text(
                json.dumps({"tag_name": "v0.16.0-4"}), encoding="utf-8"
            )
            with self.assertRaisesRegex(ReleaseError, "unexpected tag"):
                fetch_release(repo, tag, temp)

    def test_sync_workflow_captures_every_litert_pin_surface(self) -> None:
        workflow = (
            Path(__file__).resolve().parents[2]
            / ".github"
            / "workflows"
            / "sync_native_bindings.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("tool/macos_litert_lm_prepare_app.sh", workflow)
        self.assertIn("allow_litert_channel_transition:", workflow)
        self.assertIn("allow_litert_development_line_transition:", workflow)
        self.assertIn("--allow-litert-channel-transition", workflow)
        self.assertIn("--allow-litert-development-line-transition", workflow)
        self.assertIn("legacy vX.Y.Z-native.N, latest, or keep", workflow)
        allowlist = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "legacy_release_allowlist.json"
        )
        self.assertEqual(
            hashlib.sha256(allowlist.read_bytes()).hexdigest(),
            "23ba56a9b11d60410b45398e5b3410f67ffca53d282deac74dd44102d15ec674",
        )
        self.assertEqual(len(LEGACY_SCHEMA1_RELEASES), 13)

    def test_litert_tag_grammar_preserves_new_and_legacy_forms(self) -> None:
        expected = {
            "0.16.1": "v0.16.1",
            "0.16.1-2": "v0.16.1-2",
            "v0.16.1": "v0.16.1",
            "v0.16.1-2": "v0.16.1-2",
            DEVELOPMENT_TAG: DEVELOPMENT_TAG,
            f"{DEVELOPMENT_TAG}-1": f"{DEVELOPMENT_TAG}-1",
            "0.16.0-native.2": "v0.16.0-native.2",
            "v0.16.0-native.2": "v0.16.0-native.2",
            "latest": "latest",
            "keep": "keep",
        }
        for value, normalized in expected.items():
            with self.subTest(value=value):
                self.assertEqual(normalize_litert_lm_release_tag(value), normalized)
        with self.assertRaises(ReleaseError):
            normalize_litert_lm_release_tag("main")
        self.assertEqual(litert_lm_runtime_version("v0.16.1-2"), "0.16.1-2")
        self.assertEqual(litert_lm_runtime_version(DEVELOPMENT_TAG), DEVELOPMENT_TAG)

    def test_transition_rejects_stable_and_rebuild_rollbacks(self) -> None:
        validate_litert_lm_transition("v0.16.0-native.2", "v0.16.0-3")
        validate_litert_lm_transition("v0.16.0-3", "v0.16.1")
        validate_litert_lm_transition(DEVELOPMENT_TAG, f"{DEVELOPMENT_TAG}-1")
        with self.assertRaisesRegex(ReleaseError, "rollback"):
            validate_litert_lm_transition("v0.16.0-native.2", "v0.16.0-1")
        with self.assertRaisesRegex(ReleaseError, "rollback"):
            validate_litert_lm_transition("v0.16.1", "v0.16.0-3")
        with self.assertRaisesRegex(ReleaseError, "rollback"):
            validate_litert_lm_transition(f"{DEVELOPMENT_TAG}-2", DEVELOPMENT_TAG)
        with self.assertRaisesRegex(ReleaseError, "ordinal alias"):
            validate_litert_lm_transition("v0.16.0-native.2", "v0.16.0-2")
        with self.assertRaisesRegex(ReleaseError, "immediate next ordinal"):
            validate_litert_lm_transition("v0.16.0-native.2", "v0.16.0-42")
        with self.assertRaisesRegex(ReleaseError, "target line at its base"):
            validate_litert_lm_transition("v0.16.0-native.2", "v0.17.0-1")
        with self.assertRaisesRegex(ReleaseError, "immediate next ordinal"):
            validate_litert_lm_transition(DEVELOPMENT_TAG, f"{DEVELOPMENT_TAG}-2")

    def test_channel_and_development_line_transitions_require_explicit_approval(self) -> None:
        with self.assertRaisesRegex(ReleaseError, "stable/development"):
            validate_litert_lm_transition("v0.16.0", DEVELOPMENT_TAG)
        validate_litert_lm_transition(
            "v0.16.0",
            DEVELOPMENT_TAG,
            allow_channel_transition=True,
        )
        with self.assertRaisesRegex(ReleaseError, "development line"):
            validate_litert_lm_transition(DEVELOPMENT_TAG, "g111111111111")
        validate_litert_lm_transition(
            DEVELOPMENT_TAG,
            "g111111111111",
            allow_development_line_transition=True,
        )
        with self.assertRaisesRegex(ReleaseError, "enter at its base"):
            validate_litert_lm_transition(
                DEVELOPMENT_TAG,
                "g111111111111-1",
                allow_development_line_transition=True,
            )

    def test_atomic_write_rolls_back_every_file_after_partial_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = root / "a.txt"
            second = root / "b.txt"
            first.write_text("old-a", encoding="utf-8")
            second.write_text("old-b", encoding="utf-8")
            new_replace_count = 0

            def flaky_replace(source: Path, destination: Path) -> None:
                nonlocal new_replace_count
                if ".new-" in source.name:
                    new_replace_count += 1
                    if new_replace_count == 2:
                        raise OSError("injected replacement failure")
                source.replace(destination)

            with self.assertRaisesRegex(ReleaseError, "Atomic pin update failed"):
                atomic_write_many(
                    {first: "new-a", second: "new-b"},
                    replace_func=flaky_replace,
                )
            self.assertEqual(first.read_text(encoding="utf-8"), "old-a")
            self.assertEqual(second.read_text(encoding="utf-8"), "old-b")

    def test_owner_generated_schema_2_manifest_is_consumed_exactly(self) -> None:
        owner_fixture = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "litert_lm_schema2_owner_manifest.json"
        )
        self.assertEqual(
            hashlib.sha256(owner_fixture.read_bytes()).hexdigest(),
            "fdd6cdf7304de550f789c41f3032792dc0a92a0d150f64585d8a721a90406c18",
        )
        manifest = json.loads(owner_fixture.read_text(encoding="utf-8"))
        tag = manifest["release"]["tag"]
        required_bundles = [
            f"{item['platform']}-{item['arch']}" for item in manifest["platforms"]
        ]
        expected_assets = required_litert_release_asset_names(manifest, tag)
        owner_release_fixture = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "litert_lm_schema2_owner_release.json"
        )
        self.assertEqual(
            hashlib.sha256(owner_release_fixture.read_bytes()).hexdigest(),
            "e2d199613270b62ad51c6b89fdb5375979822d8b5affd96e00c51afe59296002",
        )
        release = json.loads(owner_release_fixture.read_text(encoding="utf-8"))
        release_assets = release["assets"]
        manifest_asset = next(
            asset for asset in release_assets if asset["name"] == "manifest.json"
        )
        self.assertEqual(
            {asset["name"] for asset in release_assets}, expected_assets
        )
        with tempfile.TemporaryDirectory() as temp:
            fixture_dir = Path(temp)
            fixture = fixture_dir / f"leehack__litert-lm-native__{tag}__manifest.json"
            fixture.write_bytes(owner_fixture.read_bytes())
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )
            upstream_ref_fixture = (
                fixture_dir
                / "google-ai-edge__LiteRT-LM__v0.16.0__commit.json"
            )
            upstream_ref_fixture.write_text(
                json.dumps({"sha": manifest["upstream"]["commit"]}),
                encoding="utf-8",
            )
            native_ref_fixture = (
                fixture_dir
                / f"leehack__litert-lm-native__{tag}__commit.json"
            )
            native_ref_fixture.write_text(
                json.dumps({"sha": manifest["native"]["commit"]}),
                encoding="utf-8",
            )
            checksum_fixture = (
                fixture_dir
                / f"leehack__litert-lm-native__{tag}__SHA256SUMS"
            )
            checksum_fixture.write_text(
                "".join(
                    f"{artifact['sha256']}  {artifact['path']}\n"
                    for artifact in manifest["artifacts"]
                ),
                encoding="utf-8",
            )
            checksum_asset = next(
                asset for asset in release_assets if asset["name"] == "SHA256SUMS"
            )
            checksum_asset["digest"] = (
                "sha256:" + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
            )
            validate_litert_lm_release_manifest(
                release,
                repo="leehack/litert-lm-native",
                tag=tag,
                release_json_dir=str(fixture_dir),
                required_bundles=required_bundles,
            )

            scalar_cases = (
                (
                    manifest["artifacts"][0],
                    "runtime",
                    ["native"],
                    "artifact runtime",
                ),
                (
                    manifest["platforms"][0],
                    "artifactPaths",
                    [["nested"]],
                    "artifact paths are invalid",
                ),
                (
                    manifest["platforms"][0],
                    "accelerators",
                    [{"x": "metal"}],
                    "platform accelerators are invalid",
                ),
                (
                    manifest["abi"],
                    "streamProxyCallback",
                    True,
                    "stream proxy callback ABI must be an integer",
                ),
                (
                    manifest["realModelSmokes"][0],
                    "abiVersion",
                    True,
                    "smoke ABI version must be an integer",
                ),
                (
                    manifest["realModelSmokes"][0]["fixture"],
                    "sampleCount",
                    True,
                    "sample count must be an integer",
                ),
            )
            for target, key, malformed, expected_error in scalar_cases:
                with self.subTest(malformed_schema_scalar=key):
                    original = target[key]
                    target[key] = malformed
                    fixture.write_text(json.dumps(manifest), encoding="utf-8")
                    manifest_asset["digest"] = (
                        "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
                    )
                    with self.assertRaisesRegex(ReleaseError, expected_error):
                        validate_litert_lm_release_manifest(
                            release,
                            repo="leehack/litert-lm-native",
                            tag=tag,
                            release_json_dir=str(fixture_dir),
                            required_bundles=required_bundles,
                        )
                    target[key] = original
            fixture.write_bytes(owner_fixture.read_bytes())
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )

            native_ref_fixture.write_text(
                json.dumps({"sha": "1" * 40}), encoding="utf-8"
            )
            with self.assertRaisesRegex(ReleaseError, "exact native tag"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            native_ref_fixture.write_text(
                json.dumps({"sha": manifest["native"]["commit"]}),
                encoding="utf-8",
            )

            checksum_digest = checksum_asset["digest"]
            checksum_asset["digest"] = [checksum_digest]
            with self.assertRaisesRegex(ReleaseError, "invalid GitHub SHA-256"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            checksum_asset["digest"] = checksum_digest

            original_artifact_digest = manifest["artifacts"][0]["sha256"]
            manifest["artifacts"][0]["sha256"] = int("1" * 64)
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )
            with self.assertRaisesRegex(ReleaseError, "artifact digest"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["artifacts"][0]["sha256"] = original_artifact_digest

            original_native_commit = manifest["native"]["commit"]
            numeric_native_commit = int("1" * 40)
            manifest["native"]["commit"] = numeric_native_commit
            release["target_commitish"] = numeric_native_commit
            for smoke in manifest["realModelSmokes"]:
                smoke["nativeCommit"] = numeric_native_commit
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )
            with self.assertRaisesRegex(ReleaseError, "native commit"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["native"]["commit"] = original_native_commit
            release["target_commitish"] = original_native_commit
            for smoke in manifest["realModelSmokes"]:
                smoke["nativeCommit"] = original_native_commit
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )

            fixture.write_bytes(b"\xff")
            with self.assertRaisesRegex(ReleaseError, "Failed to read release manifest"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            fixture.write_bytes(owner_fixture.read_bytes())
            manifest_asset["digest"] = (
                "sha256:" + hashlib.sha256(fixture.read_bytes()).hexdigest()
            )

            upstream_ref_fixture.write_text("{", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "Failed to resolve exact commit"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            upstream_ref_fixture.write_text(
                json.dumps({"sha": manifest["upstream"]["commit"]}),
                encoding="utf-8",
            )

            checksum_fixture.write_bytes(b"\xff")
            checksum_asset["digest"] = (
                "sha256:" + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
            )
            with self.assertRaisesRegex(ReleaseError, "not valid UTF-8"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            checksum_fixture.write_text(
                "".join(
                    f"{artifact['sha256']}  {artifact['path']}\n"
                    for artifact in manifest["artifacts"]
                ),
                encoding="utf-8",
            )
            checksum_asset["digest"] = (
                "sha256:" + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
            )

            upstream_ref_fixture.write_text(
                json.dumps({"sha": "1" * 40}), encoding="utf-8"
            )
            with self.assertRaisesRegex(ReleaseError, "exact upstream ref"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            upstream_ref_fixture.write_text(
                json.dumps({"sha": manifest["upstream"]["commit"]}),
                encoding="utf-8",
            )

            original_checksum_text = checksum_fixture.read_text(encoding="utf-8")
            checksum_lines = original_checksum_text.splitlines()
            for checksum_text, expected_error in (
                ("\n".join(checksum_lines[1:]) + "\n", "missing="),
                (
                    original_checksum_text + f"{'4' * 64}  unexpected.bin\n",
                    "unexpected=",
                ),
                (
                    original_checksum_text + checksum_lines[0] + "\n",
                    "duplicates",
                ),
            ):
                checksum_fixture.write_text(checksum_text, encoding="utf-8")
                checksum_asset["digest"] = (
                    "sha256:"
                    + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
                )
                with self.assertRaisesRegex(ReleaseError, expected_error):
                    validate_litert_lm_release_manifest(
                        release,
                        repo="leehack/litert-lm-native",
                        tag=tag,
                        release_json_dir=str(fixture_dir),
                        required_bundles=required_bundles,
                    )

            checksum_fixture.write_text(
                original_checksum_text.replace(
                    manifest["artifacts"][0]["sha256"], "2" * 64, 1
                ),
                encoding="utf-8",
            )
            checksum_asset["digest"] = (
                "sha256:" + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
            )
            with self.assertRaisesRegex(ReleaseError, "mismatched="):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            checksum_fixture.write_text(original_checksum_text, encoding="utf-8")
            checksum_asset["digest"] = "sha256:" + "3" * 64
            with self.assertRaisesRegex(ReleaseError, "bytes do not match"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            checksum_asset["digest"] = (
                "sha256:" + hashlib.sha256(checksum_fixture.read_bytes()).hexdigest()
            )

            runtime_asset = next(
                asset
                for asset in release_assets
                if asset["name"].startswith("litert-lm-native-runtime-")
            )
            runtime_asset["digest"] = "sha256:not-a-sha256"
            with self.assertRaisesRegex(ReleaseError, "invalid GitHub SHA-256"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            runtime_asset["digest"] = "sha256:" + "f" * 64

            for asset_name in sorted(expected_assets):
                with self.subTest(owner_rejected_missing_asset=asset_name):
                    removed_index = next(
                        index
                        for index, asset in enumerate(release_assets)
                        if asset["name"] == asset_name
                    )
                    removed = release_assets.pop(removed_index)
                    with self.assertRaisesRegex(ReleaseError, "owner policy"):
                        validate_litert_release_asset_inventory(release, manifest, tag)
                    release_assets.insert(removed_index, removed)
            release_assets.append(
                {"name": "unexpected-owner-rejected.bin", "digest": "sha256:" + "f" * 64}
            )
            with self.assertRaisesRegex(ReleaseError, "owner policy"):
                validate_litert_release_asset_inventory(release, manifest, tag)
            release_assets.pop()

            release_assets.append(dict(release_assets[0]))
            with self.assertRaisesRegex(ReleaseError, "duplicates"):
                validate_litert_release_asset_inventory(release, manifest, tag)
            release_assets.pop()

            original_digest = release_assets[0]["digest"]
            release_assets[0]["digest"] = "sha256:not-a-digest"
            with self.assertRaisesRegex(ReleaseError, "invalid GitHub SHA-256"):
                validate_litert_release_asset_inventory(release, manifest, tag)
            release_assets[0]["digest"] = original_digest

            release["draft"] = True
            with self.assertRaisesRegex(ReleaseError, "published, not a draft"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            release["draft"] = False
            release["prerelease"] = not release["prerelease"]
            with self.assertRaisesRegex(ReleaseError, "prerelease classification"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            release["prerelease"] = manifest["release"]["githubPrerelease"]

            removed_override = manifest["upstream"]["prebuiltOverrides"].pop()
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "owner policy"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["upstream"]["prebuiltOverrides"].append(removed_override)

            override_target = removed_override["targetPath"]
            override_artifact = next(
                artifact
                for artifact in manifest["artifacts"]
                if artifact["path"] == override_target
            )
            manifest["artifacts"].remove(override_artifact)
            override_platform = next(
                platform
                for platform in manifest["platforms"]
                if override_target in platform["artifactPaths"]
            )
            override_platform["artifactPaths"].remove(override_target)
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "override target provenance"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["artifacts"].append(override_artifact)
            override_platform["artifactPaths"].append(override_target)

            removed_artifact = next(
                artifact
                for artifact in manifest["artifacts"]
                if "CLiteRTLM-xcframework" in artifact["path"]
            )
            manifest["artifacts"].remove(removed_artifact)
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "SPM artifact inventory"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["artifacts"].append(removed_artifact)

            smoke = manifest["realModelSmokes"][0]
            smoke["model"]["sha256"] = "a" * 64
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "owner-pinned asset"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            smoke["model"]["sha256"] = (
                "97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9"
            )

            smoke["source"]["model"] = "https://example.invalid/model.tflite"
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "source provenance"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            smoke["source"]["model"] = (
                "https://huggingface.co/litert-community/moonshine-tiny/resolve/"
                "beb49ee5028b4fb21eb989bcbd2db30a433373db/"
                "moonshine_tiny_5s_i8.tflite"
            )

            original_library_digest = smoke["library"]["sha256"]
            smoke["library"]["sha256"] = "b" * 64
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "runtime artifact"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            smoke["library"]["sha256"] = original_library_digest

            smoke["expectation"]["value"] = "fabricated"
            smoke["transcript"] = "fabricated"
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "owner-pinned transcript"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            smoke["expectation"]["value"] = "country"
            smoke["transcript"] = "ask not what your country can do for you"

            manifest["platforms"][0]["artifactPaths"].append(
                manifest["platforms"][0]["artifactPaths"][0]
            )
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "artifact paths are invalid"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["platforms"][0]["artifactPaths"].pop()

            original_platforms = manifest["platforms"]
            manifest["platforms"] = {"not": "a list"}
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "platforms must be a list"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["platforms"] = original_platforms[:-1]
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(
                ReleaseError, "exactly 9 finalized platform bundles; found 8"
            ):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["platforms"] = original_platforms
            original_second_platform = manifest["platforms"][1]
            manifest["platforms"][1] = dict(manifest["platforms"][0])
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(
                ReleaseError, "missing .*; duplicates .*"
            ):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            manifest["platforms"][1] = original_second_platform

            del manifest["capabilities"]["streamChunkAccessors"]
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "owner schema 2"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )

    def test_schema_2_prepares_the_real_apple_target_transition(self) -> None:
        fixture_root = Path(__file__).resolve().parent / "fixtures"
        manifest = json.loads(
            (fixture_root / "litert_lm_schema2_owner_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        release = json.loads(
            (fixture_root / "litert_lm_schema2_owner_release.json").read_text(
                encoding="utf-8"
            )
        )
        package_swift = (
            Path(__file__).resolve().parents[2]
            / "packages"
            / "llamadart_litert_lm_flutter"
            / "darwin"
            / "llamadart_litert_lm_flutter"
            / "Package.swift"
        )
        original = package_swift.read_text(encoding="utf-8")

        prepared = prepare_litert_lm_package_swift(
            original,
            release=release,
            manifest=manifest,
            resolved_tag="v0.16.0-3",
        )

        self.assertEqual(
            package_swift.read_text(encoding="utf-8"),
            original,
            "pin preparation must not modify the checked-in manifest",
        )
        self.assertIn('let liteRtLmTag = "v0.16.0-3"', prepared)
        self.assertNotIn("GemmaModelConstraintProvider", prepared)
        self.assertIn('name: "CLiteRTLMMac"', prepared)
        self.assertIn(
            'name: "CLiteRTLMMac", condition: .when(platforms: [.macOS])',
            prepared,
        )
        self.assertIn(
            'name: "LiteRtLm", condition: .when(platforms: [.iOS, .macOS])',
            prepared,
        )
        expected_targets = {
            "LiteRtLm",
            "CLiteRTLM",
            "CLiteRTLMMac",
            "LiteRtMetalAccelerator",
            "LiteRtTopKMetalSampler",
        }
        for target in expected_targets:
            asset_name = (
                f"litert-lm-native-apple-{target}-xcframework-v0.16.0-3.zip"
            )
            asset = next(
                item for item in release["assets"] if item["name"] == asset_name
            )
            self.assertIn(
                f'checksum: "{asset["digest"].removeprefix("sha256:")}"',
                prepared,
            )

    def test_schema_2_prepares_hook_libraries_from_owner_inventory(self) -> None:
        fixture_root = Path(__file__).resolve().parent / "fixtures"
        manifest = json.loads(
            (fixture_root / "litert_lm_schema2_owner_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        hook_path = Path(__file__).resolve().parents[2] / "hook" / "build.dart"
        prepared = hook_path.read_text(encoding="utf-8")
        expected = litert_schema2_bundle_required_libraries(manifest)
        for bundle, libraries in expected.items():
            prepared = replace_litert_lm_bundle_required_libraries(
                prepared,
                bundle,
                libraries,
            )

        self.assertNotIn("GemmaModelConstraintProvider", prepared)
        self.assertIn(
            "requiredLibraries: {'libLiteRtLm.so', 'libwebgpu_dawn.so'},",
            prepared,
        )
        self.assertIn("requiredLibraries: {'LiteRtLm.dll'},", prepared)
        for bundle, libraries in expected.items():
            bundle_start = prepared.index(f"_LiteRtLmBundleSpec(\n    '{bundle}',")
            bundle_end = prepared.index("\n  ),", bundle_start)
            block = prepared[bundle_start:bundle_end]
            required_block = block[block.index("requiredLibraries:") :]
            self.assertEqual(
                set(re.findall(r"'([^']+)'", required_block)),
                set(libraries),
            )

    def test_schema_2_hook_inventory_rejects_unsafe_library_names(self) -> None:
        fixture_root = Path(__file__).resolve().parent / "fixtures"
        original = json.loads(
            (fixture_root / "litert_lm_schema2_owner_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        for filename in (
            "libx','injected.so",
            "libx$interpolated.so",
            "libx with space.so",
            "libx;command.so",
            "../injected.so",
            r"bin\android\arm64\libx.so",
        ):
            with self.subTest(filename=filename):
                manifest = json.loads(json.dumps(original))
                manifest["platforms"][0]["artifactPaths"][0] = (
                    f"bin/android/arm64/{filename}"
                )
                with self.assertRaisesRegex(
                    ReleaseError,
                    "platform artifact paths are invalid|library names are invalid",
                ):
                    litert_schema2_bundle_required_libraries(manifest)

    def test_schema_2_sync_rejects_manifest_added_spm_archive(self) -> None:
        manifest, release = _schema2_fixture_payloads()
        tag = manifest["release"]["tag"]
        extra_path = f"dist/spm/{tag}/unexpected-extra.zip"
        extra_artifact = dict(
            next(
                artifact
                for artifact in manifest["artifacts"]
                if artifact["path"].startswith("dist/spm/")
            )
        )
        extra_artifact.update(
            path=extra_path,
            fileName="unexpected-extra.zip",
            sha256="e" * 64,
            runtime="archive",
            platform=None,
            arch=None,
            accelerators=[],
        )
        manifest["artifacts"].append(extra_artifact)
        release["assets"].append(
            {"name": "unexpected-extra.zip", "digest": f"sha256:{'e' * 64}"}
        )

        with tempfile.TemporaryDirectory() as temp:
            result = _run_schema2_sync(Path(temp), manifest, release)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SPM artifact inventory", result.stdout + result.stderr)

    def test_schema_2_sync_binds_spm_release_digest_to_manifest(self) -> None:
        manifest, release = _schema2_fixture_payloads()
        spm_asset = next(
            asset
            for asset in release["assets"]
            if asset["name"].startswith(
                "litert-lm-native-apple-LiteRtLm-xcframework-"
            )
        )
        original_digest = spm_asset["digest"]
        spm_asset["digest"] = "sha256:" + "0" * 64
        self.assertNotEqual(original_digest, spm_asset["digest"])

        with tempfile.TemporaryDirectory() as temp:
            result = _run_schema2_sync(Path(temp), manifest, release)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SPM release asset digest", result.stdout + result.stderr)

    def test_schema_2_sync_rejects_backslash_artifact_paths(self) -> None:
        manifest, release = _schema2_fixture_payloads()
        tag = manifest["release"]["tag"]
        artifact = dict(
            next(
                artifact
                for artifact in manifest["artifacts"]
                if artifact["path"].startswith("dist/spm/")
            )
        )
        artifact.update(
            path=rf"dist\\spm\\{tag}\\unexpected-extra.zip",
            fileName=rf"dist\\spm\\{tag}\\unexpected-extra.zip",
            sha256="d" * 64,
            runtime="archive",
            platform=None,
            arch=None,
            accelerators=[],
        )
        manifest["artifacts"].append(artifact)

        with tempfile.TemporaryDirectory() as temp:
            result = _run_schema2_sync(Path(temp), manifest, release)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("invalid artifact path", result.stdout + result.stderr)

    def test_schema_2_sync_accepts_owner_gpu_accelerator_union(self) -> None:
        manifest, release = _schema2_fixture_payloads()
        artifact = next(
            artifact
            for artifact in manifest["artifacts"]
            if artifact["path"] == "bin/android/arm64/libLiteRtLm.so"
        )
        artifact["accelerators"] = sorted(set(artifact["accelerators"]) | {"gpu"})
        platform = next(
            platform
            for platform in manifest["platforms"]
            if platform["platform"] == "android" and platform["arch"] == "arm64"
        )
        platform["accelerators"] = sorted(set(platform["accelerators"]) | {"gpu"})

        with tempfile.TemporaryDirectory() as temp:
            result = _run_schema2_sync(Path(temp), manifest, release)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_schema_2_sync_generates_runtime_inventory_from_platform_paths(self) -> None:
        manifest, release = _schema2_fixture_payloads()

        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            result = _run_schema2_sync(temp_path, manifest, release)
            runtime = (
                temp_path / "repo/lib/src/backends/litert_lm/litert_lm_runtime.dart"
            ).read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            """Abi.macosArm64 => const <String>[\n      'libCLiteRTLM_mac.dylib',\n      'libLiteRtLm.dylib',\n    ],""",
            runtime,
        )
        self.assertIn(
            "Abi.linuxX64 => const <String>['libLiteRtLm.so'],",
            runtime,
        )
        self.assertIn(
            "Abi.windowsX64 => const <String>['LiteRtLm.dll'],",
            runtime,
        )
        self.assertNotIn("libGemmaModelConstraintProvider.dylib", runtime)
        self.assertNotIn("libLiteRtTopKWebGpuSampler.so", runtime)

    def test_schema_2_sync_updates_real_macos_inventory_surfaces(self) -> None:
        manifest, release = _schema2_fixture_payloads()

        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            result = _run_schema2_sync(
                temp_path,
                manifest,
                release,
                include_runtime_dependencies=True,
            )
            repo_root = temp_path / "repo"
            prepare = (repo_root / "tool/macos_litert_lm_prepare_app.sh").read_text(
                encoding="utf-8"
            )
            runtime = (
                repo_root / "lib/src/backends/litert_lm/litert_lm_runtime.dart"
            ).read_text(encoding="utf-8")
            if shutil.which("dart") is None:
                self.skipTest("Dart SDK is required to analyze generated inventory")
            (
                dart_format_result,
                dart_analyze_result,
                dart_run_result,
            ) = _run_dart_inventory_checks(repo_root)
            package_swift = (
                repo_root
                / "packages/llamadart_litert_lm_flutter/darwin/"
                / "llamadart_litert_lm_flutter/Package.swift"
            ).read_text(encoding="utf-8")

            library_dir = temp_path / "macos-arm64-libraries"
            library_dir.mkdir()
            for library in (
                "libCLiteRTLM_mac.dylib",
                "libLiteRtLm.dylib",
            ):
                (library_dir / library).touch()
            app_dir = temp_path / "Test.app"
            (app_dir / "Contents/Frameworks").mkdir(parents=True)
            prepare_result = _run_generated_macos_prepare(
                repo_root,
                library_dir,
                app_dir,
            )
            staged_runtime = app_dir / "Contents/Frameworks/LiteRtLmRuntime"
            staged_runtime_files = sorted(
                path.name for path in staged_runtime.iterdir()
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            prepare_result.returncode,
            0,
            prepare_result.stdout + prepare_result.stderr,
        )
        self.assertEqual(
            dart_format_result.returncode,
            0,
            dart_format_result.stdout + dart_format_result.stderr,
        )
        self.assertEqual(
            dart_analyze_result.returncode,
            0,
            dart_analyze_result.stdout + dart_analyze_result.stderr,
        )
        self.assertEqual(
            dart_run_result.returncode,
            0,
            dart_run_result.stdout + dart_run_result.stderr,
        )
        self.assertEqual(
            staged_runtime_files,
            ["libCLiteRTLM_mac.dylib", "libLiteRtLm.dylib"],
        )
        self.assertIn(
            '"libCLiteRTLM_mac.dylib" \\\n        "libLiteRtLm.dylib"',
            prepare,
        )
        self.assertIn(
            '"LiteRtLm.framework/Versions/A/LiteRtLm" \\\n        "libCLiteRTLM_mac.dylib"',
            prepare,
        )
        self.assertNotIn("libGemmaModelConstraintProvider.dylib", prepare)
        self.assertNotIn("LiteRtMetalAccelerator.framework", prepare)
        self.assertIn(
            """Abi.macosArm64 => const <String>[\n      'CLiteRTLM_mac.framework/Versions/A/CLiteRTLM_mac',\n      'LiteRtLm.framework/Versions/A/LiteRtLm',\n    ],""",
            runtime,
        )
        self.assertIn(
            """Abi.macosArm64 => const <String>[\n      'LiteRtLm.framework/Versions/A/LiteRtLm',\n      'libCLiteRTLM_mac.dylib',\n    ],""",
            runtime,
        )
        self.assertNotIn("GemmaModelConstraintProvider.framework", runtime)
        self.assertNotIn("LiteRtMetalAccelerator.framework", runtime)
        for target in (
            "LiteRtLm",
            "CLiteRTLM",
            "CLiteRTLMMac",
            "LiteRtMetalAccelerator",
            "LiteRtTopKMetalSampler",
        ):
            self.assertIn(f'name: "{target}"', package_swift)
        for optional_target in (
            "GemmaModelConstraintProvider",
            "LiteRt",
            "LiteRtTopKWebGpuSampler",
            "LiteRtWebGpuAccelerator",
            "WebgpuDawn",
        ):
            self.assertNotIn(f'name: "{optional_target}"', package_swift)

    def test_schema_2_optional_spm_companions_do_not_require_swift_targets(self) -> None:
        manifest, release = _schema2_fixture_payloads()
        tag = manifest["release"]["tag"]
        optional_targets = (
            "GemmaModelConstraintProvider",
            "LiteRt",
            "LiteRtTopKWebGpuSampler",
            "LiteRtWebGpuAccelerator",
            "WebgpuDawn",
        )
        for index, target in enumerate(optional_targets, start=1):
            asset_name = (
                f"litert-lm-native-apple-{target}-xcframework-{tag}.zip"
            )
            artifact = dict(
                next(
                    artifact
                    for artifact in manifest["artifacts"]
                    if artifact["path"].startswith("dist/spm/")
                )
            )
            artifact.update(
                path=f"dist/spm/{tag}/{asset_name}",
                fileName=asset_name,
                sha256=f"{index:x}" * 64,
                runtime="archive",
                platform=None,
                arch=None,
                accelerators=[],
            )
            manifest["artifacts"].append(artifact)
            release["assets"].append(
                {
                    "name": asset_name,
                    "digest": "sha256:" + f"{index:x}" * 64,
                }
            )

        package_swift = (
            Path(__file__).resolve().parents[2]
            / "packages/llamadart_litert_lm_flutter/darwin/"
            / "llamadart_litert_lm_flutter/Package.swift"
        )
        with tempfile.TemporaryDirectory() as temp:
            release_dir = Path(temp)
            _materialize_schema2_release_fixtures(release_dir, manifest, release)
            validated = validate_litert_lm_release_manifest(
                release,
                repo="leehack/litert-lm-native",
                tag=tag,
                release_json_dir=str(release_dir),
                required_bundles=litert_lm_bundle_names(
                    (Path(__file__).resolve().parents[2] / "hook/build.dart").read_text(
                        encoding="utf-8"
                    )
                ),
            )
        self.assertEqual(validated, manifest)
        prepared = prepare_litert_lm_package_swift(
            package_swift.read_text(encoding="utf-8"),
            release=release,
            manifest=manifest,
            resolved_tag=tag,
        )
        self.assertNotIn("GemmaModelConstraintProvider", prepared)
        self.assertNotIn("LiteRtWebGpuAccelerator", prepared)

    def test_hook_bundle_inventory_rejects_duplicate_specs(self) -> None:
        spec = (
            "_LiteRtLmBundleSpec('linux-x64', "
            "sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', "
            "requiredLibraries: {'libLiteRtLm.so'}),"
        )
        with self.assertRaisesRegex(ReleaseError, "duplicate LiteRT-LM bundle"):
            litert_lm_bundle_names(f"{spec}\n{spec}\n")

    def test_hook_library_sets_follow_dart_formatter_width(self) -> None:
        hook = (
            "_LiteRtLmBundleSpec(\n"
            "    'linux-x64',\n"
            f"    sha256: '{'a' * 64}',\n"
            "    requiredLibraries: {'old.so'},\n"
            "  ),"
        )
        short = replace_litert_lm_bundle_required_libraries(
            hook,
            "linux-x64",
            ("a.so", "b.so", "c.so"),
        )
        self.assertIn(
            "requiredLibraries: {'a.so', 'b.so', 'c.so'},",
            short,
        )

        long = replace_litert_lm_bundle_required_libraries(
            hook,
            "linux-x64",
            (
                "libLiteRtTopKWebGpuSampler.so",
                "libLiteRtWebGpuAccelerator.so",
                "libwebgpu_dawn.so",
            ),
        )
        self.assertIn(
            "requiredLibraries: {\n"
            "      'libLiteRtTopKWebGpuSampler.so',\n"
            "      'libLiteRtWebGpuAccelerator.so',\n"
            "      'libwebgpu_dawn.so',\n"
            "    },",
            long,
        )

    def test_known_legacy_schema_1_manifest_requires_exact_immutable_evidence(self) -> None:
        tag = "v0.16.0-native.2"
        owner_fixture = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "v0.16.0-native.2-manifest.json"
        )
        legacy_identity = LEGACY_SCHEMA1_RELEASES[tag]
        release = {
            "tag_name": tag,
            "tag_commit_sha": "baef0ee4459582778fdfbe5a7e3b214775f2f99c",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": name,
                    "digest": digest,
                }
                for name, digest in legacy_identity["assets"].items()
            ],
        }
        with tempfile.TemporaryDirectory() as temp:
            fixture = (
                Path(temp)
                / f"leehack__litert-lm-native__{tag}__manifest.json"
            )
            fixture.write_bytes(owner_fixture.read_bytes())
            validate_litert_lm_release_manifest(
                release,
                repo="leehack/litert-lm-native",
                tag=tag,
                release_json_dir=temp,
                required_bundles=["linux-x64"],
            )

            fixture.write_text(
                json.dumps({"schemaVersion": 1, "release": {"tag": tag}}),
                encoding="utf-8",
            )
            manifest_asset = next(
                asset for asset in release["assets"] if asset["name"] == "manifest.json"
            )
            manifest_asset["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "immutable allowlist"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=tag,
                    release_json_dir=temp,
                    required_bundles=["linux-x64"],
                )

        future_tag = "v99.0.0-native.1"
        future_release = {
            "tag_name": future_tag,
            "assets": [{"name": "manifest.json", "digest": "sha256:" + "a" * 64}],
        }
        future_manifest = {
            "schemaVersion": 1,
            "release": {"tag": future_tag},
        }
        with tempfile.TemporaryDirectory() as temp:
            fixture = (
                Path(temp)
                / f"leehack__litert-lm-native__{future_tag}__manifest.json"
            )
            fixture.write_text(json.dumps(future_manifest), encoding="utf-8")
            future_release["assets"][0]["digest"] = "sha256:" + hashlib.sha256(
                fixture.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ReleaseError, "schema 2"):
                validate_litert_lm_release_manifest(
                    future_release,
                    repo="leehack/litert-lm-native",
                    tag=future_tag,
                    release_json_dir=temp,
                    required_bundles=["linux-x64"],
                )


class NativeReleaseTagGrammarCorpusTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        fixture_path = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "native_release_tag_grammar.json"
        )
        cls.fixture = json.loads(fixture_path.read_text(encoding="utf-8"))

    def test_patterns_match_fixture(self) -> None:
        patterns = self.fixture["patterns"]
        self.assertEqual(
            pins._STABLE_NATIVE_TAG_PATTERN.pattern, patterns["stable_pattern"]
        )
        self.assertEqual(
            pins._STABLE_WRAPPER_TAG_PATTERN.pattern,
            patterns["stable_wrapper_pattern"],
        )
        self.assertEqual(
            pins._LEGACY_NATIVE_TAG_PATTERN.pattern, patterns["nightly_pattern"]
        )
        self.assertEqual(
            pins._NIGHTLY_WRAPPER_TAG_PATTERN.pattern,
            patterns["nightly_wrapper_pattern"],
        )
        self.assertEqual(
            pins._LEGACY_WRAPPER_TAG_PATTERN.pattern,
            patterns["legacy_wrapper_pattern"],
        )
        self.assertEqual(pins._NATIVE_DOC_TAG_PATTERN, patterns["doc_tag_pattern"])

    def test_positive_tag_corpus(self) -> None:
        for case in self.fixture["positive_cases"]:
            tag = case["tag"]
            with self.subTest(tag=tag):
                parsed = pins.parse_native_release_tag(tag)
                self.assertEqual(parsed.channel, case["channel"])
                self.assertEqual(list(parsed.version), case["version"])
                self.assertEqual(parsed.wrapper_revision, case["wrapper_revision"])
                self.assertEqual(parsed.upstream_tag, case["upstream_tag"])
                self.assertEqual(pins.normalize_release_tag(tag), tag)
                self.assertEqual(
                    bool(pins._STABLE_NATIVE_TAG_PATTERN.fullmatch(tag)),
                    case["is_latest_eligible"],
                )

    def test_reserved_inputs_follow_consumer_policy(self) -> None:
        for case in self.fixture["reserved_inputs"]:
            value = case["value"]
            with self.subTest(value=value):
                if case["python_sync"]:
                    self.assertEqual(pins.normalize_release_tag(value), value)
                else:
                    with self.assertRaises(ReleaseError):
                        pins.normalize_release_tag(value)
                with self.assertRaises(ReleaseError):
                    pins.parse_native_release_tag(value)

    def test_negative_tag_corpus(self) -> None:
        for case in self.fixture["negative_cases"]:
            tag = case["tag"]
            reason = case["reason"]
            with self.subTest(tag=tag, reason=reason):
                with self.assertRaises(ReleaseError):
                    pins.parse_native_release_tag(tag)
                with self.assertRaises(ReleaseError):
                    pins.normalize_release_tag(tag)

if __name__ == "__main__":
    unittest.main()
