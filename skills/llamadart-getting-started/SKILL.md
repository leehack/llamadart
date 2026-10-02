---
name: llamadart-getting-started
description: >-
  Use when adding llamadart to a Dart or Flutter app, choosing between GGUF
  (llama.cpp) and .litertlm (LiteRT-LM) models, loading or switching a model,
  or owning a LlamaEngine's lifecycle.
---

# Getting started with llamadart

llamadart runs local LLMs in Dart and Flutter: GGUF models through llama.cpp
and `.litertlm` bundles through LiteRT-LM, on Android, iOS, macOS, Windows,
Linux and web. Full docs: https://llamadart.leehack.com

## Guidelines

- Create one `LlamaEngine(LlamaBackend())` per loaded model and always
  `await engine.dispose()` when its owner goes away, in a `finally` block for
  scripts. In Flutter, create it in a long-lived owner (service, provider or
  `State`), never in `build()`.
- `LlamaBackend()` routes by model format: LiteRT-LM bundles run on LiteRT-LM
  and GGUF on llama.cpp. Native targets read the file header, so extensionless
  files load; a header contradicting the extension throws
  `LlamaModelFormatException`. Web routes by URL extension: for a URL without
  one, pass `ModelSource.url(uri, format: ModelFormat.liteRtLm)`. The formats
  are not interchangeable.
- Prefer GGUF / llama.cpp unless the model only ships as `.litertlm`. Only
  llama.cpp supports embeddings, grammar-constrained and structured JSON output,
  runtime LoRA, KV-cache state persistence, next-token scores and external
  multimodal projectors. LiteRT-LM throws `LlamaUnsupportedException` for
  llama.cpp-only options; do not catch and ignore it.
- Load remote models with `engine.loadModelSource(ModelSource.parse(...))`
  (`hf://owner/repo/file.gguf`, an HTTP(S) URL, or a local path). Native
  targets download once into a cache and reuse it: a per-user cache on
  desktop, the app's cache directory on Android and iOS (no `path_provider`
  needed). Web rejects local paths.
- `loadModel`, `loadModelSource` and `unloadModel` do not queue. Calling one
  while another runs, or loading while a model is loaded, throws
  `LlamaStateException`. Serialize model switches in app code and call
  `unloadModel()` before loading another model.
- Check `engine.isReady` before inference. Log `engine.getBackendName()` in
  diagnostics so reports name the runtime actually used.
- Pass `ModelParams(gpuLayers: 0)` to force CPU. Keep `contextSize` no larger
  than the app needs: memory grows with it.
- Catch the `LlamaException` hierarchy (`LlamaModelException`,
  `LlamaStateException`, `LlamaUnsupportedException`, ...) rather than
  `Exception`.
- Platform setup the code cannot do for you:
  - Flutter iOS needs deployment target 16.4+, macOS 14.0+.
  - Windows machines that run the app need the latest Microsoft Visual C++
    v14 Redistributable (x64 or arm64), at least as new as the build tools of
    the bundled DLLs; stock Windows Server lacks it, and llama.cpp then fails
    to load with an error naming the missing DLLs.
  - Web apps must add the WebGPU bridge script to `web/index.html`; the package
    does not inject it.
  - To ship one runtime family only, set
    `hooks.user_defines.llamadart.llamadart_native_runtimes` in `pubspec.yaml`.
- Native runtimes are fetched by the build hook on first build; no C++
  toolchain is needed. Do not vendor llama.cpp or LiteRT-LM into the app.

## Examples

Load a model from Hugging Face and run one stateless completion:

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModelSource(
      ModelSource.parse(
        'hf://unsloth/SmolLM2-135M-Instruct-GGUF/'
        'SmolLM2-135M-Instruct-Q2_K.gguf',
      ),
      modelParams: const ModelParams(contextSize: 1024, gpuLayers: 0),
      onProgress: (progress) {
        final double? fraction = progress.fraction;
        if (fraction != null) {
          print('download ${(fraction * 100).toStringAsFixed(1)}%');
        }
      },
    );
    print('runtime: ${await engine.getBackendName()}');

    final String output = await engine.create(const [
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Say hello in five words.',
      ),
    ], params: const GenerationParams(maxTokens: 32)).text();
    print(output);
  } finally {
    await engine.dispose();
  }
}
```

Switch models on one engine, and load a LiteRT-LM bundle on GPU:

```dart
import 'package:llamadart/llamadart.dart';

Future<void> switchToLiteRtLm(LlamaEngine engine, String bundlePath) async {
  await engine.unloadModel();
  try {
    await engine.loadModel(
      bundlePath,
      modelParams: const ModelParams(
        liteRtLmBackend: LiteRtLmBackendPreference.gpu,
      ),
    );
  } on LlamaModelException catch (error) {
    print('GPU load failed, retrying on CPU: $error');
    await engine.loadModel(
      bundlePath,
      modelParams: const ModelParams(
        liteRtLmBackend: LiteRtLmBackendPreference.cpu,
      ),
    );
  }
}
```

## More

- Installation and platform setup: https://llamadart.leehack.com/docs/getting-started/installation
- llama.cpp or LiteRT-LM: https://llamadart.leehack.com/docs/guides/backend-selection
- Model lifecycle and downloads: https://llamadart.leehack.com/docs/guides/model-lifecycle
