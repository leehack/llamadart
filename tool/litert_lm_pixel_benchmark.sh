#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/example/chat_app"
APP_ID="com.example.llamadart_chat_example"
MODEL_NAME="${MODEL_NAME:-gemma-4-E2B-it.litertlm}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/$MODEL_NAME}"
LOCAL_MODEL="${LOCAL_MODEL:-$ROOT_DIR/.dart_tool/litert_lm_models/$MODEL_NAME}"
DEVICE_MODEL="${DEVICE_MODEL:-/sdcard/Android/data/$APP_ID/files/$MODEL_NAME}"
BACKEND="${BACKEND:-gpu}"
RUNS="${RUNS:-3}"
WARMUPS="${WARMUPS:-1}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-256}"
MAX_TOKENS="${MAX_TOKENS:-4096}"

ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
if [[ ! -x "$ADB" ]]; then
  echo "adb not found. Set ADB=/path/to/adb or ANDROID_HOME." >&2
  exit 2
fi

DEVICE="${DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$("$ADB" devices -l | sed -n 's/[[:space:]]device .*$//p' | head -1)"
fi
if [[ -z "$DEVICE" ]]; then
  echo "No Android device found. Set DEVICE=<adb serial> if needed." >&2
  "$ADB" devices -l
  exit 2
fi

mkdir -p "$(dirname "$LOCAL_MODEL")"
if [[ ! -f "$LOCAL_MODEL" ]]; then
  echo "Downloading $MODEL_URL"
  curl -L --fail --continue-at - "$MODEL_URL" -o "$LOCAL_MODEL"
fi

echo "Building benchmark APK for backend=$BACKEND model=$DEVICE_MODEL"
(
  cd "$APP_DIR"
  flutter build apk --debug \
    -t lib/litert_lm_benchmark_app.dart \
    --dart-define="LITERT_LM_MODEL=$DEVICE_MODEL" \
    --dart-define="LITERT_LM_BACKEND=$BACKEND" \
    --dart-define="LITERT_LM_RUNS=$RUNS" \
    --dart-define="LITERT_LM_WARMUPS=$WARMUPS" \
    --dart-define="LITERT_LM_OUTPUT_TOKENS=$OUTPUT_TOKENS" \
    --dart-define="LITERT_LM_MAX_TOKENS=$MAX_TOKENS"
)

echo "Installing APK on $DEVICE"
"$ADB" -s "$DEVICE" install -r "$APP_DIR/build/app/outputs/flutter-apk/app-debug.apk"

echo "Pushing model to $DEVICE_MODEL"
"$ADB" -s "$DEVICE" shell "mkdir -p /sdcard/Android/data/$APP_ID/files"
"$ADB" -s "$DEVICE" push "$LOCAL_MODEL" "$DEVICE_MODEL"

echo "Launching benchmark app"
"$ADB" -s "$DEVICE" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1

echo "App launched. Tap Run Benchmark on the device."
