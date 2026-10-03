# Migration Guide

This document covers the major breaking upgrade paths.

## `0.10.x` -> next release: image generation engine API

Image generation is a Preview, and this release changes its API with no
deprecation period, to the pattern every llamadart engine will share: a
model of `ModelSource` files, `params:` for runtime settings, `download:`
for `ModelLoadOptions`, and generation settings on the request. The library
no longer has model presets or `String` paths.

1. **A model is a main file plus components, each a `ModelSource`.**
   `ImageGenerationModel.sdxs`, `sdTurbo`, `sdxlLightning`, `flux1Schnell`,
   `sd35LargeTurbo`, `zImageTurbo` and `custom`, `ImageGenerationModelFiles`,
   `ImageGenerationModelFamily` and `ImageGenerationModel.family` are gone.
   `load` downloads each file if needed and assigns its role from its
   header, so list files in any order:

   ```dart
   // Before
   final engine = await ImageGenerationEngine.load(
     ImageGenerationModel.flux1Schnell(
       diffusionModelPath: fluxPath,
       clipLPath: clipLPath,
       t5xxlPath: t5xxlPath,
       vaePath: aePath,
     ),
     options: const ImageGenerationOptions(device: ImageGenerationDevice.gpu),
   );
   final result = await engine.generateImage(
     const ImageGenerationRequest(prompt: 'a red fox'),
   );
   // After
   final engine = await ImageGenerationEngine.load(
     ImageGenerationModel(
       ModelSource.path(fluxPath),
       components: [
         for (final path in [aePath, clipLPath, t5xxlPath])
           ImageModelComponent.auto(ModelSource.path(path)),
       ],
     ),
     params: const ImageModelParams(device: ComputeDevice.gpu),
   );
   final result = await engine.generateImage(
     const ImageGenerationRequest(
       prompt: 'a red fox',
       width: 1024,
       height: 1024,
       steps: 4,
       guidanceScale: 1,
     ),
   );
   ```

   A file the header check cannot classify, such as a `.ckpt`, takes an
   explicit role: `ImageModelComponent(source, role: ImageModelRole.vae)`,
   or `ImageGenerationModel(source, role: ImageModelRole.checkpoint)`.
   `load` now refuses LoRA and ControlNet files, two files in one role, and
   a VAE or TAESD for other latent channels than the diffusion model's.

2. **Generation settings move to the request.** `ImageGenerationDefaults`
   is gone; an unset request size is 512x512, steps 20 and guidance 7. Set
   each former preset's values on the request, as in the
   [image generation guide's recipes](https://llamadart.leehack.com/docs/guides/image-generation#recipes):

   | 0.10.0 preset | Files | Request settings |
   | --- | --- | --- |
   | `sdxs(path)` | the checkpoint | `steps: 1, guidanceScale: 1` |
   | `sdTurbo(path, taesdPath:)` | the checkpoint, optional TAESD | `steps: 1, guidanceScale: 1` |
   | `sdxlLightning(path, vaePath:, taesdPath:)` | the checkpoint, optional VAE or TAESDXL | `width: 1024, height: 1024, steps: 4, guidanceScale: 1, sampler: euler, scheduler: sgmUniform` |
   | `flux1Schnell(...)` | diffusion model, `ae` or TAEF1, CLIP-L, T5-XXL | `width: 1024, height: 1024, steps: 4, guidanceScale: 1` |
   | `sd35LargeTurbo(...)` | diffusion model, TAESD3 or VAE, CLIP-L, CLIP-G, T5-XXL | `width: 1024, height: 1024, steps: 4, guidanceScale: 1` |
   | `zImageTurbo(...)` | diffusion model, `ae`, Qwen3 `llm` | `width: 1024, height: 1024, steps: 8, guidanceScale: 1` |
   | `custom(files, defaults:)` | the same files | the former `defaults` |

   `warmUp` takes `guidanceScale` too, so pass the size and guidance you
   generate with.

3. **`load` takes `params:`, `download:`, `onProgress:` and `store:`.**
   `ImageGenerationOptions` is now `ImageModelParams` (the engine's
   `options` getter is now `params`), and `ImageGenerationDevice` the shared
   `ComputeDevice`. `download:` takes `ModelLoadOptions` for remote files
   (cache, auth, retries, cancellation); `ModelLoadOptions.sha256` verifies a
   single-file model and throws `LlamaUnsupportedException` for several
   files, since one checksum cannot cover them. `store: ModelFileStore(resolver: ...,
   downloadManager: ...)` replaces the resolver and download manager.

4. **Errors name files by position, not path.** A missing or unusable file
   is "the main file" or "component N".

## Unreleased: decision engine load and attach

`DecisionEngine` follows the shared engine pattern, and the `String`-path
`DecisionEngine.load(engine, headPath:, configPath:)` is removed.

1. **Keep your engine: switch to `attach`.** The one-line change:

   ```dart
   // Before
   final decisions = await DecisionEngine.load(
     engine,
     headPath: headPath,
     configPath: configPath,
   );
   // After
   final decisions = await DecisionEngine.attach(
     engine,
     head: ModelSource.path(headPath),
     config: configPath == null ? null : ModelSource.path(configPath),
   );
   ```

   The head and config now resolve through the engine's download manager,
   so `hf://` and URL sources work too, and a missing local file throws
   `LlamaModelException` before the head loads. `dispose()` still frees only
   the head. On Web a path is still a URL resolved against the document base
   URL; a `blob:` URL goes in `ModelSource.path` too.

2. **Or let `load` own the engine.** Describe the files as `ModelSource`s;
   `load` downloads them, loads the encoder with the 512-token context
   decisions need, and loads the head. `dispose()` frees everything:

   ```dart
   // Before
   final engine = LlamaEngine(LlamaBackend());
   await engine.loadModelSource(
     encoder,
     modelParams: const ModelParams(contextSize: 512, gpuLayers: 0),
   );
   final headFile = await engine.modelDownloadManager.ensureModel(head);
   final decisions = await DecisionEngine.load(
     engine,
     headPath: headFile.filePath,
   );
   // ...
   await decisions.dispose();
   await engine.dispose();
   // After
   final decisions = await DecisionEngine.load(
     DecisionModel(encoder: encoder, head: head),
     params: const DecisionModelParams(device: ComputeDevice.cpu),
   );
   // ...
   await decisions.dispose();
   ```

   `configPath:` becomes `DecisionModel.config`. `download:` takes
   `ModelLoadOptions`, `store:` a `ModelFileStore` (for example
   `ModelFileStore(downloadManager: myManager)`), and `onProgress` reports all
   files together. Read the backend name from `await decisions.capabilities`.
   To load an encoder yourself for `attach`, use
   `const DecisionModelParams().encoderModelParams`.

3. **Missing-config hint.** The error for a head without `laya.config`
   metadata now asks for "the head's rl_agent_config.json as its config"
   instead of naming `configPath`; match on `laya.config` if you parse it.

## Unreleased: TranslateGemma language codes

`LlamaEngine.create`, `createStructuredJson` and `chatTemplate` deprecate
`sourceLangCode` and `targetLangCode`. Pass the codes in
`chatTemplateKwargs`, as llama.cpp's `chat_template_kwargs` does; the
parameters still work for one minor release, with deprecation warnings:

```dart
// Before
engine.create(messages, sourceLangCode: 'en', targetLangCode: 'ko');
// After
engine.create(
  messages,
  chatTemplateKwargs: const {'source_lang_code': 'en', 'target_lang_code': 'ko'},
);
```

A code passed as a parameter replaces the same key in `chatTemplateKwargs`.
A custom `BackendNativeChatGeneration` that read `sourceLangCode` or
`targetLangCode` in `generateChat` gets them from `LlamaEngine` only in
`chatTemplateKwargs` now.

## Unreleased: mobile model cache default

No source change is required. On Android and iOS, `LlamaEngine`,
`ModelDownloadController` and `DefaultModelDownloadManager()` (and `auto()`
without a mobile directory) now cache models in `llamadart/models` under the
app's cache directory, the one Flutter's `getApplicationCacheDirectory()`
returns, instead of `Directory.systemTemp/llamadart/models`. Models cached
under the old path download once more; the old copies are left for the OS to
clear. Apps that already pass a directory are unaffected. To pick another
directory for every default download, set
`DefaultModelDownloadManager.globalCacheDirectory` before the first load.

## Unreleased: typed argument errors and one logging API

1. **Argument and state errors join the `LlamaException` hierarchy.** Catch
   the new types, or `LlamaException` for all of them:

   | Call | Before | After |
   | --- | --- | --- |
   | `ModelParams.validate()` | `ArgumentError` | `LlamaArgumentException` |
   | A backend's own model load or context create with invalid `ModelParams` | `ArgumentError` or `Exception` | `LlamaArgumentException` |
   | `ModelDownloadController.start` with `options.cancelToken` | `ArgumentError` | `LlamaArgumentException` |
   | `ModelDownloadController.start` while a task runs, `retry` before `start`, either after `dispose` | `StateError` | `LlamaStateException` |
   | Web `LlamaBackend()` or `WebGpuLlamaBackend` calls before a model load | `StateError` | `LlamaStateException` |

   ```dart
   // Before
   try {
     params.validate();
   } on ArgumentError catch (e) {
     print(e.name);
   }
   // After
   try {
     params.validate();
   } on LlamaArgumentException catch (e) {
     print(e.name); // also e.invalidValue and e.message
   }
   ```

   Model loads already reported invalid `ModelParams` as
   `LlamaModelException`, and still do.

2. **A failed load's `details` is a `String`.** `LlamaModelException.details`
   from `loadModel`, `loadModelFromUrl`, `loadModelSource` and
   `loadMultimodalProjector` was a `{type, message}` map; it is now the cause's
   message, such as `Model file not found: /models/m.gguf`, with URL secrets
   still redacted.

3. **One logging API.** `LlamaLogging.configure` sets the Dart-side level,
   the native level (defaulting to the Dart-side level) and the handler for
   the whole library. The old calls still work for one minor release, with
   deprecation warnings:

   | Before | After |
   | --- | --- |
   | `LlamaEngine.configureLogging(level: l, handler: h)` | `LlamaLogging.configure(level: l, nativeLevel: n, handler: h)` |
   | `engine.setLogLevel(l)` | `LlamaLogging.configure(level: l)` |
   | `engine.setDartLogLevel(d)` + `engine.setNativeLogLevel(n)` | `LlamaLogging.configure(level: d, nativeLevel: n)` |
   | `engine.dartLogLevel`, `engine.nativeLogLevel` | `LlamaLogging.level`, `LlamaLogging.nativeLevel` |

   `configure` replaces the handler too, so pass it on every call that should
   keep it. Levels are now library-wide: `engine.setNativeLogLevel` on one
   engine changes every engine, and `LlamaEngine.configureLogging` also updates
   running worker isolates.

## Unreleased: speech engine load, attach and adapters

`SpeechToTextEngine` and `TextToSpeechEngine` follow the shared engine
pattern: `load` takes a model of `ModelSource` files and owns what it loads,
and an adapter, not a profile enum, says how to run the model. The old
constructors, `SpeechToTextModelProfile`, `TextToSpeechModelProfile` and the
`modelProfile` getters still work for one release, with deprecation warnings.

1. **Load the model, or attach to an engine you keep.** `load` creates a
   `LlamaEngine`, loads the model and projector, checks `capabilities`, and
   throws `LlamaUnsupportedException` when the model cannot recognize speech.
   `dispose()` then disposes that engine:

   ```dart
   // Before
   final engine = LlamaEngine(LlamaBackend());
   await engine.loadModel('/models/Qwen3-ASR-0.6B-Q8_0.gguf');
   await engine.loadMultimodalProjector('/models/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf');
   final recognizer = SpeechToTextEngine(
     engine,
     modelProfile: SpeechToTextModelProfile.qwen3Asr,
   );
   // After
   final recognizer = await SpeechToTextEngine.load(
     SpeechToTextModel(
       ModelSource.path('/models/Qwen3-ASR-0.6B-Q8_0.gguf'),
       projector: ModelSource.path('/models/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf'),
       adapter: const Qwen3AsrAdapter(),
     ),
   );
   try {
     final result = await recognizer.transcribeOnce(request);
   } finally {
     await recognizer.dispose();
   }
   ```

   Remote sources download into the model cache. `download:` takes
   `ModelLoadOptions` for every remote file and `onProgress:` reports the
   files together; a local file takes only the cancel token, and
   `bearerToken` and `headers` go to one host only, so remote files on two
   hosts with them set throw `LlamaArgumentException`.
   `ModelLoadOptions.sha256` throws `LlamaUnsupportedException`, since one
   checksum cannot cover two files. `params:` takes `ModelParams`, `store:` a
   `ModelFileStore` with your own resolver or download manager, and
   `backend:` the `LlamaBackend`, which the speech engine then owns and
   disposes. When `load` throws, nothing stays loaded.

   To share a `LlamaEngine` you load yourself, for example with chat, use
   `SpeechToTextEngine.attach(engine, adapter: const Qwen3AsrAdapter())`.
   Its `dispose()` cancels its task and leaves the engine loaded.

2. **Dedicated LiteRT-LM ASR is a model with a `LiteRtLmAsrAdapter`.** The
   runtime settings of `LiteRtLmAsrRuntimeConfig` and `libraryPath` move to
   the adapter, and the files become `ModelSource`s:

   ```dart
   // Before
   final recognizer = SpeechToTextEngine.liteRtLm(
     const LiteRtLmAsrRuntimeConfig(
       modelPath: '/models/moonshine_tiny.tflite',
       tokenizerPath: '/models/tokenizer.json',
       modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
     ),
   );
   // After
   final recognizer = await SpeechToTextEngine.load(
     SpeechToTextModel(
       ModelSource.path('/models/moonshine_tiny.tflite'),
       tokenizer: ModelSource.path('/models/tokenizer.json'),
       adapter: const LiteRtLmAsrAdapter(LiteRtLmAsrModelPreset.moonshineTiny),
     ),
   );
   ```

   `load` probes the runtime before it downloads anything and throws
   `LlamaUnsupportedException` where it is unavailable, including on the web,
   where `SpeechToTextEngine.liteRtLm` returned a recognizer whose
   `capabilities` reported unsupported. `params:` and `backend:` must be
   null. The model and tokenizer can be URLs or Hugging Face files: `load`
   downloads them with `download:` and `onProgress:` as in step 1.
   `SpeechToTextEngine.liteRtLm` opens local files only and throws
   `LlamaUnsupportedException` for a remote source.

3. **Text to speech takes a `TextToSpeechModel`.**

   ```dart
   // Before
   final synthesizer = TextToSpeechEngine(
     engine,
     modelProfile: TextToSpeechModelProfile.qwen3Tts,
   );
   // After, loading the files
   final synthesizer = await TextToSpeechEngine.load(
     TextToSpeechModel(
       ModelSource.parse('hf://owner/repo/tts-model.gguf'),
       projector: ModelSource.parse('hf://owner/repo/mmproj-tts-model.gguf'),
       adapter: const Qwen3TtsAdapter(),
     ),
   );
   // After, keeping your engine
   final synthesizer = TextToSpeechEngine.attach(
     engine,
     adapter: const Qwen3TtsAdapter(),
   );
   ```

4. **Profiles become adapters.**

   | Before | After |
   | --- | --- |
   | `SpeechToTextEngine(engine, modelProfile: SpeechToTextModelProfile.qwen3Asr)` | `SpeechToTextEngine.attach(engine, adapter: const Qwen3AsrAdapter())`, or `load` |
   | `SpeechToTextEngine.liteRtLm(config, libraryPath: path)` | `SpeechToTextEngine.load(SpeechToTextModel(model, tokenizer: tokenizer, adapter: LiteRtLmAsrAdapter(preset, libraryPath: path)))` |
   | `TextToSpeechEngine(engine, modelProfile: TextToSpeechModelProfile.qwen3Tts)` | `TextToSpeechEngine.attach(engine, adapter: const Qwen3TtsAdapter())`, or `load` |
   | `recognizer.modelProfile`, `synthesizer.modelProfile` | `recognizer.adapter`, `synthesizer.adapter` |

   The deprecated `modelProfile` getters throw `LlamaStateException` for an
   adapter with no profile, such as your own `SpeechToTextPromptAdapter`.

5. **Dispose the speech engine.** `dispose()` is new: it cancels a running
   task or stream, waits for it to stop, and disposes the engine `load`
   created. It is safe to call twice. Afterwards `transcribe`, `startStream`
   and `synthesize` throw `LlamaStateException`, and `capabilities` reports
   unsupported. Code that used the deprecated constructors and disposed the
   `LlamaEngine` itself keeps working. A class that `implements` `SpeechToTextEngine` or
   `TextToSpeechEngine`, such as a test fake, must add `dispose()`,
   `isDisposed`, `adapter` and `transcribeOnce` or `synthesizeOnce`.
## Unreleased: `ModelSource` for LoRA adapters, draft models and speech files

LoRA adapters, speculative draft models and LiteRT-LM ASR files take a
`ModelSource`, so a remote file downloads into the model cache like a model.
The `String` path forms still work for one minor release, with deprecation
warnings:

| Before | After |
| --- | --- |
| `engine.setLora(path, scale: s)` | `engine.setLoraSource(ModelSource.path(path), scale: s)` |
| `engine.removeLora(path)` | `engine.removeLoraSource(ModelSource.path(path))` |
| `LoraAdapterConfig(path: path, scale: s)` | `LoraAdapterConfig.source(ModelSource.path(path), scale: s)` |
| `SpeculativeDecodingConfig.draftSimple(draftModelPath: path)` (and the other constructors) | `SpeculativeDecodingConfig.draftSimple(draftModel: ModelSource.path(path))` |
| `LiteRtLmAsrRuntimeConfig(modelPath: m, tokenizerPath: t, ...)` | `LiteRtLmAsrRuntimeConfig.source(model: ModelSource.path(m), tokenizer: ModelSource.path(t), ...)`; to recognize speech, `SpeechToTextEngine.load` as in [the speech migration](#unreleased-speech-engine-load-attach-and-adapters) |

```dart
// Before
await engine.setLora('/models/lora/domain.gguf', scale: 0.7);
final config = LiteRtLmAsrRuntimeConfig(
  modelPath: '/models/moonshine_tiny.tflite',
  tokenizerPath: '/models/tokenizer.json',
  modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
);
// After
await engine.setLoraSource(
  ModelSource.path('/models/lora/domain.gguf'),
  scale: 0.7,
);
final config = LiteRtLmAsrRuntimeConfig.source(
  model: ModelSource.path('/models/moonshine_tiny.tflite'),
  tokenizer: ModelSource.path('/models/tokenizer.json'),
  modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
);
```

- A local path, relative ones included, stays `ModelSource.path(path)`. On
  WebGPU, where these paths were URLs, use `ModelSource.parse(url)`; a local
  path there throws `LlamaUnsupportedException`.
- For a page-relative URL on the web (such as `models/adapter.gguf`),
  resolve it against the page: `ModelSource.url(Uri.base.resolve(path))`.
- `ModelSource` and `const`: `ModelSource.path` is not a `const`
  constructor, so drop `const` from a `ModelParams`, `GenerationParams` or
  `LiteRtLmAsrRuntimeConfig` that now holds one.
- Remove an adapter with the same source it was set from:
  `removeLoraSource` matches sources, not paths.
- `draftModelDownload`, `setLoraSource(download:, onProgress:)` and
  `LoraAdapterConfig.source(source, download:)` set the download options
  for remote files. Remote LiteRT-LM ASR files download through
  `SpeechToTextEngine.load`; `LiteRtLmAsrRuntimeConfig` holds local files. A `ModelParams.loras` adapter never
  takes the model load's bearer token, headers or `sha256`; give it its own
  `download:` when its host needs credentials.
- A draft model downloads once per loaded model; `draftModelDownload` rejects
  `ModelCachePolicy.noCache` and `refresh`.

## Unreleased: optional `ToolDefinition.handler`

`ToolDefinition.handler` is a `ToolHandler?`, so a tool the app runs itself
can leave it out. A direct call to the handler no longer compiles: call
`invoke`, which throws `LlamaStateException` for a tool without a handler, or
null-check `handler`:

```dart
// Before
final result = await tool.handler(ToolParams(args));
// After
final result = await tool.invoke(args);
```

## `0.9.x` -> `0.10.0`: typed errors, chat templates and model names

No public signature changes, but several calls now return or throw something
different. Check each item that your app uses.

1. **`ModelParams.chatTemplate` now drives llama.cpp chat.** Before, native
   llama.cpp and WebGPU ignored it in `LlamaEngine.create`,
   `LlamaEngine.chatTemplate` and `ChatSession`, and used the GGUF
   `tokenizer.chat_template`. Now a non-empty value renders the prompt and
   selects the tool-call and reasoning parser. If you set it only as a
   fallback, pass `null` to keep the GGUF template. The value is Jinja
   source, so a name such as `chatml` is not mapped to a built-in template.

2. **WebGPU `LlamaBackend.applyChatTemplate` throws for a template
   override.** Before, it ignored `customTemplate` and
   `ModelParams.chatTemplate` and returned `role: content` lines. Now it
   throws `LlamaUnsupportedException`. Render through
   `LlamaEngine.chatTemplate` or `LlamaEngine.create` instead, which apply
   the override in Dart on every backend.

3. **`LlamaCompletionChunk.model` is the file name.** Before, it held the
   load source: the full local path, the cache path, or the redacted URL.
   Now it is the last path segment, such as `qwen.gguf`, or `llama_model`
   when there is none or it contains URL syntax such as `?`, `#` or `@`
   (`data:` and `blob:` URLs report `llama_model` too). Compare it with
   the file name instead of the path:

   ```dart
   // Before
   if (chunk.model == modelPath) { ... }
   // After
   if (chunk.model == path.basename(modelPath)) { ... }
   ```

4. **`%` in local and cache paths stays literal.** Before,
   `loadModelSource` and `ModelCacheEntry` percent-decoded paths, so
   `qwen%2541.gguf` loaded a different file and a lone `%` threw
   `ArgumentError`. Now the path is used as written: pass the path as it is
   on disk, not percent-encoded.

5. **`ModelParams.loras` is applied at load on native llama.cpp and WebGPU.**
   Before, those backends ignored it and loaded the base model. Now each
   adapter is applied in order with its scale, and a load whose adapter
   cannot be applied fails: `LlamaUnsupportedException` for an unsupported
   adapter or WebGPU bridge assets without LoRA support (the minimum version
   is in the LoRA adapters guide), otherwise `LlamaModelException` with the
   adapter in `details`. Remove adapters you did not mean to apply, and catch
   both exceptions around `loadModel`.

6. **LiteRT-LM `ModelParams` rejections throw `LlamaUnsupportedException`.**
   Before, native and web LiteRT-LM wrapped them in `LlamaModelException`.
   This covers more than one LoRA adapter and a non-default adapter scale.

   ```dart
   // Before
   } on LlamaModelException catch (e) { ... }
   // After
   } on LlamaUnsupportedException catch (e) {
     // ModelParams option this runtime does not support.
   } on LlamaModelException catch (e) { ... }
   ```

7. **Media without a projector throws.** Before, image or audio parts sent
   to a GGUF model with no projector loaded were answered from the text
   alone on native llama.cpp and failed as `LlamaInferenceException` on
   WebGPU. Now both throw `LlamaUnsupportedException`, and native llama.cpp
   and LiteRT-LM throw it for `LlamaImageContent.url`. Load a projector with
   `loadMultimodalProjector` first, or drop media parts from requests and
   history when none is loaded; pass image bytes or a file instead of a URL.

## `0.8.9` -> `0.8.10`: model download/cache defaults

No source migration is required for existing calls: `DefaultModelDownloadManager`
constructors remain source-compatible, and the mobile-specific directory
arguments added to `DefaultModelDownloadManager.auto(...)` in `0.8.10` are
optional.

There are two intentional runtime default changes to be aware of:

1. `DefaultModelDownloadManager()` no longer defaults to the process temporary
   directory on desktop/server platforms. It now uses the same platform cache
   root as `DefaultModelDownloadManager.auto()`:

   | Platform | New default root |
   | --- | --- |
   | Linux | `$XDG_CACHE_HOME/llamadart/models`, or `$HOME/.cache/llamadart/models` when `XDG_CACHE_HOME` is unset |
   | macOS | `$HOME/Library/Caches/llamadart/models` |
   | Windows | `%LOCALAPPDATA%\llamadart\models`, then `%APPDATA%\llamadart\models`, then `%USERPROFILE%\AppData\Local\llamadart\models` |

   If a desktop/server embedder cannot expose a home/cache environment, the
   default constructor preserves compatibility by falling back to
   `Directory.systemTemp/llamadart/models`. Explicit `auto(...)` and
   `sharedCache(...)` calls still report cache-resolution errors so apps can
   choose a durable directory.

2. `DefaultModelDownloadManager.auto(platform: android/ios)` without an explicit
   mobile directory no longer throws. It now uses an app-private temporary/cache
   fallback at `Directory.systemTemp/llamadart/models`. This is convenient for
   examples and rebuildable downloads, but large durable mobile model files
   should still use an app-private cache/support directory resolved by the app.
   For Flutter apps, prefer `path_provider.getApplicationCacheDirectory()` for
   re-downloadable model caches; use `getApplicationSupportDirectory()` only for
   app-owned durable support files when the app also accounts for platform
   backup/no-backup policy.

Recommended cross-platform setup:

```dart
final engine = LlamaEngine(
  LlamaBackend(),
  modelDownloadManager: DefaultModelDownloadManager.auto(
    // On Flutter, pass a path resolved by path_provider for the current app.
    // For re-downloadable model caches, prefer getApplicationCacheDirectory().
    // Desktop/server ignores this and uses the per-user shared cache.
    appPrivateCacheDirectory: appCacheModelsDirectory,
  ),
);
```

If your app resolves platform-specific mobile directories ahead of time, pass
both without adding `Platform.isAndroid` / `Platform.isIOS` branches around the
download manager constructor:

```dart
final manager = DefaultModelDownloadManager.auto(
  androidAppPrivateCacheDirectory: androidModelsDirectory,
  iosAppPrivateCacheDirectory: iosModelsDirectory,
);
```

To preserve the old temporary-cache behavior exactly on desktop/server, pass an
explicit directory:

```dart
final manager = DefaultModelDownloadManager(
  defaultCacheDirectory: path.join(
    Directory.systemTemp.path,
    'llamadart',
    'models',
  ),
);
```

If your application previously called `DefaultModelDownloadManager.auto()` on
Android/iOS and expected a `LlamaUnsupportedException`, update that test or call
`DefaultModelDownloadManager.sharedCache()` without `cacheDirectory` when you
specifically want to reject implicit mobile shared caches.

## `0.6.3` -> `0.6.4`

No public API break, but Android arm64 native packaging defaults changed.

- Shorthand config such as `android-arm64: [vulkan]` is still supported.
- If no CPU policy is set, Android arm64 now defaults to
  `cpu_profile: full` (all CPU variants).
- If you want smaller baseline-only packaging, set
  `cpu_profile: compact` explicitly.
- `cpu_variants: [...]` (when provided) overrides `cpu_profile`.

Example (preserve compact baseline-style packaging):

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_backends:
        platforms:
          android-arm64:
            backends: [vulkan]
            cpu_profile: compact
```

## `0.5.x` -> `0.6.x`

### Template routing / handler APIs

The legacy custom handler/override registry APIs were removed:

- `ChatTemplateEngine.registerHandler(...)`
- `ChatTemplateEngine.unregisterHandler(...)`
- `ChatTemplateEngine.clearCustomHandlers(...)`
- `ChatTemplateEngine.registerTemplateOverride(...)`
- `ChatTemplateEngine.unregisterTemplateOverride(...)`
- `ChatTemplateEngine.clearTemplateOverrides(...)`

Legacy per-call handler routing fields were also removed:

- render param: `customHandlerId`
- parse param: `handlerId`

### Error behavior in template render/parse

Template render/parse paths no longer silently downgrade to content-only
fallback when a handler/parser fails. Failures are now surfaced to the caller.

Audit call sites that previously relied on silent fallback behavior and handle
exceptions explicitly.

## `0.4.x` -> `0.5.0`

## 1) ChatSession API

- Old pattern (string-in, string-out helpers):
  - `session.chat(...)`
  - `session.chatText(...)`
- New pattern:
  - `session.create(List<LlamaContentPart> ...)`
  - stream `LlamaCompletionChunk`

Example migration:

```dart
// Before
await for (final token in session.chat('Hello')) {
  stdout.write(token);
}

// After
await for (final chunk in session.create([LlamaTextContent('Hello')])) {
  stdout.write(chunk.choices.first.delta.content ?? '');
}
```

## 2) LlamaChatMessage constructor names

- `LlamaChatMessage.text(...)` -> `LlamaChatMessage.fromText(...)`
- `LlamaChatMessage.multimodal(...)` -> `LlamaChatMessage.withContent(...)`

Example migration:

```dart
// Before
LlamaChatMessage.text(role: LlamaChatRole.user, content: 'Hi');

// After
LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi');
```

## 3) Logging configuration moved off ModelParams

- Removed: `ModelParams(logLevel: ...)`
- Use `LlamaLogging.configure` instead: `level:` for Dart-side logs and
  `nativeLevel:` for native logs (by default the same as `level:`)

Example migration:

```dart
// Before
await engine.loadModel(path, modelParams: ModelParams(logLevel: LlamaLogLevel.info));

// After
await LlamaLogging.configure(nativeLevel: LlamaLogLevel.info);
await engine.loadModel(path);
```

## 4) Model reload lifecycle

- `loadModel(...)` now throws if a model is already loaded.
- Call `await engine.unloadModel()` (or `dispose()`) before loading another model.

## 5) Public exports tightened

The package root (`package:llamadart/llamadart.dart`) no longer exports some
previous internals. In particular:

- `ToolRegistry`
- `LlamaTokenizer`
- `ChatTemplateProcessor`

Use `LlamaEngine`, `ChatSession`, `ToolDefinition`, and the template APIs as
the supported surface.

## 6) Custom backend implementers

If you maintain your own `LlamaBackend` implementation, update it to match the
current interface:

- Add `getVramInfo()`.
- Update `applyChatTemplate(...)` signature/return type (string-based prompt
  rendering input/output).

## 7) Template routing in strict parity mode

Template/render/parse behavior is now strict llama.cpp parity:

- `customTemplate` remains supported for per-call template overrides.
- Legacy `customHandlerId`/parse `handlerId` routing was removed.
- `ChatTemplateEngine.registerHandler(...)` and
  `ChatTemplateEngine.registerTemplateOverride(...)` were removed.
- Render/parse paths no longer silently downgrade to content-only fallback when
  a handler/parser fails; failures are surfaced to the caller.

## 8) Quick migration checklist

- Replace old `ChatSession` chat helpers with `create(...)` streaming.
- Rename `LlamaChatMessage` named constructors.
- Remove `ModelParams.logLevel` usage.
- Audit imports that depended on removed root exports.
- For custom backends, implement the latest `LlamaBackend` interface.
