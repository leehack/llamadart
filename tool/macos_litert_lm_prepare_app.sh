#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?usage: $0 /path/to/App.app}"
LITERT_DIR="${LLAMADART_LITERT_LM_LIB_DIR:-$ROOT_DIR/.dart_tool/llamadart/litert_lm_poc/0.12.0/macos_arm64}"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

install_framework() {
  local source_path="$1"
  local framework_name="$2"
  local binary_name="$3"
  local framework_dir="$FRAMEWORKS_DIR/$framework_name.framework"

  mkdir -p "$framework_dir"
  cp "$source_path" "$framework_dir/$binary_name"
  chmod +x "$framework_dir/$binary_name"
  cat > "$framework_dir/Info.plist" <<EOF
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

install_framework \
  "$LITERT_DIR/libLiteRtMetalAccelerator.dylib" \
  "LiteRtMetalAccelerator" \
  "LiteRtMetalAccelerator"

install_framework \
  "$LITERT_DIR/libGemmaModelConstraintProvider.dylib" \
  "GemmaModelConstraintProvider" \
  "GemmaModelConstraintProvider"

echo "Prepared LiteRT-LM macOS companion frameworks in $FRAMEWORKS_DIR"
