#!/usr/bin/env python3
"""Sync native runtime pins from published GitHub release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


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

LITERT_LM_APPLE_TARGETS = {
    "LiteRtLm": "litert-lm-native-apple-LiteRtLm-xcframework-{tag}.zip",
    "CLiteRTLM": "litert-lm-native-apple-CLiteRTLM-xcframework-{tag}.zip",
    "GemmaModelConstraintProvider": (
        "litert-lm-native-apple-GemmaModelConstraintProvider-"
        "xcframework-{tag}.zip"
    ),
    "LiteRt": "litert-lm-native-apple-LiteRt-xcframework-{tag}.zip",
    "LiteRtMetalAccelerator": (
        "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-{tag}.zip"
    ),
    "LiteRtTopKMetalSampler": (
        "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-{tag}.zip"
    ),
    "LiteRtTopKWebGpuSampler": (
        "litert-lm-native-apple-LiteRtTopKWebGpuSampler-xcframework-{tag}.zip"
    ),
    "LiteRtWebGpuAccelerator": (
        "litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-{tag}.zip"
    ),
}


class ReleaseError(RuntimeError):
    pass


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    hook_path = repo_root / args.hook_build
    llama_cpp_package_swift_path = repo_root / args.llama_cpp_package_swift
    litert_lm_package_swift_path = repo_root / args.litert_lm_package_swift

    hook_text = hook_path.read_text(encoding="utf-8")
    pending_writes: dict[Path, str] = {}

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
        resolved_llama_cpp_tag = release["tag_name"]
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
            update_companion_package_metadata(
                pending_writes,
                companion_package_root(llama_cpp_package_swift_path),
                args.llamadart_native_repo,
                resolved_llama_cpp_tag,
                bump_version=swift_text != original_swift_text,
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
        litert_version = resolved_litert_lm_tag.removeprefix("v")

        hook_text = replace_one(
            hook_text,
            r"const _litertLmVersion = '[^']+';",
            f"const _litertLmVersion = '{litert_version}';",
            "hook LiteRT-LM version",
        )
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
            swift_text = original_swift_text
            swift_text = replace_one(
                swift_text,
                r'let liteRtLmTag = "[^"]+"',
                f'let liteRtLmTag = "{resolved_litert_lm_tag}"',
                "LiteRT-LM Package.swift tag",
            )
            for target_name, asset_template in LITERT_LM_APPLE_TARGETS.items():
                checksum = release_asset_checksum(
                    release,
                    asset_template.format(tag=resolved_litert_lm_tag),
                )
                swift_text = replace_swift_binary_target_checksum(
                    swift_text,
                    target_name,
                    checksum,
                )
            pending_writes[litert_lm_package_swift_path] = swift_text
            update_companion_package_metadata(
                pending_writes,
                companion_package_root(litert_lm_package_swift_path),
                args.litert_lm_native_repo,
                resolved_litert_lm_tag,
                bump_version=swift_text != original_swift_text,
            )

        summaries.append(
            f"LiteRT-LM -> {args.litert_lm_native_repo}@{resolved_litert_lm_tag}"
        )

    if not summaries:
        print("No native release pins requested; pass a tag or latest.")
        return 0

    if args.dry_run:
        print("Dry run; no files written.")
    else:
        hook_path.write_text(hook_text, encoding="utf-8")
        for path, text in pending_writes.items():
            path.write_text(text, encoding="utf-8")

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
        "--llama-cpp-tag",
        default="keep",
        help="llamadart-native release tag, latest, or keep.",
    )
    parser.add_argument(
        "--litert-lm-tag",
        default="keep",
        help="litert-lm-native release tag, latest, or keep.",
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
    for asset in release.get("assets", []):
        if asset.get("name") != asset_name:
            continue
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            return digest.removeprefix("sha256:")
        download_url = asset.get("browser_download_url")
        if not download_url:
            raise ReleaseError(f"Asset {asset_name} has no download URL")
        return sha256_url(download_url)
    tag = release.get("tag_name", "<unknown>")
    names = ", ".join(
        sorted(str(asset.get("name", "")) for asset in release.get("assets", []))
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
    return tag


def normalize_litert_lm_release_tag(tag: str) -> str:
    tag = normalize_release_tag(tag)
    if tag in {"keep", "latest"} or tag.startswith("v"):
        return tag
    return f"v{tag}"


def replace_one(text: str, pattern: str, replacement: str, description: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace {description}")
    return updated


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
) -> None:
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
        r"The Apple SwiftPM manifest pins `[^`]+`\.",
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
    pattern = rf"(\s{re.escape(package_name)}:\s*\^)[0-9]+\.[0-9]+\.[0-9]+"
    updated, count = re.subn(pattern, rf"\g<1>{version}", readme_text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace {package_name} README version")
    return updated


def prepend_companion_changelog_release(
    changelog_text: str,
    version: str,
    entry: str,
    repo: str,
) -> str:
    old_entry_pattern = re.compile(
        rf"^\* Updated Apple SwiftPM native pin to `{re.escape(repo)}@[^`]+`\.\n?",
        re.MULTILINE,
    )
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
