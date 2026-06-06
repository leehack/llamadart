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

LITERT_LM_SPM_TARGETS = (
    "LiteRtLm",
    "CLiteRTLM",
    "GemmaModelConstraintProvider",
    "LiteRt",
    "LiteRtMetalAccelerator",
    "LiteRtTopKMetalSampler",
    "LiteRtTopKWebGpuSampler",
    "LiteRtWebGpuAccelerator",
)


class ReleaseError(RuntimeError):
    pass


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    hook_path = repo_root / args.hook_build
    package_swift_path = repo_root / args.package_swift

    hook_text = hook_path.read_text(encoding="utf-8")
    package_swift_text = package_swift_path.read_text(encoding="utf-8")

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
        llama_checksum = release_asset_checksum(
            release,
            f"llamadart-native-apple-xcframework-{resolved_llama_cpp_tag}.zip",
        )
        hook_text = replace_one(
            hook_text,
            r"const _llamaCppTag = '[^']+';",
            f"const _llamaCppTag = '{resolved_llama_cpp_tag}';",
            "hook llama.cpp tag",
        )
        package_swift_text = replace_one(
            package_swift_text,
            r'let llamaCppTag = "[^"]+"',
            f'let llamaCppTag = "{resolved_llama_cpp_tag}"',
            "Package.swift llama.cpp tag",
        )
        package_swift_text = replace_binary_target_checksum(
            package_swift_text,
            "llama",
            llama_checksum,
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

        package_swift_text = replace_one(
            package_swift_text,
            r'let liteRtLmTag = "[^"]+"',
            f'let liteRtLmTag = "{resolved_litert_lm_tag}"',
            "Package.swift LiteRT-LM tag",
        )
        for target in LITERT_LM_SPM_TARGETS:
            checksum = release_asset_checksum(
                release,
                f"litert-lm-native-apple-{target}-xcframework-{resolved_litert_lm_tag}.zip",
            )
            package_swift_text = replace_binary_target_checksum(
                package_swift_text,
                target,
                checksum,
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
        package_swift_path.write_text(package_swift_text, encoding="utf-8")

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
            "Update hook/build.dart and darwin/llamadart/Package.swift from "
            "published native release asset checksums."
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
        "--package-swift",
        default="darwin/llamadart/Package.swift",
        help="Path to Package.swift relative to repo root.",
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


def replace_binary_target_checksum(text: str, target: str, checksum: str) -> str:
    pattern = re.compile(
        rf'(nativeRepoBinaryTarget\(\s*name: "{re.escape(target)}",.*?'
        rf'checksum: ")[0-9a-f]+(")',
        re.DOTALL,
    )
    updated, count = pattern.subn(rf"\g<1>{checksum}\2", text, count=1)
    if count != 1:
        raise ReleaseError(f"Could not replace Package.swift checksum for {target}")
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
