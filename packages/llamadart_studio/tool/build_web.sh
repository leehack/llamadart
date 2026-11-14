#!/usr/bin/env bash
set -euo pipefail

STUDIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$STUDIO_DIR/../.." && pwd)"
BUILD_DIR="$STUDIO_DIR/build/web"
BRIDGE_TAG="$(sed -nE "s/^[[:space:]]*const defaultBridgeAssetsTag = '([^']+)';.*$/\\1/p" "$STUDIO_DIR/web/index.html")"
if [[ -z "$BRIDGE_TAG" ]]; then
  echo 'Studio bootstrap is missing its bridge asset pin.' >&2
  exit 1
fi

(
  cd "$STUDIO_DIR"
  flutter build web --release "$@"
)
WEBGPU_BRIDGE_ASSETS_TAG="$BRIDGE_TAG" \
  WEBGPU_BRIDGE_OUT_DIR="$BUILD_DIR/webgpu_bridge" \
  "$ROOT_DIR/scripts/fetch_webgpu_bridge_assets.sh"
"$ROOT_DIR/scripts/validate_chat_app_web_build.sh" "$BUILD_DIR"
