---
name: llamadart-image-generation
description: >-
  Use when generating images from text prompts in a llamadart app with the
  experimental ImageGenerationEngine: opting into the stable_diffusion
  runtime, loading SDXS or SD-Turbo (with TAESD), showing progress, cancelling,
  saving PNGs, or handling unsupported platforms, memory refusals and
  concurrent-generation errors.
---

# Image generation with llamadart

## Guidelines

- Image generation is the experimental `ImageGenerationEngine`, separate from
  `LlamaEngine`. It runs stable-diffusion.cpp through the opt-in
  `stable_diffusion` native runtime. Text-to-image only: no image-to-image,
  inpainting, LoRA or ControlNet.
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
- Platforms: Android arm64 (CPU only; Armv8.2 dot-product and fp16), iOS 16.4+
  and macOS 13.3+ (Metal), Linux arm64/x64 and Windows x64 (CPU or Vulkan; x64
  CPUs need AVX2, FMA, F16C and BMI2). Web, Android x64, the iOS x86_64
  simulator and Windows arm64 are unsupported. Windows needs the Visual C++
  2015-2022 x64 runtime.
- Gate UI on `ImageGenerationEngine.runtimeCapabilities()` (synchronous; no
  model needed): show `unsupportedReason` when `isSupported` is false.
  `ImageGenerationEngine.load` throws `LlamaUnsupportedException` in the same
  cases.
- Models (local files; download with `DefaultModelDownloadManager` or
  `ModelSource` first):
  - `ImageGenerationModel.sdxs(path)`: `concedo/sdxs-512-tinySDdistilled-GGUF`
    `sdxs-512-tinySDdistilled_Q8_0.gguf` (651 MB). Exactly 1 step at guidance
    1, which are its defaults; do not raise them.
  - `ImageGenerationModel.sdTurbo(path, taesdPath: ...)`:
    `Green-Sky/SD-Turbo-GGUF` `sd_turbo-f16-q8_0.gguf` (1.9 GB). Defaults to 1
    step at guidance 1; up to 4 steps add detail. For TAESD use
    `madebyollin/taesd` `diffusion_pytorch_model.safetensors`, not
    `taesd_decoder.safetensors`; prefer it on phones.
  - `ImageGenerationModel.custom(ImageGenerationModelFiles(...), defaults:
    ImageGenerationDefaults(steps:, guidanceScale:))` for other SD 1.x/2.x
    checkpoints; experimental and unvalidated.
- `load` checks every file exists and, unless
  `ImageGenerationOptions(checkMemory: false)`, refuses a model whose estimate
  (file sizes plus a quarter plus 256 MiB) exceeds the device figure
  (`MemAvailable` on Android/Linux, the app's limit on iOS, physical memory on
  macOS; Windows is not checked) with `LlamaModelException`. SD-Turbo does not
  fit 6 GB Android phones; offer SDXS there.
- `ImageGenerationOptions(device: auto | cpu | gpu, threads: 0)`. `gpu`
  without a GPU (Android, CPU builds) throws `LlamaUnsupportedException`.
- `load` loads weights eagerly; on Apple the first generation is still slow
  (about 19 s on iPhone) while Metal compiles shaders. Show progress.
- `engine.generate(request)` returns an `ImageGenerationTask` synchronously;
  invalid requests throw `LlamaImageGenerationException` first. Width and
  height are multiples of 8 from 64 to 2048 (512 is native; 256 is fine for
  SDXS and SD-Turbo; the runtime rounds up to 64, so read the size from
  `GeneratedImage`), steps 1 to 150, guidance 0 to 30, count 1 to 16.
  `seed: null` is random; `result.seed` reports it, image `i` used
  `seed + i`, and the same seed reproduces the same pixels.
- `task.events` (single subscription): `ImageGenerationProgressEvent`
  (`phase`: `encodingPrompt`, `sampling`, `decoding`, rarely `loading`;
  `step`, `steps`, `imageIndex`, `imageCount`), then one
  `ImageGenerationFinalEvent(result)`. Failures arrive as a stream error and
  as `ImageGenerationCompletionState.failed` on `task.done`.
- `engine.generateImage(request)` is the one-call form returning
  `ImageGenerationResult` (`images`, `seed`, `elapsed`).
- `GeneratedImage` has `width`, `height`, `channels` (3) and row-major RGB
  `pixels`; `toPng()` returns PNG bytes (for `Image.memory` or a file).
- One generation or model load at a time per process (stable-diffusion.cpp's
  progress callback is global): a second one throws `LlamaStateException`,
  even on another engine. Await `task.done` before the next request; disable
  the Generate button while one runs. Do not generate from several isolates.
- `task.cancel()` stops before the next sampling step; `done` reports
  `cancelled` and the stream closes without a final event. `dispose()` cancels
  a running task, waits, then frees the model.
- Dispose before the app quits: on macOS Metal, quitting with a model still
  loaded aborts the process. Flutter desktop apps skip `State.dispose` on
  quit; await `dispose()` in `AppLifecycleListener.onExitRequested`. If
  `ImageGenerationEngine.load` is still running, await it there and dispose
  the engine it returns.
- A runtime failure (for example an aborted Metal command buffer or out of
  memory) fails the task with `LlamaInferenceException`; the engine stays
  usable for the next request.
- Runtime logs are not forwarded to `LlamaLogger`.

## Examples

Load SDXS, stream progress and save a PNG:

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> generateFox(String sdxsPath, String outputPath) async {
  final ImageGenerationCapabilities runtime =
      ImageGenerationEngine.runtimeCapabilities();
  if (!runtime.isSupported) {
    throw LlamaUnsupportedException(runtime.unsupportedReason!);
  }

  final ImageGenerationEngine engine = await ImageGenerationEngine.load(
    ImageGenerationModel.sdxs(sdxsPath),
  );
  try {
    final ImageGenerationTask task = engine.generate(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        width: 512,
        height: 512,
        seed: 42,
      ),
    );
    await for (final ImageGenerationEvent event in task.events) {
      switch (event) {
        case ImageGenerationProgressEvent(
          :final ImageGenerationPhase phase,
          :final int step,
          :final int steps,
        ):
          print('${phase.name} $step/$steps');
        case ImageGenerationFinalEvent(:final ImageGenerationResult result):
          await File(outputPath).writeAsBytes(result.images.first.toPng());
          print('Seed ${result.seed} in ${result.elapsed.inMilliseconds} ms');
      }
    }
  } on LlamaInferenceException catch (error) {
    print('Generation failed, engine still usable: ${error.message}');
  } finally {
    await engine.dispose();
  }
}
```

SD-Turbo with TAESD, downloaded through the model cache, with cancellation:

```dart
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<Uint8List?> generateWithCancel(Future<void> userCancelled) async {
  final DefaultModelDownloadManager downloads = DefaultModelDownloadManager();
  final ModelCacheEntry model = await downloads.ensureModel(
    ModelSource.parse('hf://Green-Sky/SD-Turbo-GGUF/sd_turbo-f16-q8_0.gguf'),
  );
  final ModelCacheEntry taesd = await downloads.ensureModel(
    ModelSource.parse(
      'hf://madebyollin/taesd/diffusion_pytorch_model.safetensors',
    ),
  );

  final ImageGenerationEngine engine;
  try {
    engine = await ImageGenerationEngine.load(
      ImageGenerationModel.sdTurbo(model.filePath, taesdPath: taesd.filePath),
    );
  } on LlamaModelException catch (error) {
    print('Model refused or failed to load: ${error.message}');
    return null;
  }

  try {
    final ImageGenerationTask task = engine.generate(
      const ImageGenerationRequest(prompt: 'a lighthouse at dusk', steps: 4),
    );
    userCancelled.then((_) => task.cancel());
    final ImageGenerationCompletion completion = await task.done;
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
