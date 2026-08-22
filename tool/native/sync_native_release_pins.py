#!/usr/bin/env python3
"""Sync native runtime pins from published GitHub release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, NamedTuple


DEFAULT_LLAMADART_NATIVE_REPO = "leehack/llamadart-native"
DEFAULT_LITERT_LM_NATIVE_REPO = "leehack/litert-lm-native"
DEFAULT_LLAMA_CPP_PACKAGE_SWIFT = (
    "packages/llamadart_llama_cpp_flutter/darwin/"
    "llamadart_llama_cpp_flutter/Package.swift"
)
DEFAULT_LITERT_LM_PACKAGE_SWIFT = (
    "packages/llamadart_litert_lm_flutter/darwin/"
    "llamadart_litert_lm_flutter/Package.swift"
)
DEFAULT_LITERT_LM_RUNTIME_DART = (
    "lib/src/backends/litert_lm/litert_lm_runtime.dart"
)
DEFAULT_LITERT_LM_MACOS_PREPARE_SCRIPT = "tool/macos_litert_lm_prepare_app.sh"
DEFAULT_LLAMA_CPP_PROJECT_DOCS = (
    "README.md",
    "website/docs/getting-started/installation.md",
    "website/docs/platforms/support-matrix.md",
)
DEFAULT_CHANGELOG = "CHANGELOG.md"
SUPPORTED_NATIVE_HOOK_CONTRACT_VERSION = 1
_STABLE_NATIVE_TAG_PATTERN = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
_STABLE_WRAPPER_TAG_PATTERN = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)-([1-9][0-9]*)$"
)
_LEGACY_NATIVE_TAG_PATTERN = re.compile(r"^b(0|[1-9][0-9]*)$")
_NIGHTLY_WRAPPER_TAG_PATTERN = re.compile(
    r"^b(0|[1-9][0-9]*)-([1-9][0-9]*)$"
)
_LEGACY_WRAPPER_TAG_PATTERN = re.compile(
    r"^b(0|[1-9][0-9]*)-llamadart\.([1-9][0-9]*)$"
)
_NATIVE_DOC_TAG_PATTERN = (
    r"(?:v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)(?:-[1-9][0-9]*)?|"
    r"b(?:0|[1-9][0-9]*)(?:-[1-9][0-9]*|-llamadart\.[1-9][0-9]*)?)"
)
_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
_STABLE_NATIVE_BUNDLES = (
    "android-arm64",
    "android-x64",
    "ios-arm64",
    "ios-arm64-sim",
    "ios-x86_64-sim",
    "linux-arm64",
    "linux-x64",
    "macos-arm64",
    "macos-x86_64",
    "windows-arm64",
    "windows-x64",
)
STABLE_LITERT_TAG_RE = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
STABLE_LITERT_REBUILD_RE = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-[1-9][0-9]*$"
)
DEVELOPMENT_LITERT_TAG_RE = re.compile(r"^g[0-9a-f]{12}(?:-[1-9][0-9]*)?$")
LEGACY_LITERT_TAG_RE = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-native\.[1-9][0-9]*$"
)
FULL_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LEGACY_ALLOWLIST_PATH = (
    Path(__file__).resolve().parent / "fixtures" / "legacy_release_allowlist.json"
)
LEGACY_SCHEMA1_RELEASES: dict[str, dict[str, Any]] = json.loads(
    LEGACY_ALLOWLIST_PATH.read_text(encoding="utf-8")
)["releases"]
REQUIRED_LITERT_PLATFORM_BUNDLES = {
    "android-arm64",
    "android-x64",
    "ios-arm64",
    "ios-arm64-sim",
    "linux-arm64",
    "linux-x64",
    "macos-arm64",
    "macos-x64",
    "windows-x64",
}
LITERT_SMOKE_ASSETS = {
    "model": {
        "fileName": "moonshine_tiny_5s_i8.tflite",
        "sha256": "97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9",
        "url": (
            "https://huggingface.co/litert-community/moonshine-tiny/resolve/"
            "beb49ee5028b4fb21eb989bcbd2db30a433373db/"
            "moonshine_tiny_5s_i8.tflite"
        ),
    },
    "tokenizer": {
        "fileName": "moonshine_tokenizer.json",
        "sha256": "6579793438bc4fbafffacf699169ff53e3769c5a0a0f5e71cdee8853e8130deb",
        "url": (
            "https://huggingface.co/UsefulSensors/moonshine-tiny/resolve/"
            "390624ed33d594443aa4aa221f5b9f283b545b5a/tokenizer.json"
        ),
    },
    "fixture": {
        "fileName": "jfk.wav",
        "sha256": "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e",
        "url": (
            "https://raw.githubusercontent.com/ggml-org/whisper.cpp/"
            "592feef04a1802b18cbeffd0fd0eb5d02570c2ec/samples/jfk.wav"
        ),
    },
}
LITERT_ANDROID_DAWN_OVERRIDES = [
    {
        "sourceRepository": "google-ai-edge/LiteRT-LM",
        "sourceCommit": "f73637c57f0940b53da184e0d5adfc52a4e55eef",
        "sourcePath": "prebuilt/android_arm64/libwebgpu_dawn.so",
        "targetPath": "bin/android/arm64/libwebgpu_dawn.so",
        "sha256": "7282aacdb076ce89f0c9d93107a145b991b99eb1dfbd5b5746dd0d99466ab3c3",
    },
    {
        "sourceRepository": "google-ai-edge/LiteRT-LM",
        "sourceCommit": "f73637c57f0940b53da184e0d5adfc52a4e55eef",
        "sourcePath": "prebuilt/android_x86_64/libwebgpu_dawn.so",
        "targetPath": "bin/android/x64/libwebgpu_dawn.so",
        "sha256": "fcfb9a0b902f7dd3f81f01295f381c10b22a2d5774f95ee0db813f284a0ab087",
    },
]
LITERT_PREBUILT_OVERRIDES = {
    "v0.15.0": [
        {
            "sourceRepository": "google-ai-edge/LiteRT-LM",
            "sourceCommit": "8bee4dddc3794958b4bdd8a3a4ba75bcb71f6fbb",
            "sourcePath": "prebuilt/android_arm64/libLiteRtTopKOpenClSampler.so",
            "targetPath": "bin/android/arm64/libLiteRtTopKOpenClSampler.so",
            "sha256": "4404dc68786460602685cab62ddfa29035e9cfc38bb4550dec15abaaa1302a82",
        },
        {
            "sourceRepository": "google-ai-edge/LiteRT-LM",
            "sourceCommit": "8bee4dddc3794958b4bdd8a3a4ba75bcb71f6fbb",
            "sourcePath": "prebuilt/android_x86_64/libLiteRtTopKOpenClSampler.so",
            "targetPath": "bin/android/x64/libLiteRtTopKOpenClSampler.so",
            "sha256": "747ca5ed6a175fb4c2854ccee1d6ad97f11fe14d9e0d2b0c1710e1435376d51e",
        },
        *LITERT_ANDROID_DAWN_OVERRIDES,
    ],
    "v0.16.0": LITERT_ANDROID_DAWN_OVERRIDES,
    "v0.16.1": LITERT_ANDROID_DAWN_OVERRIDES,
}
LITERT_REQUIRED_RUNTIME_PATHS = {
    "bin/android/arm64/libLiteRtLm.so",
    "bin/android/x64/libLiteRtLm.so",
    "bin/ios/arm64/LiteRtLm.framework/LiteRtLm",
    "bin/ios/arm64/CLiteRTLM.framework/CLiteRTLM",
    "bin/ios/arm64-sim/LiteRtLm.framework/LiteRtLm",
    "bin/ios/arm64-sim/CLiteRTLM.framework/CLiteRTLM",
    "bin/linux/arm64/libLiteRtLm.so",
    "bin/linux/x64/libLiteRtLm.so",
    "bin/macos/arm64/libCLiteRTLM_mac.dylib",
    "bin/macos/arm64/libLiteRtLm.dylib",
    "bin/macos/x64/libCLiteRTLM_mac.dylib",
    "bin/macos/x64/libLiteRtLm.dylib",
    "bin/windows/x64/LiteRtLm.dll",
}
LITERT_V0_16_IOS_GPU_PATHS = {
    "bin/ios/arm64/LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator",
    "bin/ios/arm64/LiteRtTopKMetalSampler.framework/LiteRtTopKMetalSampler",
    "bin/ios/arm64-sim/LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator",
    "bin/ios/arm64-sim/LiteRtTopKMetalSampler.framework/LiteRtTopKMetalSampler",
}
LITERT_SPM_ASSET_PATTERNS = (
    "litert-lm-native-apple-CLiteRTLM-xcframework-{tag}.zip",
    "litert-lm-native-apple-CLiteRTLMMac-xcframework-{tag}.zip",
    "litert-lm-native-apple-LiteRtLm-xcframework-{tag}.zip",
)
LITERT_V0_16_SPM_ASSET_PATTERNS = (
    "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-{tag}.zip",
    "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-{tag}.zip",
)
LITERT_ALLOWED_ACCELERATORS = {"metal", "opencl", "webgpu"}


class ReleaseError(RuntimeError):
    pass


class NativeReleaseVersion(NamedTuple):
    channel: str
    version: tuple[int, ...]
    wrapper_revision: int
    upstream_tag: str


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise ReleaseError(
            f"LiteRT-LM {label} keys do not match owner schema 2; "
            f"missing={sorted(expected - actual)}, "
            f"unexpected={sorted(actual - expected)}"
        )


def required_litert_manifest_paths(
    compatibility_tag: str,
    release_tag: str,
    *,
    official_assets: bool,
) -> set[str]:
    version = tuple(int(part) for part in compatibility_tag[1:].split("."))
    required = set(LITERT_REQUIRED_RUNTIME_PATHS)
    spm_patterns = list(LITERT_SPM_ASSET_PATTERNS)
    if version >= (0, 16, 0):
        required.update(LITERT_V0_16_IOS_GPU_PATHS)
        spm_patterns.extend(LITERT_V0_16_SPM_ASSET_PATTERNS)
    if official_assets and version >= (0, 14, 0):
        required.update(
            {
                f"dist/official/{compatibility_tag}/CLiteRTLM.xcframework.zip",
                f"dist/official/{compatibility_tag}/CLiteRTLM_mac.xcframework.zip",
            }
        )
    required.update(
        f"dist/spm/{release_tag}/{pattern.format(tag=release_tag)}"
        for pattern in spm_patterns
    )
    required.update(
        override["targetPath"]
        for override in LITERT_PREBUILT_OVERRIDES.get(compatibility_tag, [])
    )
    return required


def required_litert_release_asset_names(
    manifest: dict[str, Any], release_tag: str
) -> set[str]:
    platforms = manifest.get("platforms")
    artifacts = manifest.get("artifacts")
    capabilities = manifest.get("capabilities")
    if not isinstance(platforms, list) or not isinstance(artifacts, list):
        raise ReleaseError("LiteRT-LM owner inventory requires schema-2 platform artifacts")
    if not isinstance(capabilities, dict):
        raise ReleaseError("LiteRT-LM owner inventory requires schema-2 capabilities")
    assets = {
        "manifest.json",
        "SHA256SUMS",
        "release-result.json",
        f"litert-lm-native-prebuilts-{release_tag}.tar.gz",
    }
    for platform in platforms:
        if not isinstance(platform, dict) or not isinstance(
            platform.get("releaseAsset"), str
        ):
            raise ReleaseError("LiteRT-LM owner inventory has an invalid platform asset")
        assets.add(platform["releaseAsset"])
    for artifact in artifacts:
        path = artifact.get("path") if isinstance(artifact, dict) else None
        if (
            isinstance(path, str)
            and path.startswith(f"dist/spm/{release_tag}/")
            and path.endswith(".zip")
        ):
            assets.add(Path(path).name)
    if capabilities.get("officialUpstreamAssets") is True:
        assets.add(f"litert-lm-native-official-assets-{release_tag}.tar.gz")
    return assets


def litert_schema2_apple_targets(
    manifest: dict[str, Any], release_tag: str
) -> set[str]:
    prefix = "litert-lm-native-apple-"
    suffix = f"-xcframework-{release_tag}.zip"
    targets = {
        asset_name[len(prefix) : -len(suffix)]
        for asset_name in required_litert_release_asset_names(manifest, release_tag)
        if asset_name.startswith(prefix) and asset_name.endswith(suffix)
    }
    if not targets:
        raise ReleaseError("LiteRT-LM schema-2 owner inventory has no Apple targets")
    return targets


def validate_litert_release_asset_inventory(
    release: dict[str, Any], manifest: dict[str, Any], release_tag: str
) -> None:
    assets = release.get("assets")
    if not isinstance(assets, list) or any(
        not isinstance(asset, dict) or not isinstance(asset.get("name"), str)
        for asset in assets
    ):
        raise ReleaseError("LiteRT-LM GitHub release asset inventory is invalid")
    names = [asset["name"] for asset in assets]
    if len(names) != len(set(names)):
        raise ReleaseError("LiteRT-LM GitHub release asset inventory has duplicates")
    expected = required_litert_release_asset_names(manifest, release_tag)
    actual = set(names)
    if actual != expected:
        raise ReleaseError(
            "LiteRT-LM GitHub release asset inventory does not match owner policy; "
            f"missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}"
        )
    for asset in assets:
        digest = asset.get("digest")
        if (
            not isinstance(digest, str)
            or not digest.startswith("sha256:")
            or not SHA256_RE.fullmatch(digest.removeprefix("sha256:"))
        ):
            raise ReleaseError(
                f"Asset {asset['name']} has an invalid GitHub SHA-256 digest"
            )


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    hook_path = repo_root / args.hook_build
    llama_cpp_package_swift_path = repo_root / args.llama_cpp_package_swift
    litert_lm_package_swift_path = repo_root / args.litert_lm_package_swift
    litert_lm_runtime_dart_path = repo_root / args.litert_lm_runtime_dart
    litert_lm_macos_prepare_path = repo_root / args.litert_lm_macos_prepare_script
    changelog_path = repo_root / DEFAULT_CHANGELOG
    llama_cpp_project_doc_paths = [
        repo_root / relative_path for relative_path in DEFAULT_LLAMA_CPP_PROJECT_DOCS
    ]

    hook_text = hook_path.read_text(encoding="utf-8")
    pending_writes: dict[Path, str] = {}
    project_doc_dependency_versions: dict[str, str] = {}

    summaries: list[str] = []
    resolved_llama_cpp_tag = ""
    resolved_litert_lm_tag = "keep"

    llama_cpp_tag_input = normalize_release_tag(args.llama_cpp_tag)
    litert_lm_tag_input = normalize_litert_lm_release_tag(args.litert_lm_tag)

    if llama_cpp_tag_input != "keep":
        release = fetch_release(
            args.llamadart_native_repo,
            llama_cpp_tag_input,
            args.release_json_dir,
        )
        resolved_llama_cpp_tag = validate_resolved_native_release(
            release,
            requested_tag=llama_cpp_tag_input,
            current_tag=read_hook_native_tag(hook_text),
            allow_legacy_tag=args.allow_legacy_tag,
        )
        validate_native_release_manifest(release, resolved_llama_cpp_tag)
        hook_text = replace_one(
            hook_text,
            r"const _llamaCppTag = '[^']+';",
            f"const _llamaCppTag = '{resolved_llama_cpp_tag}';",
            "hook llama.cpp tag",
        )
        if llama_cpp_package_swift_path.exists():
            checksum = release_asset_checksum(
                release,
                f"llamadart-native-apple-xcframework-{resolved_llama_cpp_tag}.zip",
            )
            original_swift_text = llama_cpp_package_swift_path.read_text(
                encoding="utf-8"
            )
            swift_text = original_swift_text
            swift_text = replace_one(
                swift_text,
                r'let llamaCppTag = "[^"]+"',
                f'let llamaCppTag = "{resolved_llama_cpp_tag}"',
                "llama.cpp Package.swift tag",
            )
            swift_text = replace_swift_binary_target_checksum(
                swift_text,
                "llama",
                checksum,
            )
            pending_writes[llama_cpp_package_swift_path] = swift_text
            package_root = companion_package_root(llama_cpp_package_swift_path)
            project_doc_dependency_versions[package_root.name] = (
                update_companion_package_metadata(
                    pending_writes,
                    package_root,
                    args.llamadart_native_repo,
                    resolved_llama_cpp_tag,
                    bump_version=(
                        args.bump_companion_versions
                        and swift_text != original_swift_text
                    ),
                )
            )
        update_llama_cpp_project_docs(
            pending_writes,
            llama_cpp_project_doc_paths,
            changelog_path,
            args.llamadart_native_repo,
            resolved_llama_cpp_tag,
        )

        summaries.append(
            f"llama.cpp -> {args.llamadart_native_repo}@{resolved_llama_cpp_tag}"
        )

    if litert_lm_tag_input != "keep":
        release = fetch_release(
            args.litert_lm_native_repo,
            litert_lm_tag_input,
            args.release_json_dir,
        )
        resolved_litert_lm_tag = release["tag_name"]
        current_litert_lm_tag = current_litert_lm_release_tag(hook_text)
        validate_litert_lm_transition(
            current_litert_lm_tag,
            resolved_litert_lm_tag,
            allow_channel_transition=args.allow_litert_channel_transition,
            allow_development_line_transition=(
                args.allow_litert_development_line_transition
            ),
        )
        litert_version = litert_lm_runtime_version(resolved_litert_lm_tag)
        litert_lm_manifest = validate_litert_lm_release_manifest(
            release,
            repo=args.litert_lm_native_repo,
            tag=resolved_litert_lm_tag,
            release_json_dir=args.release_json_dir,
            required_bundles=litert_lm_bundle_names(hook_text),
        )

        hook_text = replace_one(
            hook_text,
            r"const _litertLmReleaseTag = '[^']+';",
            f"const _litertLmReleaseTag = '{resolved_litert_lm_tag}';",
            "hook LiteRT-LM release tag",
        )
        hook_text = replace_one(
            hook_text,
            r"const _litertLmVersion = '[^']+';",
            f"const _litertLmVersion = '{litert_version}';",
            "hook LiteRT-LM version",
        )
        if not litert_lm_runtime_dart_path.exists():
            raise ReleaseError(
                f"Missing LiteRT-LM Dart runtime {litert_lm_runtime_dart_path}"
            )
        runtime_dart_text = litert_lm_runtime_dart_path.read_text(
            encoding="utf-8"
        )
        runtime_dart_text = replace_one(
            runtime_dart_text,
            r"const _litertLmReleaseTag = '[^']+';",
            f"const _litertLmReleaseTag = '{resolved_litert_lm_tag}';",
            "LiteRT-LM Dart runtime release tag",
        )
        pending_writes[litert_lm_runtime_dart_path] = replace_one(
            runtime_dart_text,
            r"const _litertLmVersion = '[^']+';",
            f"const _litertLmVersion = '{litert_version}';",
            "LiteRT-LM Dart runtime version",
        )
        if litert_lm_macos_prepare_path.exists():
            prepare_text = litert_lm_macos_prepare_path.read_text(encoding="utf-8")
            updated_prepare_text, replacement_count = re.subn(
                r"(/litert_lm/)[^/]+(/macos(?:_|/))",
                rf"\g<1>{litert_version}\g<2>",
                prepare_text,
            )
            if replacement_count == 0:
                raise ReleaseError(
                    "Could not replace LiteRT-LM version in macOS prepare script"
                )
            pending_writes[litert_lm_macos_prepare_path] = updated_prepare_text
        for bundle in litert_lm_bundle_names(hook_text):
            checksum = release_asset_checksum(
                release,
                f"litert-lm-native-runtime-{bundle}-{resolved_litert_lm_tag}.tar.gz",
            )
            hook_text = replace_litert_lm_bundle_checksum(
                hook_text,
                bundle,
                checksum,
            )

        if litert_lm_package_swift_path.exists():
            original_swift_text = litert_lm_package_swift_path.read_text(
                encoding="utf-8"
            )
            swift_text = prepare_litert_lm_package_swift(
                original_swift_text,
                release=release,
                manifest=litert_lm_manifest,
                resolved_tag=resolved_litert_lm_tag,
            )
            pending_writes[litert_lm_package_swift_path] = swift_text
            package_root = companion_package_root(litert_lm_package_swift_path)
            project_doc_dependency_versions[package_root.name] = (
                update_companion_package_metadata(
                    pending_writes,
                    package_root,
                    args.litert_lm_native_repo,
                    resolved_litert_lm_tag,
                    bump_version=(
                        args.bump_companion_versions
                        and swift_text != original_swift_text
                    ),
                )
            )

        summaries.append(
            f"LiteRT-LM -> {args.litert_lm_native_repo}@{resolved_litert_lm_tag}"
        )

    if not summaries:
        print("No native release pins requested; pass a tag or latest.")
        return 0

    if project_doc_dependency_versions:
        update_project_doc_dependency_versions(
            pending_writes,
            llama_cpp_project_doc_paths,
            project_doc_dependency_versions,
        )

    if args.dry_run:
        print("Dry run; no files written.")
    else:
        pending_writes[hook_path] = hook_text
        atomic_write_many(pending_writes)

    for summary in summaries:
        print(f"Synced {summary}")

    write_github_output(
        {
            "resolved_llama_cpp_tag": resolved_llama_cpp_tag,
            "resolved_litert_lm_tag": resolved_litert_lm_tag,
        }
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Update hook/build.dart from published native release asset "
            "checksums."
        )
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root. Defaults to the current directory.",
    )
    parser.add_argument(
        "--hook-build",
        default="hook/build.dart",
        help="Path to hook/build.dart relative to repo root.",
    )
    parser.add_argument(
        "--llama-cpp-package-swift",
        default=DEFAULT_LLAMA_CPP_PACKAGE_SWIFT,
        help=(
            "Path to the llama.cpp Flutter companion Package.swift relative "
            "to repo root. Skipped if the file does not exist."
        ),
    )
    parser.add_argument(
        "--litert-lm-package-swift",
        default=DEFAULT_LITERT_LM_PACKAGE_SWIFT,
        help=(
            "Path to the LiteRT-LM Flutter companion Package.swift relative "
            "to repo root. Skipped if the file does not exist."
        ),
    )
    parser.add_argument(
        "--litert-lm-runtime-dart",
        default=DEFAULT_LITERT_LM_RUNTIME_DART,
        help=(
            "Path to the LiteRT-LM Dart runtime version pin relative "
            "to repo root."
        ),
    )
    parser.add_argument(
        "--litert-lm-macos-prepare-script",
        default=DEFAULT_LITERT_LM_MACOS_PREPARE_SCRIPT,
        help=(
            "Path to the LiteRT-LM macOS app preparation script relative "
            "to repo root. Skipped if the file does not exist."
        ),
    )
    parser.add_argument(
        "--llama-cpp-tag",
        default="keep",
        help=(
            "Explicit llamadart-native stable, wrapper-rebuild, or "
            "historical/nightly tag; latest unsuffixed stable; or keep."
        ),
    )
    parser.add_argument(
        "--allow-legacy-tag",
        action="store_true",
        help=(
            "Allow an explicit stable-to-historical/nightly bNNNN channel "
            "switch. This does not permit version rollback or make latest "
            "accept a wrapper rebuild or nightly release."
        ),
    )
    parser.add_argument(
        "--litert-lm-tag",
        default="keep",
        help=(
            "litert-lm-native vX.Y.Z, vX.Y.Z-N, g<12hex>[-N], legacy "
            "vX.Y.Z-native.N, latest, or keep."
        ),
    )
    parser.add_argument(
        "--llamadart-native-repo",
        default=DEFAULT_LLAMADART_NATIVE_REPO,
        help="GitHub repo slug for llama.cpp native artifacts.",
    )
    parser.add_argument(
        "--litert-lm-native-repo",
        default=DEFAULT_LITERT_LM_NATIVE_REPO,
        help="GitHub repo slug for LiteRT-LM native artifacts.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Resolve releases and validate assets without writing files.",
    )
    parser.add_argument(
        "--bump-companion-versions",
        action="store_true",
        help=(
            "Also bump Flutter companion package pubspec versions and current "
            "install snippets. Native sync PRs should leave this unset; "
            "release-prep PRs may opt in."
        ),
    )
    parser.add_argument(
        "--allow-litert-channel-transition",
        action="store_true",
        help=(
            "Explicitly approve a stable/development channel transition after "
            "reviewing the owner manifest ancestry evidence."
        ),
    )
    parser.add_argument(
        "--allow-litert-development-line-transition",
        action="store_true",
        help=(
            "Explicitly approve changing from one g<commit> development line to "
            "another after reviewing owner manifest ancestry evidence."
        ),
    )
    parser.add_argument(
        "--release-json-dir",
        default="",
        help=(
            "Optional fixture directory for tests. Files are named "
            "<owner>__<repo>__<tag>.json."
        ),
    )
    return parser.parse_args()


def fetch_release(repo: str, tag: str, release_json_dir: str = "") -> dict[str, Any]:
    if release_json_dir:
        path = Path(release_json_dir) / f"{repo.replace('/', '__')}__{tag}.json"
        if not path.exists():
            raise ReleaseError(f"Missing release fixture {path}")
        return json.loads(path.read_text(encoding="utf-8"))

    if tag == "latest":
        url = f"https://api.github.com/repos/{repo}/releases/latest"
    else:
        url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            **github_auth_header(),
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ReleaseError(
            f"Failed to fetch release {repo}@{tag}: HTTP {error.code}"
        ) from error


def github_auth_header() -> dict[str, str]:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    return {"Authorization": f"Bearer {token}"} if token else {}


def release_asset_checksum(release: dict[str, Any], asset_name: str) -> str:
    asset = find_release_asset(release, asset_name)
    if asset is not None:
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            checksum = digest.removeprefix("sha256:")
            if not SHA256_RE.fullmatch(checksum):
                raise ReleaseError(
                    f"Asset {asset_name} has an invalid GitHub SHA-256 digest"
                )
            return checksum
        download_url = asset.get("browser_download_url")
        if not download_url:
            raise ReleaseError(f"Asset {asset_name} has no download URL")
        return sha256_url(download_url)
    tag = release.get("tag_name", "<unknown>")
    names = ", ".join(
        sorted(str(asset.get("name", "")) for asset in release_assets(release))
    )
    raise ReleaseError(
        f"Release {tag} does not contain required asset {asset_name}. "
        f"Available assets: {names}"
    )


def sha256_url(url: str) -> str:
    request = urllib.request.Request(url, headers=github_auth_header())
    digest = hashlib.sha256()
    with urllib.request.urlopen(request) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def normalize_release_tag(tag: str) -> str:
    tag = tag.strip()
    if not tag:
        return "keep"
    if tag not in {"keep", "latest"}:
        parse_native_release_tag(tag)
    return tag


def parse_native_release_tag(tag: str) -> NativeReleaseVersion:
    stable_match = _STABLE_NATIVE_TAG_PATTERN.fullmatch(tag)
    if stable_match:
        version = tuple(int(value) for value in stable_match.groups())
        return NativeReleaseVersion("stable", version, 0, tag)

    stable_wrapper_match = _STABLE_WRAPPER_TAG_PATTERN.fullmatch(tag)
    if stable_wrapper_match:
        major, minor, patch, wrapper_revision = (
            int(value) for value in stable_wrapper_match.groups()
        )
        return NativeReleaseVersion(
            "stable",
            (major, minor, patch),
            wrapper_revision,
            f"v{major}.{minor}.{patch}",
        )

    legacy_match = _LEGACY_NATIVE_TAG_PATTERN.fullmatch(tag)
    if legacy_match:
        build = int(legacy_match.group(1))
        return NativeReleaseVersion("nightly", (build,), 0, tag)

    nightly_wrapper_match = _NIGHTLY_WRAPPER_TAG_PATTERN.fullmatch(tag)
    if nightly_wrapper_match:
        build = int(nightly_wrapper_match.group(1))
        wrapper_revision = int(nightly_wrapper_match.group(2))
        return NativeReleaseVersion(
            "nightly",
            (build,),
            wrapper_revision,
            f"b{nightly_wrapper_match.group(1)}",
        )

    wrapper_match = _LEGACY_WRAPPER_TAG_PATTERN.fullmatch(tag)
    if wrapper_match:
        build = int(wrapper_match.group(1))
        wrapper_revision = int(wrapper_match.group(2))
        return NativeReleaseVersion(
            "nightly",
            (build,),
            wrapper_revision,
            f"b{wrapper_match.group(1)}",
        )

    raise ReleaseError(
        f"Invalid llamadart-native release tag {tag!r}. Expected stable "
        "vMAJOR.MINOR.PATCH, stable wrapper rebuild "
        "vMAJOR.MINOR.PATCH-N, canonical historical/nightly bNNNN without "
        "leading zeros, nightly wrapper "
        "rebuild bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N."
    )


def read_hook_native_tag(hook_text: str) -> str:
    match = re.search(r"const _llamaCppTag = '([^']+)';", hook_text)
    if not match:
        raise ReleaseError("Could not read hook llama.cpp tag")
    tag = match.group(1)
    parse_native_release_tag(tag)
    return tag


def validate_resolved_native_release(
    release: dict[str, Any],
    *,
    requested_tag: str,
    current_tag: str,
    allow_legacy_tag: bool,
) -> str:
    resolved_tag = release.get("tag_name")
    if not isinstance(resolved_tag, str) or not resolved_tag:
        raise ReleaseError("Native release metadata has no non-empty tag_name")
    parse_native_release_tag(resolved_tag)

    if requested_tag == "latest":
        if _STABLE_NATIVE_TAG_PATTERN.fullmatch(resolved_tag) is None:
            raise ReleaseError(
                f"llamadart-native latest resolved to {resolved_tag}. "
                "Automatic discovery accepts only unsuffixed "
                "vMAJOR.MINOR.PATCH releases; select wrapper rebuilds and "
                "historical or nightly tags explicitly."
            )
    elif resolved_tag != requested_tag:
        raise ReleaseError(
            f"Requested llamadart-native tag {requested_tag}, but release "
            f"metadata resolved {resolved_tag}. Refusing version-skewed pins."
        )

    validate_native_release_transition(
        current_tag,
        resolved_tag,
        allow_legacy_tag=allow_legacy_tag,
    )
    return resolved_tag


def validate_native_release_transition(
    current_tag: str,
    target_tag: str,
    *,
    allow_legacy_tag: bool,
) -> None:
    current = parse_native_release_tag(current_tag)
    target = parse_native_release_tag(target_tag)
    if current_tag == target_tag:
        return

    if current.channel == "nightly" and target.channel == "stable":
        return

    if current.channel == "stable" and target.channel == "nightly":
        if allow_legacy_tag:
            return
        raise ReleaseError(
            f"Refusing stable-to-historical/nightly native channel switch "
            f"{current_tag} -> {target_tag}. Pass --allow-legacy-tag only for "
            "an intentional compatibility override."
        )

    current_key = native_release_order_key(current)
    target_key = native_release_order_key(target)
    if target_key == current_key:
        raise ReleaseError(
            f"Refusing equivalent native release sequence aliases "
            f"{current_tag} -> {target_tag}. Keep the current artifact or "
            "move to a higher wrapper revision."
        )
    if target_key < current_key:
        raise ReleaseError(
            f"Refusing native release rollback {current_tag} -> {target_tag}. "
            "Use a forward release and regenerate bindings for its exact "
            "header manifest."
        )


def native_release_order_key(version: NativeReleaseVersion) -> tuple[int, ...]:
    return (*version.version, version.wrapper_revision)


def find_release_asset(
    release: dict[str, Any], asset_name: str
) -> dict[str, Any] | None:
    for asset in release_assets(release):
        if asset.get("name") == asset_name:
            return asset
    return None


def release_assets(release: dict[str, Any]) -> list[dict[str, Any]]:
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        raise ReleaseError("Native release metadata assets must be a list")
    for index, asset in enumerate(assets):
        if not isinstance(asset, dict):
            raise ReleaseError(
                "Native release metadata asset list contains a non-object "
                f"entry at index {index}"
            )
    return assets


def require_github_sha256_digest(
    asset: dict[str, Any], release_tag: str, asset_name: str
) -> str:
    digest = asset.get("digest")
    if not isinstance(digest, str) or re.fullmatch(
        r"sha256:[0-9a-f]{64}", digest
    ) is None:
        raise ReleaseError(
            f"Stable release {release_tag} does not publish a GitHub "
            f"SHA-256 digest for {asset_name}"
        )
    return digest.removeprefix("sha256:")


def release_asset_json(
    release: dict[str, Any], asset_name: str
) -> dict[str, Any]:
    asset = find_release_asset(release, asset_name)
    if asset is None:
        tag = release.get("tag_name", "<unknown>")
        raise ReleaseError(
            f"Release {tag} does not contain required asset {asset_name}"
        )

    fixture_json = asset.get("fixture_json")
    if isinstance(fixture_json, dict):
        return fixture_json

    download_url = asset.get("browser_download_url")
    if not isinstance(download_url, str) or not download_url:
        raise ReleaseError(f"Asset {asset_name} has no download URL")
    request = urllib.request.Request(download_url, headers=github_auth_header())
    try:
        with urllib.request.urlopen(request) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        json.JSONDecodeError,
        UnicodeDecodeError,
    ) as error:
        raise ReleaseError(
            f"Failed to read release manifest {asset_name}: {error}"
        ) from error
    if not isinstance(payload, dict):
        raise ReleaseError(f"Release manifest {asset_name} must be a JSON object")
    return payload


def release_asset_text(release: dict[str, Any], asset_name: str) -> str:
    asset = find_release_asset(release, asset_name)
    if asset is None:
        tag = release.get("tag_name", "<unknown>")
        raise ReleaseError(
            f"Release {tag} does not contain required asset {asset_name}"
        )

    fixture_text = asset.get("fixture_text")
    if isinstance(fixture_text, str):
        return fixture_text

    download_url = asset.get("browser_download_url")
    if not isinstance(download_url, str) or not download_url:
        raise ReleaseError(f"Asset {asset_name} has no download URL")
    request = urllib.request.Request(download_url, headers=github_auth_header())
    try:
        with urllib.request.urlopen(request) as response:
            return response.read().decode("utf-8")
    except (urllib.error.HTTPError, urllib.error.URLError, UnicodeDecodeError) as error:
        raise ReleaseError(
            f"Failed to read release checksum file {asset_name}: {error}"
        ) from error


def parse_sha256_sums(checksum_text: str, release_tag: str) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, line in enumerate(checksum_text.splitlines(), start=1):
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if match is None:
            raise ReleaseError(
                f"Release {release_tag} SHA256SUMS has invalid line "
                f"{line_number}: {line!r}"
            )
        checksum, file_name = match.groups()
        if file_name in checksums:
            raise ReleaseError(
                f"Release {release_tag} SHA256SUMS duplicates {file_name}"
            )
        checksums[file_name] = checksum
    return checksums


def validate_native_release_manifest(
    release: dict[str, Any], release_tag: str
) -> None:
    release_version = parse_native_release_tag(release_tag)
    is_new_wrapper_form = bool(
        _STABLE_WRAPPER_TAG_PATTERN.fullmatch(release_tag)
        or _NIGHTLY_WRAPPER_TAG_PATTERN.fullmatch(release_tag)
    )
    manifest_asset = find_release_asset(release, "assets.json")
    if manifest_asset is None:
        if release_version.channel == "stable" or is_new_wrapper_form:
            raise ReleaseError(
                f"Release {release_tag} is missing required assets.json "
                "provenance and hook-contract metadata."
            )
        return
    if release_version.channel == "stable":
        require_github_sha256_digest(
            manifest_asset,
            release_tag,
            "assets.json",
        )

    manifest = release_asset_json(release, "assets.json")
    native_release_tag = manifest.get("native_release_tag")
    legacy_release_tag = manifest.get("tag")
    for field_name, value in (
        ("native_release_tag", native_release_tag),
        ("tag", legacy_release_tag),
    ):
        if value is not None and (not isinstance(value, str) or not value):
            raise ReleaseError(
                f"Release {release_tag} manifest has invalid {field_name}: "
                f"{value!r}"
            )
    if is_new_wrapper_form:
        missing_tag_fields = [
            field_name
            for field_name, value in (
                ("native_release_tag", native_release_tag),
                ("tag", legacy_release_tag),
            )
            if value is None
        ]
        if missing_tag_fields:
            raise ReleaseError(
                f"Release {release_tag} manifest is missing required "
                f"tag field(s): {', '.join(missing_tag_fields)}"
            )
    if native_release_tag is not None and legacy_release_tag is not None:
        if native_release_tag != legacy_release_tag:
            raise ReleaseError(
                f"Release {release_tag} manifest native_release_tag "
                f"{native_release_tag!r} disagrees with legacy tag alias "
                f"{legacy_release_tag!r}."
            )
    manifest_release_tag = (
        native_release_tag
        if native_release_tag is not None
        else legacy_release_tag
    )
    if manifest_release_tag != release_tag:
        raise ReleaseError(
            f"Release manifest tag {manifest_release_tag!r} does not match "
            f"release {release_tag}. Refusing version-skewed native assets."
        )

    hook_contract_version = manifest.get("hook_contract_version")
    if hook_contract_version != SUPPORTED_NATIVE_HOOK_CONTRACT_VERSION:
        raise ReleaseError(
            f"Release {release_tag} requires native hook contract "
            f"{hook_contract_version!r}; this checkout supports "
            f"{SUPPORTED_NATIVE_HOOK_CONTRACT_VERSION}."
        )

    for field in ("llama_cpp_commit", "native_commit"):
        value = manifest.get(field)
        if not isinstance(value, str) or not _COMMIT_PATTERN.fullmatch(value):
            raise ReleaseError(
                f"Release {release_tag} manifest has invalid {field}: {value!r}"
            )

    llama_cpp_tag = manifest.get("llama_cpp_tag")
    llama_cpp_ref = manifest.get("llama_cpp_ref")
    if llama_cpp_tag is not None and llama_cpp_ref is not None:
        if llama_cpp_tag != llama_cpp_ref:
            raise ReleaseError(
                f"Release {release_tag} manifest llama_cpp_tag "
                f"{llama_cpp_tag!r} disagrees with llama_cpp_ref "
                f"{llama_cpp_ref!r}."
            )
    upstream_ref = llama_cpp_tag if llama_cpp_tag is not None else llama_cpp_ref
    if upstream_ref != release_version.upstream_tag:
        raise ReleaseError(
            f"Release {release_tag} manifest resolves llama.cpp tag "
            f"{upstream_ref!r}, expected {release_version.upstream_tag!r}. "
            "Refusing version-skewed native ABI metadata."
        )

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise ReleaseError(
            f"Release {release_tag} manifest artifacts must be a list"
        )

    manifest_checksums: dict[str, str] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ReleaseError(
                f"Release {release_tag} manifest contains a non-object artifact"
            )
        file_name = artifact.get("file")
        checksum = artifact.get("sha256")
        if not isinstance(file_name, str) or not file_name:
            raise ReleaseError(
                f"Release {release_tag} manifest artifact has no file name"
            )
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ReleaseError(
                f"Release {release_tag} manifest has invalid checksum for "
                f"{file_name}"
            )
        if file_name in manifest_checksums:
            raise ReleaseError(
                f"Release {release_tag} manifest duplicates artifact {file_name}"
            )
        manifest_checksums[file_name] = checksum

        release_asset = find_release_asset(release, file_name)
        if release_asset is None:
            raise ReleaseError(
                f"Release {release_tag} manifest lists unavailable bundle "
                f"{file_name}"
            )
        digest = release_asset.get("digest") or ""
        if release_version.channel == "stable":
            digest = (
                "sha256:"
                + require_github_sha256_digest(
                    release_asset,
                    release_tag,
                    file_name,
                )
            )
        if (
            digest.startswith("sha256:")
            and digest.removeprefix("sha256:") != checksum
        ):
            raise ReleaseError(
                f"Release {release_tag} checksum mismatch for {file_name}: "
                "manifest and GitHub release metadata disagree."
            )

    if release_version.channel == "stable":
        required_assets = {
            *(
                f"llamadart-native-{bundle}-{release_tag}.tar.gz"
                for bundle in _STABLE_NATIVE_BUNDLES
            ),
            f"llamadart-native-apple-xcframework-{release_tag}.zip",
            f"llamadart-native-headers-{release_tag}.tar.gz",
        }
        missing = sorted(required_assets.difference(manifest_checksums))
        if missing:
            raise ReleaseError(
                f"Stable release {release_tag} manifest is missing required "
                f"bundle(s): {', '.join(missing)}"
            )
        checksum_asset = find_release_asset(release, "SHA256SUMS")
        if checksum_asset is None:
            raise ReleaseError(
                f"Stable release {release_tag} is missing required SHA256SUMS"
            )
        require_github_sha256_digest(
            checksum_asset,
            release_tag,
            "SHA256SUMS",
        )
        published_checksums = parse_sha256_sums(
            release_asset_text(release, "SHA256SUMS"),
            release_tag,
        )
        for file_name, checksum in manifest_checksums.items():
            published_checksum = published_checksums.get(file_name)
            if published_checksum != checksum:
                raise ReleaseError(
                    f"Stable release {release_tag} SHA256SUMS checksum for "
                    f"{file_name} is {published_checksum!r}, expected "
                    f"{checksum!r} from assets.json"
                )


def normalize_litert_lm_release_tag(tag: str) -> str:
    tag = tag.strip()
    if not tag:
        return "keep"
    if tag in {"keep", "latest"}:
        return tag
    if (
        STABLE_LITERT_TAG_RE.fullmatch(tag)
        or STABLE_LITERT_REBUILD_RE.fullmatch(tag)
        or DEVELOPMENT_LITERT_TAG_RE.fullmatch(tag)
        or LEGACY_LITERT_TAG_RE.fullmatch(tag)
    ):
        return tag
    if re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
        tag,
    ):
        return f"v{tag}"
    raise ReleaseError(
        "Invalid LiteRT-LM native tag. Expected vMAJOR.MINOR.PATCH, "
        "vMAJOR.MINOR.PATCH-N, g<12hex>, g<12hex>-N, or legacy "
        "vMAJOR.MINOR.PATCH-native.N."
    )


def current_litert_lm_release_tag(hook_text: str) -> str:
    release_match = re.search(
        r"const _litertLmReleaseTag = '([^']+)';", hook_text
    )
    if release_match is not None:
        return release_match.group(1)
    match = re.search(r"const _litertLmVersion = '([^']+)';", hook_text)
    if match is None:
        raise ReleaseError("Could not find current LiteRT-LM version in hook/build.dart")
    version = match.group(1)
    return version if version.startswith("g") else f"v{version}"


def litert_lm_runtime_version(release_tag: str) -> str:
    """Return the cache/runtime version without altering commit release tags."""
    return release_tag.removeprefix("v")


def validate_litert_lm_transition(
    current: str,
    target: str,
    *,
    allow_channel_transition: bool = False,
    allow_development_line_transition: bool = False,
) -> None:
    if current == target:
        return
    current_development = DEVELOPMENT_LITERT_TAG_RE.fullmatch(current)
    target_development = DEVELOPMENT_LITERT_TAG_RE.fullmatch(target)
    if current_development or target_development:
        if bool(current_development) != bool(target_development):
            if not allow_channel_transition:
                raise ReleaseError(
                    "LiteRT-LM stable/development transition requires explicit "
                    "owner-ancestry approval"
                )
            target_rebuild = (
                development_release_order(target)[1]
                if target_development
                else stable_release_order(target)[1]
            )
            if target_rebuild != 0:
                raise ReleaseError(
                    "LiteRT-LM channel transition must enter the target line at its base"
                )
            return
        if current_development and target_development:
            current_base, current_rebuild = development_release_order(current)
            target_base, target_rebuild = development_release_order(target)
            if (
                current_base != target_base
                and not allow_development_line_transition
            ):
                raise ReleaseError(
                    "LiteRT-LM development line transition requires explicit "
                    "owner-ancestry approval"
                )
            if current_base != target_base:
                if target_rebuild != 0:
                    raise ReleaseError(
                        "LiteRT-LM development line transition must enter at its base"
                    )
                return
            if target_rebuild < current_rebuild:
                raise ReleaseError(
                    f"LiteRT-LM development rebuild rollback: {current} -> {target}"
                )
            if target_rebuild != current_rebuild + 1:
                raise ReleaseError(
                    "LiteRT-LM development rebuild must use the immediate next ordinal"
                )
        return

    current_version, current_rebuild = stable_release_order(current)
    target_version, target_rebuild = stable_release_order(target)
    if (
        target_version == current_version
        and target_rebuild == current_rebuild
        and target != current
    ):
        raise ReleaseError(
            f"LiteRT-LM ordinal alias is forbidden: {current} and {target} "
            "identify the same rebuild"
        )
    if target_version < current_version or (
        target_version == current_version and target_rebuild < current_rebuild
    ):
        raise ReleaseError(f"LiteRT-LM release rollback: {current} -> {target}")
    if target_version > current_version:
        if target_rebuild != 0:
            raise ReleaseError(
                "LiteRT-LM stable transition must enter the target line at its base"
            )
        return
    if target_rebuild != current_rebuild + 1:
        raise ReleaseError(
            "LiteRT-LM stable rebuild must use the immediate next ordinal"
        )


def stable_release_order(tag: str) -> tuple[tuple[int, int, int], int]:
    legacy = LEGACY_LITERT_TAG_RE.fullmatch(tag)
    compact = STABLE_LITERT_REBUILD_RE.fullmatch(tag)
    stable = STABLE_LITERT_TAG_RE.fullmatch(tag)
    if legacy:
        version_text, rebuild_text = tag[1:].rsplit("-native.", 1)
    elif compact:
        version_text, rebuild_text = tag[1:].rsplit("-", 1)
    elif stable:
        version_text, rebuild_text = tag[1:], "0"
    else:
        raise ReleaseError(f"Cannot order invalid LiteRT-LM release tag {tag}")
    return tuple(int(part) for part in version_text.split(".")), int(rebuild_text)


def development_release_order(tag: str) -> tuple[str, int]:
    if not DEVELOPMENT_LITERT_TAG_RE.fullmatch(tag):
        raise ReleaseError(f"Cannot order invalid LiteRT-LM development tag {tag}")
    parts = tag.rsplit("-", 1)
    return parts[0], int(parts[1]) if len(parts) == 2 else 0


def validate_litert_lm_release_manifest(
    release: dict[str, Any],
    *,
    repo: str,
    tag: str,
    release_json_dir: str,
    required_bundles: list[str],
) -> dict[str, Any]:
    manifest_result = fetch_litert_lm_release_manifest(
        release,
        repo=repo,
        tag=tag,
        release_json_dir=release_json_dir,
    )
    if manifest_result is None:
        raise ReleaseError(
            f"Release {repo}@{tag} has no immutable manifest.json evidence"
        )
    manifest, manifest_digest = manifest_result
    release_manifest_digest = release_asset_checksum(release, "manifest.json")
    if release_manifest_digest != manifest_digest:
        raise ReleaseError(
            "LiteRT-LM manifest bytes do not match the GitHub release digest"
        )

    schema = manifest.get("schemaVersion")
    release_identity = manifest.get("release")
    if not isinstance(release_identity, dict) or release_identity.get("tag") != tag:
        raise ReleaseError(f"Release manifest tag does not match {tag}")
    if schema == 1:
        legacy_identity = LEGACY_SCHEMA1_RELEASES.get(tag)
        if legacy_identity is None:
            raise ReleaseError(
                f"Release {repo}@{tag} must use LiteRT-LM manifest schema 2"
            )
        expected_assets = legacy_identity.get("assets")
        if not isinstance(expected_assets, dict):
            raise ReleaseError("Legacy release allowlist has invalid asset evidence")
        expected_manifest_asset_digest = expected_assets.get("manifest.json")
        if not isinstance(expected_manifest_asset_digest, str) or not expected_manifest_asset_digest.startswith("sha256:"):
            raise ReleaseError("Legacy release allowlist has no manifest digest")
        expected_manifest_digest = expected_manifest_asset_digest.removeprefix(
            "sha256:"
        )
        expected_tag_commit = legacy_identity.get("tagCommit")
        if manifest_digest != expected_manifest_digest:
            raise ReleaseError(
                f"Legacy release {repo}@{tag} manifest digest is not immutable allowlist evidence"
            )
        if fetch_tag_commit(repo, tag, release_json_dir, release) != expected_tag_commit:
            raise ReleaseError(
                f"Legacy release {repo}@{tag} tag commit is not immutable allowlist evidence"
            )
        actual_assets = {
            str(asset.get("name")): str(asset.get("digest"))
            for asset in release.get("assets", [])
            if isinstance(asset, dict)
        }
        if actual_assets != expected_assets:
            raise ReleaseError(
                f"Legacy release {repo}@{tag} asset digests are not immutable allowlist evidence"
            )
        if release.get("draft", False) != legacy_identity.get("draft") or release.get(
            "prerelease", False
        ) != legacy_identity.get("prerelease"):
            raise ReleaseError(
                f"Legacy release {repo}@{tag} classification is not immutable allowlist evidence"
            )
        return manifest
    if schema != 2:
        raise ReleaseError(f"Unsupported LiteRT-LM manifest schemaVersion {schema}")

    require_exact_keys(
        manifest,
        {
            "schemaVersion",
            "package",
            "release",
            "upstream",
            "native",
            "abi",
            "capabilities",
            "platforms",
            "artifacts",
            "realModelSmokes",
        },
        "manifest",
    )
    if manifest.get("package") != "litert-lm-native":
        raise ReleaseError("LiteRT-LM manifest has an unexpected package identity")

    upstream = manifest.get("upstream")
    native = manifest.get("native")
    if not isinstance(upstream, dict) or not FULL_COMMIT_RE.fullmatch(
        str(upstream.get("commit", ""))
    ):
        raise ReleaseError("LiteRT-LM manifest is missing an exact upstream commit")
    if not isinstance(native, dict) or not FULL_COMMIT_RE.fullmatch(
        str(native.get("commit", ""))
    ):
        raise ReleaseError("LiteRT-LM manifest is missing an exact native commit")
    if upstream.get("repository") != "google-ai-edge/LiteRT-LM":
        raise ReleaseError("LiteRT-LM manifest has an unexpected upstream repository")
    if native.get("repository") != repo:
        raise ReleaseError("LiteRT-LM manifest has an unexpected native repository")
    if release.get("target_commitish") != native["commit"]:
        raise ReleaseError("LiteRT-LM release target does not match native commit")

    stable_rebuild = STABLE_LITERT_REBUILD_RE.fullmatch(tag)
    development = DEVELOPMENT_LITERT_TAG_RE.fullmatch(tag)
    expected_rebuild = int(tag.rsplit("-", 1)[1]) if stable_rebuild else 0
    if development:
        development_parts = tag.rsplit("-", 1)
        expected_rebuild = (
            int(development_parts[1]) if len(development_parts) == 2 else 0
        )
        expected_base = f"g{upstream['commit'][:12]}"
        if tag != expected_base and not tag.startswith(f"{expected_base}-"):
            raise ReleaseError(
                f"Development release {tag} does not match upstream commit {upstream['commit']}"
            )
        if upstream.get("tag") is not None:
            raise ReleaseError("Development release must not claim a stable upstream tag")
        if upstream.get("developmentIdentity") != expected_base:
            raise ReleaseError("Development identity does not match upstream commit")
        expected_channel = "development"
        expected_kind = "rebuild" if expected_rebuild > 0 else "commit"
    else:
        expected_upstream_tag = (
            tag.rsplit("-", 1)[0] if stable_rebuild else tag
        )
        if upstream.get("tag") != expected_upstream_tag:
            raise ReleaseError(
                f"Stable release {tag} must use upstream tag {expected_upstream_tag}"
            )
        if upstream.get("compatibilityTag") != expected_upstream_tag:
            raise ReleaseError("Stable compatibility tag must equal its upstream tag")
        expected_channel = "stable"
        expected_kind = "rebuild" if expected_rebuild > 0 else "upstream"

    if not STABLE_LITERT_TAG_RE.fullmatch(str(upstream.get("compatibilityTag", ""))):
        raise ReleaseError("LiteRT-LM manifest has an invalid compatibility tag")
    expected_prerelease = development is not None or expected_rebuild > 0
    expected_release_fields = {
        "channel": expected_channel,
        "kind": expected_kind,
        "rebuild": expected_rebuild,
        "githubPrerelease": expected_prerelease,
    }
    require_exact_keys(
        release_identity,
        {"tag", *expected_release_fields.keys()},
        "release identity",
    )
    require_exact_keys(
        upstream,
        {
            "repository",
            "tag",
            "commit",
            "compatibilityTag",
            "developmentIdentity",
            "prebuiltOverrides",
        },
        "upstream provenance",
    )
    require_exact_keys(native, {"repository", "commit"}, "native provenance")
    if not isinstance(upstream.get("prebuiltOverrides"), list):
        raise ReleaseError("LiteRT-LM manifest prebuiltOverrides must be a list")
    if upstream.get("developmentIdentity") != f"g{upstream['commit'][:12]}":
        raise ReleaseError("LiteRT-LM development identity does not match upstream commit")
    for override in upstream["prebuiltOverrides"]:
        if not isinstance(override, dict):
            raise ReleaseError("LiteRT-LM prebuilt override provenance is invalid")
        require_exact_keys(
            override,
            {
                "sourceRepository",
                "sourceCommit",
                "sourcePath",
                "targetPath",
                "sha256",
            },
            "prebuilt override provenance",
        )
        if (
            override.get("sourceRepository") != "google-ai-edge/LiteRT-LM"
            or not FULL_COMMIT_RE.fullmatch(str(override.get("sourceCommit", "")))
            or not SHA256_RE.fullmatch(str(override.get("sha256", "")))
        ):
            raise ReleaseError("LiteRT-LM prebuilt override provenance is invalid")
    expected_overrides = LITERT_PREBUILT_OVERRIDES.get(
        str(upstream.get("compatibilityTag")), []
    )
    if upstream["prebuiltOverrides"] != expected_overrides:
        raise ReleaseError(
            "LiteRT-LM prebuilt override provenance does not match owner policy"
        )
    for name, expected in expected_release_fields.items():
        if release_identity.get(name) != expected:
            raise ReleaseError(
                f"LiteRT-LM manifest release {name} does not match {tag}"
            )
    if release.get("draft") is not False:
        raise ReleaseError("LiteRT-LM release must be published, not a draft")
    if release.get("prerelease") is not expected_prerelease:
        raise ReleaseError(
            "LiteRT-LM GitHub prerelease classification does not match manifest"
        )

    abi = manifest.get("abi")
    capabilities = manifest.get("capabilities")
    if isinstance(abi, dict):
        require_exact_keys(
            abi,
            {"upstreamC", "streamProxyCallback", "asrBridge"},
            "ABI declaration",
        )
    if isinstance(capabilities, dict):
        require_exact_keys(
            capabilities,
            {
                "textGeneration",
                "streaming",
                "streamChunkAccessors",
                "asr",
                "officialUpstreamAssets",
            },
            "capability declaration",
        )
    if (
        not isinstance(abi, dict)
        or abi.get("upstreamC") != "c/engine.h"
        or abi.get("streamProxyCallback") != 1
        or abi.get("asrBridge") != 1
    ):
        raise ReleaseError("LiteRT-LM manifest does not declare required bridge ABIs")
    if not isinstance(capabilities, dict) or not all(
        capabilities.get(name) is True
        for name in ("textGeneration", "streaming", "streamChunkAccessors", "asr")
    ):
        raise ReleaseError("LiteRT-LM manifest lacks required generation capabilities")
    if development is None and capabilities.get("officialUpstreamAssets") is not True:
        raise ReleaseError("Stable LiteRT-LM release lacks official upstream assets")
    if development is not None and capabilities.get("officialUpstreamAssets") is not False:
        raise ReleaseError("Development LiteRT-LM release must not claim official assets")

    platforms = manifest.get("platforms")
    if not isinstance(platforms, list) or len(platforms) != len(
        REQUIRED_LITERT_PLATFORM_BUNDLES
    ):
        raise ReleaseError("LiteRT-LM manifest platforms must be a list")
    available_bundles = {
        f"{item.get('platform')}-{item.get('arch')}"
        for item in platforms
        if isinstance(item, dict)
    }
    expected_bundles = set(required_bundles)
    if expected_bundles != REQUIRED_LITERT_PLATFORM_BUNDLES:
        raise ReleaseError(
            "llamadart hook bundle inventory does not cover the finalized nine-platform contract"
        )
    if available_bundles != REQUIRED_LITERT_PLATFORM_BUNDLES or len(
        available_bundles
    ) != len(platforms):
        raise ReleaseError(
            "LiteRT-LM manifest must contain each finalized platform bundle exactly once"
        )
    missing_bundles = sorted(expected_bundles - available_bundles)
    if missing_bundles:
        raise ReleaseError(
            "LiteRT-LM manifest is missing required platform bundles: "
            + ", ".join(missing_bundles)
        )

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ReleaseError("LiteRT-LM manifest contains no artifacts")
    artifacts_by_path: dict[str, dict[str, Any]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ReleaseError("LiteRT-LM manifest contains an invalid artifact")
        require_exact_keys(
            artifact,
            {
                "runtime",
                "platform",
                "arch",
                "path",
                "fileName",
                "sha256",
                "upstreamTag",
                "upstreamCommit",
                "releaseTag",
                "accelerators",
            },
            "artifact provenance",
        )
        if not SHA256_RE.fullmatch(str(artifact.get("sha256", ""))):
            raise ReleaseError("LiteRT-LM manifest contains an invalid artifact digest")
        if artifact.get("releaseTag") != tag:
            raise ReleaseError("LiteRT-LM artifact releaseTag does not match release")
        if artifact.get("upstreamCommit") != upstream["commit"]:
            raise ReleaseError("LiteRT-LM artifact upstream commit does not match manifest")
        if artifact.get("upstreamTag") != upstream.get("tag"):
            raise ReleaseError("LiteRT-LM artifact upstream tag does not match manifest")
        artifact_path = artifact.get("path")
        if (
            not isinstance(artifact_path, str)
            or not artifact_path
            or Path(artifact_path).is_absolute()
            or ".." in Path(artifact_path).parts
            or Path(artifact_path).as_posix() != artifact_path
        ):
            raise ReleaseError("LiteRT-LM manifest contains an invalid artifact path")
        if artifact.get("fileName") != Path(artifact_path).name:
            raise ReleaseError("LiteRT-LM artifact fileName does not match path")
        if artifact.get("runtime") not in {"native", "archive", "web"}:
            raise ReleaseError("LiteRT-LM artifact has an invalid runtime family")
        accelerators = artifact.get("accelerators")
        if (
            not isinstance(accelerators, list)
            or any(not isinstance(value, str) or not value for value in accelerators)
            or len(accelerators) != len(set(accelerators))
            or not set(accelerators).issubset(LITERT_ALLOWED_ACCELERATORS)
        ):
            raise ReleaseError("LiteRT-LM artifact accelerators are invalid")
        if artifact_path in artifacts_by_path:
            raise ReleaseError("LiteRT-LM manifest contains duplicate artifact paths")
        artifacts_by_path[artifact_path] = artifact

    for override in expected_overrides:
        target = artifacts_by_path.get(override["targetPath"])
        if (
            target is None
            or target.get("runtime") != "native"
            or target.get("sha256") != override["sha256"]
        ):
            raise ReleaseError(
                "LiteRT-LM prebuilt override target provenance does not match owner policy"
            )

    covered_native_paths: set[str] = set()
    for platform in platforms:
        if not isinstance(platform, dict):
            raise ReleaseError("LiteRT-LM manifest contains an invalid platform")
        require_exact_keys(
            platform,
            {"platform", "arch", "releaseAsset", "artifactPaths", "accelerators"},
            "platform declaration",
        )
        paths = platform.get("artifactPaths")
        if (
            not isinstance(paths, list)
            or not paths
            or len(paths) != len(set(paths))
        ):
            raise ReleaseError("LiteRT-LM platform artifact paths are invalid")
        if any(path not in artifacts_by_path for path in paths):
            raise ReleaseError("LiteRT-LM platform references an unknown artifact path")
        if any(
            artifacts_by_path[path].get("platform") != platform.get("platform")
            or artifacts_by_path[path].get("arch") != platform.get("arch")
            for path in paths
        ):
            raise ReleaseError("LiteRT-LM platform artifact provenance does not match")
        if any(artifacts_by_path[path].get("runtime") != "native" for path in paths):
            raise ReleaseError("LiteRT-LM platform may reference only native artifacts")
        covered_native_paths.update(paths)
        accelerators = platform.get("accelerators")
        if not isinstance(accelerators, list) or len(accelerators) != len(
            set(accelerators)
        ):
            raise ReleaseError("LiteRT-LM platform accelerators are invalid")
        linked_accelerators = sorted(
            {
                accelerator
                for path in paths
                for accelerator in artifacts_by_path[path]["accelerators"]
            }
        )
        if accelerators != linked_accelerators or not set(accelerators).issubset(
            LITERT_ALLOWED_ACCELERATORS
        ):
            raise ReleaseError(
                "LiteRT-LM platform accelerators do not match linked artifacts"
            )
        expected_release_asset = (
            "litert-lm-native-runtime-"
            f"{platform.get('platform')}-{platform.get('arch')}-{tag}.tar.gz"
        )
        if platform.get("releaseAsset") != expected_release_asset:
            raise ReleaseError("LiteRT-LM platform release asset does not match identity")
        release_asset_checksum(release, expected_release_asset)

    native_paths = {
        path
        for path, artifact in artifacts_by_path.items()
        if artifact.get("runtime") == "native"
    }
    if covered_native_paths != native_paths:
        raise ReleaseError("LiteRT-LM manifest has unbound native artifact provenance")
    required_paths = required_litert_manifest_paths(
        str(upstream["compatibilityTag"]),
        tag,
        official_assets=capabilities["officialUpstreamAssets"] is True,
    )
    missing_paths = sorted(required_paths - set(artifacts_by_path))
    if missing_paths:
        raise ReleaseError(
            "LiteRT-LM manifest is missing owner-required artifact paths: "
            + ", ".join(missing_paths)
        )
    platform_paths = {
        (platform["platform"], platform["arch"]): set(platform["artifactPaths"])
        for platform in platforms
    }
    for path in sorted(required_paths):
        artifact = artifacts_by_path[path]
        parts = Path(path).parts
        if parts[0] == "bin":
            expected_platform, expected_arch = parts[1:3]
            if (
                artifact.get("runtime") != "native"
                or artifact.get("platform") != expected_platform
                or artifact.get("arch") != expected_arch
                or path not in platform_paths[(expected_platform, expected_arch)]
            ):
                raise ReleaseError(
                    "LiteRT-LM required runtime path has invalid platform binding"
                )
        elif (
            artifact.get("runtime") != "archive"
            or artifact.get("platform") is not None
            or artifact.get("arch") is not None
        ):
            raise ReleaseError(
                "LiteRT-LM required archive path has invalid platform binding"
            )

    validate_litert_release_asset_inventory(release, manifest, tag)

    passed_smokes: set[str] = set()
    smokes = manifest.get("realModelSmokes")
    if not isinstance(smokes, list):
        raise ReleaseError("LiteRT-LM realModelSmokes must be a list")
    smoke_identities: set[tuple[str, str, str]] = set()
    for item in smokes:
        if not isinstance(item, dict):
            raise ReleaseError("LiteRT-LM smoke must be an object")
        require_exact_keys(
            item,
            {
                "id",
                "result",
                "platform",
                "arch",
                "backend",
                "upstreamCommit",
                "nativeCommit",
                "abiVersion",
                "library",
                "model",
                "tokenizer",
                "fixture",
                "source",
                "expectation",
                "transcript",
            },
            "real-model smoke",
        )
        if item.get("result") != "pass":
            raise ReleaseError("LiteRT-LM smoke is not a pass")
        if item.get("upstreamCommit") != upstream["commit"]:
            raise ReleaseError("LiteRT-LM smoke upstream commit does not match manifest")
        if item.get("nativeCommit") != native["commit"]:
            raise ReleaseError("LiteRT-LM smoke native commit does not match manifest")
        if item.get("id") != "litert_lm_asr_moonshine":
            raise ReleaseError("LiteRT-LM smoke has an unexpected identity")
        if item.get("backend") != "cpu" or item.get("abiVersion") != 1:
            raise ReleaseError("LiteRT-LM smoke has invalid backend or ABI evidence")
        if not isinstance(item.get("transcript"), str) or not item["transcript"].strip():
            raise ReleaseError("LiteRT-LM smoke has no transcript evidence")
        for field, expected_keys in (
            ("library", {"fileName", "sha256"}),
            ("model", {"fileName", "sha256"}),
            ("tokenizer", {"fileName", "sha256"}),
            ("fixture", {"fileName", "sha256", "sampleRateHz", "sampleCount"}),
        ):
            payload = item.get(field)
            if not isinstance(payload, dict):
                raise ReleaseError(f"LiteRT-LM smoke has invalid {field} evidence")
            require_exact_keys(payload, expected_keys, f"smoke {field}")
            if (
                not isinstance(payload.get("fileName"), str)
                or not payload["fileName"]
                or not SHA256_RE.fullmatch(str(payload.get("sha256", "")))
            ):
                raise ReleaseError(f"LiteRT-LM smoke has an invalid {field} digest")
        fixture = item["fixture"]
        if fixture.get("sampleRateHz") != 16000 or not isinstance(
            fixture.get("sampleCount"), int
        ) or fixture["sampleCount"] <= 0:
            raise ReleaseError("LiteRT-LM smoke has invalid fixture metadata")
        for field, pinned in LITERT_SMOKE_ASSETS.items():
            payload = item[field]
            if (
                payload.get("fileName") != pinned["fileName"]
                or payload.get("sha256") != pinned["sha256"]
            ):
                raise ReleaseError(
                    f"LiteRT-LM smoke {field} does not match the owner-pinned asset"
                )
        library = item["library"]
        matching_libraries = [
            artifact
            for artifact in artifacts_by_path.values()
            if artifact.get("runtime") == "native"
            and artifact.get("platform") == item.get("platform")
            and artifact.get("arch") == item.get("arch")
            and artifact.get("fileName") == library.get("fileName")
            and artifact.get("sha256") == library.get("sha256")
        ]
        if len(matching_libraries) != 1:
            raise ReleaseError(
                "LiteRT-LM smoke library does not match one packaged runtime artifact"
            )
        source = item.get("source")
        if not isinstance(source, dict):
            raise ReleaseError("LiteRT-LM smoke has no immutable source provenance")
        require_exact_keys(
            source,
            {"runtimeReleaseAsset", "model", "tokenizer", "fixture"},
            "smoke source provenance",
        )
        expected_runtime_asset = (
            "litert-lm-native-runtime-"
            f"{item.get('platform')}-{item.get('arch')}-{tag}.tar.gz"
        )
        if source.get("runtimeReleaseAsset") != expected_runtime_asset or any(
            source.get(field) != LITERT_SMOKE_ASSETS[field]["url"]
            for field in ("model", "tokenizer", "fixture")
        ):
            raise ReleaseError("LiteRT-LM smoke has invalid source provenance")
        expectation = item.get("expectation")
        if not isinstance(expectation, dict):
            raise ReleaseError("LiteRT-LM smoke has no transcript expectation")
        require_exact_keys(
            expectation,
            {"type", "value"},
            "smoke transcript expectation",
        )
        expectation_value = expectation.get("value")
        if expectation != {
            "type": "case-insensitive-substring",
            "value": "country",
        } or expectation_value.casefold() not in item["transcript"].casefold():
            raise ReleaseError(
                "LiteRT-LM smoke does not satisfy the owner-pinned transcript expectation"
            )
        identity = (
            str(item.get("id")),
            str(item.get("platform")),
            str(item.get("arch")),
        )
        if identity in smoke_identities:
            raise ReleaseError("LiteRT-LM smoke identity is duplicated")
        smoke_identities.add(identity)
        passed_smokes.add(f"{item.get('platform')}/{item.get('arch')}")
    required_smokes = {"linux/x64", "windows/x64"}
    if not required_smokes.issubset(passed_smokes):
        raise ReleaseError(
            "LiteRT-LM manifest is missing required real-model smoke evidence: "
            + ", ".join(sorted(required_smokes - passed_smokes))
        )
    return manifest


def fetch_litert_lm_release_manifest(
    release: dict[str, Any],
    *,
    repo: str,
    tag: str,
    release_json_dir: str,
) -> tuple[dict[str, Any], str] | None:
    manifest_asset = next(
        (
            asset
            for asset in release.get("assets", [])
            if isinstance(asset, dict) and asset.get("name") == "manifest.json"
        ),
        None,
    )
    if manifest_asset is None:
        return None
    if release_json_dir:
        fixture = (
            Path(release_json_dir)
            / f"{repo.replace('/', '__')}__{tag}__manifest.json"
        )
        if not fixture.exists():
            raise ReleaseError(f"Missing release manifest fixture {fixture}")
        payload = fixture.read_bytes()
        manifest = json.loads(payload.decode("utf-8"))
        if not isinstance(manifest, dict):
            raise ReleaseError(f"Release {repo}@{tag} manifest is not a JSON object")
        return manifest, hashlib.sha256(payload).hexdigest()

    url = manifest_asset.get("browser_download_url")
    if not isinstance(url, str) or not url:
        raise ReleaseError(f"Release {repo}@{tag} manifest has no download URL")
    request = urllib.request.Request(url, headers=github_auth_header())
    with urllib.request.urlopen(request) as response:
        payload = response.read()
    manifest = json.loads(payload.decode("utf-8"))
    if not isinstance(manifest, dict):
        raise ReleaseError(f"Release {repo}@{tag} manifest is not a JSON object")
    return manifest, hashlib.sha256(payload).hexdigest()


def fetch_tag_commit(
    repo: str,
    tag: str,
    release_json_dir: str,
    release: dict[str, Any],
) -> str:
    if release_json_dir:
        commit = release.get("tag_commit_sha")
        if not isinstance(commit, str) or not FULL_COMMIT_RE.fullmatch(commit):
            raise ReleaseError(
                f"Legacy release fixture {repo}@{tag} lacks exact tag_commit_sha"
            )
        return commit
    url = f"https://api.github.com/repos/{repo}/commits/{tag}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            **github_auth_header(),
        },
    )
    with urllib.request.urlopen(request) as response:
        payload = json.loads(response.read().decode("utf-8"))
    commit = payload.get("sha")
    if not isinstance(commit, str) or not FULL_COMMIT_RE.fullmatch(commit):
        raise ReleaseError(f"Could not resolve exact tag commit for {repo}@{tag}")
    return commit


def allows_legacy_litert_manifest(tag: str) -> bool:
    return tag in LEGACY_SCHEMA1_RELEASES


def replace_one(text: str, pattern: str, replacement: str, description: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace {description}")
    return updated


def atomic_write_many(
    writes: dict[Path, str],
    *,
    replace_func: Any = os.replace,
) -> None:
    """Commit a set of text replacements with rollback on partial failure."""
    staged: dict[Path, Path] = {}
    backups: dict[Path, Path | None] = {}
    replaced: list[Path] = []
    try:
        for path, text in writes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, staged_name = tempfile.mkstemp(
                prefix=f".{path.name}.new-", dir=path.parent
            )
            staged_path = Path(staged_name)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                output.write(text)
                output.flush()
                os.fsync(output.fileno())
            if path.exists():
                staged_path.chmod(path.stat().st_mode)
                backup_descriptor, backup_name = tempfile.mkstemp(
                    prefix=f".{path.name}.backup-", dir=path.parent
                )
                os.close(backup_descriptor)
                backup_path = Path(backup_name)
                shutil.copy2(path, backup_path)
                backups[path] = backup_path
            else:
                backups[path] = None
            staged[path] = staged_path

        for path in sorted(writes, key=lambda item: item.as_posix()):
            replace_func(staged[path], path)
            replaced.append(path)
            staged.pop(path, None)
    except Exception as error:
        rollback_errors: list[str] = []
        for path in reversed(replaced):
            backup = backups[path]
            try:
                if backup is None:
                    path.unlink(missing_ok=True)
                else:
                    replace_func(backup, path)
                    backups[path] = None
            except Exception as rollback_error:  # pragma: no cover - catastrophic IO
                rollback_errors.append(f"{path}: {rollback_error}")
        detail = ""
        if rollback_errors:
            detail = "; rollback failures: " + "; ".join(rollback_errors)
        raise ReleaseError(f"Atomic pin update failed: {error}{detail}") from error
    finally:
        for path in (*staged.values(), *(item for item in backups.values() if item)):
            path.unlink(missing_ok=True)


def litert_lm_bundle_names(hook_text: str) -> list[str]:
    pattern = re.compile(
        r"_LiteRtLmBundleSpec\(\s*'([^']+)',\s*sha256: '[0-9a-f]+'",
        re.DOTALL,
    )
    bundles = pattern.findall(hook_text)
    if not bundles:
        raise ReleaseError("Could not find LiteRT-LM bundle specs in hook/build.dart")
    return bundles


def replace_litert_lm_bundle_checksum(
    hook_text: str,
    bundle: str,
    checksum: str,
) -> str:
    pattern = re.compile(
        rf"(_LiteRtLmBundleSpec\(\s*'{re.escape(bundle)}',\s*sha256: ')[0-9a-f]+(')",
        re.DOTALL,
    )
    updated, count = pattern.subn(rf"\g<1>{checksum}\2", hook_text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace LiteRT-LM checksum for {bundle}")
    return updated


def replace_swift_binary_target_checksum(
    swift_text: str,
    target_name: str,
    checksum: str,
) -> str:
    pattern = re.compile(
        rf'(nativeRepoBinaryTarget\(\s*name: "{re.escape(target_name)}",'
        r'.*?checksum: ")[0-9a-f]+(")',
        re.DOTALL,
    )
    updated, count = pattern.subn(rf"\g<1>{checksum}\2", swift_text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace Package.swift checksum for {target_name}")
    return updated


def prepare_litert_lm_package_swift(
    original_swift_text: str,
    *,
    release: dict[str, Any],
    manifest: dict[str, Any],
    resolved_tag: str,
) -> str:
    original_tag = swift_variable_value(
        original_swift_text,
        "liteRtLmTag",
        "LiteRT-LM Package.swift tag",
    )
    swift_text = original_swift_text
    if manifest.get("schemaVersion") == 2:
        expected_targets = litert_schema2_apple_targets(manifest, resolved_tag)
        legacy_targets = (expected_targets - {"CLiteRTLMMac"}) | {
            "GemmaModelConstraintProvider"
        }
        current_targets = {
            target_name
            for target_name, _ in swift_native_repo_binary_targets(
                swift_text,
                tag_variable="liteRtLmTag",
                current_tag=original_tag,
            )
        }
        if current_targets == legacy_targets:
            if swift_text.count("GemmaModelConstraintProvider") != 3:
                raise ReleaseError(
                    "Legacy LiteRT-LM Package.swift Gemma target topology is ambiguous"
                )
            swift_text = swift_text.replace(
                "GemmaModelConstraintProvider",
                "CLiteRTLMMac",
            )
            swift_text = replace_one(
                swift_text,
                (
                    r'(name: "CLiteRTLMMac", condition: '
                    r'\.when\(platforms: \[)\.iOS(\]\)\))'
                ),
                r"\g<1>.macOS\2",
                "LiteRT-LM Package.swift macOS compatibility target condition",
            )
        elif current_targets != expected_targets:
            raise ReleaseError(
                "LiteRT-LM Package.swift binary targets do not match the legacy "
                "or schema-2 owner inventory"
            )

    apple_targets = swift_native_repo_binary_targets(
        swift_text,
        tag_variable="liteRtLmTag",
        current_tag=original_tag,
    )
    if manifest.get("schemaVersion") == 2 and {
        target_name for target_name, _ in apple_targets
    } != litert_schema2_apple_targets(manifest, resolved_tag):
        raise ReleaseError(
            "LiteRT-LM Package.swift binary targets do not match schema-2 owner inventory"
        )
    swift_text = replace_one(
        swift_text,
        r'let liteRtLmTag = "[^"]+"',
        f'let liteRtLmTag = "{resolved_tag}"',
        "LiteRT-LM Package.swift tag",
    )
    for target_name, asset_template in apple_targets:
        checksum = release_asset_checksum(
            release,
            asset_template.format(tag=resolved_tag),
        )
        swift_text = replace_swift_binary_target_checksum(
            swift_text,
            target_name,
            checksum,
        )
    return swift_text


def swift_variable_value(
    swift_text: str,
    variable_name: str,
    description: str,
) -> str:
    match = re.search(
        rf'\blet\s+{re.escape(variable_name)}\s*=\s*"([^"]+)"',
        swift_text,
    )
    if not match:
        raise ReleaseError(f"Could not read {description}")
    return match.group(1)


def swift_native_repo_binary_targets(
    swift_text: str,
    *,
    tag_variable: str,
    current_tag: str,
) -> list[tuple[str, str]]:
    pattern = re.compile(
        r'nativeRepoBinaryTarget\(\s*name:\s*"(?P<name>[^"]+)"'
        r'.*?artifactName:\s*"(?P<artifact_name>[^"]+)"'
        r'.*?checksum:\s*"[0-9a-f]+"',
        re.DOTALL,
    )
    targets: list[tuple[str, str]] = []
    for match in pattern.finditer(swift_text):
        artifact_template = swift_artifact_template(
            match.group("artifact_name"),
            tag_variable=tag_variable,
            current_tag=current_tag,
        )
        targets.append((match.group("name"), artifact_template))
    if not targets:
        raise ReleaseError("Could not find nativeRepoBinaryTarget entries")
    return targets


def swift_artifact_template(
    artifact_name: str,
    *,
    tag_variable: str,
    current_tag: str,
) -> str:
    interpolated_tag = rf"\({tag_variable})"
    if interpolated_tag in artifact_name:
        return artifact_name.replace(interpolated_tag, "{tag}")
    if current_tag in artifact_name:
        return artifact_name.replace(current_tag, "{tag}")
    return artifact_name


def companion_package_root(package_swift_path: Path) -> Path:
    try:
        return package_swift_path.parents[2]
    except IndexError as error:
        raise ReleaseError(
            f"Could not infer companion package root from {package_swift_path}"
        ) from error


def update_companion_package_metadata(
    pending_writes: dict[Path, str],
    package_root: Path,
    repo: str,
    tag: str,
    *,
    bump_version: bool,
) -> str:
    pubspec_path = package_root / "pubspec.yaml"
    readme_path = package_root / "README.md"
    changelog_path = package_root / "CHANGELOG.md"
    if not pubspec_path.exists():
        raise ReleaseError(f"Missing companion package pubspec {pubspec_path}")
    if not readme_path.exists():
        raise ReleaseError(f"Missing companion package README {readme_path}")
    if not changelog_path.exists():
        raise ReleaseError(f"Missing companion package CHANGELOG {changelog_path}")

    pubspec_text = pubspec_path.read_text(encoding="utf-8")
    current_version = companion_pubspec_version(pubspec_text, pubspec_path)
    next_version = (
        bump_patch_version(current_version) if bump_version else current_version
    )
    if bump_version:
        pending_writes[pubspec_path] = replace_pubspec_version(
            pubspec_text,
            next_version,
            pubspec_path,
        )

    readme_text = readme_path.read_text(encoding="utf-8")
    readme_text = replace_one(
        readme_text,
        r"The Apple SwiftPM manifest pins\s+`[^`]+`\.",
        f"The Apple SwiftPM manifest pins `{repo}@{tag}`.",
        f"{package_root.name} README native pin",
    )
    readme_text = replace_readme_dependency_version(
        readme_text,
        package_root.name,
        next_version,
    )
    pending_writes[readme_path] = readme_text

    if bump_version:
        changelog_text = changelog_path.read_text(encoding="utf-8")
        pending_writes[changelog_path] = prepend_companion_changelog_release(
            changelog_text,
            next_version,
            f"* Updated Apple SwiftPM native pin to `{repo}@{tag}`.",
            repo,
        )
    else:
        changelog_text = changelog_path.read_text(encoding="utf-8")
        pending_writes[changelog_path] = update_companion_changelog_unreleased(
            changelog_text,
            f"* Updated Apple SwiftPM native pin to `{repo}@{tag}`.",
            repo,
        )

    return next_version


def update_llama_cpp_project_docs(
    pending_writes: dict[Path, str],
    doc_paths: list[Path],
    changelog_path: Path,
    repo: str,
    tag: str,
) -> None:
    for doc_path in doc_paths:
        if not doc_path.exists():
            raise ReleaseError(f"Missing project native pin doc {doc_path}")
        doc_text = doc_path.read_text(encoding="utf-8")
        updated_doc_text = replace_llama_cpp_native_doc_references(
            doc_text,
            repo,
            tag,
        )
        if updated_doc_text == doc_text:
            if tag not in doc_text:
                raise ReleaseError(
                    f"Could not update llama.cpp native pin references in {doc_path}"
                )
        else:
            pending_writes[doc_path] = updated_doc_text

    if not changelog_path.exists():
        raise ReleaseError(f"Missing project CHANGELOG {changelog_path}")
    changelog_text = changelog_path.read_text(encoding="utf-8")
    pending_writes[changelog_path] = update_core_changelog_native_pin(
        changelog_text,
        repo,
        tag,
    )


def replace_llama_cpp_native_doc_references(
    doc_text: str,
    repo: str,
    tag: str,
) -> str:
    replacements = (
        (
            rf"(llamadart_native_tag:\s*){_NATIVE_DOC_TAG_PATTERN}",
            rf"\g<1>{tag}",
        ),
        (
            rf"({re.escape(repo)}@){_NATIVE_DOC_TAG_PATTERN}",
            rf"\g<1>{tag}",
        ),
        (
            rf"(llamadart-native-[a-z0-9_-]+-)"
            rf"{_NATIVE_DOC_TAG_PATTERN}(?=\.tar\.gz`)",
            rf"\g<1>{tag}",
        ),
        (
            rf"(default native tag `){_NATIVE_DOC_TAG_PATTERN}(`)",
            rf"\g<1>{tag}\2",
        ),
        (
            rf"(llamadart-native` tag\s+`){_NATIVE_DOC_TAG_PATTERN}(`)",
            rf"\g<1>{tag}\2",
        ),
        (
            rf"(module availability by bundle \(`){_NATIVE_DOC_TAG_PATTERN}(`\))",
            rf"\g<1>{tag}\2",
        ),
    )
    for pattern, replacement in replacements:
        doc_text = re.sub(pattern, replacement, doc_text)
    return doc_text


def update_project_doc_dependency_versions(
    pending_writes: dict[Path, str],
    doc_paths: list[Path],
    dependency_versions: dict[str, str],
) -> None:
    replacement_counts = {
        package_name: 0 for package_name in dependency_versions
    }
    for doc_path in doc_paths:
        if not doc_path.exists():
            raise ReleaseError(f"Missing project dependency doc {doc_path}")
        doc_text = pending_writes.get(doc_path)
        if doc_text is None:
            doc_text = doc_path.read_text(encoding="utf-8")
        for package_name, version in dependency_versions.items():
            doc_text, count = replace_dependency_version(
                doc_text,
                package_name,
                version,
            )
            replacement_counts[package_name] += count
        pending_writes[doc_path] = doc_text

    missing = [
        package_name
        for package_name, count in replacement_counts.items()
        if count == 0
    ]
    if missing:
        raise ReleaseError(
            "Could not replace project docs dependency versions for "
            + ", ".join(missing)
        )


def update_core_changelog_native_pin(
    changelog_text: str,
    repo: str,
    tag: str,
) -> str:
    native_version = parse_native_release_tag(tag)
    if native_version.wrapper_revision > 0:
        base_tag = native_version.upstream_tag
        entry = (
            "* Updated the default llama.cpp native runtime pin to\n"
            f"  `{repo}@{tag}`, keeping the `{base_tag}` llama.cpp\n"
            "  ABI/bindings while picking up wrapper-only native fixes. Refreshed\n"
            "  the `llamadart_llama_cpp_flutter` Apple SwiftPM checksum and\n"
            "  aligned current README/website native override docs."
        )
    else:
        entry = (
            "* Updated the default llama.cpp native runtime pin to\n"
            f"  `{repo}@{tag}`, regenerated matching Dart FFI bindings, refreshed\n"
            "  the `llamadart_llama_cpp_flutter` Apple SwiftPM checksum, and\n"
            "  aligned current README/website native override docs."
        )
    heading_match = re.search(r"(?m)^## Unreleased\s*\n+", changelog_text)
    if not heading_match:
        return f"## Unreleased\n\n{entry}\n\n{changelog_text.lstrip()}"

    body_start = heading_match.end()
    next_heading = re.search(r"(?m)^##\s+", changelog_text[body_start:])
    body_end = (
        body_start + next_heading.start() if next_heading else len(changelog_text)
    )
    body = changelog_text[body_start:body_end]
    old_entry_pattern = re.compile(
        r"^\* Updated the default llama\.cpp native runtime pin to(?:\n  .*)*\n?",
        re.MULTILINE,
    )
    existing_entry = old_entry_pattern.search(body)
    if existing_entry and f"`{repo}@{tag}`" in existing_entry.group(0):
        return changelog_text
    body = old_entry_pattern.sub("", body).lstrip()
    return (
        changelog_text[:body_start]
        + f"{entry}\n\n{body}"
        + changelog_text[body_end:]
    )


def companion_pubspec_version(pubspec_text: str, pubspec_path: Path) -> str:
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$",
        pubspec_text,
        re.MULTILINE,
    )
    if not match:
        raise ReleaseError(f"Could not read semver version from {pubspec_path}")
    return match.group(1)


def bump_patch_version(version: str) -> str:
    major, minor, patch = version.split(".")
    return f"{major}.{minor}.{int(patch) + 1}"


def replace_pubspec_version(
    pubspec_text: str,
    version: str,
    pubspec_path: Path,
) -> str:
    updated, count = re.subn(
        r"^version:\s*[0-9]+\.[0-9]+\.[0-9]+\s*$",
        f"version: {version}",
        pubspec_text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise ReleaseError(f"Could not replace version in {pubspec_path}")
    return updated


def replace_readme_dependency_version(
    readme_text: str,
    package_name: str,
    version: str,
) -> str:
    updated, count = replace_dependency_version(
        readme_text,
        package_name,
        version,
        count=1,
    )
    if count != 1:
        raise ReleaseError(f"Could not replace {package_name} README version")
    return updated


def replace_dependency_version(
    text: str,
    package_name: str,
    version: str,
    *,
    count: int = 0,
) -> tuple[str, int]:
    pattern = rf"(\s{re.escape(package_name)}:\s*\^)[0-9]+\.[0-9]+\.[0-9]+"
    return re.subn(pattern, rf"\g<1>{version}", text, count=count)


def prepend_companion_changelog_release(
    changelog_text: str,
    version: str,
    entry: str,
    repo: str,
) -> str:
    old_entry_pattern = re.compile(
        rf"^\* Updated Apple SwiftPM native pin to\s+`{re.escape(repo)}@[^`]+`\.\n?",
        re.MULTILINE,
    )
    unreleased_match = re.search(r"(?m)^## Unreleased\s*\n+", changelog_text)
    if unreleased_match:
        body_start = unreleased_match.end()
        next_heading = re.search(r"(?m)^##\s+", changelog_text[body_start:])
        body_end = (
            body_start + next_heading.start()
            if next_heading
            else len(changelog_text)
        )
        body = old_entry_pattern.sub(
            "", changelog_text[body_start:body_end]
        ).strip()
        release_body = entry if not body else f"{entry}\n\n{body}"
        remaining = (
            changelog_text[: unreleased_match.start()]
            + changelog_text[body_end:]
        ).lstrip()
        return f"## {version}\n\n{release_body}\n\n{remaining}"

    heading_match = re.search(
        rf"(?m)^## {re.escape(version)}\s*\n+",
        changelog_text,
    )
    if not heading_match:
        return f"## {version}\n\n{entry}\n\n{changelog_text.lstrip()}"

    body_start = heading_match.end()
    next_heading = re.search(r"(?m)^##\s+", changelog_text[body_start:])
    body_end = (
        body_start + next_heading.start() if next_heading else len(changelog_text)
    )
    body = old_entry_pattern.sub("", changelog_text[body_start:body_end]).strip()
    new_body = f"{entry}\n\n"
    if body:
        new_body = f"{entry}\n\n{body}\n\n"
    return changelog_text[:body_start] + new_body + changelog_text[body_end:]


def update_companion_changelog_unreleased(
    changelog_text: str,
    entry: str,
    repo: str,
) -> str:
    old_entry_pattern = re.compile(
        rf"^\* Updated Apple SwiftPM native pin to\s+`{re.escape(repo)}@[^`]+`\.\n?",
        re.MULTILINE,
    )
    heading_match = re.search(r"(?m)^## Unreleased\s*\n+", changelog_text)
    if not heading_match:
        return f"## Unreleased\n\n{entry}\n\n{changelog_text.lstrip()}"

    body_start = heading_match.end()
    next_heading = re.search(r"(?m)^##\s+", changelog_text[body_start:])
    body_end = (
        body_start + next_heading.start() if next_heading else len(changelog_text)
    )
    body = old_entry_pattern.sub("", changelog_text[body_start:body_end]).strip()
    new_body = f"{entry}\n\n"
    if body:
        new_body = f"{entry}\n\n{body}\n\n"
    return changelog_text[:body_start] + new_body + changelog_text[body_end:]


def write_github_output(values: dict[str, str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
