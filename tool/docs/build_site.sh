#!/usr/bin/env bash
# Builds the Jaspr docs site into website/build/jaspr and fails on broken
# internal links. Needs Dart (the pinned Flutter SDK) and Node.js for npx.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEBSITE_DIR="$ROOT_DIR/website"
PAGEFIND_VERSION="1.5.2"

cd "$WEBSITE_DIR"

echo "[docs] Resolving website dependencies"
dart pub get

echo "[docs] Building Jaspr site"
dart run jaspr_cli:jaspr build

echo "[docs] Finalizing output and checking links"
dart run tool/finalize_site.dart build/jaspr

echo "[docs] Indexing search with Pagefind $PAGEFIND_VERSION"
npx --yes "pagefind@$PAGEFIND_VERSION" --site build/jaspr

echo "[docs] Site build ready: $WEBSITE_DIR/build/jaspr"
