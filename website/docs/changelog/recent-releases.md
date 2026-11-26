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

## 0.21.2

- Keep default WebGPU bridge assets at `v0.1.94` (unchanged from 0.21.0).

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `24d62c212338dda646a3b815d5883557a01b09997dee4f5b84245c5ab64fa5f6`.

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

## 0.20.8

- Aligned default WebGPU bridge assets to `v0.1.94` to reduce GGUF loading memory with improved JavaScript-backed staging and bounded WebGPU weight uploads.
- Default to JavaScript-backed GGUF and projector staging on supported Chromium memory64 loads with size hints up to 4 GiB. On wasm32 single-thread cores, automatically stage GGUFs with hints above 960 MiB through 3.75 GiB and reject larger hints before downloading when automatic staging applies.
- Add multi-turn chat, a model picker, generation settings, and streaming stats to the DartPad GGUF example. Improve download feedback and error recovery.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-7` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `24d62c212338dda646a3b815d5883557a01b09997dee4f5b84245c5ab64fa5f6`.

## 0.20.7

- Bundle the Visual C++ runtime DLLs with Windows image generation.
- Aligned default WebGPU bridge assets to `v0.1.93` on jsDelivr's npm route. Web pages without cross-origin isolation or usable SharedArrayBuffer now select the single-thread GGUF core automatically. Set `window.__llamadartBridgeAllowSingleThreadCore = false` to opt out.
- Stream text from Stories15M GGUF in the new DartPad Preview example.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-7` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `d6200d9f467b20a942f4a77ff7041d98815ecb16acecd5176040b503f3544f95`.

## 0.20.6

- Aligned default WebGPU bridge assets to `v0.1.92` and added `ModelParams.jsBackedModelStaging` to control JS-backed Web GGUF and projector staging when the bridge supports it.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-7` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `4f2fb82d55a932e9182e703d5265f3fc5875f808d4d9aa0ba18a0585d0d7784b`.

## 0.20.5

- Recognize committed WebKit model cache entries across cache formats and reuse cached projectors in the Web backend and chat app.
- Throw `LlamaModelUnloadedException` when a Web request needs a fresh model load after a core abort.
- Aligned default WebGPU bridge assets to `v0.1.90` to use the correct model URL for fetch-backed loads and prevent repeated loads from stalling.
- Fix intermittent duplicate tokens and wrong arithmetic in LiteRT-LM text generation on macOS Metal (#2134).

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-7` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `c247b099018f55472dc83e561f0105a83f4ce03aa153d32365a07b34cde129f1`.

## 0.20.4

- Use the corrected Qwen3-0.6B LiteRT-LM bundle in GPU and automatic validation profiles so split emoji tokens decode correctly (#554).
- End the thinking budget when a thinking-capable Qwen3-Coder XML template starts a tool call, so a forced closing tag cannot interrupt the call (#1949).
- Fix drift and prompt echoes when reusing a LiteRT-LM engine for independent Qwen3.5 requests on macOS CPU or Metal (#672).
- Aligned default WebGPU bridge assets to `v0.1.87`.

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-6` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `922574bd6389f9ec8ce1ba41d291ba80b1d9f50906f860e8c74f7a9997c0edf9`.

## 0.20.3

- Reduce known Qwen3-ASR instruction echoes in windowed partials and finals. Keep the original wording with changing voiced speech or audio-only agreement within one word edit. Quiet or misrecognized dictation can be dropped, with an empty-transcript error if no text survives ([#2088](https://github.com/leehack/llamadart/issues/2088)).
- Keep Gemma 4 undeclared calls and fenced or inline-backtick JSON as text, recover only valid standalone function calls to declared tools, and preserve prose when calls are recovered or superseded by native calls. Strip stray call delimiters after recovery and release non-matching streamed text once the tool name is known ([#2081](https://github.com/leehack/llamadart/issues/2081), [#2095](https://github.com/leehack/llamadart/issues/2095)).
- Clarify which speech-to-text modes emit partial transcripts and when to split whole-file Qwen3-ASR recordings.
- Keep default WebGPU bridge assets at `v0.1.86` (unchanged from 0.20.2).

Runtime baseline: native llama.cpp `v1.0.0-3` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-5` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `d589fbe3c334e4fcb0ccbac3efc4500209358a010b6662ee8523e598a433a0f2`.

## 0.20.2

- Adopt `llamadart-native@v1.0.0-3` for the Windows Visual C++ runtime and GPU memory fit fixes, plus native speech cancellation and text handling fixes ([#2087](https://github.com/leehack/llamadart/pull/2087)).
- Add opt-in `Qwen3WindowedAsrAdapter` and expose `SpeechToTextInputMode` via `SpeechToTextCapabilities.inputMode` for bounded native Qwen3-ASR live PCM. It emits replaceable partials at 2, 4 and 6 seconds, commits at quiet boundaries or 8 seconds, and reduces false transcripts from quiet noise. Web, `SpeechToTextEngine.attach` and non-`qwen3a` projectors throw `LlamaUnsupportedException` ([#327](https://github.com/leehack/llamadart/issues/327), [#2079](https://github.com/leehack/llamadart/issues/2079)).
- Document measured `LlamaCppLiveAsrAdapter` throughput on two-thread Linux and Windows x64 CPUs. LFM3-Audio kept up with live input and Voxtral Realtime took about four times the audio duration ([#327](https://github.com/leehack/llamadart/issues/327)).
- Document `-` for stdin in the live ASR example and report the required PCM format when input ends mid-sample.
- Report Vulkan and apply Android Vulkan context settings and prompt limits when an OpenCL preference falls back to a filtered list of Vulkan devices ([#2020](https://github.com/leehack/llamadart/issues/2020)).
- Keep Gemma 4 reply text and later valid tool calls when a malformed call has an unclosed string delimiter ([#2042](https://github.com/leehack/llamadart/pull/2042)).
- Preserve Gemma 4 prose before loose JSON tool calls in streamed and final replies, and keep MiniMax M3 quoted tool markup and literal thinking tags visible across token splits ([#1930](https://github.com/leehack/llamadart/issues/1930)).
- Preserve partial LFM2 end-marker text such as `<|` in the last plain string argument when the model omits its closing quote ([#1988](https://github.com/leehack/llamadart/pull/1988)).
- Clarify that a thinking budget keeps forced-open Granite required-call grammars applied and pauses Ling 3 required-call grammars ([#1965](https://github.com/leehack/llamadart/pull/1965)).
- Throw `LlamaUnsupportedException` when the loaded WebGPU assets lack `presencePenalty` support ([#1965](https://github.com/leehack/llamadart/pull/1965)).
- Streamed text-to-speech chunks now report the sample rate and channel count of the actual native PCM ([#2048](https://github.com/leehack/llamadart/issues/2048)).
- Document the Windows system commit limit for very large llama.cpp contexts and advise keeping a system-managed pagefile with adequate disk space or reducing `contextSize` ([llamadart-native#211](https://github.com/leehack/llamadart-native/issues/211)).
- Keep default WebGPU bridge assets at `v0.1.86` (unchanged from 0.20.1).

Runtime baseline: native llama.cpp `v1.0.0-3` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-5` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `d589fbe3c334e4fcb0ccbac3efc4500209358a010b6662ee8523e598a433a0f2`.

## 0.20.1

- Adopt `leehack/llamadart-native@v1.0.0-2` (llama.cpp `v1.0.0`, `b1b770d9`): Windows CUDA `ModelParams.gpuMemoryFit` now accounts for VRAM held by other processes, matching Vulkan, and refuses TCC or `GGML_CUDA_DEVICES` virtual devices with `LlamaGpuMemoryFitException` when system-wide free memory cannot be read; Apple apps may still pair `llamadart_llama_cpp_flutter` `0.20.0` (`v1.0.0-1`) with an upgrade warning ([#2034](https://github.com/leehack/llamadart/issues/2034), [llamadart-native#206](https://github.com/leehack/llamadart-native/issues/206)).
- Add `LlamaCppLiveAsrAdapter` for native incremental live PCM speech recognition (`SpeechToTextEngine.startStream()`, `transcribe`, `transcribeOnce` with mono 16 kHz `pcm-f32le`) on Voxtral Realtime and LFM3-Audio GGUF models with their audio projectors (`llamadart-native@v1.0.0-1`; Web and older runtimes throw `LlamaUnsupportedException`), and expose `SpeechToTextCapabilities.streamingInputUnsupportedReason` ([#327](https://github.com/leehack/llamadart/issues/327)).
- Fixed a race when multiple processes first access the same model cache entry concurrently ([#2028](https://github.com/leehack/llamadart/issues/2028)).
- Keep default WebGPU bridge assets at `v0.1.86` (unchanged from 0.20.0).

Runtime baseline: native llama.cpp `v1.0.0-2` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-5` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `d589fbe3c334e4fcb0ccbac3efc4500209358a010b6662ee8523e598a433a0f2`.

## 0.20.0

- Adopt `leehack/llamadart-native@v1.0.0-1` (llama.cpp `v1.0.0`, `b1b770d9`) with regenerated bindings, `mtmd_helper_get_capabilities` video probing and the `v0.9.0` ARM FP16 fixes. Native runtimes not built from llama.cpp `v1.0.0`, including `llamadart_native_tag` or `llamadart_native_path` overrides, now throw `LlamaUnsupportedException` before a model loads.
- Aligned default WebGPU bridge assets to `v0.1.86` (llama.cpp `v1.0.0`, matching the native runtime) ([#2024](https://github.com/leehack/llamadart/issues/2024)).
- Update native image generation to `stable-diffusion-native@v0.4.0`. Apple apps using image generation must upgrade the core and Stable Diffusion companion together. FLUX.1 Kontext reference editing now reports `supportsReferenceImageEditing` false and throws `LlamaUnsupportedException` on this runtime until it is requalified ([#1222](https://github.com/leehack/llamadart/issues/1222)).
- Add experimental streamed text-to-speech: `TextToSpeechRequest.streamAudio` emits `TextToSpeechAudioChunkEvent` PCM chunks on `TextToSpeechTask.events` before the final event for Qwen3-TTS, LFM3-Audio and Pocket TTS on native, gated by `TextToSpeechCapabilities.supportsIncrementalAudio` (needs `llamadart-native@v1.0.0-1`; Soprano, Chatterbox, Web, and capabilities without a positive sample rate or channel count report `supportsIncrementalAudio` false and throw `LlamaUnsupportedException` instead of emitting 0 Hz chunks). The new sealed event subtype means an exhaustive `switch` over `TextToSpeechEvent` needs a case ([#2036](https://github.com/leehack/llamadart/issues/2036), [#2023](https://github.com/leehack/llamadart/issues/2023)).
- Add opt-in `ModelParams.gpuMemoryFit`: Linux and Windows llama.cpp GPU loads offload only the layers that fit free GPU memory, or fall back to CPU, and report the result through `LlamaEngine.getGpuMemoryFitReport()`. Requires `llamadart-native` `v1.0.0` or later (`v1.0.0-1` on Windows; Windows CUDA free-memory excludes other processes, so prefer Vulkan there) ([#2034](https://github.com/leehack/llamadart/issues/2034)).
- Fixed Gemma 4 tool-call parsing dropping or corrupting `<|"|>`-delimited string arguments containing raw newlines, `"` or backslashes; delimited text is now taken verbatim, as in llama.cpp ([#2041](https://github.com/leehack/llamadart/issues/2041)).
- Restore native text-to-speech discovery when Dart bundles its runtime outside the working directory.
- Avoid initializing unavailable Linux Vulkan backends during llama.cpp automatic loading and device probes while retaining other bundled backends, and add an opt-in Linux Vulkan loader preflight for native hosts.
- Speed up model checksum verification on Apple platforms and keep verification off the UI isolate.
- Pair all three Apple runtime companions at `0.20.0` with matching native binaries.

Runtime baseline: native llama.cpp `v1.0.0-1` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.19.1-5` and stable-diffusion uses `v0.4.0`. Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `d589fbe3c334e4fcb0ccbac3efc4500209358a010b6662ee8523e598a433a0f2`.

