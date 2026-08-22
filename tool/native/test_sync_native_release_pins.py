from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from sync_native_release_pins import (  # noqa: E402
    ReleaseError,
    normalize_litert_lm_release_tag,
    validate_litert_lm_transition,
    validate_litert_lm_release_manifest,
)


UPSTREAM_COMMIT = "ba82499873945908bf8bcfc96e955d0677eb1fa1"
NATIVE_COMMIT = "451ba0ce7c366972b4dc0e58f08ffe590958f943"
DEVELOPMENT_TAG = "gba8249987394"


class SyncNativeReleasePinsTest(unittest.TestCase):
    def test_litert_tag_grammar_preserves_new_and_legacy_forms(self) -> None:
        expected = {
            "0.16.1": "v0.16.1",
            "v0.16.1": "v0.16.1",
            "v0.16.1-2": "v0.16.1-2",
            DEVELOPMENT_TAG: DEVELOPMENT_TAG,
            f"{DEVELOPMENT_TAG}-1": f"{DEVELOPMENT_TAG}-1",
            "v0.16.0-native.2": "v0.16.0-native.2",
            "latest": "latest",
            "keep": "keep",
        }
        for value, normalized in expected.items():
            with self.subTest(value=value):
                self.assertEqual(normalize_litert_lm_release_tag(value), normalized)
        with self.assertRaises(ReleaseError):
            normalize_litert_lm_release_tag("main")

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

    def test_schema_2_manifest_is_required_for_development_and_validated(self) -> None:
        required_bundles = [
            "android-arm64",
            "android-x64",
            "ios-arm64",
            "ios-arm64-sim",
            "linux-arm64",
            "linux-x64",
            "macos-arm64",
            "macos-x64",
            "windows-x64",
        ]
        platforms = []
        artifacts = []
        release_assets = [{"name": "manifest.json"}]
        for bundle in required_bundles:
            if bundle.endswith("arm64-sim"):
                platform, arch = "ios", "arm64-sim"
            else:
                platform, arch = bundle.rsplit("-", 1)
            artifact_path = f"bin/{platform}/{arch}/runtime.bin"
            release_asset = (
                "litert-lm-native-runtime-"
                f"{platform}-{arch}-{DEVELOPMENT_TAG}.tar.gz"
            )
            platforms.append(
                {
                    "platform": platform,
                    "arch": arch,
                    "releaseAsset": release_asset,
                    "artifactPaths": [artifact_path],
                }
            )
            artifacts.append(
                {
                    "platform": platform,
                    "arch": arch,
                    "path": artifact_path,
                    "sha256": "a" * 64,
                    "releaseTag": DEVELOPMENT_TAG,
                    "upstreamCommit": UPSTREAM_COMMIT,
                }
            )
            release_assets.append(
                {"name": release_asset, "digest": "sha256:" + "f" * 64}
            )
        manifest = {
            "schemaVersion": 2,
            "release": {
                "tag": DEVELOPMENT_TAG,
                "channel": "development",
                "kind": "commit",
                "rebuild": 0,
                "githubPrerelease": True,
            },
            "upstream": {
                "repository": "google-ai-edge/LiteRT-LM",
                "tag": None,
                "commit": UPSTREAM_COMMIT,
                "compatibilityTag": "v0.16.1",
                "developmentIdentity": DEVELOPMENT_TAG,
            },
            "native": {
                "repository": "leehack/litert-lm-native",
                "commit": NATIVE_COMMIT,
            },
            "abi": {"streamProxyCallback": 1, "asrBridge": 1},
            "capabilities": {
                "textGeneration": True,
                "streaming": True,
                "asr": True,
                "officialUpstreamAssets": False,
            },
            "platforms": platforms,
            "artifacts": artifacts,
            "realModelSmokes": [
                self._smoke("linux", "x64"),
                self._smoke("windows", "x64"),
            ],
        }
        release = {
            "tag_name": DEVELOPMENT_TAG,
            "target_commitish": NATIVE_COMMIT,
            "assets": release_assets,
        }
        with tempfile.TemporaryDirectory() as temp:
            fixture_dir = Path(temp)
            fixture = fixture_dir / (
                "leehack__litert-lm-native__"
                f"{DEVELOPMENT_TAG}__manifest.json"
            )
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            validate_litert_lm_release_manifest(
                release,
                repo="leehack/litert-lm-native",
                tag=DEVELOPMENT_TAG,
                release_json_dir=str(fixture_dir),
                required_bundles=required_bundles,
            )

            release_assets[1]["digest"] = "sha256:not-a-sha256"
            with self.assertRaisesRegex(ReleaseError, "invalid GitHub SHA-256"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=DEVELOPMENT_TAG,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )
            release_assets[1]["digest"] = "sha256:" + "f" * 64

            manifest["realModelSmokes"] = []
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "smoke evidence"):
                validate_litert_lm_release_manifest(
                    release,
                    repo="leehack/litert-lm-native",
                    tag=DEVELOPMENT_TAG,
                    release_json_dir=str(fixture_dir),
                    required_bundles=required_bundles,
                )

    def test_known_legacy_schema_1_manifest_remains_consumable(self) -> None:
        tag = "v0.16.0-native.2"
        release = {"tag_name": tag, "assets": [{"name": "manifest.json"}]}
        manifest = {
            "schemaVersion": 1,
            "release": {"tag": tag},
            "upstream": {"tag": "v0.16.0", "commit": None},
        }
        with tempfile.TemporaryDirectory() as temp:
            fixture = (
                Path(temp)
                / f"leehack__litert-lm-native__{tag}__manifest.json"
            )
            fixture.write_text(json.dumps(manifest), encoding="utf-8")
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
            "assets": [{"name": "manifest.json"}],
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
            with self.assertRaisesRegex(ReleaseError, "schema 2"):
                validate_litert_lm_release_manifest(
                    future_release,
                    repo="leehack/litert-lm-native",
                    tag=future_tag,
                    release_json_dir=temp,
                    required_bundles=["linux-x64"],
                )

    @staticmethod
    def _smoke(platform: str, arch: str) -> dict[str, object]:
        return {
            "id": "litert_lm_asr_moonshine",
            "platform": platform,
            "arch": arch,
            "result": "pass",
            "upstreamCommit": UPSTREAM_COMMIT,
            "nativeCommit": NATIVE_COMMIT,
            "backend": "cpu",
            "abiVersion": 1,
            "transcript": "how are you doing",
            "expect": "how are you",
            "library": {"sha256": "1" * 64},
            "model": {"sha256": "2" * 64},
            "tokenizer": {"sha256": "3" * 64},
            "fixture": {"sha256": "4" * 64},
        }


if __name__ == "__main__":
    unittest.main()
