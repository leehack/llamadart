---
name: llamadart-image-generation
description: >-
  Use when generating images from text prompts in a llamadart app with the
  Preview (experimental) ImageGenerationEngine: opting into the stable_diffusion
  runtime, loading SDXS or SD-Turbo (with TAESD) or the desktop SDXL-Lightning,
  FLUX.1-schnell, SD 3.5 Large Turbo and Z-Image-Turbo models from pinned
  Hugging Face files or local paths, showing download and generation
  progress, cancelling,
  saving PNGs, or handling unsupported platforms, memory refusals and
  concurrent-generation errors.
---

# Image generation with llamadart

## Guidelines

- Image generation is a Preview: the `ImageGenerationEngine` API is
  experimental and may change. It is separate from `LlamaEngine`. It runs
  stable-diffusion.cpp through the opt-in `stable_diffusion` native runtime.
  Text-to-image only: no image-to-image, inpainting, LoRA or ControlNet.
- The app must bundle the runtime (about 40 to 70 MB per target); it is never
  included by default or by `all`. In the app's `pubspec.yaml`:

  ```yaml
  hooks:
    user_defines:
      llamadart:
        llamadart_native_runtimes: [llama_cpp, stable_diffusion]
  ```

  Keep `litert_lm` in the list if the app also loads `.litertlm` models. Run
  `flutter clean` once after changing it. Linux and Windows bundle the Vulkan
  build when `llamadart_native_backends` selects Vulkan (the default);
  `llamadart_stable_diffusion_backends: [cpu]` picks the CPU build.
- Flutter iOS and macOS apps should add the
  `llamadart_stable_diffusion_flutter` companion package. It links the
  runtime's XCFramework through Swift Package Manager and selects the runtime
  on iOS and macOS without the entry above. Without it the hook bundles the
  runtime, and App Store Connect rejects that iOS framework's
  `MinimumOSVersion`; only Xcode and `xcodebuild` show the build warning about
  it. Pair companion `0.0.2` with core `0.11.1` and `0.11.0`; adding it opts
  the app into the runtime (about 37 MB per Apple target).
- Platforms: Android arm64 (CPU only; Armv8.2 dot-product and fp16), iOS 16.4+
  and macOS 13.3+ (Metal), Linux arm64/x64 and Windows x64 (CPU or Vulkan; x64
  CPUs need AVX2, FMA, F16C and BMI2). Web, Android x64 and Windows arm64
  are unsupported. Windows needs the latest
  Microsoft Visual C++ v14 Redistributable (x64).
- Gate UI on `await ImageGenerationEngine.checkRuntime()` (no model needed;
  probes on a separate isolate): show a progress indicator until it
  completes, then `unsupportedReason` when `isSupported` is false.
  `ImageGenerationEngine.load` throws `LlamaUnsupportedException` in the same
  cases. There is no synchronous probe.
- `await engine.capabilities` (an `EngineCapabilities`) reports the loaded
  model's family and device, and unsupported once disposed; it never throws.
  It changes only on `dispose()`, so read it once after `load` and keep it in
  the widget state instead of awaiting it in `build`.
- Models: `ImageGenerationModel(mainSource, components: [...])`. Every file
  is a `ModelSource` (`ModelSource.path`, an HTTP(S) URL or `hf://owner/repo@
  sha/file`); pin a commit. The library has no presets: the app owns each
  model's files and request settings. `load` downloads remote files, then
  reads each file's header (GGUF metadata and tensor names, safetensors
  header) to give it its `ImageModelRole`: `checkpoint`, `diffusionModel`,
  `vae`, `taesd`, `clipL`, `clipG`, `t5xxl` or `llm`. Pass components as
  `ImageModelComponent.auto(source)` in any order; use
  `ImageModelComponent(source, role: ImageModelRole.vae)` (or
  `ImageGenerationModel(source, role: ...)`) only for a file the header check
  cannot classify, such as a `.ckpt`, or to pick between same-layout files
  (TAESD vs TAESDXL, TAESD3 vs TAEF1). `load` refuses LoRA, ControlNet,
  upscaler and vision-projector files, `taesd_decoder.safetensors`, two
  files in one role, no or two sources of diffusion weights, and a VAE or
  TAESD for other latent channels (TAESD with FLUX), naming files by
  position, never by path. `engine.roles` reports the assignment. Validated
  models and request settings (the guide's recipes have pinned files):
  - SDXS-512 (`concedo/sdxs-512-tinySDdistilled-GGUF`
    `sdxs-512-tinySDdistilled_Q8_0.gguf`, 683 MB): request `steps: 1,
    guidanceScale: 1`; do not raise them.
  - SD-Turbo (`Green-Sky/SD-Turbo-GGUF` `sd_turbo-f16-q8_0.gguf`, 2.0 GB):
    `steps: 1, guidanceScale: 1`, up to 4 steps for detail. Add
    `madebyollin/taesd` `diffusion_pytorch_model.safetensors` as a component
    on phones.
  - Desktop models (desktop GPUs and Macs, not phones; 7 to 12 GB), all at
    `width: 1024, height: 1024, guidanceScale: 1`: SDXL-Lightning
    (`ByteDance/SDXL-Lightning` `sdxl_lightning_4step.safetensors`, optional
    `madebyollin/taesdxl`; `steps: 4, sampler: ImageGenerationSampler.euler,
    scheduler: ImageGenerationScheduler.sgmUniform`); FLUX.1-schnell
    (`second-state/FLUX.1-schnell-GGUF` Q4_0 and `ae.safetensors`, `clip_l`
    and `t5xxl` Q8_0 from `second-state/stable-diffusion-3.5-medium-GGUF`;
    `madebyollin/taef1` can replace `ae`; `steps: 4`); SD 3.5 Large Turbo
    (`city96/stable-diffusion-3.5-large-turbo-gguf` Q4_0, the same encoders
    plus `clip_g`, and `madebyollin/taesd3` since the SD 3.5 VAE is gated;
    `steps: 4`); Z-Image-Turbo (`leejet/Z-Image-Turbo-GGUF` Q4_K,
    `unsloth/Qwen3-4B-Instruct-2507-GGUF` Q4_K_M and the FLUX `ae`;
    `steps: 8`). The memory check asks for about 8.6 GiB for
    SDXL-Lightning, 8.3 GiB for Z-Image-Turbo, and 14.5 and 13.1 GiB for
    FLUX.1-schnell and SD 3.5 Large Turbo (`load` refuses those two on a
    16 GB Mac under Metal's working-set cap).
- `ImageGenerationEngine.load(model, params:, download:, onProgress:,
  store:)`: `params` (`ImageModelParams`) holds runtime settings; `download`
  (`ModelLoadOptions`, the same type as `LlamaEngine`) sets the cache policy
  and directory, `bearerToken` or headers, retries and a `cancelToken` for
  every remote file; local files take only the cancel token. `bearerToken`
  and headers never cross hosts: remote files on more than one origin with
  them set throw `LlamaArgumentException`. `sha256` verifies a
  single-file model and is rejected (`LlamaUnsupportedException`) once
  there are components.
  `onProgress` reports `ModelDownloadProgress` across all files; cached and
  local files count as received, and `totalBytes` is `null` until every
  file size is known. A cancelled load throws `LlamaStateException`
  (during the native load, once it returns, freeing the model); a
  failed download throws what the download manager throws (usually
  `LlamaModelException`). The runtime check, `params` checks and local-file
  checks run before anything downloads, so the web and unsupported devices
  download nothing. Loads are atomic: on failure nothing stays loaded. The
  default download manager caches where `LlamaEngine`'s does (on Android and
  iOS, `llamadart/models` in the app's cache directory, or
  `DefaultModelDownloadManager.globalCacheDirectory`); pass `store:
  ModelFileStore(downloadManager: DefaultModelDownloadManager.appPrivate(
  cacheDirectory: ...))` for another directory.
- Model licenses differ by model, including on commercial use (Stability AI
  Community License for SD-Turbo and SD 3.5 Large Turbo, CreativeML Open
  RAIL++-M for SDXS and SDXL-Lightning, Apache 2.0 for FLUX.1-schnell and
  Z-Image-Turbo). Tell users to check the model card's license before
  shipping a model; the guide's Model licenses table links each one.
- `ImageGenerationRequest` carries every generation setting: size, steps
  and guidance fall back to 512x512, 20 and 7 (undistilled SD 1.x/2.x), so
  always set the model's own. It also takes `sampler`
  (`ImageGenerationSampler`), `scheduler` (`ImageGenerationScheduler`) and
  `flowShift` (flow-matching models only, greater than 0, at most 100);
  `null` keeps the runtime's default for the model. SDXL-Lightning wants
  `euler` with `sgmUniform`.
- `load` checks every file exists and, unless
  `ImageModelParams(checkMemory: false)`, refuses a model whose estimate
  (file sizes plus a quarter plus 512 MiB, for the model's native size)
  exceeds the device figure with `LlamaModelException`: on Android the larger
  of `MemAvailable` and half of `MemTotal` less the app's own memory,
  `MemAvailable` on Linux CPU, the app's limit on iOS, physical memory on
  macOS, capped on Metal by the GPU's recommended working set. On a Vulkan
  GPU (Linux, Windows) it is the GPU's free memory when the driver reports
  one, otherwise its total; an integrated GPU gets the host figure. The
  Windows CPU and integrated GPUs on Windows are not checked, and the Vulkan
  check has not run on a physical GPU yet. SD-Turbo usually
  loads on 8 GB Android phones when no chat model is loaded, and is usually
  refused on 6 GB ones; offer SDXS there.
- `ImageModelParams(device: ComputeDevice.auto | cpu | gpu, threads: 0)`.
  `gpu` without a GPU (Android, CPU builds) and `npu` throw
  `LlamaUnsupportedException`.
  `flashAttention` and `vaeDirectConvolution` default to `null`, which picks
  per device: flash attention on for the CPU and Metal, off on Vulkan; direct
  VAE convolutions on except on Metal (about 7 times slower there) and when
  a tiny autoencoder decodes (a `taesd` file, or a checkpoint embedding one,
  as SDXS does, seen from its header). Leave them `null` unless measuring. Direct VAE
  convolutions leave the image identical; flash attention changes pixels
  slightly.
- `load` loads weights eagerly, but GPU shaders compile on first use: the
  first runtime probe in a process (`checkRuntime()` or `load()`, both off
  the calling isolate) compiles the Metal library on Apple (about 16 s on an
  M4 Max with an empty shader cache), and the first GPU image compiles its
  pipelines (12 s on Linux Vulkan, 45 s on Windows Vulkan, against under
  0.6 s warm). The OS or driver caches them for later launches. Show
  progress.
- `await engine.warmUp(width:, height:, guidanceScale:)` right after
  `load`, while the user writes the prompt, moves the pipeline compile off
  the first real image. Pass the size and guidance the app generates with,
  since another size can compile more. At a desktop model's
  1024x1024 it costs one step and a decode (about 2 to 4 s for SDXL-Lightning
  with TAESDXL on an M4 Max). It runs one discarded single-step image,
  returns at once on the CPU, holds the one-operation slot (await it before
  `generate`), and completes normally when `dispose()` cancels it.
- `await engine.generate(request)` returns the running
  `ImageGenerationTask`; invalid requests throw
  `LlamaImageGenerationException` first. Width and
  height are multiples of 8 from 64 to 2048; use the model's native size
  (512x512 for SDXS and SD-Turbo, 1024x1024 for the desktop models). 256 is fine for SDXS and SD-Turbo; the runtime
  rounds up to 64, so read the size from `GeneratedImage`. Steps are 1 to
  150, guidance 0 to 30, count 1 to 16.
  `seed: null` is random; `result.seed` reports it, image `i` used
  `seed + i`, and the same seed reproduces the same pixels.
- `task.events` (single subscription): `ImageGenerationProgressEvent`
  (`phase`: `encodingPrompt`, `sampling`, `decoding`, rarely `loading`;
  `step`, `steps`, `imageIndex`, `imageCount`), then one
  `ImageGenerationFinalEvent(result)`. The stream never emits an error.
  `await task.result` returns the `ImageGenerationResult` (`images`, `seed`,
  `elapsed`), or throws the failure, or `LlamaStateException` when
  cancelled; `task.done` reports the same outcome as an
  `ImageGenerationCompletion` and never throws.
- `engine.generateImage(request)` is the one-call form of
  `(await engine.generate(request)).result`.
- `GeneratedImage` has `width`, `height`, `channels` (3) and row-major RGB
  `pixels`; `toPng()` returns PNG bytes (for `Image.memory` or a file).
- One generation or model load at a time per process (stable-diffusion.cpp
  reports progress for the whole process): a second one throws
  `LlamaStateException`,
  even on another engine. Await `task.done` before the next request; disable
  the Generate button while one runs. Do not generate from several isolates.
- `task.cancel()` stops before the next sampling step; `done` reports
  `cancelled`, `result` throws `LlamaStateException`, and the stream closes
  without a final event. `dispose()` cancels
  a running task, waits, then frees the model.
- Progress events arrive in groups, up to about 50 ms after the runtime
  reports them (the engine polls the runtime), always in order and before
  the final event.
- Dispose before a Flutter app quits. A process that ends with an image
  model loaded no longer aborts on macOS Metal, but nothing cancels a running
  generation when a Dart program ends or a Flutter app quits, so the process
  stays until the generation finishes. Flutter
  desktop apps skip `State.dispose` on
  quit; await `dispose()` in `AppLifecycleListener.onExitRequested`. If
  `ImageGenerationEngine.load` is still running, await it there and dispose
  the engine it returns. When the engine's owner can be disposed before quit
  (a pushed route), its listener goes with it: make one app-level exit
  listener await every engine's disposal, including one its owner already
  started.
- A runtime failure (for example an aborted Metal command buffer or out of
  memory) fails the task with `LlamaInferenceException`; the engine stays
  usable for the next request.
- A load the runtime rejects (`LlamaModelException`) quotes the errors
  stable-diffusion.cpp logged, with files named by role, such as
  `<checkpoint file>`. For a split checkpoint it also names the missing roles
  (no `vae`/`taesd`, no text encoder); a file in the wrong role only gets
  `get sd version from file failed`, so check that each file is in its role.
- Runtime messages reach the `LlamaLogging.configure` handler when both
  `level` and `nativeLevel` admit them (default `none`: nothing is logged,
  to stderr either). Configure before `load`; messages arrive after each
  load and generation, not during one.

## Examples

Load SDXS from a local file, stream progress and save a PNG:

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> generateFox(String sdxsPath, String outputPath) async {
  final ImageGenerationCapabilities runtime =
      await ImageGenerationEngine.checkRuntime();
  if (!runtime.isSupported) {
    throw LlamaUnsupportedException(runtime.unsupportedReason!);
  }

  final ImageGenerationEngine engine = await ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(sdxsPath)),
  );
  try {
    final ImageGenerationTask task = await engine.generate(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        steps: 1,
        guidanceScale: 1,
        seed: 42,
      ),
    );
    task.events.listen((ImageGenerationEvent event) {
      if (event
          case ImageGenerationProgressEvent(
            :final ImageGenerationPhase phase,
            :final int step,
            :final int steps,
          )) {
        print('${phase.name} $step/$steps');
      }
    });
    final ImageGenerationResult result = await task.result;
    await File(outputPath).writeAsBytes(result.images.first.toPng());
    print('Seed ${result.seed} in ${result.elapsed.inMilliseconds} ms');
  } on LlamaInferenceException catch (error) {
    print('Generation failed, engine still usable: ${error.message}');
  } finally {
    await engine.dispose();
  }
}
```

SD-Turbo with TAESD from pinned Hugging Face files, with download progress,
cancellable while downloading or generating:

```dart
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<Uint8List?> generateWithCancel(Future<void> userCancelled) async {
  final ModelDownloadCancelToken cancelDownload = ModelDownloadCancelToken();
  ImageGenerationTask? task;
  userCancelled.then((_) {
    cancelDownload.cancel();
    task?.cancel();
  });

  final ImageGenerationEngine engine;
  try {
    engine = await ImageGenerationEngine.load(
      ImageGenerationModel(
        ModelSource.parse(
          'hf://Green-Sky/SD-Turbo-GGUF@'
          '19a31586d02d64a73b4419bc193b3ecfaf38e1f0/sd_turbo-f16-q8_0.gguf',
        ),
        components: <ImageModelComponent>[
          ImageModelComponent.auto(
            ModelSource.parse(
              'hf://madebyollin/taesd@614f76814bbe30edbe2e627ace1c2234c81a2c0e/'
              'diffusion_pytorch_model.safetensors',
            ),
          ),
        ],
      ),
      download: ModelLoadOptions(cancelToken: cancelDownload),
      onProgress: (ModelDownloadProgress progress) {
        final double? fraction = progress.fraction;
        if (fraction != null) {
          print('Files ${(fraction * 100).toStringAsFixed(0)}%');
        }
      },
    );
  } on LlamaStateException {
    return null; // Cancelled while downloading.
  } on LlamaModelException catch (error) {
    print('Download failed, or the model was refused: ${error.message}');
    return null;
  }

  try {
    final ImageGenerationTask running = task = await engine.generate(
      const ImageGenerationRequest(
        prompt: 'a lighthouse at dusk',
        steps: 4,
        guidanceScale: 1,
      ),
    );
    if (cancelDownload.isCancelled) {
      running.cancel(); // Cancelled while the task was starting.
    }
    final ImageGenerationCompletion completion = await running.done;
    return switch (completion.state) {
      ImageGenerationCompletionState.completed =>
        completion.result!.images.first.toPng(),
      ImageGenerationCompletionState.cancelled => null,
      ImageGenerationCompletionState.failed => throw completion.error!,
    };
  } finally {
    await engine.dispose();
  }
}
```
