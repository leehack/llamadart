---
title: Recent releases
description: Release notes for the current and previous llamadart minor, with a link to the full changelog for older releases.
---

This page keeps the current and previous minor
releases. Notes for every older release are in
[`CHANGELOG.md`](https://github.com/leehack/llamadart/blob/main/CHANGELOG.md).

For upgrade planning, combine this page with the
[Upgrade Checklist](../migration/upgrade-checklist). For breaking changes,
validate against the exact release tag notes.

## 0.23.0

- Add `GenerationParams.dryMultiplier`, `dryBase`, `dryAllowedLength`, `dryPenaltyLastN` and `drySequenceBreakers` (DRY repetition penalty) for native llama.cpp, reported by `LlamaEngineCapabilities.samplerControls`; WebGPU and LiteRT-LM reject them. Native llama.cpp rejects a `dryAllowedLength` at or above the DRY window (capped at the context size) and settings that can exhaust a token allow-list with `LlamaArgumentException`, and a failure inside DRY sampler setup becomes `LlamaInferenceException` instead of ending the process (`llamadart-native` v1.1.0-1 and later).
- Add `LlamaEngine.setModelFromFileDescriptor` to load a single-file GGUF from an open file descriptor without a copy (Android document grants, user-picked iOS/macOS files); it throws `LlamaUnsupportedException` on Windows, the Web, LiteRT-LM and native runtimes older than `llamadart-native` v1.1.0-1.
- Adopt `llamadart-native` v1.1.0-1 (llama.cpp v1.1.0). Native runtime overrides must now be built from llama.cpp v1.1.0; v1.0.0 builds throw `LlamaUnsupportedException`. On Linux x64, the HIP backend needs ROCm 6.3 or newer.
- Aligned default WebGPU bridge assets to `v0.1.96`, which embeds llama.cpp v1.1.0.
- Block llama.cpp GPU loads on Android when a Qualcomm proprietary Vulkan device is registered: `ComputeDevice.gpu` throws `LlamaUnsupportedException` and automatic GPU attempts fall back to CPU with a warning.
- Unsupported sampler errors now name the tuning fields to reset after disabling XTC, dynamic temperature, or Mirostat.
- Show backend-reported per-request token counts and timings in the example chat app.

Runtime baseline: native llama.cpp `v1.1.0-1` and Web use upstream `v1.1.0@171527522610996f5f0acf12334e185156ca8f44`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `0cafdc729d985d61407f66b07c99c53ac935bef4572c9d596c2a3704c21b68c0`.

## 0.22.0

- Add native llama.cpp sampler controls to `GenerationParams`: `frequencyPenalty`, `penaltyLastN`, `logitBias`, `typicalP`, `topNSigma`, `xtcProbability`/`xtcThreshold`, `dynatempRange`/`dynatempExponent` and `mirostat`/`mirostatTau`/`mirostatEta`. `LlamaEngineCapabilities.samplerControls` reports support; WebGPU and LiteRT-LM reject them. The example server maps `frequency_penalty`, `presence_penalty` and `logit_bias`.
- Native llama.cpp rejects non-finite or extreme `temp`, `topP`, `minP`, `penalty` and `presencePenalty` with `LlamaArgumentException` instead of aborting the process or leaving a grammar.
- Add `GenerationParams.topLogprobs` to stream per-token log-probabilities and top alternatives from native llama.cpp on chat chunks, completions and `generate()`; WebGPU, LiteRT-LM, speculative decoding and backends without `supportsTokenLogprobs` reject it.
- Aligned default WebGPU bridge assets to `v0.1.95`, so Web chat templates render the model's own BOS and EOS text and honor its add-BOS setting.
- Video-input errors now name LiteRT-LM on LiteRT-LM runtimes, and a native runtime older than `llamadart-native` v0.8.0 is reported as missing `mtmd_helper_get_capabilities` instead of as a projector without a vision encoder. `supportsVideo` stays `false`.
- On an iOS simulator, llama.cpp no longer runs on Metal: `ComputeDevice.gpu` throws `LlamaUnsupportedException` and an explicit `GpuBackend.metal` loads on the CPU with a warning, because the simulator GPU cannot run llama.cpp's Metal kernels ([#950](https://github.com/leehack/llamadart/issues/950)).
- Add `DefaultModelDownloadManager.importDownloadedFile` to verify a file downloaded by a platform background executor and move it into the model cache, with optional `expectedBytes`, SHA-256, `etag` and `lastModified`.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `a24a0fac2b60c877fd42c8eb4f34930f1a0c7cdb883b750f86a2773a72bc7a08`.

