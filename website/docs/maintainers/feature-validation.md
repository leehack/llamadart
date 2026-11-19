---
title: Feature validation evidence
description: Where feature qualification evidence lives for maintainers - qualification procedures, local-only scenarios, device calibration data and owner-repository trackers that user pages cite only as "Qualified on" lines.
---

User guides state what a feature was qualified on and link here once. The
procedures, receipts and calibration data below back those statements. Re-run
the relevant scenario when you change the behavior a line describes, and keep
the user page's "Qualified on" line in step with what you can reproduce.

## Qualification procedures

| Feature | Procedure |
| --- | --- |
| Native multimodal embeddings | [`doc/multimodal_embeddings_native.md`](https://github.com/leehack/llamadart/blob/main/doc/multimodal_embeddings_native.md) |
| Text embedding helpers (EmbeddingGemma-2 retrieval comparison) | [`doc/embedding_text_helpers.md`](https://github.com/leehack/llamadart/blob/main/doc/embedding_text_helpers.md) |
| Native reranking | [`doc/native_reranking.md`](https://github.com/leehack/llamadart/blob/main/doc/native_reranking.md) |
| Decision models (timings, parity, web check) | [`doc/decision_engine.md`](https://github.com/leehack/llamadart/blob/main/doc/decision_engine.md) |
| LiteRT-LM chat templates | [`doc/litert_lm_templates.md`](https://github.com/leehack/llamadart/blob/main/doc/litert_lm_templates.md) |
| Image seamless textures | [`doc/image_seamless_textures.md`](https://github.com/leehack/llamadart/blob/main/doc/image_seamless_textures.md) |
| Local image sets | [`doc/local_image_sets.md`](https://github.com/leehack/llamadart/blob/main/doc/local_image_sets.md) |
| Image editing | [`doc/image_editing.md`](https://github.com/leehack/llamadart/blob/main/doc/image_editing.md) |
| ControlNet | [`doc/image_controlnet.md`](https://github.com/leehack/llamadart/blob/main/doc/image_controlnet.md) |
| Hires fix | [`doc/image_hires_fix.md`](https://github.com/leehack/llamadart/blob/main/doc/image_hires_fix.md) |
| Reference image editing | [`doc/image_reference_editing.md`](https://github.com/leehack/llamadart/blob/main/doc/image_reference_editing.md) |

Run a scenario with `dart run tool/testing/run_local_e2e.dart --list`, then
`--scenario <name> --dry-run`, as in the repository's `AGENTS.md`.

## Local-only scenarios and receipts

- **Reranking.** The local-only `native-reranking` scenario compares against
  the pinned upstream oracle. Its receipts identify the model hashes, runtime
  revision and tested device and backend. Native API availability alone does
  not qualify a model, quantization or platform.
- **Chat app on Web.** `chat-app-web-mock-smoke` runs the chat app against a
  mock bridge with no model download:
  `dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-mock-smoke`.
  `tool/testing/serve_static_with_headers.py` serves a built app with the
  cross-origin isolation headers.
- **Command-line example.** The real-model parity gates in
  `example/llamadart_cli` are tagged `local-only` and need local llama.cpp
  builds and model files. The parity harness setup and environment overrides
  are in the example README.
- **Observability example.** Dart VM tests cover the adapter and OTLP/HTTP
  export; Flutter mobile and browser export are not qualified.
- **Image generation.** The `image-generation-smoke` checks cover the
  conditioning cache (disabled, default and one-entry caches with SDXS and
  SD-Turbo, repeated and changed prompts, eviction, cancellation and reload,
  on macOS arm64 CPU and Metal) and module placement (they read where the
  runtime put each module's weights, from `total params memory size` in its
  debug log, and compare pixels with the default placement). The
  `image-local-checkpoint-sets` scenario builds two unchanged shards from the
  fixed complete checkpoint, compares the public directory and index output
  with the pinned C settings, and checks source-removal lifetime, cache reuse,
  cancellation cleanup and recovery. `example/basic_app/bin/local_image_set.dart`
  is its runnable consumer. Approximation-cache modes are tracked in
  [#1233](https://github.com/leehack/llamadart/issues/1233).
- **Tool results with media.** The Hermes-style `<tool_call>` path was
  smoke-tested on macOS CPU and Metal with Qwen3.5-0.8B weights, a
  `qwen3vl_merger` projector and the Qwen3-VL template.

## Image and audio embeddings

### Native llama.cpp media embeddings

EmbeddingGemma-2 needs a compatible projector, native `v0.7.0-1` or later,
and one complete physical micro-batch per input. The
[BF16 validation pack](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#multimodal-embedding-pack)
has CPU qualification on macOS arm64, Linux x64, Windows x64, Android and
iOS, plus macOS Metal.

The November 14, 2026 media-vector receipts used EmbeddingGemma-2 BF16 with
the gemma4v/gemma4a projector:

| Platform | Device and driver | Package | Result |
| --- | --- | --- | --- |
| Linux x64 | NVIDIA L4, driver 580.178 | 0.19.9 | CPU, CUDA and Vulkan ([Linux receipt](https://github.com/leehack/llamadart/issues/1189#issuecomment-6877631575)) |
| Windows Server 2022 x64 | NVIDIA L4, GRID driver 596.86 | 0.19.10 | CPU, CUDA and Vulkan ([Windows receipt](https://github.com/leehack/llamadart/issues/1189#issuecomment-6881250817)) |
| Android arm64 | Galaxy S24, Adreno 750, API 36 | 0.19.10 | OpenCL passed. Vulkan driver 2150604839 gave a typed refusal ([Android receipt](https://github.com/leehack/llamadart/issues/1189#issuecomment-6883121575)) |
| Android arm64 | Pixel 9 Pro, Mali-G715, API 35 | 0.19.10 | Vulkan passed. OpenCL gave a typed refusal ([Android receipt](https://github.com/leehack/llamadart/issues/1189#issuecomment-6883121575)) |

These receipts cover the recorded native artifacts, models, backends and
devices. Native 1.0, core 0.20 and other GPU combinations require their own
qualification.

### WebGPU media embeddings

The loaded bridge must report API-version-1 modality support, and the model
needs a compatible projector. The
[Web receipts](https://github.com/leehack/llamadart/blob/main/doc/multimodal_embeddings_web.md#current-evidence-and-limits)
cover EmbeddingGemma-2 on Chrome CPU wasm memory64 and Chrome WebGPU on an
Apple GPU with Metal, compared with native CPU and Metal. The wasm32 repeat
batch check passed on the then-pinned assets with the fix available from
`v0.1.76`. Use memory64 for more heap headroom.

The [NVIDIA L4 receipt](https://github.com/leehack/llamadart/blob/main/doc/multimodal_embeddings_web.md#nvidia-l4-qualification-on-the-recorded-source)
covers Ubuntu 24.04.5, Chrome 157.0.8103.78, driver 615.71.09 and bridge
`v0.1.85` on wasm64. Direct and worker runs at source `eb18767e` had the
GPU active and passed against the native `v0.7.0-1` CPU pack reference.
Fresh native `v0.9.0` parity, GPU device-loss recovery and other GPU
combinations remain unqualified.

### LiteRT-LM media embeddings

Native bundle processors are qualified on CPU on macOS arm64, iOS arm64,
Android arm64 (Galaxy S24 and arm64 emulators), Linux x64 and arm64, and
Windows x64. This uses the separate embedding engine with a compatible
bundle.

LiteRT-LM Web is unsupported. Web CPU cannot load the external text-encoder
weights, and the pinned WebGPU vectors missed the native CPU parity gate.
See the [basic app](../examples/basic-app#run) for the native CPU recipe and
its platform and bundle requirements.

## LiteRT-LM Qwen3 bundles

The updated Qwen3-0.6B bundle is verified on macOS CPU, and Linux and Windows
CPU qualification runs in the maintained smoke workflow. GPU, iOS, Android and
Web adoption still need separate validation
([#554](https://github.com/leehack/llamadart/issues/554)). The registry
coverage, smoke commands and contribution notes for LiteRT-LM chat templates
are in `doc/litert_lm_templates.md`.

Native strict JSON Schema output is qualified on Android arm64 CPU and GPU by
the `chat-app-litert-json-schema` scenario on a Galaxy S24 and a Pixel 9 Pro;
the run record is in
[`doc/cross_platform_validation.md`](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#android-arm64-strict-json-schema-on-cpu-and-gpu-2026-11-13).
It is qualified on Linux x64 CPU and GPU by the `litert-lm-json-schema`
scenario on an NVIDIA L4 (Vulkan, driver 615.71)
([record](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#linux-x64-strict-json-schema-on-cpu-and-gpu-2026-11-14)),
and on Windows x64 CPU and GPU by the same scenario on an NVIDIA L4 (Direct3D 12,
GRID 596.86)
([record](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#windows-x64-strict-json-schema-on-cpu-and-gpu-2026-11-14)).
The Linux arm64 GPU stays unqualified.

## Speech to text

Qwen3-ASR 0.6B Q8_0 was validated on WAV up to 33 s, and on MP3 and FLAC
copies of the 11 s `jfk.wav`, on native macOS and in headless Chromium.
Language-marker behavior has no dedicated validation contract yet. Built-in
windowing for inputs over 30 s is tracked in
[#327](https://github.com/leehack/llamadart/issues/327).

## Image generation

### SDXS and SD-Turbo timings

The [SDXS and SD-Turbo receipt](https://github.com/leehack/llamadart/issues/779)
records earlier runtimes on macOS (M4 Max), iOS (iPhone 16 Pro and iPhone SE 3),
Android (Pixel 9 Pro, Galaxy S24 and Galaxy A53), Linux x64 and Windows x64.

Warm measurements used the same runtime, 512x512 and one step:

| Device | SDXS Q8 (651 MB) | SD-Turbo Q8 + TAESD (1.9 GB) |
| --- | --- | --- |
| M4 Max, Metal | 1.5 s | 1.2 s |
| iPhone 16 Pro, Metal | 1.7 s | 4.1 s |
| Galaxy S24, CPU | 5.9 s | 11.8 s |
| Galaxy A53, CPU | 26 to 29 s | Refused by the [memory check](../guides/image-generation-memory-and-limits#memory-check) |

### Desktop model timings

The October 2026 [Metal receipt](https://github.com/leehack/llamadart/pull/810#real-model-runs-m4-max-64-gb-metal-macos-this-branch)
and [Vulkan CLI receipt](https://github.com/leehack/llamadart/issues/802#issuecomment-5925069431)
cover 1024x1024 images from the [desktop model families](../examples/basic-app#image-generation-presets).
The Metal column measures the first image in a new process with automatic
attention and VAE settings.

| Model | M4 Max, Metal: time, peak process memory | Memory check asks for | NVIDIA L4, Vulkan (native CLI, warm) |
| --- | --- | --- | --- |
| SDXL-Lightning + TAESDXL | 6.1 s, 7.8 GiB (12.1 s with the checkpoint's VAE) | 8.6 GiB | 4.4 s |
| FLUX.1-schnell Q4_0 + TAEF1 | 61 s, 12.9 GiB | 14.5 GiB | 25.3 s with `ae` |
| SD 3.5 Large Turbo Q4_0 + TAESD3 | 16.1 s, 12.3 GiB | 13.1 GiB | 19.4 s with the SD 3.5 VAE |
| Z-Image-Turbo Q4_K | 91 s, 7.8 GiB | 8.3 GiB | 35.0 s (Q8_0) |

The Vulkan figures come from stable-diffusion.cpp's own CLI on the same
runtime commit with `vae_conv_direct`. The Dart desktop runs covered macOS
Metal. The engine now sets `vae_conv_direct` on Vulkan. The tiny autoencoders
(TAESDXL, TAEF1, TAESD3) cut 6 to 9 s from each 1024x1024 decode on the M4 Max
with no visible quality loss in these samples. The SD 3.5 VAE repository is
gated, so TAESD3 is the ungated choice.

### Other image family timings

The [initial Metal receipt](https://github.com/leehack/llamadart/issues/802#issuecomment-5923960986)
reports about 3 minutes for SD 3.5 Medium and about 11 minutes for Qwen-Image
per 1024x1024 image on an M4 Max. Qwen-Image used the native CLI. See the
[files and settings](../examples/basic-app#other-image-model-families).

### Android memory-check calibration

The memory check's Android allowance comes from Firebase Test Lab runs of the
chat app's settings comparison. An app that kept touching all of its memory
was killed only after allocating 0.9 to 3.6 GiB more than `MemAvailable`:

| Phone (RAM) | `MemTotal` | `MemAvailable` at idle | Allocated when killed | Half of `MemTotal` less the app |
| --- | --- | --- | --- | --- |
| Moto G Play 2024 (4 GB) | 3.57 GiB | 1.38 GiB | 2.31 GiB | 1.45 GiB |
| Galaxy A53 (6 GB) | 5.26 GiB | 1.81 GiB | 2.81 GiB | 2.31 GiB |
| Pixel 6a (6 GB) | 5.45 GiB | 1.87 GiB | 3.63 GiB | 2.37 GiB |
| Galaxy S24 (8 GB) | 6.95 GiB | 2.38 GiB | 3.88 GiB | 3.10 GiB |
| Pixel 8a (8 GB) | 7.38 GiB | 2.56 GiB | 4.81 GiB | 3.29 GiB |
| Pixel 9 Pro (16 GB) | 15.19 GiB | 9.13 GiB | 12.75 GiB | 7.18 GiB |

With the check off, no SD-Turbo variant was killed on these phones, but the
Galaxy A53 swapped most of the app out: a one-step image took 65 s with TAESD
and 282 s with the full VAE, against 18 s and 67 s on the Pixel 6a. The
Android memory figure varied by up to a gigabyte between idle readings.

The GPU memory rules are tested on reported figures. The call that reads them
is checked on macOS Metal, where its total equals the working set. On an
NVIDIA L4 under Vulkan, one GPU each on Linux and Windows, the figures, the
device facts and the device selection were checked. The warning, the refusal
and the two-GPU paths have not been checked on a physical GPU yet
([#1024](https://github.com/leehack/llamadart/issues/1024)).

### Attention and VAE measurements

The phone figures in the user guide's attention and VAE table are Firebase
Test Lab runs of the chat app's settings comparison. Peak memory is the
`phys_footprint` interval peak on the iPhone and a 20 ms sampled `VmRSS` peak
on Android, where Test Lab refused the `VmHWM` reset on all three phones. The
Galaxy A53's memory check refused SD-Turbo (about 2.9 GiB needed, 2.5 GiB
available), so it has no SD-Turbo figures, and its SDXS figures come from a run
that does not verify because of that refusal: they are an observation, not
verified evidence. The iPhone full-VAE arm was not measured in those runs because the
`v0.3.0-3` decode trips the GPU watchdog; the `v0.3.0-4` graph split is
qualified separately below
([#1047](https://github.com/leehack/llamadart/issues/1047)).

### iOS full-VAE graph split

The `v0.3.0-4` XCFramework splits Metal graphs through upstream's eval callback
at 2^26 elements. On 2026-11-13, DDP ran these exact bytes on an iPhone 16 Pro
(iOS 18.3) and an iPhone 17 Pro. Every split arm passed 3 of 3 decodes, the
unsplit control failed its third decode with the GPU command-buffer error (the
watchdog), and a 30-decode soak passed 30 of 30 with one image hash and a flat
footprint. The iPhone 17 Pro (iOS 26.5) showed the dispose retention that
runtime `v0.3.0-5` improved. Before the fix, the second dispose could leave
about 2 GB resident and trigger a memory-check refusal on a later load. Four
load/dispose cycles completed on both phones, with residual memory above
baseline on the iPhone 16 Pro. The `v0.3.0-6`
Apple scratch-buffer fix passed four full-VAE load/dispose cycles and eight
decodes per device at `6b191b28` on iOS 18.3.2 and 26.5.1. Small nonzero
residuals remain; this single session is not proof of zero leaks
([#2004](https://github.com/leehack/llamadart/issues/2004)). The dated record is in
[cross-platform validation](https://github.com/leehack/llamadart/blob/main/doc/cross_platform_validation.md#ios-full-vae-graph-split-1047-2026-11-13).

### Full-checkpoint container checks

With `stable-diffusion-native v0.3.0-1` (`be48649` plus the owner
pickle-reader repair), complete byte-equivalent SD-Turbo F16 checkpoints pass
through `ImageGenerationEngine` on macOS arm64 CPU:

| Complete checkpoint | Role selection | Result |
| --- | --- | --- |
| F16 GGUF | Automatic and explicit checkpoint | Exact native-reference RGB |
| Safetensors, same 1,323 tensors | Automatic and explicit checkpoint | Exact native-reference RGB |
| Tensor-only PyTorch legacy `.pth` | Explicit checkpoint | Exact native-reference RGB, including the >2-GiB input |
| PyTorch ZIP `.pt` and nested `state_dict` ZIP `.ckpt` | Explicit checkpoint | Exact native-reference RGB |

These checks use the [pinned SD-Turbo F16 source](https://huggingface.co/Green-Sky/SD-Turbo-GGUF/blob/19a31586d02d64a73b4419bc193b3ecfaf38e1f0/sd_turbo-f16.gguf)
and its embedded full VAE. Local Safetensors and PyTorch 2.11/protocol-2
variants preserve every tensor byte. All seven public loads generate the same
128-square, one-step Euler/discrete image at seed 42, CFG 1 and four CPU
threads, matching separate guarded direct-C controls. This is container and
transport evidence, not an image-quality or speed benchmark.

Other architectures, dtypes, producer layouts, arbitrary serialized objects,
accelerators, Windows/Linux and mobile full-checkpoint paths are unqualified
by this check. No model weights ship with the tests. The
[basic example's container checks](https://github.com/leehack/llamadart/tree/main/example/basic_app#8-image-generation-example-experimental)
and maintained `image-container-formats` scenario repeat the selected controls
from local files and independent native references.

Earlier `v0.2.0-4` checks rejected the 2.6-GB legacy file and timed out on full
ZIP inputs. The current legacy result verifies the published reader repair;
ZIP's earlier timeout cause remains unresolved
([stable-diffusion-native#24](https://github.com/leehack/stable-diffusion-native/issues/24)).
Passing the selected ZIP inputs is a later non-reproduction, not proof of a
causal ZIP fix.

### Owner-repository trackers

- Newer upstream and FP8 CPU qualification:
  [stable-diffusion-native#20](https://github.com/leehack/stable-diffusion-native/issues/20).
- Process abort in `new_sd_ctx` when the GPU budget is below the weights:
  [stable-diffusion-native#34](https://github.com/leehack/stable-diffusion-native/issues/34).
- Android GPU backends (ggml Vulkan and OpenCL crashed or ran slower on the
  phones tried):
  [stable-diffusion-native#2](https://github.com/leehack/stable-diffusion-native/issues/2).

## Chat templates

Flint's `\x` escape repair does not qualify the architecture for the pinned
native runtime; see
[llamadart-native#112](https://github.com/leehack/llamadart-native/issues/112).
