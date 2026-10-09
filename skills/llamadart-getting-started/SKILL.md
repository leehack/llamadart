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

- Create one engine per loaded model with
  `LlamaEngine.load(LlamaModel(source))`, or with `LlamaEngine(LlamaBackend())`
  and `setModel` when the engine must exist before the load, and always
  `await engine.dispose()` when its owner goes away, in a `finally` block for
  scripts. A `LlamaEngine.load` that throws has already disposed its engine,
  so start the `try` after it returns. In Flutter, create the engine in a
  long-lived owner (service, provider or `State`), never in `build()`.
  `dispose()` is final: a later load or request throws `LlamaStateException`,
  so use `setModel` to switch models and a new engine after `dispose()`.
  Disposal promptly rejects a running `setModel` or deprecated
  `loadModelSource` and cancels its package-managed model/LoRA downloads.
  Caller-owned cancel tokens remain unchanged; transfers stop cooperatively
  at their next checkpoint. Custom resolvers/managers must poll the linked
  token they receive, even though disposal no longer waits for their work.
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
  llama.cpp-only options; do not catch and ignore it. After a load,
  `engine.runtime` names the runtime and `await engine.capabilities` reports
  every option it applies; gate features on these, never on the file
  extension or `getBackendName()` text.
- Name the model with `ModelSource.parse(...)` (`hf://owner/repo/file.gguf`,
  an HTTP(S) URL, or a local path) and pass `params:` (`ModelParams`),
  `download:` (`ModelLoadOptions`) and `onProgress:` to `LlamaEngine.load` or
  `setModel`. Native targets download once into a cache and reuse it: a
  per-user cache on desktop, the app's cache directory on Android and iOS (no
  `path_provider` needed). On web the runtime fetches the file itself and a
  local path is a URL relative to the document.
- `setModel` replaces the loaded model; do not call `unloadModel()` first.
  `unloadModel()` only frees the model without loading another. Neither
  queues: while a `setModel` runs, another `setModel` or an `unloadModel`
  throws `LlamaStateException`. Serialize model switches in app code, or stop
  the running load with `ModelLoadOptions.cancelToken`.
- Check `engine.isReady` before inference. Log `engine.getBackendName()` in
  diagnostics so reports name the runtime actually used.
- `ModelParams(device: ComputeDevice.cpu)` forces the CPU on every runtime.
  `ComputeDevice.gpu` or `npu` runs there or throws
  `LlamaUnsupportedException`, never on another device; native LiteRT-LM
  reports a GPU or NPU delegate that fails to start from the first
  generation or `tokenize`, and under `auto` an engine it cannot create
  throws `LlamaModelException` there. Leave `device` at `auto` for each
  runtime's default.
  `ModelParams.liteRtLmBackend` and `LiteRtLmBackendPreference` are
  deprecated. Keep `contextSize` no larger than the app needs: memory grows
  with it.
- Import only `package:llamadart/llamadart.dart` in app code. Custom
  backends and backend test fakes (`implements LlamaBackend,
  BackendTextToSpeech`, ...) and direct LiteRT-LM runtime access also import
  `package:llamadart/backend.dart`. Avoid
  `package:llamadart/llama_cpp_bindings.dart`: the raw FFI is native-only
  and can change in any release.
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
  final LlamaEngine engine = await LlamaEngine.load(
    LlamaModel(
      ModelSource.parse(
        'hf://unsloth/SmolLM2-135M-Instruct-GGUF/'
        'SmolLM2-135M-Instruct-Q2_K.gguf',
      ),
    ),
    params: const ModelParams(contextSize: 1024, gpuLayers: 0),
    onProgress: (progress) {
      final double? fraction = progress.fraction;
      if (fraction != null) {
        print('download ${(fraction * 100).toStringAsFixed(1)}%');
      }
    },
  );
  try {
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
  final LlamaModel model = LlamaModel(ModelSource.path(bundlePath));
  try {
    // setModel replaces the model the engine holds.
    await engine.setModel(
      model,
      params: const ModelParams(device: ComputeDevice.gpu),
    );
    // Native LiteRT-LM starts the GPU delegate on its first use.
    await engine.tokenize('warm up');
  } on LlamaUnsupportedException catch (error) {
    print('No LiteRT-LM GPU here, loading on the CPU: $error');
    await engine.setModel(
      model,
      params: const ModelParams(device: ComputeDevice.cpu),
    );
  }
}
```

## More

- Installation and platform setup: https://llamadart.leehack.com/docs/getting-started/installation
- llama.cpp or LiteRT-LM: https://llamadart.leehack.com/docs/guides/backend-selection
- Model lifecycle and downloads: https://llamadart.leehack.com/docs/guides/model-lifecycle
