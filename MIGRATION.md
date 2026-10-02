# Migration Guide

This document covers the major breaking upgrade paths.

## `0.10.x` -> next release: image generation model sources

Image generation is a Preview. The path-based model API still works in the
next release but is deprecated, and a later release removes it.

1. **Presets take `ModelSource`s and download pinned files by default.**
   Each path factory has a `*Preset` replacement whose parameters are
   `ModelSource`s named after the file roles. Omit a file to use the
   preset's `ImageGenerationPresetFile`, which `ImageGenerationEngine.load`
   downloads into the model cache. Wrap a local path in `ModelSource.path`:

   ```dart
   // Before
   final entry = await DefaultModelDownloadManager().ensureModel(
     ModelSource.parse(
       'hf://concedo/sdxs-512-tinySDdistilled-GGUF/'
       'sdxs-512-tinySDdistilled_Q8_0.gguf',
     ),
   );
   final engine = await ImageGenerationEngine.load(
     ImageGenerationModel.sdxs(entry.filePath),
   );
   // After
   final engine = await ImageGenerationEngine.load(
     ImageGenerationModel.sdxsPreset(),
     onProgress: (progress) => print(progress.fraction),
   );
   // After, keeping a local file
   final engine = await ImageGenerationEngine.load(
     ImageGenerationModel.sdxsPreset(model: ModelSource.path(sdxsPath)),
   );
   ```

   | Deprecated | Replacement |
   | --- | --- |
   | `sdxs(modelPath)` | `sdxsPreset(model:)` |
   | `sdTurbo(modelPath, taesdPath:)` | `sdTurboPreset(model:, taesd:)` |
   | `sdxlLightning(modelPath, vaePath:, taesdPath:)` | `sdxlLightningPreset(model:, vae:, taesd:)` |
   | `flux1Schnell(diffusionModelPath:, clipLPath:, t5xxlPath:, vaePath:, taesdPath:)` | `flux1SchnellPreset(diffusionModel:, clipL:, t5xxl:, vae:, taesd:)` |
   | `sd35LargeTurbo(diffusionModelPath:, clipLPath:, clipGPath:, t5xxlPath:, vaePath:, taesdPath:)` | `sd35LargeTurboPreset(diffusionModel:, clipL:, clipG:, t5xxl:, vae:, taesd:)` |
   | `zImageTurbo(diffusionModelPath:, llmPath:, vaePath:)` | `zImageTurboPreset(diffusionModel:, llm:, vae:)` |

   An optional file that the old factory left out stays out: `sdTurboPreset`
   and `sdxlLightningPreset` add no TAESD unless given one, such as
   `ImageGenerationPresetFile.taesd.source`. `flux1SchnellPreset` and
   `sd35LargeTurboPreset` no longer throw `ArgumentError` without a
   decoder: they use the pinned FLUX `ae` and TAESD3, and any `vae` or
   `taesd` you pass replaces that default.

2. **`ImageGenerationModelFiles` takes sources.** Replace
   `ImageGenerationModelFiles(model: path, ...)` with
   `ImageGenerationModelFiles.fromSources(model: ModelSource.path(path),
   ...)`; `ImageGenerationModel.custom` is unchanged. The `String` fields
   (`model`, `vae`, ...) and `paths` are deprecated: read
   `files.sources['vae']` instead. For a file from a URL or Hugging Face
   they are `null`, and `paths` leaves it out.

3. **`ImageGenerationEngine.load` resolves every file.** It now checks local
   files through the model download manager, like
   `LlamaEngine.loadModelSource`, and takes `loadOptions`, `onProgress`,
   `modelResolver` and `modelDownloadManager`. `ModelLoadOptions.sha256`
   throws `LlamaUnsupportedException`, since one checksum cannot cover
   several files. Loading only local files behaves as before.

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
- Use engine-level controls instead:
  - `await engine.setDartLogLevel(...)`
  - `await engine.setNativeLogLevel(...)`
  - or `await engine.setLogLevel(...)` to set both

Example migration:

```dart
// Before
await engine.loadModel(path, modelParams: ModelParams(logLevel: LlamaLogLevel.info));

// After
await engine.setNativeLogLevel(LlamaLogLevel.info);
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
