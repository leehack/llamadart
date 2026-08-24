from __future__ import annotations

import json
import hashlib
import sys
import tempfile
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from sync_native_release_pins import (  # noqa: E402
    ReleaseError,
    LEGACY_SCHEMA1_RELEASES,
    atomic_write_many,
    fetch_release,
    litert_lm_runtime_version,
    normalize_litert_lm_release_tag,
    prepare_litert_lm_package_swift,
    require_exact_keys,
    required_litert_release_asset_names,
    validate_litert_lm_transition,
    validate_litert_lm_release_manifest,
    validate_litert_release_asset_inventory,
)


UPSTREAM_COMMIT = "ba82499873945908bf8bcfc96e955d0677eb1fa1"
NATIVE_COMMIT = "451ba0ce7c366972b4dc0e58f08ffe590958f943"
DEVELOPMENT_TAG = "gba8249987394"


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
            with self.assertRaisesRegex(ReleaseError, "owner-required artifact paths"):
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

if __name__ == "__main__":
    unittest.main()
