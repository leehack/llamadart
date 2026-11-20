---
title: On-device image generation (Preview)
sidebar_label: Image generation (Preview)
description: Generate images from text prompts on device with the Preview ImageGenerationEngine and the opt-in stable-diffusion.cpp runtime.
---

:::warning Preview
Image generation is a Preview.

- The `ImageGenerationEngine` API is experimental and may change in a later
  release.
- The `stable_diffusion` runtime is opt-in: an app bundles it only when it
  [names it in `pubspec.yaml`](#bundle-the-runtime).
- Earlier runtimes ran SDXS and SD-Turbo on macOS, iOS, Android, Linux x64
  and Windows x64. Desktop presets have Dart qualification on macOS Metal.
  See [device qualification and timings](../maintainers/feature-validation#image-generation).
- Open limits: no web runtime yet
  ([#969](https://github.com/leehack/llamadart/issues/969)); the
  [memory check](./image-generation-memory-and-limits#memory-check)'s warning, refusal and two-GPU paths have not
  been checked on physical Vulkan hardware
  ([#1024](https://github.com/leehack/llamadart/issues/1024)).
- Model licenses differ, including on commercial use; see
  [Model licenses](../examples/basic-app#model-licenses).
:::

`ImageGenerationEngine` turns a text prompt into images on the device. It runs
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) through
the opt-in `stable_diffusion` native runtime, separately from `LlamaEngine`.
Both `prompt` and `negativePrompt` are text. For example, `<image:cat.png>`
is passed as literal text. The engine escapes native image markers, including
incomplete ones, and respects an existing backslash escape.

Bounded image-to-image and binary-mask editing are available through
`ImageEditingRequest` on the [CPU recipe](./image-generation-advanced#image-editing), and an
SD 1.x ControlNet steers `ControlNetImageGenerationRequest` on the
[bounded CPU recipe](./image-generation-advanced#controlnet). The v0.4.0 runtime reports
`supportsReferenceImageEditing: false` pending requalification of the
[FLUX.1 Kontext Metal recipe](./image-generation-advanced#reference-image-editing). LoRA has no public
image-generation API yet.

## Support

| Platform | Device | Minimum OS | Notes |
| --- | --- | --- | --- |
| macOS (arm64, x86_64) | Metal, CPU | macOS 13.3 | Validated on an M4 Max |
| iOS (arm64, arm64 and x86_64 simulator) | Metal, CPU | iOS 16.4 | Validated on iPhone 16 Pro and iPhone SE 3 |
| Android arm64 | CPU | Not set by llamadart | Needs Armv8.2 dot-product and fp16 (`asimddp`, `fphp`, `asimdhp`); validated on Pixel 9 Pro, Galaxy S24 and Galaxy A53; no x64 runtime |
| Linux (arm64, x64) | CPU, or Vulkan with the Vulkan build | Not set by llamadart | x64 CPUs need AVX2, FMA, F16C and BMI2; validated on x64 with CPU and an NVIDIA L4 |
| Windows x64 | CPU, or Vulkan with the Vulkan build | Not set by llamadart | Needs the latest Microsoft Visual C++ v14 Redistributable (x64) and AVX2; the Vulkan build needs a GPU driver that provides `vulkan-1.dll`; validated on Windows Server 2022 with CPU and an NVIDIA L4; no arm64 runtime |
| Web | None | | `load` throws `LlamaUnsupportedException` |

`await ImageGenerationEngine.checkRuntime()` reports whether this build and
device can generate images, and why not, without loading a model or blocking
the calling isolate. Its first call in a process can take seconds; see
[First-image latency and warm-up](./image-generation-settings#first-image-latency-and-warm-up).
`ImageGenerationCapabilities` implements `EngineCapabilities`, like every
engine's capabilities.

## Bundle the runtime

The runtime adds about 40 to 70 MB per target, so it is never bundled by
default. Name it in the app's `pubspec.yaml`, then run `flutter clean` once:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: all
```

Unset, `llamadart_native_runtimes` bundles `llama_cpp` and `litert_lm`. A list
replaces those defaults, so it names every runtime the app loads. Beside
Flutter Edge AI an implied `litert_lm` is left out; see
[Alongside Flutter Edge AI](../platforms/native-build-hooks#alongside-flutter-edge-ai).

| The app loads | `llamadart_native_runtimes` |
| --- | --- |
| GGUF and `.litertlm` models | unset |
| Images only | `[stable_diffusion]` |
| GGUF models and images | `[llama_cpp, stable_diffusion]` |
| Every runtime published for the target | `all` |

Linux and Windows get the Vulkan build when `llamadart_native_backends`
selects Vulkan, which it does by default; set
`llamadart_stable_diffusion_backends: [cpu]` for the CPU build. See
[Native runtime configuration](../platforms/native-build-hooks#opt-in-stable_diffusion-runtime-experimental).

Flutter iOS and macOS apps should also add the companion package, which links
the runtime's XCFramework through Swift Package Manager and selects the
runtime on those platforms by itself, adding about 37 MB per Apple target.
Use the companion with the core's `MAJOR.MINOR`; the core accepts only an
Apple SD companion pinning its own runtime, so upgrade the core and
`llamadart_stable_diffusion_flutter` together:

```yaml
dependencies:
  llamadart_stable_diffusion_flutter: ^0.20.3
```

Without it, `all` leaves the image runtime out of a Flutter iOS or macOS app
and `ImageGenerationEngine.checkRuntime()` reports it as not bundled. The
build warns about it: `flutter build macos`, Xcode and `xcodebuild` show the
warning, and `flutter build ios` output does not. A list naming
`stable_diffusion` bundles the runtime through the hook instead, into a
framework that Flutter marks `MinimumOSVersion` 13.0 while the library needs
iOS 16.4, so App Store Connect rejects the iOS upload. The iOS build reports
this as an Xcode build warning, which Xcode and `xcodebuild` show but plain
`flutter build` and `flutter run` output does not. See
[Flutter Apple apps](../platforms/apple-setup#companion-packages).
The hook-bundled runtime also cannot carry an Apple privacy manifest; the
companion's XCFramework does. See
[Apple privacy manifest](../platforms/apple-setup#apple-privacy-manifest)
for the File Timestamp reasons (`C617.1`, `3B52.1`) an app declares itself
when its `stable_diffusion.framework` has no manifest.

## Get a model

### Weight formats and layouts

`ImageGenerationEngine` loads **GGUF and Safetensors directly**. Safetensors
does not need conversion to GGUF, and a model can mix containers across its
components. These image-loading rules are separate from `LlamaEngine`'s text
model formats; leave `ModelSource.format` unset for image files.

| Input | Public image API | Qualification / limits |
| --- | --- | --- |
| GGUF file (`.gguf`) | Direct loading; automatic role detection from metadata and tensor names | Use a compatible image checkpoint or component, not an arbitrary LLM GGUF |
| Safetensors file (`.safetensors`) | Direct loading; automatic role detection from tensor names and shapes | Complete SD-Turbo F16 and existing SDXL-Lightning/VAE/TAESD recipes; see the bounded checks below |
| PyTorch checkpoint (`.ckpt`, `.pth`, `.pt`) | Explicit role required; forwarded to the native loader | Selected complete SD-Turbo tensor-only ZIP/nested ZIP/legacy checkpoints pass on macOS CPU; arbitrary layouts remain unqualified ([#1218](https://github.com/leehack/llamadart/issues/1218)) |
| Separate component files | Each file resolves independently and gets a role; GGUF and Safetensors can be mixed | Supply the matching diffusion weights, encoders and decoder from the [preset index](../examples/basic-app#image-generation-presets) |
| Diffusers component directory or repository | No public Diffusers pipeline/repository ingestion | Pass compatible component files individually; this does not describe the separate complete-checkpoint index recipe |
| Complete Safetensors checkpoint index and shards | Opt in with `ImageGenerationModel.localSafetensorsSet` | Bounded SD-Turbo F16/F32 tensor recipe, macOS CPU, owned verified cache and whole-set accounting; no automatic remote shard fetch. See [local checkpoint sets](./image-generation-advanced#local-checkpoint-sets) |

GGUF magic bytes and Safetensors headers drive role detection, not their
filename extensions. The header check assigns roles; it does not validate all
weight data or prove the architecture, dtype or quantization runs on the active
backend. F16/F32/BF16 Safetensors and GGUF quantization still need compatible
tensors and kernels. Do not assume arbitrary FP8/INT8 variants work; newer
upstream and FP8 CPU qualification are tracked upstream.
`checkRuntime()` reports runtime/device availability, not support for every
model. Use [Support](#support) and the recipe's platform evidence separately.
The public model roles do not include LoRA, upscaler or external tokenizer
inputs; `controlNet` loads only in the [ControlNet recipe](./image-generation-advanced#controlnet).

FP8 image weights (`F8_E4M3`/`F8_E5M2` in Safetensors, types 43/44 in
GGUF) load on Metal with stable-diffusion-native `v0.3.0-1` or later, which
converts them to F16 there: they need twice their file size in memory, which
`ImageModelParams.checkMemory` counts. FP8
weights, uninspectable GGUF/Safetensors headers and ordinary JSON shard
indexes are refused with `LlamaUnsupportedException` on Metal, including
`ComputeDevice.auto` when it selects Metal, before native context creation
([#1446](https://github.com/leehack/llamadart/issues/1446)); use
`ComputeDevice.cpu` there. FP8 re-encodings of SD-Turbo are measured on
macOS arm64 CPU and Metal; arbitrary FP8 models are not qualified.

For a trusted PyTorch checkpoint whose native layout is compatible:

```dart
final model = ImageGenerationModel(
  ModelSource.path('model.ckpt'),
  role: ImageModelRole.checkpoint,
);
```

An explicit role selects a native input; it does not convert the file or make
an unsupported checkpoint compatible. PyTorch component loading can work while
larger full-checkpoint loading remains unqualified; do not generalize a small
decoder's result to an entire diffusion model. The native reader handles a
restricted state-dict representation without executing Python callables; arbitrary
serialized modules, TorchScript and legacy TAR checkpoints are not supported.
Use trusted model files. There is no public conversion API or load-time
quantization/mmap option. Weights load eagerly; see the
[memory check](./image-generation-memory-and-limits#memory-check) before substituting larger unquantized files.

On iOS, the pinned `v0.4.0` runtime admits full-VAE recipes through Metal
graph splitting. Device qualification on v0.4.0 is pending. External
VAE/TAESD components, SDXL-size VAEs, larger resolutions and SDXS through
`sd_dart_new_sd_ctx` lack device qualification. A Metal command-buffer failure
surfaces as an error. A runtime without the split refuses full VAE and
external-decoder recipes. Use `ImageModelPlacement(vaeOnCpu: true)` for Metal
diffusion or `ComputeDevice.cpu`. Its intrinsic tiny-decoder v1 context
policy still serves SDXS Metal decoding. See the
[iOS device receipts](../maintainers/feature-validation#ios-full-vae-graph-split).

#### Pinned-runtime format checks

See the [full-checkpoint container checks](../maintainers/feature-validation#full-checkpoint-container-checks)
for the tested files, runtime and results.

### Sources

Each file uses a `ModelSource`: a local file (`ModelSource.path`), an HTTP(S)
URL, or a Hugging Face file. Pin Hugging Face files with `@<sha>` to keep the
bytes stable. `ImageGenerationEngine.load` resolves each file and reads its
header to determine its runtime role. For split models, supply the other files
through `ImageGenerationModel.components` using `ImageModelComponent.auto`
or an explicit role.

### Roles

The engine reads only each file's header: the GGUF metadata and tensor
names, or the safetensors header. A GGUF whose `general.architecture` names a
llama.cpp language model, such as `qwen3`, is the `llm` text encoder; reading
stops there. Each file gets one `ImageModelRole`:

| Role | Files | Used by |
| --- | --- | --- |
| `checkpoint` | A single file with diffusion weights, usually with its VAE and text encoders | SD 1.x, 2.x, SDXL, SD 3.5 Medium |
| `diffusionModel` | A split model's UNet or transformer | SD 3.5 Large, FLUX, Z-Image, Qwen-Image |
| `vae` | A VAE | Split models; replaces a checkpoint's own |
| `taesd` | A tiny autoencoder that replaces the VAE decoder | Any family with a matching one |
| `clipL`, `clipG`, `t5xxl` | Text encoders | SDXL-style, SD 3.5, FLUX |
| `llm` | A language-model text encoder | Z-Image, Qwen-Image |
| `controlNet` | A ControlNet, loaded with the model | SD 1.x, in the [ControlNet recipe](./image-generation-advanced#controlnet) |

The set needs exactly one `checkpoint` or `diffusionModel` and at most one
file per role. `load` throws `LlamaModelException`, naming files by position
(the main file, component 1, ...) and never by path, for:

- a LoRA adapter, upscaler or vision projector, which text to image does not
  load;
- `taesd_decoder.safetensors`, a decoder-only export the runtime rejects
  (use `diffusion_pytorch_model.safetensors`);
- two files in one role, a checkpoint plus separate diffusion weights, or no
  diffusion weights;
- a VAE or tiny autoencoder for other latent channels than the diffusion
  model's, such as TAESD (4 channels) with FLUX (16);
- a file with no known image-model layout, such as a pickled `.ckpt`;
- a `ModelLoadOptions.sha256` mismatch, which names the main file the same
  way.

Give such a file its role yourself with `ImageModelComponent(source, role:
ImageModelRole.vae)`, or `ImageGenerationModel(source, role: ...)` for the
main file. Explicit roles also settle layouts the header cannot tell apart:
TAESD and TAESDXL share one layout, as do TAESD3 and TAEF1, and only their
latent channels are checked. Classification runs on the downloaded file, so a
wrong file costs its download; it stays in the cache.

### Loading options

- `onProgress` reports all files together as a `ModelDownloadProgress`.
  Cached and local files count as received. `totalBytes` is `null` until
  every file's size is known: local files from the start, others when their
  download starts.
- `download:` (`ModelLoadOptions`, as for `LlamaEngine.load`)
  applies to every remote file: cache policy and directory, `bearerToken` and
  headers (for example for a gated repository), resume, retries and the
  cancel token. Local files take only the cancel token. `bearerToken` and
  headers never cross hosts: with them set, remote files on more than one
  origin (scheme, host and port) throw `LlamaArgumentException` before
  anything downloads from a second host.
  `ModelLoadOptions.sha256` verifies a single-file model; with components
  it throws `LlamaUnsupportedException`, since it cannot name one of
  several files. Verify each component independently before loading it.
- A cancelled load throws `LlamaStateException`. Cancelling stops a
  download at once; the native load cannot be interrupted, so a cancel
  during it takes effect when it returns, and the model it loaded is freed.
  A failed download throws what the download manager throws, usually
  `LlamaModelException`, with URL secrets redacted.
- The runtime check, `params:` checks and the check that every local file
  exists run first, so an unsupported platform, including the web, downloads
  nothing.
- A load is atomic: when it throws, nothing stays loaded.
- `store: ModelFileStore(resolver: ..., downloadManager: ...)` replaces the
  defaults, as for `LlamaEngine`. The default download manager caches in the
  same place as `LlamaEngine`'s: on Android and iOS, `llamadart/models` in the
  app's cache directory, or `DefaultModelDownloadManager.globalCacheDirectory`
  when set. Pass
  `ModelFileStore(downloadManager: DefaultModelDownloadManager.appPrivate(cacheDirectory: ...))`
  to keep the weights somewhere else.

`engine.roles` reports the file in each role.

## Generate an image with SDXS

With the [runtime bundled](#bundle-the-runtime), save this script in your
Dart package as `bin/generate_image.dart` and run
`dart run bin/generate_image.dart`. The first run downloads the pinned
683 MB SDXS-512 checkpoint. It uses one step at guidance 1 and writes a
512x512 PNG.

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(
      ModelSource.parse(
        'hf://concedo/sdxs-512-tinySDdistilled-GGUF@'
        '3144d898d61492f8382ffcabec055733fc5b2a0e/'
        'sdxs-512-tinySDdistilled_Q8_0.gguf',
      ),
    ),
  );
  try {
    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        steps: 1,
        guidanceScale: 1,
      ),
    );
    await File('sdxs.png').writeAsBytes(result.images.first.toPng());
  } finally {
    await engine.dispose();
  }
}
```

## Examples

The [basic app's image presets](../examples/basic-app#image-generation-presets)
include SDXS, SD-Turbo and the four desktop models. The
[chat app's image screen](../examples/chat-app#image-generation) runs SDXS and
SD-Turbo with TAESD.

## Next

1. [Generate and settings](./image-generation-settings): requests, attention
   and VAE settings, VAE tiling, caches, module placement, warm-up, progress
   and cancellation.
2. [Memory, logs and limits](./image-generation-memory-and-limits): the memory
   check, runtime logs, errors and known limits.
3. [Advanced requests](./image-generation-advanced): seamless textures, local
   checkpoint sets, image editing, ControlNet, hires fix and reference image
   editing.

## Moved topics

These sections have moved. Published package README links continue to land here.

### VAE tiling

See [VAE tiling](./image-generation-settings#vae-tiling) for the current instructions.

### Conditioning cache

See [Conditioning cache](./image-generation-settings#conditioning-cache) for the current instructions.

### Module placement and GPU memory

See [Module placement and GPU memory](./image-generation-settings#module-placement-and-gpu-memory) for the current instructions.

### Seamless textures

See [Seamless textures](./image-generation-advanced#seamless-textures) for the current instructions.

### Local checkpoint sets

See [Local checkpoint sets](./image-generation-advanced#local-checkpoint-sets) for the current instructions.

### Image editing

See [Image editing](./image-generation-advanced#image-editing) for the current instructions.

### ControlNet

See [ControlNet](./image-generation-advanced#controlnet) for the current instructions.

### Hires fix

See [Hires fix](./image-generation-advanced#hires-fix) for the current instructions.

### Reference image editing

See [Reference image editing](./image-generation-advanced#reference-image-editing) for the current instructions.

### Recipes

See [Image generation presets](../examples/basic-app#image-generation-presets)
for the runnable presets and their inputs.

### Model licenses

See [Model licenses](../examples/basic-app#model-licenses) for model and
component license sources.

### Desktop models

See [Desktop model timings](../maintainers/feature-validation#desktop-model-timings)
for the measured desktop presets and their qualification limits.

### Other families

See [Other image model families](../examples/basic-app#other-image-model-families)
for the SD 3.5 Medium and Qwen-Image recipes.
