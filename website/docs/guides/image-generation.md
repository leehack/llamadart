---
title: On-device image generation
sidebar_label: Image generation
description: Generate images from text prompts on device with the experimental ImageGenerationEngine and the opt-in stable-diffusion.cpp runtime.
---

`ImageGenerationEngine` turns a text prompt into images on the device. It runs
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) through
the opt-in `stable_diffusion` native runtime, separately from `LlamaEngine`.

The API is experimental. Two small, distilled SD 1.x/2.x-family models are
validated: SDXS-512 and SD-Turbo. It is text-to-image only: no image-to-image,
inpainting, LoRA or ControlNet yet.

## Support

| Platform | Device | Minimum OS | Notes |
| --- | --- | --- | --- |
| macOS (arm64, x86_64) | Metal, CPU | macOS 13.3 | Validated on an M4 Max |
| iOS (arm64, arm64 simulator) | Metal, CPU | iOS 16.4 | Validated on iPhone 16 Pro and iPhone SE 3; no x86_64 simulator runtime |
| Android arm64 | CPU | Not set by llamadart | Needs Armv8.2 dot-product and fp16 (`asimddp`, `fphp`, `asimdhp`); validated on Pixel 9 Pro, Galaxy S24 and Galaxy A53; no x64 runtime |
| Linux (arm64, x64) | CPU, or Vulkan with the Vulkan build | Not set by llamadart | x64 CPUs need AVX2, FMA, F16C and BMI2; validated on x64 with CPU and an NVIDIA L4 |
| Windows x64 | CPU, or Vulkan with the Vulkan build | Not set by llamadart | Needs the Microsoft Visual C++ 2015-2022 Redistributable (x64) and AVX2; the Vulkan build needs a GPU driver that provides `vulkan-1.dll`; validated on Windows Server 2022 with CPU and an NVIDIA L4; no arm64 runtime |
| Web | None | | `load` throws `LlamaUnsupportedException` |

Measured with the prototype on the same runtime, 512x512, one step, warm:

| Device | SDXS Q8 (651 MB) | SD-Turbo Q8 + TAESD (1.9 GB) |
| --- | --- | --- |
| M4 Max, Metal | 1.5 s | 1.2 s |
| iPhone 16 Pro, Metal | 1.7 s | 4.1 s |
| Galaxy S24, CPU | 5.9 s | 11.8 s |
| Galaxy A53, CPU | 26 to 29 s | Does not fit in memory |

`await ImageGenerationEngine.checkRuntime()` reports whether this build and
device can generate images, and why not, without loading a model or blocking
the calling isolate. `ImageGenerationEngine.runtimeCapabilities()` returns the
same result synchronously, but its first call can block for seconds; see
[First-image latency and warm-up](#first-image-latency-and-warm-up).

## Bundle the runtime

The runtime adds about 40 to 70 MB per target, so it is never bundled by
default. Name it in the app's `pubspec.yaml`, then run `flutter clean` once:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp, stable_diffusion]
```

Linux and Windows get the Vulkan build when `llamadart_native_backends`
selects Vulkan, which it does by default; set
`llamadart_stable_diffusion_backends: [cpu]` for the CPU build. See
[Native runtime configuration](../platforms/native-build-hooks#opt-in-stable_diffusion-runtime-experimental).

## Get a model

| Preset | Files | Defaults |
| --- | --- | --- |
| `ImageGenerationModel.sdxs(path)` | `sdxs-512-tinySDdistilled_Q8_0.gguf` from [`concedo/sdxs-512-tinySDdistilled-GGUF`](https://huggingface.co/concedo/sdxs-512-tinySDdistilled-GGUF) (651 MB) | 1 step, guidance 1 |
| `ImageGenerationModel.sdTurbo(path, taesdPath: ...)` | `sd_turbo-f16-q8_0.gguf` from [`Green-Sky/SD-Turbo-GGUF`](https://huggingface.co/Green-Sky/SD-Turbo-GGUF) (1.9 GB), optionally `diffusion_pytorch_model.safetensors` from [`madebyollin/taesd`](https://huggingface.co/madebyollin/taesd) (9 MB) | 1 step, guidance 1 |
| `ImageGenerationModel.custom(files, defaults: ...)` | Other SD 1.x/2.x checkpoints, single-file or split | 20 steps, guidance 7 |

SDXS is distilled for exactly one step. SD-Turbo takes one to four steps; four
add detail at about four times the sampling time. TAESD replaces the full VAE
decoder: several times faster and far less memory, at a small quality cost.
Use it on phones. `taesd_decoder.safetensors` from the same repository is
rejected by the runtime; use `diffusion_pytorch_model.safetensors`.

The engine takes local files. Download them with the package-managed cache,
which resumes interrupted downloads:

```dart
final downloads = DefaultModelDownloadManager();
final entry = await downloads.ensureModel(
  ModelSource.parse(
    'hf://concedo/sdxs-512-tinySDdistilled-GGUF/'
    'sdxs-512-tinySDdistilled_Q8_0.gguf',
  ),
);
final model = ImageGenerationModel.sdxs(entry.filePath);
```

`.custom` is experimental. Larger families stable-diffusion.cpp supports, such
as SDXL or FLUX, may load but are untested and can exceed phone memory.

## Generate

```dart
final engine = await ImageGenerationEngine.load(
  model,
  options: const ImageGenerationOptions(device: ImageGenerationDevice.auto),
);
print('${engine.capabilities.modelVersion} on '
    '${engine.capabilities.backendName}');

final task = engine.generate(
  const ImageGenerationRequest(
    prompt: 'a red fox in autumn leaves',
    width: 512,
    height: 512,
    seed: 42,
  ),
);
await for (final event in task.events) {
  switch (event) {
    case ImageGenerationProgressEvent(:final phase, :final step, :final steps):
      print('$phase $step/$steps');
    case ImageGenerationFinalEvent(:final result):
      final png = result.images.first.toPng();
      print('${png.length} PNG bytes, seed ${result.seed}');
  }
}
await engine.dispose();
```

`engine.generateImage(request)` is the one-call form; it returns the
`ImageGenerationResult` or throws the failure.

- Width and height are multiples of 8 from 64 to 2048. SD 1.x/2.x models are
  trained at 512; SDXS and SD-Turbo also work at 256. The runtime rounds the
  size up to a multiple of 64 for these models, so a 200x136 request produces
  256x192; `GeneratedImage.width` and `height` report the real size.
- `steps` and `guidanceScale` fall back to the model's defaults. A guidance of
  1 skips the negative prompt and halves the work per step.
- A `null` seed picks one at random. `result.seed` reports the seed used, and
  image `i` of `count` used `seed + i`. The same seed, size, steps and model
  reproduce the same pixels.
- `GeneratedImage.pixels` holds row-major RGB bytes; `toPng()` encodes them.
- Invalid requests throw `LlamaImageGenerationException` before a task
  starts.

`load` loads every weight up front. The first image in a process can still be
slow while the GPU compiles shaders; see
[First-image latency and warm-up](#first-image-latency-and-warm-up).

## First-image latency and warm-up

ggml compiles GPU shaders the first time a process needs them, in two places:

- The first runtime probe in a process (`checkRuntime()`,
  `runtimeCapabilities()` or `load()`) initializes the GPU backend. On Apple
  GPUs this compiles ggml's Metal library. `checkRuntime()` and `load()` run
  the probe on a separate isolate; `runtimeCapabilities()` runs it on the
  calling isolate and blocks it.
- The first generation on the GPU compiles the pipelines it runs.

The operating system or GPU driver caches the compiled shaders on disk, so
later launches are faster. ggml in the bundled runtime keeps no cache of its
own (no Metal binary archive or Vulkan pipeline cache); whether iOS and
Android keep the driver cache across launches is not measured yet.

| Device and step | Empty shader cache | Cached shaders |
| --- | --- | --- |
| M4 Max, Metal: first runtime probe | 15.5 to 18.7 s | 0.4 to 0.5 s |
| M4 Max, Metal: SDXS 512x512, first image, then next | 1.0 s, then 0.46 s | 0.41 to 0.48 s, then 0.38 to 0.45 s |
| M4 Max, Metal: SD-Turbo + TAESD 512x512, first image, then next | 0.79 to 0.90 s, then 0.54 to 0.66 s | 0.68 to 0.73 s, then 0.67 to 0.68 s |
| NVIDIA L4, Linux Vulkan: first image, then SDXS warm | About 12 s, then 176 ms | Later processes reuse the driver cache |
| NVIDIA L4, Windows Vulkan: first image, then SDXS warm | About 45 s, then 571 ms | Later processes reuse the driver cache |
| iPhone 16 Pro, Metal | About 19 s before the first image on first launch, not split between the probe and the image | Not measured |

The empty-cache M4 Max figures ran with `MTL_SHADER_CACHE_SIZE=0`, which
turns the Metal shader cache off. The Vulkan figures are from
[#779](https://github.com/leehack/llamadart/issues/779). The CPU compiles
nothing; its first image is as fast as the next.

`warmUp` moves the pipeline compile off the first real image. It runs one
single-step generation at the given size and discards it:

```dart
final engine = await ImageGenerationEngine.load(model);
// While the user writes the prompt:
await engine.warmUp(width: 512, height: 512);
```

- Warm up at the size the app will generate. ggml picks some pipelines by
  tensor size: on the M4 Max a 64x64 warm-up left about 0.1 s of the 512x512
  compile, while a 512x512 warm-up left none.
- It moves the cost, it does not remove it. Call it while the user is not
  waiting, such as right after `load` while they type; `load`, `warmUp` and
  `generate` back to back take no less time than `load` and `generate`.
- It holds the one-operation slot: await it before the next `generate` or
  `load`, which otherwise throw `LlamaStateException`. `dispose()` cancels a
  running warm-up, which then completes normally.
- On the CPU it returns at once.

`warmUp` cannot move the Metal library compile, which happens before an
engine exists. To keep a Flutter UI responsive on a first launch, check the
runtime with `checkRuntime()` and show a progress indicator until it
completes:

```dart
final capabilities = await ImageGenerationEngine.checkRuntime();
```

With an empty shader cache on the M4 Max, `runtimeCapabilities()` stalled a
10 ms timer on the calling isolate for the whole 16 s probe. During
`checkRuntime()` the timer kept firing, with gaps of 13 to 31 ms in most
runs. One pause remains: a garbage collection on the calling isolate waits
while the probe isolate loads the runtime library (about 0.4 s), so an
allocating UI can pause once for up to that long (179 ms in the chat
example's macOS E2E). Calls that overlap share one probe. The compiled
library belongs to the process, so later probes, including
`runtimeCapabilities()`, return at once. `load()` probes the same way and
does not block the caller either.

## Progress phases

The runtime reports all progress through one `(step, steps)` callback, so the
engine labels it from the call sequence:

1. `encodingPrompt` when the generation starts.
2. `sampling` with `0/steps` when each image's first step starts, then one
   event per step. `imageIndex` says which image.
3. `decoding` with `0/count` after the last image's last step, then the final
   event. The runtime reports decoding progress only when it decodes in tiles.

`loading` appears only if the runtime loads weights lazily, which the engine
avoids by loading them eagerly.

## Cancellation, concurrency and disposal

- `task.cancel()` stops before the next sampling step or before decoding, and
  `task.done` then reports `cancelled`. A cancel issued before the runtime
  starts is honored too.
- stable-diffusion.cpp reports progress through one process-wide callback, so
  one generation or model load runs at a time. Another `generate` or `load`
  meanwhile throws `LlamaStateException`, even on a different engine. The guard
  covers engines in one isolate; do not generate from several isolates at
  once.
- `dispose()` cancels a running generation, waits for it, and frees the model.
  `generateImage` then throws `LlamaStateException`.
- Free the model before the app quits: on macOS Metal, quitting with a model
  still loaded aborts the process. Flutter desktop apps do not run
  `State.dispose` on quit, so await `dispose()` in
  `AppLifecycleListener.onExitRequested`. If `ImageGenerationEngine.load` is
  still running, await it there and dispose the engine it returns.
- Generation runs in a worker isolate; the calling isolate stays responsive.

## Memory check

Before loading, the engine estimates the model's peak memory as its file
sizes plus a quarter, plus 256 MiB, and compares that with what the device
reports:

| Platform | Compared with |
| --- | --- |
| Android, Linux | `MemAvailable` from `/proc/meminfo` |
| iOS | The app's remaining memory limit (`os_proc_available_memory`) |
| macOS | Physical memory |
| Windows | Not checked |

A model that does not fit throws `LlamaModelException` naming both figures,
instead of the system killing the app. The estimate is simple and matches the
measured SDXS peaks (1.06 to 1.55 GB of process memory); set
`ImageGenerationOptions(checkMemory: false)` to load anyway.

## Errors

| Exception | When |
| --- | --- |
| `LlamaUnsupportedException` | The runtime is not bundled, the platform or CPU is unsupported, on the web, or `ImageGenerationDevice.gpu` without a GPU |
| `LlamaModelException` | A file is missing, the model does not fit, or the runtime cannot load it as an image model |
| `LlamaImageGenerationException` | An invalid request or options |
| `LlamaStateException` | Another generation or load is running, or the engine is disposed |
| `LlamaInferenceException` | The runtime failed a generation, for example an aborted Metal command buffer or running out of memory; the engine runs the next request |

## Known limits

- Runtime logs are not forwarded to `LlamaLogger`: stable-diffusion.cpp's log
  text is only valid during a call made from its own threads
  ([stable-diffusion-native#3](https://github.com/leehack/stable-diffusion-native/issues/3)).
  ggml's own backend messages still reach stderr.
- Android runs on the CPU only: ggml Vulkan and OpenCL crashed or ran slower
  on the phones tried
  ([stable-diffusion-native#2](https://github.com/leehack/stable-diffusion-native/issues/2)).
- iOS can abort a Metal command buffer under GPU pressure (seen once with
  SD-Turbo at four steps); the task fails and the next request runs.
- Windows is not memory-checked. Per-platform validation results, including
  timings, are in [#779](https://github.com/leehack/llamadart/issues/779).
- The web has no image runtime yet
  ([#780](https://github.com/leehack/llamadart/issues/780)).

The [basic app](../examples/basic-app) has a command-line image example, and
the [chat app](../examples/chat-app) has an image screen that downloads SDXS
or SD-Turbo with TAESD and generates on device.
