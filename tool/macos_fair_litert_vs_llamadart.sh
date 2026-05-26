#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAT_APP_DIR="$ROOT_DIR/example/chat_app"
LITERT_MODEL="${LITERT_MODEL:-$ROOT_DIR/.dart_tool/litert_lm_models/gemma-4-E2B-it.litertlm}"
LLAMADART_MODEL="${LLAMADART_MODEL:-/opt/UnitySrc/personal/llama/llamadart/models/gemma-4-E2B-it-Q4_K_S.gguf}"
DECODE_TOKENS="${DECODE_TOKENS:-256}"
PROMPT="${PROMPT:-Write a detailed practical guide for product engineers who want to use on-device language models in mobile and desktop apps. Cover privacy, latency, offline behavior, personalization, battery tradeoffs, model format choices, benchmarking methodology, rollout strategy, and failure modes. Use clear paragraphs and continue until the answer is complete.}"

APP="$CHAT_APP_DIR/build/macos/Build/Products/Debug/llamadart_chat_example.app"
MODEL_IN_APP="$APP/Contents/Resources/$(basename "$LITERT_MODEL")"

echo "== llamadart / llama.cpp Metal =="
(
  cd "$ROOT_DIR"
  dart run tool/macos_llamadart_benchmark.dart \
    "$LLAMADART_MODEL" \
    "$PROMPT" \
    "$DECODE_TOKENS"
)

echo
echo "== LiteRT-LM Metal =="
(
  cd "$CHAT_APP_DIR"
  rm -rf \
    "$APP/Contents/Frameworks/LiteRtMetalAccelerator.framework" \
    "$APP/Contents/Frameworks/GemmaModelConstraintProvider.framework"

  flutter build macos --debug \
    -t lib/litert_lm_benchmark_app.dart \
    --dart-define=BENCHMARK_AUTO_RUN=true \
    --dart-define="LITERT_LM_MODEL=$MODEL_IN_APP" \
    --dart-define=LLAMADART_MODEL= \
    --dart-define=LITERT_LM_BACKEND=gpu \
    --dart-define=LITERT_LM_SPECULATIVE=false \
    --dart-define=LITERT_LM_RUNS=3 \
    --dart-define=LITERT_LM_WARMUPS=1 \
    --dart-define="LITERT_LM_OUTPUT_TOKENS=$DECODE_TOKENS" \
    --dart-define=LITERT_LM_MAX_TOKENS=4096 \
    --dart-define="LITERT_LM_PROMPT=$PROMPT"

  "$ROOT_DIR/tool/macos_litert_lm_prepare_app.sh" "$APP" >/dev/null
  cp "$LITERT_MODEL" "$MODEL_IN_APP"

  "$APP/Contents/MacOS/llamadart_chat_example" 2>&1 \
    | rg --line-buffered 'BENCHMARK: RESULT|BENCHMARK: BENCHMARK_DONE|ERROR|Failed to create engine|RegisterAccelerator'
)
