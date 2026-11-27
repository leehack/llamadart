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

## 0.22.0

- Add native llama.cpp sampler controls to `GenerationParams`: `frequencyPenalty`, `penaltyLastN`, `logitBias`, `typicalP`, `topNSigma`, `xtcProbability`/`xtcThreshold`, `dynatempRange`/`dynatempExponent` and `mirostat`/`mirostatTau`/`mirostatEta`. `LlamaEngineCapabilities.samplerControls` reports support; WebGPU and LiteRT-LM reject them. The example server maps `frequency_penalty`, `presence_penalty` and `logit_bias`.
- Native llama.cpp rejects non-finite or extreme `temp`, `topP`, `minP`, `penalty` and `presencePenalty` with `LlamaArgumentException` instead of aborting the process or leaving a grammar.
- Add `GenerationParams.topLogprobs` to stream per-token log-probabilities and top alternatives from native llama.cpp on chat chunks, completions and `generate()`; WebGPU, LiteRT-LM, speculative decoding and backends without `supportsTokenLogprobs` reject it.
- Aligned default WebGPU bridge assets to `v0.1.95`, so Web chat templates render the model's own BOS and EOS text and honor its add-BOS setting.
- Video-input errors now name LiteRT-LM on LiteRT-LM runtimes, and a native runtime older than `llamadart-native` v0.8.0 is reported as missing `mtmd_helper_get_capabilities` instead of as a projector without a vision encoder. `supportsVideo` stays `false`.
- On an iOS simulator, llama.cpp no longer runs on Metal: `ComputeDevice.gpu` throws `LlamaUnsupportedException` and an explicit `GpuBackend.metal` loads on the CPU with a warning, because the simulator GPU cannot run llama.cpp's Metal kernels ([#950](https://github.com/leehack/llamadart/issues/950)).
- Add `DefaultModelDownloadManager.importDownloadedFile` to verify a file downloaded by a platform background executor and move it into the model cache, with optional `expectedBytes`, SHA-256, `etag` and `lastModified`.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `a24a0fac2b60c877fd42c8eb4f34930f1a0c7cdb883b750f86a2773a72bc7a08`.

## 0.21.0

- Add `GenerationParams.ignoreEos` to keep native llama.cpp generating past end-of-generation tokens where `supportsIgnoreEos` is true. Grammars, WebGPU and LiteRT-LM reject this option.
- Cancel streamed Web GGUF loads with `ModelLoadOptions.cancelToken` or engine disposal and stop automatic retries.
- Update native LiteRT-LM to `v0.20.0` with C API 1.1.0. The loader also accepts C API 1.0.x.
- Update the chat app and Studio to `@litert-lm/core@0.20.0`. For explicit CPU loads, custom Web preloads must expose the same module's `Backend` enum as `window.LiteRtLmBackendEnum`. Web embeddings remain disabled.
- Report how to re-enable memory64 after a Web wasm32 size refusal and document that a split GGUF size hint sums every shard.
- Enable bundled MTP on LiteRT-LM WebGPU with a load-time probe and per-request opt-in.
- Reject unsupported native LiteRT-LM text LoRA adapters during model load with a typed diagnostic.
- Keep default WebGPU bridge assets at `v0.1.94` (unchanged from 0.20.8).

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `24d62c212338dda646a3b815d5883557a01b09997dee4f5b84245c5ab64fa5f6`.

