# Migration Guide

This document covers the major breaking upgrade paths.

## `0.10.x` -> `0.11.0`: image generation engine API

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

## `0.10.x` -> `0.11.0`: `LlamaEngine.load` and `setModel`

`LlamaEngine` loads like the other engines: `LlamaEngine.load` creates an
engine and loads a `LlamaModel`, and `setModel` loads or replaces the model
of an engine you already have. `loadModel`, `loadModelSource`,
`loadModelFromUrl` and `loadMultimodalProjector` are deprecated and keep
working until 1.0.

1. **Load a model and its projector in one call.** Runtime settings are
   `params:` and download settings are `download:`. The load is atomic: when
   it throws, the engine and its backend are disposed and nothing stays
   loaded.

   ```dart
   // Before
   final engine = LlamaEngine(LlamaBackend());
   await engine.loadModelSource(
     ModelSource.parse('hf://owner/repo/model.gguf'),
     modelParams: const ModelParams(contextSize: 4096),
     options: ModelLoadOptions(bearerToken: token),
     onProgress: (progress) => print(progress.fraction),
   );
   try {
     await engine.loadMultimodalProjectorSource(
       ModelSource.parse('hf://owner/repo/mmproj.gguf'),
     );
   } catch (_) {
     await engine.unloadModel();
     rethrow;
   }
   // After
   final engine = await LlamaEngine.load(
     LlamaModel(
       ModelSource.parse('hf://owner/repo/model.gguf'),
       projector: ModelSource.parse('hf://owner/repo/mmproj.gguf'),
     ),
     params: const ModelParams(contextSize: 4096),
     download: ModelLoadOptions(bearerToken: token),
     onProgress: (progress) => print(progress.fraction),
   );
   ```

   A local file is `ModelSource.path(path)`, and `ModelSource.parse` takes a
   path, an `http(s)` URL or an `hf://` reference. A custom resolver or
   download manager goes in `store: ModelFileStore(...)`. `onProgress`
   reports the model and its projector together: with a projector,
   `totalBytes` and `fraction` are null until the model has downloaded and
   the projector reports its size, so show `receivedBytes` until then.

2. **Switch models with `setModel`.** It replaces the loaded model, so the
   `unloadModel()` before a second load is no longer needed. The loaded
   model keeps serving until every file of the new one has downloaded; a
   download that fails or is cancelled leaves it loaded. A load that fails
   after that leaves nothing loaded. On the Web the runtime fetches the
   files itself, so `setModel` unloads the loaded model before the fetch, and
   a fetch that fails leaves nothing loaded.

   ```dart
   // Before
   await engine.unloadModel();
   await engine.loadModel('/models/other.gguf', modelParams: params);
   // After
   await engine.setModel(
     LlamaModel(ModelSource.path('/models/other.gguf')),
     params: params,
   );
   ```

   While `setModel` runs, another `setModel` and `unloadModel()` throw
   `LlamaStateException`; stop it with `download`'s cancel token.
   `dispose()` stops its downloads at once, and the call throws
   `LlamaStateException`.

3. **`loadMultimodalProjectorSource` takes `download:`.** `options:` is the
   deprecated name; passing both throws `LlamaArgumentException`. Use the
   method to change the projector of a loaded model; load a model with its
   projector as in step 1. `unloadModel()` and `dispose()` now stop its
   download, and the load throws `LlamaStateException` instead of
   `LlamaContextException`.

4. **What differs from the deprecated loaders.**
   - A local file takes only `download`'s cancel token and, for a model
     without a projector, its `sha256`. `loadModelSource` threw
     `LlamaUnsupportedException` for a local path with a bearer token,
     headers, cache directory, cache policy, resume or retry setting;
     `load` and `setModel` do not apply them to a local file.
   - `download`'s bearer token and headers go to one origin only: a model
     and projector on different hosts throw `LlamaArgumentException` when
     they are set.
   - `ModelLoadOptions.sha256` with a projector throws
     `LlamaUnsupportedException`, since it cannot name two files.
   - A projector for a LiteRT-LM model and `ComputeDevice.npu` for a GGUF
     throw `LlamaUnsupportedException` before anything downloads, when the
     `ModelSource.format` or file name gives the format.
   - On the Web, a `ModelSource.path` is a URL relative to the document, or
     a `blob:` URL. It used to throw `LlamaUnsupportedException`, and now
     loads in the deprecated `loadModelSource`, `setLoraSource` and draft
     models too.
   - A subclass that overrides `loadModel` no longer sees loads made
     through `load` and `setModel`. Fake a `LlamaBackend` in tests, or
     override `setModel`.
   - `load` and `setModel` check a local file through the download manager
     before the backend sees it, so a test that loads a made-up path such
     as `model.gguf` into a fake backend now throws `LlamaModelException`
     (`Local model file does not exist`). Give the test a real temporary
     file, or a fake `ModelDownloadManager` in `store:` or
     `LlamaEngine(backend, modelDownloadManager: ...)`.
   - A `blob:` URL goes in `ModelSource.path`; `ModelSource.parse` accepts
     only paths, `http(s)` URLs and `hf://` references.
   - A `LlamaEngineObserver` sees a whole `load` or `setModel` call as one
     model load, with its downloads, so a file that is missing or fails to
     download ends that operation with an error. `loadModelSource` reports
     only the load that follows its download.

5. **New members on `LlamaEngine`.** A class that `implements LlamaEngine`
   must add `setModel`, and an override of `loadMultimodalProjectorSource`
   must add the `download` parameter and make `options` nullable.

6. **Messages.** A request before a load throws `LlamaContextException`
   with `Engine not ready: no model is loaded. Call LlamaEngine.load or
   setModel first.` Code that matched the earlier text should catch the
   exception type instead.

## `0.10.x` -> `0.11.0`: one task shape for image and speech engines

`ImageGenerationTask`, `SpeechToTextTask` and `TextToSpeechTask` share one
shape: `events` carries progress only, `done` reports how the task ended and
never throws, the new `result` returns the result or throws, and `cancel()`
stops only that task.

1. **`ImageGenerationEngine.generate` returns a `Future` (Preview).** Await
   it for the task; invalid requests, a disposed engine and a running
   generation now fail that future instead of throwing synchronously. The
   one-generation slot is still taken when `generate` is called.

   ```dart
   // Before
   final task = engine.generate(request);
   // After
   final task = await engine.generate(request);
   ```

2. **Task `events` no longer carry errors.** A failed task closes `events`
   without a final event. Code that caught the failure from the stream (an
   `onError` handler, or `try` around `await for`) reads it from `result`
   or `done` instead:

   ```dart
   // Before
   try {
     await for (final event in task.events) {
       if (event is TextToSpeechFinalEvent) save(event.result);
     }
   } on LlamaException catch (error) {
     report(error);
   }
   // After
   task.events.listen(showProgress);
   try {
     save(await task.result);
   } on LlamaException catch (error) {
     report(error); // LlamaStateException when the task was cancelled
   }
   ```

   `SpeechToTextStreamingSession` is unchanged: its `events` still report a
   failure as a stream error as well as through `done`, and its `cancel()`
   returns a `Future`, because it ends a live input stream rather than one
   result.

3. **`SpeechToTextTask.cancel()` stops only its own task.** A prompt-adapter
   task used to call `LlamaEngine.cancelGeneration`, which also ended chat,
   tool-loop and other requests on the same engine. It now cancels only the
   task's own generation. Call `LlamaEngine.cancelGeneration` yourself if you
   relied on that.

## `0.10.x` -> `0.11.0`: decision engine load and attach

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

## `0.10.x` -> `0.11.0`: TranslateGemma language codes

`LlamaEngine.create`, `createStructuredJson` and `chatTemplate` deprecate
`sourceLangCode` and `targetLangCode`. Pass the codes in
`chatTemplateKwargs`, as llama.cpp's `chat_template_kwargs` does; the
parameters keep working, with deprecation warnings, until 1.0:

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

## `0.10.x` -> `0.11.0`: mobile model cache default

No source change is required. On Android and iOS, `LlamaEngine`,
`ModelDownloadController` and `DefaultModelDownloadManager()` (and `auto()`
without a mobile directory) now cache models in `llamadart/models` under the
app's cache directory, the one Flutter's `getApplicationCacheDirectory()`
returns, instead of `Directory.systemTemp/llamadart/models`. Models cached
under the old path download once more; the old copies are left for the OS to
clear. Apps that already pass a directory are unaffected. To pick another
directory for every default download, set
`DefaultModelDownloadManager.globalCacheDirectory` before the first load.

## `0.10.x` -> `0.11.0`: typed argument errors and one logging API

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
   the whole library. The old calls keep working, with deprecation warnings,
   until 1.0:

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

## `0.10.x` -> `0.11.0`: speech engine load, attach and adapters

`SpeechToTextEngine` and `TextToSpeechEngine` follow the shared engine
pattern: `load` takes a model of `ModelSource` files and owns what it loads,
and an adapter, not a profile enum, says how to run the model. The old
constructors, `SpeechToTextModelProfile`, `TextToSpeechModelProfile` and the
`modelProfile` getters keep working, with deprecation warnings, until 1.0.

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
## `0.10.x` -> `0.11.0`: `ModelSource` for LoRA adapters, draft models and speech files

LoRA adapters, speculative draft models and LiteRT-LM ASR files take a
`ModelSource`, so a remote file downloads into the model cache like a model.
The `String` path forms keep working, with deprecation warnings, until 1.0:

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

## `0.10.x` -> `0.11.0`: optional `ToolDefinition.handler`

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

## `0.10.x` -> `0.11.0`: app, backend and bindings entrypoints

`package:llamadart/llamadart.dart` is now the app API only. Code that loads
models, generates and uses the speech, image and decision engines needs no
change. Custom backends, backend test fakes and raw runtime access import one
of two new libraries.

1. **Raw llama.cpp FFI: `package:llamadart/llama_cpp_bindings.dart`.** The
   ffigen bindings (`llama_backend_init`, `llama_decode`, `ggml_*`, `mtmd_*`
   and their structs) are no longer in the app API. They are native only, and
   any release that updates llama.cpp can change them:

   ```dart
   import 'package:llamadart/llama_cpp_bindings.dart';
   import 'package:llamadart/llamadart.dart';
   ```

2. **Backend SPI: `package:llamadart/backend.dart`.** These names move there:
   - `BackendAvailability`, `BackendBatchEmbeddings`, `BackendDartLogLevel`,
     `BackendDecision`, `BackendDecisionCapabilities`,
     `BackendDecisionHeadInfo`, `BackendDecisionOutput`,
     `BackendDecisionSequence`, `BackendEmbeddings`,
     `BackendEmbeddingsSupport`, `BackendGenerationCapabilities`,
     `BackendGenerationCapabilitiesSupport`, `BackendGpuEnumeration`,
     `BackendGrammarConstraintsSupport`, `BackendLazyGrammarSupport`,
     `BackendModelFileTypeDiagnostics`, `BackendNativeChatGeneration`,
     `BackendNextTokenScoring`, `BackendNextTokenScoringSupport`,
     `BackendPerformanceDiagnostics`, `BackendPromptSpeechToTextSupport`,
     `BackendRuntimeDiagnostics`, `BackendStatePersistence`,
     `BackendStatePersistenceSupport`, `BackendTextToSpeech`,
     `BackendTextToSpeechCapabilities`, `BackendTextToSpeechPhase`,
     `BackendTextToSpeechProgress`, `BackendTextToSpeechRequest` and
     `BackendTextToSpeechResult`.
   - `LiteRtLmBackend`, `LiteRtLmRuntimeClient`, `LiteRtLmRuntimeMetrics` and
     `LiteRtLmRuntimeResult`.
   - `LiteRtLmAsrRuntimeSession`, `LiteRtLmAsrPushResult`,
     `LiteRtLmAsrProcessResult` and `LiteRtLmAsrProcessState`.

   `LlamaBackend`, `BackendPerfContextData`, `BackendTextToSpeechModel`,
   `StateLoadResult`, `LiteRtLmAsrBackend`, `LiteRtLmAsrModelPreset` and
   `LiteRtLmAsrRuntimeConfig` stay in the app API; `backend.dart` exports the
   first four too. Add the import next to the app one:

   ```dart
   import 'package:llamadart/backend.dart';
   import 'package:llamadart/llamadart.dart';
   ```

3. **Engine hooks are extension members.** `modelHandle`, `contextHandle`,
   `backendTextToSpeechCapabilities`, `synthesizeTextToSpeechBackend`,
   `cancelTextToSpeechBackend`, `backendDecisionCapabilities`,
   `loadDecisionHeadBackend`, `runDecisionBackend` and
   `freeDecisionHeadBackend` move from `LlamaEngine` to the
   `LlamaEngineBackendHooks` extension in `backend.dart`. Calls keep working
   once `backend.dart` is imported. A `LlamaEngine` subclass that overrode
   one no longer intercepts it, and the analyzer reports only an
   `override_on_non_overriding_member` warning. A fake that
   `implements LlamaEngine` is bypassed the same way wherever it is typed as
   `LlamaEngine`, as inside `TextToSpeechEngine` and `DecisionEngine`: the
   extension runs instead of the fake's members and reads engine state the
   fake lacks, so the call fails with `NoSuchMethodError`. In both cases, fake
   at the backend instead:

   ```dart
   // Before
   class FakeEngine extends LlamaEngine {
     FakeEngine() : super(LlamaBackend());
     @override
     Future<BackendTextToSpeechResult> synthesizeTextToSpeechBackend(
       BackendTextToSpeechRequest request, {
       void Function(BackendTextToSpeechProgress progress)? onProgress,
     }) async => fakeResult;
   }
   // After
   class FakeBackend implements LlamaBackend, BackendTextToSpeech {
     @override
     Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
       int contextHandle,
       int mmContextHandle,
       BackendTextToSpeechRequest request, {
       void Function(BackendTextToSpeechProgress progress)? onProgress,
     }) async => fakeResult;
     // ... the rest of LlamaBackend and BackendTextToSpeech
   }
   ```

4. **Removed deprecated APIs.** `LiteRtLmBenchmarkClient`,
   `LiteRtLmBenchmarkMetrics` and `LiteRtLmBenchmarkResult` are gone; use
   `LiteRtLmRuntimeClient`, `LiteRtLmRuntimeMetrics` and
   `LiteRtLmRuntimeResult`. `LiteRtLmRuntimeClient.conversationTokenCount`
   and `replaceConversationWithClone` are gone with no replacement.

## `0.10.x` -> `0.11.0`: one `ComputeDevice` for every engine

`ModelParams.device` takes a `ComputeDevice` and applies to llama.cpp and
LiteRT-LM, as `ImageModelParams.device` and `DecisionModelParams.device`
already do. `ModelParams.liteRtLmBackend`, `LiteRtLmBackendPreference` and
`LiteRtLmBackend(preferredBackend:)` are deprecated and keep working until
1.0.

1. **Replace the LiteRT-LM selector with `device`.**

   ```dart
   // Before
   final engine = LlamaEngine(LiteRtLmBackend(preferredBackend: 'gpu'));
   await engine.loadModel(
     path,
     modelParams: const ModelParams(
       liteRtLmBackend: LiteRtLmBackendPreference.gpu,
     ),
   );
   // After
   final engine = await LlamaEngine.load(
     LlamaModel(ModelSource.path(path)),
     params: const ModelParams(device: ComputeDevice.gpu),
   );
   ```

   `ComputeDevice.auto`, the default, keeps each runtime's default device, so
   code that sets neither field is unchanged. Setting `device` together with
   `liteRtLmBackend` throws `LlamaArgumentException`; setting it with
   `LiteRtLmBackend(preferredBackend:)` throws `LlamaUnsupportedException`.
   Code that still constructs `LiteRtLmBackend` imports it from
   `package:llamadart/backend.dart`, as the section above describes.

2. **An explicit device is a requirement.** With `device: cpu`, `gpu` or
   `npu`, a device the runtime and platform cannot provide throws
   `LlamaUnsupportedException`, not the `LlamaModelException` the deprecated
   selector throws, and nothing falls back to another device:
   - llama.cpp `gpu` without a GPU module or device, which `preferredBackend`
     used to load on the CPU with a warning, now throws; on Android `gpu`
     uses Vulkan, which `auto` does not.
   - On the Web, `gpu` needs a WebGPU adapter, and the llama.cpp bridge no
     longer retries a failed GPU load on the CPU.
   - Native LiteRT-LM creates its engine on first use, so a GPU or NPU
     delegate that fails to start throws from the first generation or
     tokenizer call.

   Use `ComputeDevice.auto` to accept the runtime's default, or catch
   `LlamaException` to cover the old and new types.

3. **One `device` covers both runtimes.** Under `auto`, `gpuLayers` and
   `preferredBackend` still choose the LiteRT-LM backend as before. To run
   llama.cpp on the CPU and LiteRT-LM on the GPU from one `ModelParams`, keep
   the deprecated `liteRtLmBackend` with `device: auto`, or pick the params
   from `ModelSource.format`.

4. **`ModelParams.validate()` runs before the download.** `loadModel`,
   `loadModelSource` and `loadModelFromUrl` call it first, so an invalid
   combination throws `LlamaArgumentException` before anything downloads,
   where it used to fail the backend load as `LlamaModelException`. New
   rules reject `device: cpu` with a GPU `preferredBackend`, and `gpu` or
   `npu` with a CPU or BLAS `preferredBackend`, `gpuLayers: 0`, or
   `splitMode: ModelSplitMode.none` with a negative `mainGpu`.

5. **Decision models.** `DecisionModelParams.encoderModelParams` now carries
   `device` instead of `preferredBackend: GpuBackend.cpu` and `gpuLayers: 0`
   for `cpu`. `DecisionModelParams(device: ComputeDevice.gpu)` no longer asks
   the backend for GPU support before loading: the encoder loads on a GPU or
   the load throws `LlamaUnsupportedException`.

## `0.10.x` -> `0.11.0`: shared capabilities and terminal dispose

1. **Image capabilities are async; `runtimeCapabilities()` is removed.**
   `ImageGenerationEngine.capabilities` returns a `Future`, like every other
   engine's. It changes only when the engine is disposed, so read it once
   after `load` and keep it, for example in a Flutter `State`, instead of
   reading it in `build`. Probe the runtime before loading with
   `checkRuntime()`, which runs off the calling isolate:

   ```dart
   // Before
   final runtime = ImageGenerationEngine.runtimeCapabilities();
   print(engine.capabilities.backendName);
   // After
   final runtime = await ImageGenerationEngine.checkRuntime();
   final capabilities = await engine.capabilities;
   print(capabilities.backendName);
   ```

   `ImageGenerationCapabilities` and `DecisionCapabilities` now implement
   `EngineCapabilities`, so code that reads `isSupported`,
   `unsupportedReason` and `backendName` can take any engine's capabilities.

2. **`LlamaEngine.dispose()` is terminal.** A second call returns the same
   future instead of disposing the backend again. After it, a load or request
   throws `LlamaStateException` (requests used to throw
   `LlamaContextException`), `DecisionEngine.attach` throws
   `LlamaStateException`, and `capabilities` reports the engine as disposed.
   The backend queries `getBackendName`, `getAvailableBackends`,
   `isGpuSupported`, `getVramInfo`, `listGpuDevices` and
   `getResolvedGpuLayers`, which used to answer after `dispose`, now throw
   `LlamaStateException`; read them before disposing. Model queries such as
   `getMetadata` and `getContextSize` return their no-model values, as
   before. `unloadModel` and `cancelGeneration` do nothing. To switch models, call
   `setModel`; to start over after `dispose`, create a new
   `LlamaEngine`. A load running when `dispose` is called now throws
   `LlamaStateException` instead of completing, and its model is unloaded.
   A class that `implements LlamaEngine` must add `bool get isDisposed`.

3. **`supportsVision` and `supportsAudio` agree with `capabilities`.** On a
   LiteRT-LM bundle that takes media directly, they are now true without a
   multimodal projector. When the runtime cannot probe a projector, they
   are false instead of throwing `LlamaUnsupportedException`.

## `0.10.x` -> `0.11.0`: Apple companions, new members and stricter checks

1. **Flutter iOS/macOS apps update the companion packages with the core.**
   Core `0.11.0` pairs with `llamadart_llama_cpp_flutter` `0.0.21`,
   `llamadart_litert_lm_flutter` `0.0.13` and
   `llamadart_stable_diffusion_flutter` `0.0.2`. A `^0.0.x` constraint admits
   only that version, so edit each one the app uses:

   ```yaml
   dependencies:
     llamadart: ^0.11.0
     llamadart_llama_cpp_flutter: ^0.0.21
     llamadart_litert_lm_flutter: ^0.0.13
     llamadart_stable_diffusion_flutter: ^0.0.2
   ```

   An Apple build that resolves an older llama.cpp or stable_diffusion
   companion fails with `Incompatible Apple ... companion`.

2. **More members for a class that `implements` an app type.** `ChatSession`
   gains `createStructuredJson`, and `LlamaEngine` gains `runtime`,
   `capabilities`, `setLoraSource` and `removeLoraSource`, besides `setModel`
   and `isDisposed` above.

3. **An unknown `responseFormat` type or key throws.** A map with a
   misspelled `type` or key, such as `json_shema` or `schma`, used to generate
   unconstrained output. It now throws `LlamaUnsupportedException` before
   generation; a `null`-valued key counts as absent.

4. **Native `LlamaBackend()` picks the runtime from the file header.** An
   extensionless download now loads in the runtime its header names. A
   recognized header that contradicts the file's model extension or an
   explicit `format:` throws `LlamaModelFormatException`; rename the file or
   pass the matching `format:`.

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
