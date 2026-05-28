---
title: Backend Benchmarks
description: Measured llama.cpp/GGUF and LiteRT-LM results for Gemma 4 on Android, macOS, and web.
---

This page records app-level benchmark results for choosing between
`llama.cpp` / GGUF and LiteRT-LM / `.litertlm` in `llamadart`.

These are deployment benchmarks, not pure kernel benchmarks. The artifacts are
different runtime formats:

- `gemma-4-E2B-it-Q4_K_S.gguf` for `llama.cpp`.
- `gemma-4-E2B-it.litertlm` for native LiteRT-LM.
- `gemma-4-E2B-it-web.litertlm` for LiteRT-LM web.

## Method

All runs used the same long-form prompt, `contextSize` / max context of 4096,
a target output cap of 256 tokens, one warmup run, and three measured runs. The
tables report the median of the measured runs unless noted.

The prompt asked for a practical guide covering privacy, latency, offline
behavior, personalization, battery tradeoffs, model formats, benchmarking,
rollout strategy, and failure modes.

## Results

| Device / target | Backend | Model artifact | Runtime path | Median wall tok/s | Median decode tok/s | Load / init notes |
| --- | --- | --- | --- | ---: | ---: | --- |
| Pixel 9 Pro, Android 16 | LiteRT-LM | `gemma-4-E2B-it.litertlm` | GPU | 15.18 | 15.51 | `loadMilliseconds=261`, backend init about 8.6s |
| Pixel 9 Pro, Android 16 | llama.cpp | `gemma-4-E2B-it-Q4_K_S.gguf` | Vulkan | 1.66 | 1.82 | `loadMilliseconds=8831`; process reached about 7.4 GB RSS |
| Mac, Apple M4 Max, macOS 26.5 | LiteRT-LM | `gemma-4-E2B-it.litertlm` | Metal | 130.08 | 131.90 | `loadMilliseconds=86`, backend init about 4.6s |
| Mac, Apple M4 Max, macOS 26.5 | llama.cpp | `gemma-4-E2B-it-Q4_K_S.gguf` | Metal | 136.15 | 140.48 including sampling | `loadMilliseconds=1883`; backend eval-only counter was much higher |
| Web, Chromium on Apple M4 Max | LiteRT-LM | `gemma-4-E2B-it-web.litertlm` | WebGPU | 62.70 | 64.30 | `loadMilliseconds=7730`; first token 98-129ms |
| Web, Chromium on Apple M4 Max | llama.cpp | `gemma-4-E2B-it-Q4_K_S.gguf` | WebGPU bridge | Did not complete | Did not complete | wasm model load aborted after progressing into the 72% init phase |

The Pixel 9 Pro was explicitly woken and kept awake with `svc power stayon true`.
Thermal status was 0 before the benchmark and 1 after the run, so the Android
numbers should be treated as practical app-level numbers rather than a cooled
lab baseline.

## Interpretation

On Pixel 9 Pro, LiteRT-LM GPU was about 9x faster than llama.cpp Vulkan for this
Gemma 4 E2B deployment comparison. The GGUF/Vulkan path also consumed much more
memory and pushed the device into light thermal pressure by the end of the run.

On the M4 Max, llama.cpp Metal and LiteRT-LM Metal were close for wall-clock
throughput. Use model format, feature needs, and distribution constraints as
the deciding factors on macOS rather than assuming LiteRT-LM is faster.

On web, the web-compatible LiteRT-LM Gemma 4 bundle completed successfully,
while the large Gemma 4 GGUF artifact did not complete model load in Chromium.
For browser deployments, this makes model format and artifact size an
availability constraint before it is a throughput question.

## Reproducing

macOS:

```bash
DECODE_TOKENS=256 tool/macos_fair_litert_vs_llamadart.sh
```

Web:

```bash
DOWNLOAD_LITERT_WEB_MODEL=1 \
DECODE_TOKENS=256 \
WARMUPS=1 \
RUNS=3 \
TARGETS=litert_lm \
tool/web_fair_litert_vs_llamadart.sh
```

Pixel / Android:

```bash
ADB=/path/to/adb
DEVICE=<adb-serial>
"$ADB" -s "$DEVICE" shell svc power stayon true
"$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP

DEVICE="$DEVICE" \
ADB="$ADB" \
OUTPUT_TOKENS=256 \
WARMUPS=1 \
RUNS=3 \
TARGETS=litert_lm,llamadart \
tool/litert_lm_pixel_benchmark.sh
```

For web GGUF experiments, use `TARGETS=llamadart`. Large GGUF files may fail
browser wasm memory or initialization limits even when the same file runs on
native targets.
