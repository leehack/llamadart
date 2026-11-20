#!/usr/bin/env bash
set -euo pipefail

through="$1"
candidate="$(git rev-parse --verify "$2^{commit}")"
body="$3"
if [[ "$(git rev-parse HEAD)" != "$candidate" ]]; then
  echo "Release candidate must be checked out." >&2
  exit 1
fi
if [[ "$(git rev-parse "$candidate^1")" != "$through" ]]; then
  echo "Release candidate must have the verified through commit as its first parent." >&2
  exit 1
fi

previous="$(git show "$through:pubspec.yaml" | awk '/^version:[[:space:]]+/ {print $2}')"
version="$(awk '/^version:[[:space:]]+/ {print $2}' pubspec.yaml)"
dart run tool/testing/check_released_changelog_sections.dart --prep "$through" "$candidate"
dart run tool/release/collect_pr_changelog.dart --version "$version" --from "v$previous" \
  --through "$through" --verify-input "$body" --candidate "$candidate"
dart run tool/testing/verify_release_docs_versions.dart --release-prep
dart run tool/testing/check_webgpu_bridge_tag.dart --release-prep "v$previous"
