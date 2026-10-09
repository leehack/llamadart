---
name: llamadart-flutter-app
description: >-
  Use when integrating llamadart into a Flutter app: deciding where the
  LlamaEngine lives and when to dispose it, keeping the UI responsive while
  streaming, showing model download progress and managing the model cache,
  iOS and macOS deployment targets, the llamadart_llama_cpp_flutter and
  llamadart_litert_lm_flutter companion packages, Android and web setup, or
  trimming bundled native runtimes with hooks.user_defines.
---

# Flutter apps with llamadart

Wire a llamadart engine into a Flutter app without leaking it, blocking the UI
or shipping runtimes the app does not use.

## Guidelines

- Own the engine in a long-lived object (a service, a `ChangeNotifier`, a
  provider, or a `State`), never in `build()`. Create it once, load in
  `initState` or a start method, and dispose it with the owner: cancel any
  download token and `engine.cancelGeneration()`, then `engine.dispose()`.
  `State.dispose` is synchronous, so wrap the call in `unawaited(...)`.
  `dispose()` waits for an in-flight load or unload, then unloads the model
  and releases the backend; that load then throws `LlamaStateException`.
  It immediately marks the engine disposed, even inside logging or backend
  hooks. Every call shares one future, including a failed teardown; disposal
  does not retry cleanup after failure.
  Model unload, replacement, and disposal also cancel active chat-session
  requests: partial replies stay in history, while requests stopped before
  output roll back and throw `LlamaStateException`. Tool loops report
  `LlamaToolLoopStopReason.cancelled`, wait for running handlers, and roll back
  unfinished tool turns before another model request.
- Quitting a desktop app (Cmd-Q, closing the last window) does not run
  `State.dispose`. Also dispose `LlamaEngine`, `DecisionEngine` and
  `ImageGenerationEngine` instances from
  `AppLifecycleListener(onExitRequested: ...)`, awaiting them before
  returning `AppExitResponse.exit` (from `dart:ui`). A Flutter macOS app
  that quits without disposing (Quit menu item, last window,
  `exitApplication`) still exits cleanly: Flutter shuts the isolates down
  first, so llamadart frees the models they hold, and the llama.cpp runtime
  (`llamadart-native` `v0.5.0-2` and later) and the stable_diffusion runtime
  (`stable-diffusion-native` `v0.2.0-1` and later) free a model the quit
  caught mid-load. Dispose anyway: the quit waits for a native call that is
  still running, so for the rest of an image generation, and only macOS has
  been measured (the runtimes free nothing at process exit outside Apple
  platforms). When the engine's owner can be disposed before quit (a
  pushed route), its listener goes with it: make one app-level exit listener
  await every engine's disposal, including one its owner already started.
- Keep inference state out of widgets. Put a plain Dart controller between
  the engine and the UI (example below) and adapt it to `ChangeNotifier`,
  `ValueNotifier`, BLoC or Riverpod. Loading, chat history and streaming
  basics are in the llamadart-getting-started and llamadart-chat-streaming
  skills.
- Stream through a `StreamSubscription` stored on the owner so Stop and
  dispose can reach it. For Stop, call `engine.cancelGeneration()`: the stream
  ends normally with a partial reply on native backends, but `ChatSession`
  throws `LlamaStateException` and rolls back if cancelled before any reply
  content. A partial reply stays in history only if that session has not
  reset; WebGPU cancellation can also surface a generation error. In `dispose`, also cancel the subscription.
- Do not call `setState` or `notifyListeners` per token. Append deltas to a
  `StringBuffer` and flush on a short timer (the example chat app notifies
  about every 16 ms), and flush once more on done or error. Check `mounted`
  before any `setState` after an `await`.
- Disable Send while a generation runs: one engine runs one generation at a
  time, and a second request throws `LlamaStateException`.
- Show download progress from `setModel(onProgress: ...)` (or
  `LlamaEngine.load(onProgress: ...)`).
  `ModelDownloadProgress.fraction` is `null` while the total size is unknown;
  pass it straight to `LinearProgressIndicator(value: ...)` to get an
  indeterminate bar. A cancelled `ModelDownloadCancelToken` makes the load
  throw `LlamaStateException`; treat that as a cancel, not an error.
- Web backends download through the browser and reject a cancel token (and
  checksums, auth headers and non-default cache policies) with
  `LlamaUnsupportedException`. Pass `ModelLoadOptions(cancelToken: ...)` only
  when `!kIsWeb`, otherwise `ModelLoadOptions.defaults`.
- For a download screen with stages, cancel and retry, use
  `ModelDownloadController`, which has no Flutter dependency. It owns
  cancellation: call `controller.cancel()` and never put a `cancelToken` in
  the options you pass to `start` (it throws `LlamaArgumentException`). Then
  `engine.setModel(LlamaModel(ModelSource.path(entry.filePath)))`, or pass
  the original `ModelSource`: the load reuses the cached file.
- On Android and iOS the default cache is already `llamadart/models` in the
  app's cache directory (what `getApplicationCacheDirectory()` returns), which
  survives app updates; no `path_provider` setup is needed. To move every
  default download, for example to `getApplicationSupportDirectory()`, set
  `DefaultModelDownloadManager.globalCacheDirectory` at startup before the
  first load, in every isolate that creates engines. A manager you build yourself goes to
  `LlamaEngine(..., modelDownloadManager:)` too, so loads and cache inspection
  agree. On web the default manager's operations throw
  `LlamaUnsupportedException`.
- Do not cancel downloads on every app pause or screen lock. Downloads are
  foreground Dart HTTP requests; a later session resumes from the `.part`
  file when the server allows it. Background downloads need a custom
  `ModelDownloadManager`.
- Platform setup the package cannot do:
  - iOS deployment target 16.4+ (`IPHONEOS_DEPLOYMENT_TARGET`, and
    `platform :ios, '16.4'` in a CocoaPods Podfile); macOS 14.0+
    (`MACOSX_DEPLOYMENT_TARGET`).
  - macOS apps that download models need the
    `com.apple.security.network.client` entitlement in both
    `DebugProfile.entitlements` and `Release.entitlements`.
  - Android release builds need the `INTERNET` permission in
    `AndroidManifest.xml`.
  - Windows machines that run the app need the latest Microsoft Visual C++
    v14 Redistributable (x64 or arm64), at least as new as the build tools of
    the bundled DLLs; stock Windows Server lacks it.
  - Web needs the WebGPU bridge script in `web/index.html`; the package does
    not inject it. LiteRT-LM on web is single-turn text only (no
    `ChatSession`).
- Apple SwiftPM linking uses the companion packages:
  `llamadart_llama_cpp_flutter` (llama.cpp XCFrameworks),
  `llamadart_litert_lm_flutter` (LiteRT-LM iOS XCFrameworks) and
  `llamadart_stable_diffusion_flutter` (image generation). Use the companion
  version the llamadart README pairs with your core version. The build
  verifies the companion's runtime pin and fails on a mismatch; fix the
  version and rerun `flutter pub get`. Flutter macOS LiteRT-LM still uses the
  core hook's native assets.
- LiteRT-LM on iOS: 16.4 is the declared deployment floor, not a tested one.
  On a device it has run only on an iPhone 16 Pro with iOS 18.3.2, so test
  older iOS versions before supporting them.
- App Store builds should use the companion for each runtime they ship: an
  Apple privacy manifest reaches an app inside a companion's XCFramework,
  never in hook-bundled dylibs. The llama.cpp XCFramework has one from
  `llamadart-native` `v0.5.0-1` (`llamadart_llama_cpp_flutter` releases after
  `0.0.20`), and the stable_diffusion one from `stable-diffusion-native`
  `v0.2.0-1` (`llamadart_stable_diffusion_flutter` releases after `0.0.1`).
  When llama.cpp or
  stable_diffusion runs on the hook path, or the embedded `llama.framework` or
  `stable_diffusion.framework` has no `PrivacyInfo.xcprivacy`, add
  `NSPrivacyAccessedAPICategoryFileTimestamp` to the app's own
  `PrivacyInfo.xcprivacy` with reason `C617.1`, plus `3B52.1` only when it
  ships stable_diffusion. The LiteRT-LM iOS frameworks carry their own
  manifests from `litert-lm-native` `v0.17.0-8` (`llamadart_litert_lm_flutter`
  releases after `0.0.12`). When LiteRT-LM runs on the hook path, or its
  embedded frameworks have no `PrivacyInfo.xcprivacy`, add File Timestamp
  (`C617.1`, `3B52.1`), System Boot Time (`35F9.1`) and User Defaults
  (`CA92.1`) to the app's own manifest.
- When the llama.cpp or LiteRT-LM companion is present, the installed
  companions pick those Apple runtime families and `llamadart_native_runtimes`
  is otherwise ignored with a warning; the tag, repository, path and backend
  user-defines do not change SwiftPM binaries either. The stable_diffusion
  companion is independent: it selects image generation on iOS and macOS and
  leaves llama.cpp and LiteRT-LM where they were.
- Image generation (`ImageGenerationEngine`) needs
  `llamadart_extra_runtimes: [stable_diffusion]`, which keeps the default
  runtimes; it is never bundled by default. On iOS and
  macOS add `llamadart_stable_diffusion_flutter` instead, since App Store
  Connect rejects the iOS framework the hook bundles. Details are in the
  llamadart-image-generation skill.
- Native runtimes are downloaded by the build hook on the first
  `flutter run` or `flutter build` for each target; no C++ toolchain is
  needed. Expect a slower first build. After changing any
  `hooks.user_defines.llamadart` key, run `flutter clean` once so stale native
  assets are not reused.
- Trim app size with `hooks.user_defines.llamadart`:
  `llamadart_native_runtimes` ships one model format, and
  `llamadart_native_backends` picks llama.cpp modules per platform (Android
  arm64 also takes `cpu_profile: compact`). A backend list that names a
  module the bundle lacks is discarded whole with a warning and the defaults
  (`cpu`, `vulkan`) are bundled. Apple llama.cpp is one consolidated CPU and
  Metal runtime and is not configurable.
- Selecting `litert_lm` by name fails the build on targets without a
  LiteRT-LM runtime, such as the iOS x86_64 simulator. Apps that include
  LiteRT-LM must exclude that simulator architecture.
- Android: llama.cpp ships `cpu` and `vulkan` by default; `opencl` is opt-in
  through `llamadart_native_backends`. llama.cpp `ComputeDevice.auto` stays
  on the CPU there; Vulkan is experimental and device-dependent, so request
  `ComputeDevice.gpu` only on devices the app has validated. Leave
  `ModelParams.microBatchSize` unset on Android Vulkan: a text prompt is then
  decoded at most 8 tokens at a time, and a value above 32 returns wrong text
  on some GPUs. The cap applies to text-prompt decoding only: it does not
  cover prompts with image or audio input, embeddings, decision models,
  text-to-speech, or speculative-decoding verification batches during
  generation, which can exceed 32 tokens, so speculative decoding can still
  produce wrong output on an affected GPU.
  LiteRT-LM defaults to the GPU on
  Android (`ComputeDevice.auto`), and on adapters with a 128 MiB
  storage-buffer limit (for example Adreno 750) a model with a larger weight
  buffer, such as Qwen3 0.6B, loads and then produces wrong text without an
  error; load it with `ModelParams(device: ComputeDevice.cpu)` or let the
  user switch. `ComputeDevice.npu` needs a
  supporting SoC and bundle, and throws `LlamaUnsupportedException` without
  one.
- Budget memory for phones: 1B-3B parameter models, a `contextSize` no larger
  than the app needs, and one loaded model at a time.

## Examples

`pubspec.yaml` for a GGUF-only app that links the Apple companion and trims
Android (on Apple targets the companion, not `llamadart_native_runtimes`,
picks the runtime):

```yaml
dependencies:
  llamadart: ^<core version>
  llamadart_llama_cpp_flutter: ^<companion version paired in the README>
  path_provider: ^2.1.5

hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
      llamadart_native_backends:
        platforms:
          android-arm64:
            backends: [vulkan]
            cpu_profile: compact
```

A Flutter-free chat controller the widget layer owns. A `State` or
`ChangeNotifier` creates it in `initState`, calls `load()`, rebuilds from
`onChanged`, wires Send to `send`, Stop to `stop`, calls
`unawaited(controller.dispose())` from its own `dispose`, and awaits
`controller.dispose()` in `onExitRequested`:

```dart
import 'dart:async';

import 'package:llamadart/llamadart.dart';

class ChatController {
  ChatController({
    required this.modelUri,
    required this.onChanged,
    required this.isWeb,
    ModelDownloadManager? downloadManager,
  }) : _engine = LlamaEngine(
         LlamaBackend(),
         modelDownloadManager: downloadManager,
       );

  final String modelUri;
  final void Function() onChanged;
  final bool isWeb;

  final LlamaEngine _engine;
  final ModelDownloadCancelToken _downloadCancel = ModelDownloadCancelToken();
  final StringBuffer _pending = StringBuffer();

  ChatSession? _session;
  StreamSubscription<LlamaCompletionChunk>? _generation;
  Timer? _flushTimer;
  bool _disposed = false;

  double? downloadFraction;
  String status = 'Idle';
  String reply = '';

  bool get isReady => _session != null;
  bool get isGenerating => _generation != null;

  Future<void> load() async {
    status = 'Downloading model';
    onChanged();
    try {
      await _engine.setModel(
        LlamaModel(ModelSource.parse(modelUri)),
        params: const ModelParams(contextSize: 2048),
        download: isWeb
            ? ModelLoadOptions.defaults
            : ModelLoadOptions(cancelToken: _downloadCancel),
        onProgress: (ModelDownloadProgress progress) {
          if (_disposed) return;
          downloadFraction = progress.fraction;
          onChanged();
        },
      );
      if (_disposed) return;
      _session = ChatSession(_engine, systemPrompt: 'Be concise.');
      status = 'Ready';
    } on LlamaException catch (error) {
      if (_disposed) return;
      status = _downloadCancel.isCancelled
          ? 'Download cancelled'
          : 'Load failed: ${error.message}';
    }
    onChanged();
  }

  void send(String text) {
    final ChatSession? session = _session;
    if (session == null || isGenerating || text.trim().isEmpty) return;
    reply = '';
    _generation = session
        .create(
          <LlamaContentPart>[LlamaTextContent(text)],
          params: const GenerationParams(maxTokens: 512),
        )
        .listen(
          (LlamaCompletionChunk chunk) {
            if (chunk.text.isEmpty) return;
            _pending.write(chunk.text);
            _flushTimer ??= Timer(const Duration(milliseconds: 32), _flush);
          },
          onError: (Object error) {
            _pending.write('\n[error: $error]');
            _finish();
          },
          onDone: _finish,
          cancelOnError: true,
        );
    onChanged();
  }

  void stop() => _engine.cancelGeneration();

  void _flush() {
    _flushTimer = null;
    if (_disposed || _pending.isEmpty) return;
    reply += _pending.toString();
    _pending.clear();
    onChanged();
  }

  void _finish() {
    _flushTimer?.cancel();
    _generation = null;
    _flush();
    if (!_disposed) onChanged();
  }

  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _downloadCancel.cancel();
    _engine.cancelGeneration();
    await _generation?.cancel();
    await _engine.dispose();
  }
}
```

A download screen with stages, cancel and retry, using an app-private cache
directory the Flutter layer resolved with `getApplicationCacheDirectory()`:

```dart
import 'dart:async';

import 'package:llamadart/llamadart.dart';

class ModelDownloadScreenModel {
  ModelDownloadScreenModel(String appCacheDirectory, this.onSnapshot)
    : manager = DefaultModelDownloadManager.auto(
        appPrivateCacheDirectory: appCacheDirectory,
      ) {
    controller = ModelDownloadController(manager: manager);
    _subscription = controller.snapshots.listen(onSnapshot);
  }

  final ModelDownloadManager manager;
  final void Function(ModelDownloadTaskSnapshot snapshot) onSnapshot;
  late final ModelDownloadController controller;
  late final StreamSubscription<ModelDownloadTaskSnapshot> _subscription;

  Future<String?> fetch(String uri) async {
    try {
      final ModelCacheEntry entry = await controller.start(
        ModelSource.parse(uri),
      );
      return entry.filePath;
    } on Exception {
      return null;
    }
  }

  void cancel() => controller.cancel();

  Future<String?> retry() async {
    if (!controller.snapshot.canRetry) return null;
    try {
      return (await controller.retry()).filePath;
    } on Exception {
      return null;
    }
  }

  Future<void> removeCached(String uri) async {
    final ModelCacheEntry? entry = await manager.get(
      ModelSource.parse(uri).cacheKey,
    );
    if (entry != null) {
      await manager.remove(entry.cacheKey);
    }
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await controller.dispose();
  }
}
```

Render `snapshot.stage` (`resolving`, `checkingCache`, `downloading`,
`verifying`, `ready`, `failed`, `cancelled`), `snapshot.fraction` and the
redacted `snapshot.errorMessage`; source and redirect URL credentials are
removed from failure diagnostics and cancellation messages, including known
secrets repeated in the model filename. Transient I/O failures retain retry behavior.
Load the returned path with
`engine.setModel(LlamaModel(ModelSource.path(path)))`.

## More

- Flutter chat app tutorial: https://llamadart.leehack.com/docs/tutorials/flutter-chat-app
- Installation and Apple setup: https://llamadart.leehack.com/docs/getting-started/installation
- Native runtime configuration: https://llamadart.leehack.com/docs/platforms/native-build-hooks
- Download and cache models: https://llamadart.leehack.com/docs/guides/model-downloads
- Full chat app example: https://llamadart.leehack.com/docs/examples/chat-app
