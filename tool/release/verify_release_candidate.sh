#!/usr/bin/env bash
set -euo pipefail

through="$1"
candidate="$(git rev-parse --verify "$2^{commit}")"
body="$3"
base_ref="$4"
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
core_version_pattern='^((0|[1-9][0-9]*)\.(0|[1-9][0-9]*))\.(0|[1-9][0-9]*)'
if [[ ! "$version" =~ $core_version_pattern(\+[A-Za-z0-9._-]+)?$ ]]; then
  echo "Unsupported stable core release version: $version" >&2
  exit 1
fi
line="${BASH_REMATCH[1]}"
patch="${BASH_REMATCH[4]}"
expected_base=main
if [[ "$patch" != 0 ]]; then
  expected_base="release/$line.x"
fi
if [[ "$base_ref" != "$expected_base" ]]; then
  echo "Core release $version must target $expected_base. Found $base_ref." >&2
  exit 1
fi

if [[ "$base_ref" == main ]]; then
  dart run tool/release/patch_branch.dart parity --main "$through" --require-closed-forward-ports
else
  if [[ ! "$previous" =~ $core_version_pattern$ || "${BASH_REMATCH[1]}" != "$line" ]]; then
    echo "Core release must advance to the next patch on $base_ref. Found $previous -> $version." >&2
    exit 1
  fi
  previous_patch="${BASH_REMATCH[4]}"
  # Bash arithmetic wraps out-of-range patch numbers.
  if [[ "$previous_patch" != "$((previous_patch))" || "$version" != "$line.$((previous_patch + 1))" ]]; then
    echo "Core release must advance to the next patch on $base_ref. Found $previous -> $version." >&2
    exit 1
  fi
  dart run tool/release/patch_branch.dart parity --line "$line" --branch "$through" --main refs/remotes/origin/main
fi
dart run tool/testing/check_released_changelog_sections.dart --prep "$through" "$candidate"
dart run tool/release/collect_pr_changelog.dart --version "$version" --from "v$previous" \
  --through "$through" --verify-input "$body" --candidate "$candidate" --base-ref "$base_ref"
dart run tool/testing/verify_release_docs_versions.dart --release-prep
dart run tool/testing/check_webgpu_bridge_tag.dart --release-prep "v$previous"
