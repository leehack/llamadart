#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?usage: $0 /path/to/App.app}"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

resolve_litert_arch() {
  local arch="${LLAMADART_LITERT_LM_ARCH:-$(uname -m)}"
  case "$arch" in
    arm64 | aarch64)
      echo "arm64"
      ;;
    x64 | x86_64 | amd64)
      echo "x64"
      ;;
    *)
      echo "Unsupported LiteRT-LM macOS architecture: $arch" >&2
      exit 2
      ;;
  esac
}

LITERT_ARCH="$(resolve_litert_arch)"

required_libraries() {
  case "$LITERT_ARCH" in
    arm64)
      printf '%s\n' \
        "libGemmaModelConstraintProvider.dylib" \
        "libLiteRt.dylib" \
        "libLiteRtLm.dylib" \
        "libLiteRtMetalAccelerator.dylib" \
        "libLiteRtTopKMetalSampler.dylib" \
        "libLiteRtTopKWebGpuSampler.dylib" \
        "libLiteRtWebGpuAccelerator.dylib" \
        "libStreamProxy.dylib"
      ;;
    x64)
      printf '%s\n' \
        "libLiteRtLm.dylib" \
        "libStreamProxy.dylib"
      ;;
  esac
}

validate_litert_dir() {
  local candidate="$1"
  local mode="${2:-candidate}"
  local missing=()
  local library

  [[ -d "$candidate" ]] || return 1
  while IFS= read -r library; do
    if [[ ! -f "$candidate/$library" ]]; then
      missing+=("$library")
    fi
  done < <(required_libraries)

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "$mode" == "explicit" ]]; then
    echo "LiteRT-LM macOS $LITERT_ARCH library directory is incomplete: $candidate" >&2
    echo "Missing required runtime libraries:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 2
  fi
  return 1
}

resolve_litert_dir() {
  if [[ -n "${LLAMADART_LITERT_LM_LIB_DIR:-}" ]]; then
    validate_litert_dir "$LLAMADART_LITERT_LM_LIB_DIR" "explicit"
    echo "$LLAMADART_LITERT_LM_LIB_DIR"
    return
  fi

  local candidates=(
    "$ROOT_DIR/.dart_tool/llamadart/litert_lm/0.12.0/macos_$LITERT_ARCH"
    "$ROOT_DIR/.dart_tool/llamadart/litert_lm/0.12.0/macos/$LITERT_ARCH"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if validate_litert_dir "$candidate"; then
      echo "$candidate"
      return
    fi
  done

  echo "No complete LiteRT-LM macOS $LITERT_ARCH library directory found." >&2
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

LITERT_DIR="$(resolve_litert_dir)"

install_framework \
  "$LITERT_DIR/libLiteRtLm.dylib" \
  "LiteRtLm" \
  "LiteRtLm"

install_framework \
  "$LITERT_DIR/libStreamProxy.dylib" \
  "StreamProxy" \
  "StreamProxy"

if [[ "$LITERT_ARCH" == "arm64" ]]; then
  install_framework \
    "$LITERT_DIR/libLiteRt.dylib" \
    "LiteRt" \
    "LiteRt"

  install_framework \
    "$LITERT_DIR/libLiteRtMetalAccelerator.dylib" \
    "LiteRtMetalAccelerator" \
    "LiteRtMetalAccelerator"

  install_framework \
    "$LITERT_DIR/libGemmaModelConstraintProvider.dylib" \
    "GemmaModelConstraintProvider" \
    "GemmaModelConstraintProvider"

  install_framework \
    "$LITERT_DIR/libLiteRtTopKMetalSampler.dylib" \
    "LiteRtTopKMetalSampler" \
    "LiteRtTopKMetalSampler"

  install_framework \
    "$LITERT_DIR/libLiteRtTopKWebGpuSampler.dylib" \
    "LiteRtTopKWebGpuSampler" \
    "LiteRtTopKWebGpuSampler"

  install_framework \
    "$LITERT_DIR/libLiteRtWebGpuAccelerator.dylib" \
    "LiteRtWebGpuAccelerator" \
    "LiteRtWebGpuAccelerator"
fi

echo "Prepared LiteRT-LM macOS companion frameworks in $FRAMEWORKS_DIR"
