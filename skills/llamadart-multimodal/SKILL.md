---
name: llamadart-multimodal
description: >-
  Use when sending images or audio to a model with llamadart: loading a GGUF
  multimodal projector (mmproj), building LlamaImageContent or
  LlamaAudioContent messages, checking supportsVision / supportsAudio, using
  LiteRT-LM bundle-native media, handling web limits, or debugging media that
  is ignored or rejected.
---

# Multimodal input with llamadart

## Guidelines

- Loading, chat and streaming basics are in the llamadart-getting-started and
  llamadart-chat-streaming skills; this skill only covers media.
- Pick the flow by model format:
  - GGUF (llama.cpp): load the model, then its matching projector with
    `engine.loadMultimodalProjector(path)` or
    `engine.loadMultimodalProjectorSource(ModelSource.parse(...))`. The
    projector must come from the same model family and release as the model.
  - `.litertlm` (LiteRT-LM): the bundle carries its own media processors. Do
    not load a projector; `loadMultimodalProjector*` throws
    `LlamaUnsupportedException` on LiteRT-LM.
- Load the model first. Either projector call before a model is loaded
  throws `LlamaContextException`. A projector that is missing or
  rejected by the runtime throws `LlamaModelException`.
- After loading a projector, check `await engine.supportsVision` and
  `await engine.supportsAudio` before offering image or audio input. A
  projector can expose only some of a family's modalities; never infer support
  from the model card. `engine.hasMultimodalProjector` only says a projector is
  loaded.
- `supportsVision` and `supportsAudio` report the GGUF projector only. They
  are `false` for `.litertlm` bundles, whose media support you must know from
  the bundle itself.
- Always check before sending media to a GGUF model. With no projector loaded,
  image or audio parts throw `LlamaUnsupportedException` on llama.cpp, native
  and WebGPU.
- Put media in a message with
  `LlamaChatMessage.withContent(role: ..., content: [...])`, or pass the parts
  to `ChatSession.create`. Place media before the text that refers to it.
- Media sources that each runtime actually reads:
  - `LlamaImageContent(path: ...)` or `LlamaImageContent(bytes: ...)` with
    encoded JPEG/PNG bytes. Prefer `path` on native.
  - `LlamaAudioContent(path: ...)`, `LlamaAudioContent(bytes: ...)` with
    encoded audio (for example WAV), or `samples:` (raw PCM `Float32List`).
  - `LlamaImageContent.url` is consumed only by the web bridge. Native
    llama.cpp and native LiteRT-LM throw `LlamaUnsupportedException` for it;
    download the image and pass bytes instead.
  - Native LiteRT-LM also rejects raw PCM `samples` and `bytes` combined with
    `width`/`height` (raw RGB). Do not set `width`/`height` on encoded bytes.
- Video is not supported. `await engine.supportsVideo` is always `false` and
  `LlamaVideoContent` fails with `LlamaUnsupportedException`; send extracted
  frames as `LlamaImageContent` instead.
- Loading a second projector replaces the first. `unloadMultimodalProjector()`
  drops only the projector; `unloadModel()` and `dispose()` also release it.
  When switching GGUF models, load the new model's projector after the new
  model: the old one is gone with `unloadModel()` and must not be reused.
- Projector offload follows the model load: `ModelParams(gpuLayers: 0)` or
  `preferredBackend: GpuBackend.cpu` also keeps the projector on CPU. If
  multimodal output is wrong or crashes on GPU, get a CPU baseline first.
- On llama.cpp, `GenerationParams.thinkingBudget` and speculative decoding
  throw `LlamaUnsupportedException` for requests that contain media. Leave
  them unset for multimodal turns.
- The package does not resize media. Downscale large images (the example chat
  app caps the long edge at 384px) and keep `maxTokens` and context budgets
  tighter than for text; images in history keep consuming context on later
  turns.
- Web:
  - WebGPU loads projectors by URL. `loadMultimodalProjectorSource` accepts
    remote unauthenticated URLs only; local paths and `ModelLoadOptions` that
    need the native cache (`bearerToken`/`headers`, `sha256`, `cachePolicy`,
    `cacheDirectory`, `cancelToken`, `resume: false`, custom `maxRetries`)
    throw `LlamaUnsupportedException`.
  - Local file paths are native-only; on web pass browser file bytes or URLs.
  - LiteRT-LM on web is text-only.
- `LlamaAudioContent` is generic audio routed through generation, not a
  transcript API. For transcription use `SpeechToTextEngine` (Speech to Text
  guide).

## Examples

GGUF model plus projector, with capability checks before sending an image:

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel('/models/gemma-3-4b-it-Q4_K_M.gguf');
    await engine.loadMultimodalProjector('/models/mmproj-gemma-3-4b-it.gguf');

    if (!await engine.supportsVision) {
      throw StateError('This projector does not provide vision input.');
    }
    print('audio input: ${await engine.supportsAudio}');

    final LlamaChatMessage message = LlamaChatMessage.withContent(
      role: LlamaChatRole.user,
      content: const [
        LlamaImageContent(path: '/photos/receipt.jpg'),
        LlamaTextContent('What is the total on this receipt?'),
      ],
    );

    final String answer = await engine.create(
      [message],
      params: const GenerationParams(maxTokens: 128),
    ).text();
    print(answer);
  } finally {
    await engine.dispose();
  }
}
```

Switching GGUF models that each need their own projector:

```dart
import 'package:llamadart/llamadart.dart';

Future<bool> switchVisionModel(
  LlamaEngine engine, {
  required String modelUri,
  required String projectorUri,
}) async {
  if (engine.isReady) {
    await engine.unloadModel();
  }
  await engine.loadModelSource(ModelSource.parse(modelUri));
  await engine.loadMultimodalProjectorSource(ModelSource.parse(projectorUri));
  return engine.supportsVision;
}
```

Image and audio bytes with a native `.litertlm` bundle (no projector):

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<String> describeClip(
  LlamaEngine engine,
  String imagePath,
  String wavPath,
) async {
  await engine.loadModel('/models/gemma-4-E2B-it.litertlm');

  final Uint8List imageBytes = await File(imagePath).readAsBytes();
  final Uint8List audioBytes = await File(wavPath).readAsBytes();
  return engine.create(
    [
      LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          LlamaImageContent(bytes: imageBytes),
          LlamaAudioContent(bytes: audioBytes),
          const LlamaTextContent('Does the audio match the picture?'),
        ],
      ),
    ],
    params: const GenerationParams(maxTokens: 160),
  ).text();
}
```

## More

- Multimodal guide: https://llamadart.leehack.com/docs/guides/multimodal
- Speech to text: https://llamadart.leehack.com/docs/guides/speech-to-text
- Support matrix: https://llamadart.leehack.com/docs/platforms/support-matrix
- Performance tuning: https://llamadart.leehack.com/docs/guides/performance-tuning
