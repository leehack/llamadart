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

- In custom backends and fakes, declare URL-load callbacks as
  `void Function(double progress)? onProgress` (0.14+), including
  `BackendModelFormatRouting.modelLoadFromUrlAs`. Forward progress fractions
  unchanged; return values do not control or cancel loading. Native FFI `bool`
  callbacks keep their separate contract.

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
  extension or `getBackendName()` text. Native thinking-budget support requires
  the runtime's reasoning-budget export. Native `mtp` stays advertised for
  external drafts; in-file MTP needs an MTP head and `loadMtp: true`. Other
  draft strategies need `draftModel` or throw `LlamaArgumentException` at start.
- KV-state save/load is not an exact generation checkpoint. On native
  llama.cpp, an exact restored prompt with prefix reuse re-evaluates its final
  token; scores and continuation may differ from full-prompt evaluation. The
  contract is numerical tolerance, not bit-exactness: with automatic prompt
  batching, probabilities may differ slightly and greedy output can change. Live
  logits and sampler/RNG state are not restored. If the caller explicitly
  chooses full prompt evaluation, use `reusePromptPrefix: false`; do not promise
  exact resume or silently replace KV reuse with full prompt evaluation.
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
  Native llama.cpp with `device: ComputeDevice.auto`,
  `splitMode: ModelSplitMode.none` and a negative `mainGpu` reports `CPU`
  in backend name/capabilities and `0` resolved GPU layers. Layer and row
  splits do not disable GPUs this way; explicit `gpu` / `npu` rejects the
  single-device negative-index combination with `LlamaArgumentException`.
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
- A load throws `LlamaUnsupportedException` naming every `ModelParams` field
  the model's runtime would ignore: `liteRtLm*` fields on a GGUF model,
  llama.cpp tuning such as `batchSize` or `loadMtp` on a `.litertlm` model,
  `preferMemory64` / `modelBytesHint` off the Web. Build one per runtime with
  `LlamaCppModelParams(...)` for GGUF or `LiteRtLmModelParams(...)` for
  `.litertlm` (LiteRT-LM options without the prefix: `cacheDir`,
  `dispatchLibDir`, `embeddingEngine`, ...); either one used for the other
  runtime throws. The `liteRtLm*` arguments of `ModelParams` are deprecated.
- Import only `package:llamadart/llamadart.dart` in app code. Custom
  backends and backend test fakes (`implements LlamaBackend,
  BackendTextToSpeech`, ...) and direct LiteRT-LM runtime access also import
  `package:llamadart/backend.dart`; its `LlamaEngineBackendHooks` are
  extension members, so call them on a `LlamaEngine`-typed value, never
  through `dynamic`. Avoid `package:llamadart/llama_cpp_bindings.dart`: the
  raw FFI is native-only and can change in any release.
- Catch the `LlamaException` hierarchy (`LlamaModelException`,
  `LlamaStateException`, `LlamaUnsupportedException`, ...) rather than
  `Exception`.
- If a fresh Flutter 3.47.1 macOS SwiftPM build reports generated macOS 12.0
  beside a companion requiring 14.0, use the
  [consumer bootstrap](https://llamadart.leehack.com/docs/getting-started/installation#fresh-macos-swiftpm-bootstrap):
  `flutter pub get`, raise only the generated package floor, then build with
  `--no-pub`. Repeat after regeneration; preserve Runner's 14.0+ target and
  companion manifests, native URLs and checksums.
- Platform setup the code cannot do for you:
  - Flutter iOS needs deployment target 16.4+, macOS 14.0+.
  - Windows: llama.cpp and LiteRT-LM bundle the Visual C++ runtime DLLs
    they need. Machines that run the opt-in `stable_diffusion` runtime need
    the latest Microsoft Visual C++ v14 Redistributable (x64); stock Windows
    Server lacks it.
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
