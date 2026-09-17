#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
CHAT_APP_DIR="$ROOT_DIR/example/chat_app"
BUILD_DIR="$CHAT_APP_DIR/build/web"
BASE_HREF="${CHAT_APP_BASE_HREF:-/}"
BUILD_TARGET="lib/main.dart"
if [[ "${1:-}" == "--validation" ]]; then
  BUILD_TARGET="lib/validation_main.dart"
  shift
  for argument in "$@"; do
    case "$argument" in --dart-define=VALIDATION_*) ;; *) echo "Unsupported validation option" >&2; exit 64 ;; esac
  done
elif [[ $# -gt 0 ]]; then
  echo "Unsupported build option: $1" >&2
  exit 64
fi

(
  cd "$CHAT_APP_DIR"
  flutter build web --release --base-href "$BASE_HREF" --target "$BUILD_TARGET" "$@"
)

WEBGPU_BRIDGE_OUT_DIR="$BUILD_DIR/webgpu_bridge" \
  "$ROOT_DIR/scripts/fetch_webgpu_bridge_assets.sh"

if [[ -n "${CHAT_APP_BUILD_SHA:-}" ]]; then
  printf '{"commit":"%s"}\n' "$CHAT_APP_BUILD_SHA" \
    > "$BUILD_DIR/llamadart-build.json"
fi

"$ROOT_DIR/scripts/validate_chat_app_web_build.sh" "$BUILD_DIR"
