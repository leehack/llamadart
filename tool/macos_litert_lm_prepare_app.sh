#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?usage: $0 /path/to/App.app}"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

resolve_litert_dir() {
  if [[ -n "${LLAMADART_LITERT_LM_LIB_DIR:-}" ]]; then
    echo "$LLAMADART_LITERT_LM_LIB_DIR"
    return
  fi

  local candidates=(
    "$ROOT_DIR/.dart_tool/llamadart/litert_lm_poc/0.12.0/macos_arm64"
    "$ROOT_DIR/.dart_tool/llamadart/litert_lm_poc/0.12.0/macos/arm64"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/libLiteRtLm.dylib" && -f "$candidate/libStreamProxy.dylib" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "No low-level-compatible LiteRT-LM macOS library directory found." >&2
  exit 2
}

install_framework() {
  local source_path="$1"
  local framework_name="$2"
  local binary_name="$3"
  local framework_dir="$FRAMEWORKS_DIR/$framework_name.framework"
  local version_dir="$framework_dir/Versions/A"
  local resources_dir="$version_dir/Resources"

  rm -rf "$framework_dir"
  mkdir -p "$resources_dir"
  cp "$source_path" "$version_dir/$binary_name"
  chmod +x "$version_dir/$binary_name"
  ln -s A "$framework_dir/Versions/Current"
  ln -s Versions/Current/Resources "$framework_dir/Resources"
  ln -s "Versions/Current/$binary_name" "$framework_dir/$binary_name"
  cat > "$resources_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$binary_name</string>
  <key>CFBundleIdentifier</key>
  <string>com.llamadart.litertlm.$framework_name</string>
  <key>CFBundleName</key>
  <string>$framework_name</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
EOF
}

install_framework_if_exists() {
  local source_path="$1"
  local framework_name="$2"
  local binary_name="$3"
  if [[ -f "$source_path" ]]; then
    install_framework "$source_path" "$framework_name" "$binary_name"
  fi
}

LITERT_DIR="$(resolve_litert_dir)"
if [[ -f "$LITERT_DIR/libStreamProxy.dylib" ]]; then
  STREAM_PROXY_LIB="$LITERT_DIR/libStreamProxy.dylib"
else
  echo "No LiteRT-LM stream proxy library found in $LITERT_DIR." >&2
  exit 2
fi

install_framework \
  "$LITERT_DIR/libLiteRtLm.dylib" \
  "LiteRtLm" \
  "LiteRtLm"

install_framework \
  "$STREAM_PROXY_LIB" \
  "StreamProxy" \
  "StreamProxy"

install_framework_if_exists \
  "$LITERT_DIR/libLiteRt.dylib" \
  "LiteRt" \
  "LiteRt"

install_framework_if_exists \
  "$LITERT_DIR/libLiteRtMetalAccelerator.dylib" \
  "LiteRtMetalAccelerator" \
  "LiteRtMetalAccelerator"

install_framework_if_exists \
  "$LITERT_DIR/libGemmaModelConstraintProvider.dylib" \
  "GemmaModelConstraintProvider" \
  "GemmaModelConstraintProvider"

install_framework_if_exists \
  "$LITERT_DIR/libLiteRtTopKMetalSampler.dylib" \
  "LiteRtTopKMetalSampler" \
  "LiteRtTopKMetalSampler"

echo "Prepared LiteRT-LM macOS companion frameworks in $FRAMEWORKS_DIR"
