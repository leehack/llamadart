---
title: Platform and backend support matrix
sidebar_label: Support matrix
description: Check which runtimes, backends and features llamadart supports on each platform, the known limitations, and the pinned runtime versions.
---

Use this page to check whether a runtime or feature works on a platform.
`LlamaBackend()` picks the runtime from the model format: LiteRT-LM bundles run
on LiteRT-LM, and GGUF files run on llama.cpp natively or on the WebGPU bridge
in a browser. Native targets read the file header; web targets use the URL's
extension or `ModelSource.format`
([How routing works](../guides/backend-selection#how-routing-works)). To choose backend modules or leave a
runtime out of the app, see [Native runtime configuration](./native-build-hooks).

All five public engine types share `LlamadartEngine<C extends EngineCapabilities>`
for capability inspection and final disposal. This lifecycle interface does not
change the runtime support below; see [engine ownership](../guides/model-lifecycle#shared-engine-ownership).

Eager `createTask` / `generateTask` handles wrap the same native and Web text
paths, with request-scoped subscription cancellation and observable terminal
outcomes. They add no model/backend capability; see [task ownership](../guides/generation-and-streaming#eager-task-handles).

## At a glance

Desktop source-CLI diagnostics can opt into
`dart run llamadart:doctor_native --runtime llama_cpp --json` (or
`litert_lm` / `stable_diffusion`) to check a declared artifact in an isolated
process. It checks selected symbols/static ABI markers, without device or model
initialization. This adds no runtime/platform/model capability: production loader
behavior, loaded release identity, emitted app assets and GPU/inference remain
unchecked. See [scope and limits](./diagnose-setup#isolated-native-check).

| Platform | GGUF backends | LiteRT-LM backends | Minimum OS | Speech to text | Text to speech | Decision models | Image generation (Preview) | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Android (arm64, x64) | CPU; Vulkan experimental, device-dependent; OpenCL opt-in | CPU, GPU, NPU | Not set by llamadart | Qwen3-ASR (GGUF); LiteRT-LM ASR | Qwen3-TTS; LFM3-Audio, Soprano, Chatterbox, Pocket TTS | Untested | arm64 CPU; validated on Pixel 9 Pro, Galaxy S24 and A53 | Supported |
| iOS (arm64, arm64 simulator, x86_64 simulator) | CPU, Metal; on a simulator Metal returns incorrect output and `auto` uses the CPU ([#950](https://github.com/leehack/llamadart/issues/950)) | CPU, GPU; none on the x86_64 simulator | iOS 16.4 deployment target; LiteRT-LM run on a device only on iOS 18.3.2 | Qwen3-ASR (GGUF); LiteRT-LM ASR | Qwen3-TTS; LFM3-Audio, Soprano, Chatterbox, Pocket TTS | Untested | Metal, iOS 16.4; validated on iPhone 16 Pro and SE 3; `vaeDirectConvolution: true` throws on Metal ([#1044](https://github.com/leehack/llamadart/issues/1044)) | Supported |
| macOS (arm64, x86_64) | CPU, Metal; on x86_64, Rosetta included, `auto` uses the CPU because Metal returns garbled output on Intel Macs with AMD GPUs ([#1597](https://github.com/leehack/llamadart/issues/1597)) | arm64: CPU, GPU; x86_64: none ([litert-lm-native#72](https://github.com/leehack/litert-lm-native/issues/72)) | macOS 14.0 (Flutter) | Qwen3-ASR (GGUF); LiteRT-LM ASR | Qwen3-TTS; LFM3-Audio, Soprano, Chatterbox, Pocket TTS | Validated on Metal and CPU | Metal, macOS 13.3; validated on arm64 | Supported |
| Linux (arm64, x64) | CPU, Vulkan; BLAS opt-in; x64: CUDA, HIP opt-in | arm64: CPU; x64: CPU, explicit GPU | Not set by llamadart | Qwen3-ASR (GGUF); LiteRT-LM ASR | Qwen3-TTS; LFM3-Audio, Soprano, Chatterbox, Pocket TTS | Untested | CPU or Vulkan; x64 needs AVX2; validated on x64 (CPU, NVIDIA L4) | Supported |
| Windows (arm64, x64) | CPU, Vulkan; BLAS opt-in; x64: CUDA opt-in | x64: CPU, explicit GPU (Qwen3-0.6B and Gemma 4 E2B run on an NVIDIA L4 over Direct3D 12, GRID 596.86, runtime `v0.19.1-5`; [details](./known-platform-issues#linux-and-windows)); arm64: none | Not set by llamadart | Qwen3-ASR (GGUF); LiteRT-LM ASR on x64 | Qwen3-TTS; LFM3-Audio, Soprano, Chatterbox, Pocket TTS | Untested | x64 CPU or Vulkan, needs AVX2 and the Visual C++ runtime; validated on Windows Server 2022 (CPU, NVIDIA L4) | Supported |
| Web | WebGPU, WebAssembly CPU | CPU, GPU through `@litert-lm/core` | Chrome 128, Firefox 129, Safari 17.4 (llama.cpp measured on Safari 27, Firefox 160 and Linux NVIDIA Chrome 157: [known issues](./known-platform-issues#vulkan-and-the-web); needs `require-corp` isolation; LiteRT-LM GPU text, history and chat app checked in Safari 27 on Apple silicon with `@litert-lm/core@0.19.0`; CPU [differs](./known-platform-issues#vulkan-and-the-web), [#1802](https://github.com/leehack/llamadart/issues/1802)) | Qwen3-ASR, WAV, MP3 or FLAC bytes | Qwen3-TTS, memory64 | Checked in headless Chromium on macOS | Not yet ([#969](https://github.com/leehack/llamadart/issues/969)) | Experimental |

On Windows, the llama.cpp and LiteRT-LM bundles ship the Visual C++ runtime
DLLs they need, so they need no Visual C++ Redistributable. The opt-in
`stable_diffusion` runtime does not ship them: machines that run it need the
latest Microsoft Visual C++ v14 Redistributable (x64), which stock Windows
Server lacks, and its load error names the DLLs that failed to load.

Streamed text-to-speech PCM (`TextToSpeechRequest.streamAudio`) is native only
and needs llamadart-native `v1.0.0-1`: Qwen3-TTS, LFM3-Audio and Pocket TTS
stream, Soprano and Chatterbox do not, and Web refuses
([details](../guides/text-to-speech#streaming-audio)).

With the pinned bridge assets, Web speech-to-text and text-to-speech
cancellation is request-scoped, including queued STT generation and TTS startup
awaiting a capability probe.

Speech to text, text to speech and decision models are experimental. Image
generation is a Preview: its API is experimental and may change, and it needs
the opt-in `stable_diffusion` runtime. Native hosts can opt into the Linux
Vulkan loader preflight from `backend.dart` before runtime initialization. It
checks instance creation and a nonempty device list, including software devices;
it does not qualify GPU suitability or Linux image inference and is not run
automatically by `ImageGenerationEngine`. CPU-only builds need no preflight.
Studio runs this preflight before probing and loading its default Linux Vulkan
image runtime and disables Image Studio with the returned reason.
The table’s phone, Linux and Windows image-generation measurements predate v0.4.0.
Per-platform requirements, validated
models, memory figures and the bounded recipes for tiling, editing, ControlNet,
hires fix, reference editing, seamless textures, module placement, the
conditioning cache, FP8 weights and local checkpoint sets are in
[Image generation](../guides/image-generation#support). On iOS, the pinned
`v0.4.0` runtime splits Metal graphs, so full-VAE decoding is admitted;
device qualification on v0.4.0 is pending. Earlier runtimes decoded SD-Turbo with its embedded full VAE at 512×512 on iPhone
16 Pro and iPhone 17 Pro ([#1047](https://github.com/leehack/llamadart/issues/1047)).
External VAE/TAESD components, SDXL-size VAEs, larger resolutions and SDXS
through `sd_dart_new_sd_ctx` are not device-qualified, and a Metal
command-buffer failure surfaces as an error. A runtime without
the split refuses full-VAE Metal decoding; it then needs an intrinsic SDXS tiny
decoder and the intrinsic tiny-decoder v1 context policy, or
`ImageModelPlacement(vaeOnCpu: true)` or `ComputeDevice.cpu`. On iOS 26,
disposing an image model returns its memory at once with `v0.3.0-5`; earlier
runtimes could keep about 2 GB resident, so a later load failed the memory check
(fixed in runtime `v0.3.0-5`, measured on iPhone 17 Pro; iPhone 16 Pro retained memory above baseline,
[#2004](https://github.com/leehack/llamadart/issues/2004)).

GGUF Qwen3-ASR accepts WAV, MP3 and FLAC; real-model checks cover all three on
native macOS and in headless Chromium. Opt-in windowed live PCM for Qwen3-ASR
(`Qwen3WindowedAsrAdapter`) is native-only, requires a verified `qwen3a`
projector via `SpeechToTextEngine.load`, and re-decodes 2/4/6 s uncommitted
prefixes in a bounded 8 s ring. The first window commits after 8 s of audio
plus inference, and later full windows need 6.05–8 s of new audio plus inference.
Quiet intervals with a nonempty decode may take a second inference pass,
including when `finish()` flushes remaining audio. Windows join with `\n`, and
`maxOutputTokens` applies per decode (`1024` in `startStream`). Continuous
speech or background noise can force an 8 s hard cut and split words.
Evidence so far covers only English on macOS arm64 CPU. Native llama.cpp
live PCM streaming
(`LlamaCppLiveAsrAdapter` on Voxtral Realtime and LFM3-Audio) is native-only
and requires `llamadart-native@v1.0.0-1`+; Web throws `LlamaUnsupportedException`
before model download. LiteRT-LM ASR is CPU-only streaming recognition. Decision models run on llama.cpp and WebGPU only; on LiteRT-LM
`DecisionEngine.load` and `attach` throw `LlamaUnsupportedException`. See
[Speech to text](../guides/speech-to-text#choose-an-approach),
[Text to speech](../guides/text-to-speech) and
[Decision models](../guides/decision-models). Decision tasks stop preflight or
discard an already-dispatched answer after the backend finishes; they do not
add native interruption or support on LiteRT-LM.

Native Android Vulkan Qwen3.5 supports the same features as other models with
the bundled runtime; on GPUs with a subgroup size below 32 other than 8 its
image encoder runs on the CPU. A llama.cpp runtime older than ggml `0.28.0`
(llamadart-native `v0.8.0`) restricts it to ordinary text on GPUs with a
subgroup size below 32 other than 8. See
[the exact predicate and evidence](./known-platform-issues#android).

## Compute device

`ModelParams.device` (`ComputeDevice`) applies to every runtime. `auto` keeps
each runtime's default; `cpu`, `gpu` and `npu` run there or throw
`LlamaUnsupportedException`, never on another device. See
[Choosing the device](../guides/backend-selection#choosing-the-device).

| Runtime | `auto` | `gpu` | `npu` |
| --- | --- | --- | --- |
| Native llama.cpp | Best GPU backend that loads, all layers; CPU without a GPU module or device, on Android and on an iOS simulator | Needs a GPU module and device; Vulkan on Android (experimental); Metal on an iOS simulator, where its output is incorrect | Throws |
| WebGPU (llama.cpp) | WebGPU when available, else the WebAssembly CPU runtime | Needs a WebGPU adapter and GPU layers after load; no CPU retry | Throws |
| Native LiteRT-LM | GPU on Android, iOS and macOS; CPU on Linux and Windows; a GPU engine that fails to start retries on the CPU with a warning | GPU backend on Android, iOS, macOS arm64, Linux x64 (Vulkan) and Windows x64 (Direct3D 12); a delegate that fails to start throws on first use | Android only |
| LiteRT-LM Web | WebGPU, without a probe | Needs a WebGPU adapter | Throws |
| Image generation | First GPU reported, else CPU; CPU on macOS x86_64 | Needs a GPU; Android and the CPU builds have none | Throws |
| LiteRT-LM ASR | CPU | Not selectable | Not selectable |

Native llama.cpp on Linux checks Vulkan loader/device availability before
initialization. `GpuBackend.auto` skips unavailable Vulkan and keeps the other
bundled backends eligible; an explicit `GpuBackend.vulkan` load throws
`LlamaUnsupportedException`. Opt-in Vulkan device enumeration skips its module
when unavailable. Passing this check does not qualify driver stability or
inference.

The WebGPU bridge ignores negative `mainGpu` values, including with
`splitMode: ModelSplitMode.none`; they do not select the CPU as they do in
native llama.cpp. Explicit `gpu` still requires WebGPU after load.

Android LiteRT-LM apps targeting API 31+ need an optional `libOpenCL.so`
manifest request on Android 12+; see [Android setup](../getting-started/installation#android-litert-lm-setup).
An accessible OpenCL library does not guarantee GPU initialization or correct
model output. WebGPU buffer limits remain device-dependent; an automatic CPU
retry is CPU execution and does not qualify a GPU path.

Under `auto`, `gpuLayers: 0` or a CPU or BLAS `preferredBackend` selects the
CPU on both llama.cpp and LiteRT-LM, and a GPU `preferredBackend` (Vulkan,
Metal, CUDA, OpenCL or HIP) selects the LiteRT-LM GPU backend. On Linux x64
and Windows x64, the LiteRT-LM GPU backend is not CUDA. On Linux x64 it needs
a hardware Vulkan driver: with only software Vulkan devices (llvmpipe,
lavapipe, SwiftShader) explicit `gpu` throws `LlamaUnsupportedException` and
a GPU hint under `auto` runs on the CPU. Windows arm64 has no LiteRT-LM
runtime. The deprecated `liteRtLmBackend` selector works until 1.0; an
unavailable choice there throws `LlamaModelException`.

`LlamaBackend()` rejects a LiteRT-LM model with `LlamaUnsupportedException`
before any download on macOS x86_64, Windows arm64 and the x86_64 iOS
simulator, which have no LiteRT-LM runtime, and for an explicit `device` the
platform's LiteRT-LM lacks, such as `gpu` on Linux arm64. The message names
the ABI. This applies when `ModelSource.format` or the file name says
`.litertlm`; a model known only from its file header is rejected when it
loads.

`await engine.checkLoad(model, params: params)` returns the same verdict as a
`LlamaLoadCheckReport` without downloading, reading a file or starting a
runtime: `unsupported` with the exception the load would throw, `deferred`
when only the file header can tell the format, `unknown` when the backend
cannot tell, as with `LlamaEngine(LiteRtLmBackend())`, and otherwise
`supported`, with the format, runtime and device the load would use. Like the
setup report, it is policy: native libraries, browser assets, `auto` device
selection, LoRA limits, download options and the file are checked by the load
([backend selection](../guides/backend-selection#check-a-load-before-it-runs)).

Dart-side chat-template rendering accepts Jinja `\xHH` string escapes on
native and web. Model architecture support depends on the pinned runtime; see
[chat templates](../guides/chat-template-and-parsing).

## Features by runtime

| Feature | Native llama.cpp | WebGPU | Native LiteRT-LM | LiteRT-LM Web |
| --- | --- | --- | --- | --- |
| Decision tasks (cooperative) | Preflight stop or post-dispatch answer discard; no native interruption | Same, with decision-capable bridge assets | No | No |
| LFM2 Python tool argument types | Declared legacy ToolParam types; copied string backslashes preserved | Same Dart parser; inference requires LFM-capable assets | N/A: LFM GGUF format | N/A: LFM GGUF format |
| LFM2 auto Python-call grammar | Lazy schema enforcement with prompt penalties preserved; legacy ToolParam declarations | Text-only; requires v0.1.82+ loaded-core `lazyGrammar` and `penaltyPromptTokensWithGrammar` probes; otherwise typed unsupported | N/A: LFM GGUF format | N/A: LFM GGUF format |
| LFM2 reasoning tool markers | Stay in reasoning; no executable calls | Same Dart parser; inference requires LFM-capable assets | N/A: LFM GGUF format | N/A: LFM GGUF format |
| Explicit parallel tool flags | Supported Dart tool grammars honor the request independently of history probes | Same Dart routing; enforcement depends on the active grammar capability | Runtime-managed; no new constraint capability | Rejected: no parallel tool-call switch |
| Model-free setup report | Desktop IO only; publication policy, no native/model probe | Typed unsupported; no live browser check | Desktop IO only; publication policy, no native/model probe | Typed unsupported |
| Pre-load check | `npu` and options llama.cpp ignores rejected; native library and GPU unchecked | Options the Web runtime ignores rejected; WebGPU and bridge assets unchecked | No runtime on macOS x86_64, Windows arm64 or the x86_64 iOS simulator, and explicit devices the ABI lacks (`gpu` on Linux arm64), and embeddings on Android x86_64, rejected; `LlamaEngine(LiteRtLmBackend())` reports `unknown` | Options the Web runtime ignores, `npu` and the embedding engine rejected; browser runtime unchecked |
| LoRA | `ModelParams.loras` at load and `setLoraSource` at runtime, stacked and scaled; aLoRA rejected | Same, with bridge assets whose `getLoraAdapterCapabilities()` reports support ([llama-web-bridge#142](https://github.com/leehack/llama-web-bridge/pull/142)); otherwise rejected | Unsupported by the current advanced engine; see [owner #99](https://github.com/leehack/litert-lm-native/issues/99) | No |
| GPU device list and split (`gpuDevices`, `tensorSplit`) | Devices of one backend by `listGpuDevices` index, with proportions; validated on one Metal GPU and a Vulkan Tesla T4 (two-device paths with Mesa lavapipe as the second device); two-GPU hardware has no evidence ([#1528](https://github.com/leehack/llamadart/issues/1528)) and CUDA is not hardware-qualified | No | No | No |
| Row split (`ModelSplitMode.row`) | Needs llama.cpp split buffer types, which no bundled backend provides; a load on a bundled GPU backend whose module loads (Metal, CUDA, HIP, Vulkan, OpenCL), with `GpuBackend.blas` or `GpuBackend.cpu`, with `auto` on Android, the iOS simulator and macOS x86_64 (which runs on the CPU), or that falls back to the CPU because the requested backend is missing or Vulkan is refused, throws `LlamaUnsupportedException` before the model loads, so use `ModelSplitMode.layer`; a bundled module that fails to load or finds no device loads row on the CPU instead ([#1576](https://github.com/leehack/llamadart/issues/1576)) | No | No | No |
| Renamed legacy Qwen3 thinking switch | N/A: GGUF metadata | N/A: GGUF metadata | `chatTemplate: liteRtLmQwen3ChatTemplate`; requires native template setter | Canonical override throws at load: no template setter in `@litert-lm/core@0.19.0` |
| Thinking budget | Text-only, without speculative decoding, when the native reasoning-budget export resolves | Text-only, with bridge assets whose `getCompletionCapabilities()` reports `thinkingBudget` ([llama-web-bridge#144](https://github.com/leehack/llama-web-bridge/pull/144)); otherwise rejected | Native chat, without speculative decoding, on bundles whose first response channel is a thinking channel (Gemma 4); bounds that channel only; `0` and `forcedMessage` rejected | No |
| Web model/projector browser cache and post-abort reload | N/A | Format-independent model and projector cache with assets `v0.1.89+`; reload after `LlamaModelUnloadedException` in direct mode; worker restores the model on demand | N/A | N/A |
| Template-derived thinking-budget end sequences | Thinking-capable Qwen3-Coder XML, text-only, with llamadart-native `v1.0.0-4` or newer | Same templates with assets `v0.1.87+` whose core reports `thinkingBudgetMultiEnd` | Bundle-owned single end | No |
| Strict `responseFormat` | Yes | Yes, without tools | macOS arm64 CPU/GPU, iOS arm64 CPU/GPU (simulator runs; Gemma 4 GPU fails engine creation), Android arm64 CPU/GPU (Galaxy S24 and Pixel 9 Pro runs with Qwen3 and Gemma 4; the GPU through OpenCL), Linux x64 CPU/GPU (NVIDIA L4 over Vulkan, driver 615.71; Qwen3 and Gemma 4), Windows x64 CPU/GPU (NVIDIA L4 over Direct3D 12, GRID driver 596.86; Qwen3 and Gemma 4), Linux arm64 CPU (its GPU is not qualified); every other host, GPU or NPU refused, admitted Qwen3 (canonical text template) or Gemma 4 (bundle template) model; the schema subset both GBNF and LLGuidance enforce (nested objects, arrays, `$ref`, `anyOf`, anchored patterns, `uuid`/`date` formats, bounds); thinking with Gemma 4 only; no tools/media/speculation/caller stops | No |
| Lazy grammar | Yes | Yes when the loaded bridge reports `lazyGrammar`; otherwise first-token `root` only | No GBNF grammar | No GBNF grammar |
| Presence penalty | Yes | With bridge assets whose `getCompletionCapabilities()` reports `presencePenalty` ([llama-web-bridge#140](https://github.com/leehack/llama-web-bridge/pull/140)); otherwise rejects a non-zero value | Yes, without speculative decoding; counts only tokens of the current send | No: rejects a non-zero value |
| Min-P | Yes | With bridge assets whose `getCompletionCapabilities()` reports `minP` ([llama-web-bridge#140](https://github.com/leehack/llama-web-bridge/pull/140)); otherwise rejects a non-zero value | No: rejects a non-zero value | No: rejects a non-zero value |
| Repetition `penalty` | Yes | Yes | A value other than the default, at least `1.0`, without speculative decoding; counts only tokens of the current send | No: rejects a value other than the default |
| Speculative decoding | Draft model, MTP, n-gram and DSpark strategies; external drafts require `draftModel`, in-file MTP requires an MTP head and `loadMtp`; `draftMicroBatchSize` sizes the draft context; recurrent/hybrid models reject nonzero rollback capacity | Same, with bridge assets whose `getCompletionCapabilities()` reports the strategy ([llama-web-bridge#153](https://github.com/leehack/llama-web-bridge/pull/153)); draft and n-gram cache paths are URLs, MTP uses the model's own layers, and `draftMicroBatchSize` is rejected; otherwise rejected | Runtime default or MTP, for bundles with a speculative drafter; `capabilities` reports the bundle's declaration | No |
| MoE expert placement and cache | `cpuMoeLayers` keeps experts in host memory; `moeCacheBytes` caches them on Metal and CUDA GPUs (qualified on Metal with OLMoE; CUDA has no hardware evidence); only `moeCacheBytes` throws `LlamaUnsupportedException` on Vulkan, other backends and tensor split, while `cpuMoeLayers` alone runs there | No | No | No |
| GPU memory fit | Opt-in; Linux and Windows GPU loads, with `llamadart-native` v1.0.0 or later (`llama_dart_fit_params`); when no layer fits, `ComputeDevice.auto` loads on the CPU device alone; macOS, iOS and Android report it skipped (shared memory); a fit that fails, or `ComputeDevice.gpu` with no layer that fits, throws `LlamaGpuMemoryFitException`. Validated on an NVIDIA L4 on Linux over Vulkan and CUDA (Ministral 8B Q5_K_M, 32k context, about 5.4 GiB free: 14 of 34 layers fit, then load and decode; without the fit the same load fails with an error) and on Windows over Vulkan (`llamadart-native` v1.0.0-1 or later) and CUDA (`llamadart-native` v1.0.0-2 or later; counts other processes' VRAM, and refuses TCC or `GGML_CUDA_DEVICES` virtual devices where system-wide free memory cannot be read with `LlamaGpuMemoryFitException`); multi-GPU has no hardware evidence | No: `LlamaUnsupportedException` | No: `LlamaUnsupportedException` | No: `LlamaUnsupportedException` |
| State persistence | Yes | Yes; WASMFS paths, lost on page reload | No | No |
| State identity (`stateIdentity`) | `llamadart-native` `v0.7.0-3+` | No: the bridge reports no build identity | No | No |
| Embeddings | Yes; one-pass attention and MEAN/CLS inputs must fit the physical micro-batch | Yes; rejects rerankers and over-long one-pass input as native does | CPU, explicit embedding engine; macOS arm64, iOS arm64, Linux x64 and arm64, and Windows x64 qualified (Linux and Windows need litert-lm-native `v0.19.1-2` or later, older custom runtimes are refused); Android arm64 verified on a Galaxy S24 without SME and on arm64 emulators; Android x86_64 throws `LlamaUnsupportedException` at load | Unsupported (parity gate) |
| Reranking | Rank-pooled GGUF only; explicit loaded-context probe, complete-pair limits and independent sequence batching | No | No | No |
| Text task helpers and Matryoshka | Opt-in EG2 text profile; CPU BF16 retrieval reference | Same Dart helpers on an available embedding engine; no new Web qualification | Same Dart helpers on an available CPU embedding engine; bundle requires independent retrieval qualification | Unsupported with the underlying embedding engine |
| Image/audio embeddings (`embedContent`) | EmbeddingGemma-2 + compatible projector, native v0.7.0-1 floor; one complete micro-batch. Recorded S24 Vulkan and Pixel OpenCL refusals ([artifact-specific receipts](../maintainers/feature-validation#native-llamacpp-media-embeddings)) | API-version-1 modality probe + compatible projector; memory64 recommended ([Web evidence and limits](../maintainers/feature-validation#webgpu-media-embeddings)) | CPU only with compatible bundle processors ([native LiteRT-LM qualification](../maintainers/feature-validation#litert-lm-media-embeddings)) | Unsupported (parity gate) ([LiteRT-LM Web limits](../maintainers/feature-validation#litert-lm-media-embeddings)) |
| Next-token scores | Yes | Yes | No | No |
| Generation-limit reporting | `length` for output or context limits | `length` with the bridge usage probe; cap cause unspecified | `length` for output or context limits | `withTextHistory()`: `length` for output or context limits, inferred from the runtime's token counts after a load probe; a reply ending exactly at `maxTokens` also reports `length`. Default constructors: no |
| Per-request usage | `usage` on the final `create` chunk | Yes | No | No ([#725](https://github.com/leehack/llamadart/issues/725)) |
| Operation observers | Yes; after a load, `runtime` is `llamaCpp` | Yes; after a load, `runtime` is `llamaCpp` | Yes; after a load, `runtime` is `liteRtLm` | Yes; after a load, `runtime` is `liteRtLm` |
| Multi-turn `ChatSession` | Yes | Yes | Yes | `LlamaBackend.withTextHistory()` or `LiteRtLmBackend.withTextHistory()` (existing defaults retain single-user-text): system/user/assistant text when the loaded runtime consumes `preface` and exposes `getHistory()` (`@litert-lm/core@0.19.0`), plus assistant tool calls and tool results when it also reads `preface.tools` (`supportsToolCalling`); final user or tool result message required; model/browser qualification is separate |
| Deterministic session template time | `TemplateTimeChatSession`, Dart-rendered templates | Same Dart template path | Dart-side rendering only; runtime-owned template clock unchanged | No: runtime-owned clock; explicit template time rejected |
| Tool calling | Yes | Yes | Yes, through the `LlamaEngine` parser; LiteRT-native constrained tool execution is not wired | Manual only, with `withTextHistory()` when the loaded runtime reads `preface.tools`: calls come from the runtime's `tool_calls`, checked in Chrome with Qwen3 0.6B on WebAssembly CPU and Gemma 4 E2B on WebGPU; `ToolChoice.required` and tool-result `content` throw; default constructors report no tool calling |
| Incomplete tool diagnostics | LFM raw `partialToolCalls` at reported length limits | Same parser when the runtime reports a length limit | Same Dart parser at reported length limits | Unqualified: calls come from the runtime's `tool_calls` |
| Canonical JSON Schema tools | Supported subset and selected formats | Selected formats; lazy grammars require the `lazyGrammar` runtime probe | No | No |
| Automatic `sendWithTools` / `completeWithTools` loop | Yes | Requires reliable runtime finish reporting | Yes | `withTextHistory()` when the load's token-count probe passes (`@litert-lm/core@0.19.0`), checked in Chrome with Qwen3 0.6B on WebAssembly CPU and Gemma 4 E2B on WebGPU; otherwise throws before generation |
| Multimodal | Image and audio with a projector | Image and audio with a projector URL | Image and audio files or bytes, when the bundle supports them | No |
| Video | No | No | No | No |
| Tool-result media | Images with a vision projector and a Hermes-style template (smoke-tested on macOS CPU and Metal with Qwen3.5-0.8B weights, a `qwen3vl_merger` projector and the Qwen3-VL template) | No | No | No |

Tool-result media are `LlamaToolResultContent.content` parts;
`LlamaEngineCapabilities.toolResultMedia` reports them. Other formats, audio,
video and URL-only images throw `LlamaUnsupportedException`, as do tool-role
image/audio parts and media alongside `LlamaToolResultContent` under any role
([tool-result media](../guides/tool-calling#tool-result-media)).

LiteRT-LM Web `generate(prompt)` wraps the prompt in one user turn of the bundle's chat template (native LiteRT-LM and the other backends send it unchanged). `@litert-lm/core@0.19.0` cannot replace that template, and its `Session` API decodes a whole reply per call, with no streaming or stop cause. `create()` and `ChatSession` are unaffected ([#1863](https://github.com/leehack/llamadart/issues/1863)).

`LlamaEngine.supportsVideo` returns `false` on every runtime, and passing
`LlamaVideoContent` throws `LlamaUnsupportedException`. Web state paths point
into the bridge's WASMFS virtual filesystem; to keep state across reloads,
export and import it in app code. The pinned bridge assets report the WebGPU LoRA, thinking-budget,
presence-penalty, Min-P and speculative decoding capabilities; older assets
report none of them ([Older bridge assets](./webgpu-bridge#older-bridge-assets)).
After a load, `LlamaEngine.runtime` names the runtime and
`LlamaEngine.capabilities` reports the rows of this table for the loaded model:
media input, embeddings, next-token scores, multi-turn chat, tools, structured
output and grammars, sampling controls and speculative decoding. Guides:
[LoRA adapters](../guides/lora-adapters),
[Tool calling](../guides/tool-calling#tool-choice-semantics),
[Performance tuning](../guides/performance-tuning),
[Multimodal](../guides/multimodal),
[Embeddings](../guides/embeddings),
[Observing operations](../guides/generation-and-streaming#observing-operations).

## Known limitations

Device, OS and driver limits on iOS, macOS, Android, Linux, Windows and the
web are on [Known platform issues](./known-platform-issues).

LiteRT-LM `v0.19.1-6` passed Qwen3-0.6B hello and arithmetic on CPU and
OpenCL on Galaxy S24 (SC-51E, API 36). The corrected model stayed on GPU
across both automatic-selection lifetimes.
[Device qualification record](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#galaxy-s24-litert-lm-cpu-and-opencl-requalification).

## Pinned runtimes

| Runtime | Pinned release |
| --- | --- |
| llama.cpp native | `leehack/llamadart-native@v1.0.0-4` |
| LiteRT-LM native | `leehack/litert-lm-native@v0.19.1-6` |
| stable-diffusion.cpp native (opt-in, Preview) | `leehack/stable-diffusion-native@v0.4.0`, for [image generation](../guides/image-generation); see [Opt-in stable_diffusion runtime](./native-build-hooks#opt-in-stable_diffusion-runtime-experimental). Flutter iOS/macOS apps link its XCFramework through `llamadart_stable_diffusion_flutter` |
| WebGPU bridge assets | `leehack/llama-web-bridge-assets`; see [Pinned bridge assets](./webgpu-bridge#pinned-bridge-assets) |

SD `v0.3.0-6` passed four full-VAE load/dispose cycles and eight decodes per device on iPhone 16 Pro (iOS 18.3.2) and iPhone 17 Pro (iOS 26.5.1), tested at `6b191b28`. Small nonzero residual memory remains; this single session is not proof of zero leaks (#2004).

The native-assets hook currently pins `llamadart-native` tag
`v1.0.0-4` and
`litert-lm-native` release `v0.19.1-6` (`lib/src/hook/native_release_pins.dart`).
The Windows llama.cpp bundles select the newest Visual C++ runtime per
architecture. The published Apple llama.cpp companions `0.20.0` and `0.20.1`
remain compatible with an upgrade warning and use their own native builds.

The direct native client, service probes and speech worker share ABI-aware
discovery. Public selection admits legacy runtimes and C API 1.0.x; unknown
or future versions are refused before engine calls. The pinned runtime is
published native
[v0.19.1-6](https://github.com/leehack/litert-lm-native/releases/tag/v0.19.1-6)
(owner `9246bf2a`, upstream `7a03724c`). The selected loader requires macOS 14+
before loading any core or companion library, including legacy libraries and
custom paths. Web uses `@litert-lm/core@0.19.0`.
The Flutter companion's iOS 16.4 floor remains separate.
Apps can override the llama.cpp release with `llamadart_native_tag`; accepted
tag forms, keys, backend modules and local bundles:
[Native runtime configuration](./native-build-hooks#override-the-llamacpp-release).

Apps load the bridge assets themselves; see
[Add the bridge to your app](./webgpu-bridge#add-the-bridge-to-your-app).
Linux system libraries: [Linux prerequisites](./linux-prerequisites).

## Experimental Studio Coding storage

Studio on iOS/Android offers **Create local workspace** in persistent app storage,
with nested browse/read/write/edit tools and per-file Copy. **Open local workspace**
in Coding setup reopens earlier folders. The last selected workspace is restored
on restart, including after app storage moves during an update; app data
removal removes local files. Physical
mobile workflow qualification remains open. External provider URI/security-scoped
grants are unsupported. Local shell and process MCP remain desktop-only; Web has
no local workspace filesystem. See the
[Studio README](https://github.com/leehack/llamadart/tree/main/packages/llamadart_studio)
for setup and qualification limits.
