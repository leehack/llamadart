# llamadart Chat Example

A Flutter chat application demonstrating real-world usage of llamadart with UI.

## Features

- 🦙 Real-time chat with local LLM
- 🖼️ **Runtime-checked multimodal support**: The app enables image/audio inputs
  only when the loaded projector/runtime path actually reports those
  capabilities.
- 📋 **Clipboard attachments**: Paste screenshots or copied image/audio files
  with `Cmd/Ctrl+V`, or use **Paste attachment** from the attachment menu on
  touch devices. Plain-text paste continues to work normally.
- 🎙️ **Whole-file transcription**: Compatible native GGUF ASR models can
  transcribe a selected file or capture a foreground microphone recording,
  then transcribe it after **Stop & transcribe**.
- 📝 **Live dictation**: Native chat models, including generic audio-chat
  models, can use a separately installed LiteRT sidecar to show confirmed and
  pending English text while the user speaks, then place the final text in the
  editable composer. Choose the recommended 54 MB Moonshine Tiny model or the
  optional higher-capacity, heavier 615 MB Parakeet TDT 0.6B model. The app
  shows model size, installed state, determinate download progress, cancel,
  and retry. A persisted settings switch explains and enables or disables this
  optional workflow. Audio-chat models keep their separate **Ask with voice**
  action.
- 🗣️ **Ask with voice**: Compatible native direct-media models or GGUF models
  with an audio-capable projector can receive a short microphone recording as
  ordinary multimodal chat and answer the request after **Stop & ask**.
- 🔊 **Text to speech**: The cross-platform Qwen3-TTS preset switches the
  composer into a dedicated synthesis mode with language, optional speaker
  reference, cancellation, playback, and WAV export.
- 📱 Material Design 3 UI
- ⚙️ Model configuration (path, runtime-detected backend selection, GPU layers,
  context size, logical batch size, and micro-batch size; LiteRT-LM does not
  expose the llama.cpp/WebGPU batch controls)
- 🧩 Capability badges per model (Tools / Thinking / Vision / Audio / Video)
- 🧪 GGUF and LiteRT-LM model routing through the same high-level engine APIs
- 🎯 Per-model presets for temperature, Top-K, Top-P, context, and max tokens
- 🛠️ Tool-calling toggles with template support checks
- 💾 Settings persistence
- 🔇 Separate Dart vs native log level controls
- 🔄 Streaming generation
- 🎨 Restrained user bubbles with readable, copyable assistant responses
- 📊 Compact runtime status with detailed performance diagnostics on demand

## Setup

### 1. Run the App
```bash
cd example/chat_app
flutter pub get
flutter run
```

If you run this app on Apple platforms with the Flutter SwiftPM companion
packages enabled, set the Xcode project deployment target to iOS `16.4` or
macOS `14.0` or newer first.

This app keeps the default all-runtime native-assets configuration so native
`.litertlm` presets work on supported targets. If you copy this app and only
ship GGUF models, set `llamadart_native_runtimes` to `[llama_cpp]` to reduce
bundle size on hook-managed native-assets builds. Flutter iOS/macOS apps that
want SwiftPM-linked Apple frameworks should add `llamadart_llama_cpp_flutter`,
`llamadart_litert_lm_flutter`, or both beside `llamadart`.

### 1.1 Run Tests
```bash
cd example/chat_app
flutter test
```

Note: this is a Flutter app, so use `flutter test` (not `dart test`).

Slow device E2E tests are tagged `local-only` and skipped by default. To run
the real model/mmproj download-cache-load check manually on a selected device:

```bash
flutter test --run-skipped -t local-only \
  integration_test/model_cache_mmproj_e2e_test.dart -d <device>
```

### 2. Choose and Download a Model
1. The app opens to the chat shell. Tap **Select model** in the welcome view or
   the settings control in the top bar to open the model library.
   - Native mobile/desktop builds store downloaded model files under the app's
     application-specific cache `models` directory via `path_provider`; web builds use
     browser Cache Storage/origin-scoped runtime caches.
2. Select one of the focused pre-configured models:
   - Cross-platform: FunctionGemma 270M, Qwen3.5 0.8B, Gemma 4 E2B
     GGUF, Gemma 4 E2B LiteRT-LM, and Gemma 4 E4B GGUF.
   - Native and Web: Qwen3-ASR 0.6B and Qwen3-TTS 1.7B Base.
   - Native desktop: Gemma 4 12B, Gemma 4 26B A4B,
     Gemma 4 31B, and Qwen3.6 35B A3B.
   - Built-in GGUF chat presets use [Unsloth distributions](https://huggingface.co/unsloth).
     The speech presets use llama.cpp's `ggml-org` Qwen3-ASR and Qwen3-TTS
     pairs, and the LiteRT-LM preset uses `litert-community`; every card
     identifies its source.
   - The library opens with the current platform selected. Use the Mobile, Web,
     and Desktop filters to compare compatible presets; unavailable models are
     clearly disabled when browsing another platform. Downloaded models appear
     first, and search matches names, filenames, descriptions, distributions,
     and capabilities such as vision or tools.
   - Gemma 4 E4B remains available across platforms because it is an
     edge/mobile-capable model, although its memory requirement still makes it
     appropriate only for capable devices.
   - Cards keep size, RAM, platform, capabilities, and the recommended context
     visible while leaving detailed sampling controls in the inference settings.
   - Custom and discovered models have a compact actions menu. **Remove from
     library** removes only the saved entry; downloaded-file deletion remains
     a separate action, with an explicit combined option in the confirmation.
3. Tap the **Download** icon. The app uses `Dio` to download the model directly to your device's app-specific cache directory. Additional model downloads enter a FIFO queue and start one at a time. A persistent progress pill remains in the app header when settings is closed; tap it to reopen download details.
4. Once downloaded, tap **Select** to load the model.
   - The Qwen3-ASR preset exposes **Attach Audio** and **Transcribe Audio** on
     native and Web builds. Native selected-file transcription accepts WAV,
     MP3, or FLAC; Web accepts WAV bytes with bridge assets `v0.1.30+`. On
     Android, iOS, macOS, Windows, and supported secure browser origins it also
     shows a microphone button. The microphone records a temporary mono WAV
     for up to five minutes; **Stop & transcribe** finalizes it, runs whole-file
     STT, and deletes the native file or revokes the browser blob.
     Capture is foreground-only and cancelling discards the temporary
     recording. This Qwen path remains whole-file rather than live. For native chat
     models, including generic audio-chat models, the composer can separately
     install a live-dictation model/tokenizer and expose **Live transcription**
     on Android, iOS, macOS, and Windows. Moonshine Tiny is the recommended
     54 MB default; Parakeet TDT 0.6B is an optional 615 MB higher-capacity,
     heavier choice. Both process mono 16 kHz PCM in five-second windows on a
     worker isolate through `SpeechToTextEngine.liteRtLm`, show confirmed and
     replaceable pending English text, and put the finalized transcript into the composer for review instead of
     sending it automatically. The selected sidecar is remembered, and the UI
     shows its size, installed state, determinate download progress, cancel,
     and retry. Sessions are capped at five minutes and cancelled when the app
     leaves the foreground. Audio-chat models keep **Ask with voice** as a
     separate action. Linux and Web remain disabled; dedicated streaming ASR
     is native-only.
     Parakeet TDT is converted by
     [LiteRT Community](https://huggingface.co/litert-community/parakeet-tdt-0.6b-v3)
     from NVIDIA's
     [CC-BY-4.0 model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
     All STT actions require the matching projector and a positive runtime
     audio probe. The preset's native and Web sources use immutable revisions,
     exact sizes, and SHA-256 metadata.
   - The cross-platform Qwen3-TTS preset uses a separate typed synthesis flow,
     not chat generation. Enter text, optionally select a language and choose
     or record a speaker reference, then synthesize. The app reports generation
     progress, automatically plays the completed 24 kHz mono output, and lets
     you stop, replay, or save it as WAV. Recorded references are read into
     memory and their temporary WAV files are best-effort deleted. Web accepts
     selected speaker-reference files as bytes but does not record speaker
     references. The matching model/projector downloads are immutable and
     SHA-256 verified. Current output is complete-buffer only, not streaming
     playback. Web requires bridge assets `v0.1.33+` and memory64 for the roughly
     1.48 GB pair. To bound browser memory and generation time, the Web example
     limits one utterance to 96 codec frames (about 7.7 seconds) and labels
     output that reaches the limit; short sentences are recommended. LiteRT-LM
     and automatic read-aloud of chat responses remain unsupported.
   - Microphone capture is enabled on Android, iOS, macOS, Windows, and secure
     browser origins when a compatible ASR model is active and WAV recording is
     supported. It remains hidden on Linux because the recorder plugin can
     report startup before its required external tools are ready; selected-file
     transcription still works there.
     flow has passed on a physical Pixel using CPU inference and in the iOS
     Simulator. This is not yet physical-iPhone or Windows validation.
   - The native Gemma 4 E2B presets expose **Ask with voice** when either the
     LiteRT-LM platform profile declares direct audio input or the matching
     GGUF projector is loaded and reports audio support. It records for at most
     30 seconds; **Stop & ask** sends the encoded WAV bytes through normal
     multimodal chat and asks the model to answer the spoken request. This is not
     `SpeechToTextEngine`: it has no transcript, timestamp, confidence, or live
     partial-text contract. Qwen3-ASR continues to use the separate five-minute
     **Stop & transcribe** flow, and takes precedence for models declared as
     ASR profiles.
   - The voice-question UI is code-supported on Android, iOS, macOS, and
     Windows when a native direct-media bundle or audio-capable projector and
     microphone recorder are available. Linux recording and Web are excluded.
     Automated tests cover capability gating and lifecycle behavior. Current
     packaged microphone UI evidence is LiteRT-LM on macOS; the GGUF path has
     engine-level Metal evidence only. Android, iOS, and Windows still require
     real-model/device evidence before being described as validated.
     See the `chat-app-voice-question-smoke` row in
     `tool/testing/test_matrix.dart`.
   - After **Stop & ask**, the app makes a best-effort attempt to delete the
     temporary WAV file. Its encoded bytes remain in the in-memory conversation
     history so later turns and response regeneration can retain the audio
     context; those turns can therefore reprocess the recording and use
     additional memory.
   - LiteRT-LM first initializes audio preprocessing on the selected backend,
     then transparently retries CPU if that executor is incompatible and
     remembers the working choice for the loaded model. For the validated
     Gemma 4 E2B bundle, GPU text/vision with CPU audio is the resolved path;
     this is not a universal LiteRT-LM CPU-audio limitation.
   - Gemma 4 E2B is included as a GGUF + `mmproj` bundle. In the current native
     `llama.cpp` mtmd path used here, that projector exposes image, audio, and
     video input, so it uses the same **Ask with voice** interaction. Audio
     remains experimental upstream; start with short mono clips for the most
     reliable results. The GGUF audio-answer path has current engine-level
     real-model evidence on macOS; microphone UI/device validation on Android,
     iOS, and Windows remains outstanding. Web keeps audio runtime-gated until
     the loaded bridge reports support.
   - LiteRT-LM `.litertlm` presets, when present, use the same model library
     flow. The example `pubspec.yaml` enables the `litert_lm` native runtime
     family for supported native targets, while Web builds load web-compatible
     `.litertlm` URLs through `@litert-lm/core@0.15.0`; `web/index.html` sets a
     default module URL that apps can override with
     `window.__llamadartLiteRtLmModuleUrl`.
   - LiteRT-LM Web is currently a single-turn text runtime. Because
     `@litert-lm/core` accepts one prompt string and applies its own chat
     wrapper internally, the chat app cannot pass structured chat history,
     tool declarations, tool choice, or thinking-budget/template controls to
     web `.litertlm` models. The app disables Function Calling and Thinking
     controls for this runtime; use GGUF/WebGPU or native LiteRT-LM when those
     structured controls are required.
   - The Gemma 4 E2B LiteRT-LM preset uses the native `.litertlm` bundle on
     Android, iOS arm64/arm64 simulator, macOS, Linux, and Windows x64; it uses
     the `-web.litertlm` bundle on Flutter Web. The example excludes the iOS
     x86_64 Simulator architecture while the arm64-only LiteRT-LM companion is
     enabled; Windows arm64 remains GGUF-only.

### 3. Advanced Configuration (Optional)
1. Tap the settings control in the top bar.
2. Adjust **GPU Layers**, **Context Size**, and **Preferred Backend**. Expand
   **Advanced** for Dart and native/bridge log levels.
   - `Auto` selects the best supported runtime; on supported Macs it prefers
     Metal. The selector also lists concrete runtime-detected options such as
     CPU/Vulkan/CUDA for GGUF or CPU/GPU/NPU for LiteRT-LM.
   - For native GGUF models, Auto combines the selected model size, current
     device-memory availability, system headroom, and requested context. It
     prefers full offload and preserves the preset context when they fit,
     reducing context before falling back to partial offload under pressure.
     Auto intent is persisted separately from the resolved values, so the app
     recalculates available headroom on every model load and after a restart.
   - **GPU Layers** controls model offload separately: `0` runs on CPU, while
     **Max** enables Auto tuning when the backend is Auto and requests full GPU
     offload when it fits. Choosing a lower layer count makes it a fixed manual
     setting. Reload the model to apply changes.
3. Optionally enable **Function Calling** and edit tool declarations depending on model/template support.
4. Tap **Load Model** to apply changes.


## Testing Scenarios

### Scenario 1: Fresh Install
1. Install the app
2. Model not loaded -> Show welcome screen
3. Configure and load model
4. Verify it works

### Scenario 2: App Restart
1. Load model and chat
2. Close and reopen app
3. Verify settings persist
4. Verify model reloads automatically

### Scenario 3: Offline Mode
1. Use app once (downloads libraries)
2. Disconnect internet
3. Restart app
4. Verify it works offline

### Scenario 4: Multiple Messages
1. Load model
2. Send multiple messages
3. Verify responses
4. Check context is maintained

## Architecture

The app follows a clean, layered architecture with strict separation of concerns:

```
lib/
├── main.dart                      # App entry point
├── screens/
│   ├── app_shell_screen.dart       # Responsive shell/navigation host
│   ├── chat_screen.dart            # Main chat UI
│   └── manage_models_screen.dart   # Model library + inference controls
├── widgets/
│   ├── chat_input.dart             # Message input + media staging
│   ├── message_bubble.dart         # Message rendering (markdown/thinking/tool)
│   ├── model_card.dart             # Model picker cards
│   ├── tool_declarations_dialog.dart
│   ├── tool_execution_card.dart
│   └── ...                         # Other modular UI components
├── providers/
│   └── chat_provider.dart          # App state & orchestration
├── services/
│   ├── chat_service.dart           # Engine orchestration + prompt cleanup
│   ├── chat_generation_service.dart
│   ├── assistant_output_service.dart
│   ├── model_service_base.dart
│   ├── model_service_io.dart       # Native download/delete/resume
│   ├── model_service_web.dart      # Browser cache prefetch/eviction
│   └── settings_service.dart       # Local persistence (SharedPreferences)
├── models/
│   ├── chat_message.dart           # Message data with token caching
│   ├── chat_settings.dart          # Configuration data
│   └── downloadable_model.dart     # Model metadata
└── utils/
    ├── backend_utils.dart
    └── text_sanitizer.dart
```

### Key Components

- **`ChatProvider`**: Orchestrates state and reacts to user input.
- **`ChatService`**: Handles prompt construction, token counting, and engine interaction.
- **`ModelService`**: Manages the model library with native/web-specific download backends.
- **`SettingsService`**: Handles persistent storage of user preferences.
- **`ChatMessage`**: Implements **Token Caching** to optimize performance during long conversations.

## Code Examples

### Loading a Model
```dart
final engine = LlamaEngine(LlamaBackend());
await engine.loadModel(
  modelPath,
  modelParams: ModelParams(
    gpuLayers: 99, // Offload all layers for best performance on GPU
    contextSize: 2048,
    preferredBackend: GpuBackend.vulkan,
  ),
);

// Optional: Load multimodal projector
if (mmprojPath != null) {
  await engine.loadMultimodalProjector(mmprojPath);
}
```

### Sending a Multimodal Message
```dart
final messages = [
  LlamaChatMessage.withContent(
    role: LlamaChatRole.user,
    content: [
      LlamaImageContent(path: 'path/to/image.jpg'),
      LlamaTextContent('What is this image?'),
    ],
  ),
];

final stream = engine.create(
  messages,
  params: GenerationParams(
    maxTokens: 4096, // Example value; tune per model/device.
    temp: 0.7,
  ),
);

await for (final chunk in stream) {
  stdout.write(chunk.choices.first.delta.content ?? '');
}
```

### Persisting Settings
```dart
final prefs = await SharedPreferences.getInstance();
await prefs.setString('model_path', modelPath);
await prefs.setInt('preferred_backend', backendIndex);
```

## Troubleshooting

**"Failed to load library" or "Native asset not found" on first run:**
- Ensure you have an active internet connection. The `llamadart` build hook needs to download the selected native runtime bundles for your platform.
- Check the console for download progress logs.
- If behind a proxy, ensure Dart/Flutter can access GitHub.
- If a native `.litertlm` load fails, confirm `pubspec.yaml` includes
  `litert_lm` for your target. This example does that for supported native
  targets, excludes the unsupported iOS x86_64 Simulator architecture, and
  keeps Windows arm64 GGUF-only.
- If you recently changed native backend or runtime config and are upgrading
  from an older build cache, run a one-time `flutter clean`.

**"Model file not found" error:**
- Ensure you have successfully downloaded a model from the selection screen.
- If you manually moved a model, verify the path in the settings sheet.

**Slow generation:**
- Ensure hardware acceleration is enabled (e.g., Metal on Apple, Vulkan on Android/Linux/Windows).
- Check if `GPU Layers` is set to a high enough value (default 99 offloads all layers).
- Use a smaller model or a lighter 4-bit quant when your device is memory-bound.
- For LiteRT-LM, select CPU/GPU/NPU intentionally in the settings sheet when
  comparing performance. NPU is Android-only and may fail for a given device,
  OS, or model bundle; fall back to GPU or CPU when the runtime reports that
  engine creation is unsupported.

**Multimodal instability or decode crashes (Qwen VLMs):**
- Keep the bundled model defaults unless you are tuning carefully. Qwen3.5
  0.8B uses `Context Size` 4096 and `Max Tokens` 1024; the native-desktop
  Qwen3.6 35B A3B preset uses 16384 and 4096 respectively.
- The chat app now downscales picked multimodal images to a `384px` max edge before staging them, which reduces prompt/context pressure on Android, iOS, macOS, and Web.
- Start a fresh conversation before large image prompts to avoid context-slot pressure.
- If a follow-up turn after an image reports that the active context window was exceeded, retry with a smaller image, a larger `Context Size`, or fewer earlier image turns in the same chat.
- If crashes persist on lower-memory devices, keep thinking off, switch to
  Qwen3.5 0.8B, or disable multimodal for that run.

**Gemma 4 audio does not appear in the attachment menu:**
- For the GGUF preset, confirm the matching `mmproj` finished downloading and
  loaded successfully. The current projector reports both `vision=true` and
  `audio=true` on the pinned native runtime.
- Native Gemma 4 LiteRT-LM consumes audio directly from its `.litertlm` bundle
  and does not need an `mmproj`. LiteRT-LM Web remains text-only.
- Audio input is experimental in `llama.cpp`. Prefer mono 16 kHz WAV input and
  keep initial clips under 30 seconds.

**`Invalid argument(s): string is not well-formed UTF-16` in Flutter painting:**
- This indicates malformed streamed text (broken surrogate pair) reached text rendering.
- Upgrade to the latest chat app code (stream-boundary + text-sanitization fixes are included).
- Restart the app fully after upgrade (`flutter clean` + `flutter run`) to ensure stale binaries are not reused.

**Slow model downloads on iOS/Android:**
- Run on a release/profile build (`flutter run --release`) for realistic transfer performance.
- Large multimodal bundles download both model and mmproj files; expect two-stage transfer.
- Model downloads run sequentially. Queued cards show their position and can be
  removed from the queue without interrupting the active transfer.
- Optional Hugging Face auth can improve throughput/rate-limits:
  `flutter run --dart-define=HF_TOKEN=<your_token>`
- Optional experimental parallel range downloader for large files:
  `flutter run --dart-define=LLAMADART_CHAT_PARALLEL_DOWNLOAD=true`

**Backend list/selection notes:**
- The settings sheet shows `Auto` plus detected runtime backends/devices, not
  only packaged modules.
- `Auto` backend preferences are resolved to the best detected backend at model
  load time.


**App crashes on startup:**
- Check console output for error messages
- Verify llamadart dependency is correctly configured
- Ensure Flutter version >= 3.38.0

**macOS warning: "Stale file ... located outside of the allowed root paths":**
- This is usually a stale Flutter/Xcode build cache path after moving or renaming directories.
- From `example/chat_app`, run:
  - `flutter clean`
  - `flutter pub get`
  - `flutter run -d macos`

**`llama_grammar_init_impl: failed to parse grammar` during tool calls:**
- This indicates invalid generated GBNF (often from custom template/handler grammar escaping).
- Update to the latest package version and retry.
- If using custom handlers, validate grammar strings and prefer Dart raw strings (`r'''...'''`) for multiline GBNF.

**Assistant response appears as JSON (for example `{"response":"..."}`):**
- This can be model/template behavior (notably in Ministral-family flows), not necessarily a UI rendering bug.
- The chat app intentionally shows raw assistant content and adds a `content:json` debug badge when output looks JSON-shaped.
- If you want plain-text UX, unwrap known response envelopes in app-level normalization before rendering.

## Tech Stack

- **llamadart** - High-performance LLM inference
- **Provider** - Reactive state management
- **Dio** - Robust background downloads
- **SharedPreferences** - Persistent settings
- **Material Design 3** - Modern UI components
- **Google Fonts** - Typography

## Platform Support

| Platform | Status | Hardware Acceleration |
|----------|--------|-----------------------|
| macOS    | ✅ Tested | Metal |
| iOS      | ✅ Tested | Metal |
| Android  | ✅ Tested | Vulkan |
| Linux    | 🟡 Expected | Vulkan |
| Windows  | ✅ Tested | Vulkan |
| Web      | ✅ Tested | CPU / Experimental WebGPU |

### Web Limitations

- Web uses the llama.cpp bridge backend with CPU mode and experimental WebGPU acceleration.
- Bridge runtime loading prefers local `web/webgpu_bridge` assets on `localhost`/`127.0.0.1` for dev validation, and otherwise prefers pinned jsDelivr assets with local fallback.
- Override CDN source/version with `window.__llamadartBridgeAssetsRepo` and
  `window.__llamadartBridgeAssetsTag` in `web/index.html`.
- To pin self-hosted assets before build:
  `WEBGPU_BRIDGE_ASSETS_TAG=<tag> ./scripts/fetch_webgpu_bridge_assets.sh`.
- Bridge fetch defaults include Safari compatibility patching for universal
  browser support (`WEBGPU_BRIDGE_PATCH_SAFARI_COMPAT=1`,
  `WEBGPU_BRIDGE_MIN_SAFARI_VERSION=170400`).
- `web/index.html` also applies Safari compatibility patching at runtime before
  bridge initialization (including CDN fallback).
- Bridge model loading uses browser Cache Storage by default, so repeated loads
  of the same model URL can avoid full re-download.
- Current browser targets in this repo: Chrome >= 128, Firefox >= 129,
  Safari >= 17.4.
- Safari WebGPU uses a compatibility gate in `llamadart`: legacy bridge assets
  default to CPU fallback, while adaptive bridge assets can probe/cap GPU
  layers and auto-fallback to CPU when unstable.
- For legacy assets, experimental override remains available via
  `window.__llamadartAllowSafariWebGpu = true` before model load.
- Multimodal projector loading on web is URL-based (model + matching mmproj URL).
- Model selection auto-wires mmproj URLs for multimodal web models.
- Image/audio attachments on web use browser file bytes (local path-based loading remains native-only).
- Browser microphone recording warms up before the app shows its ready state.
  Before ASR, the app trims that warmup silence and rejects too-short, silent,
  or unsupported PCM WAV captures with an actionable message.
- Browser paste events support screenshots and copied image/audio files without
  replacing normal text paste. Clipboard attachments are capped at 64 MB.
- On web, model files are loaded by URL (local file download/cache flow differs from native).
- On web, **Download** prefetches model/mmproj bytes into browser Cache Storage with progress.
- Qwen3.5 `0.8B` WebGPU loads are capped to a low layer count for stable browser text output.
- Qwen3.5 multimodal web runs currently use CPU-safe fallback for stability even when the text model was loaded with WebGPU acceleration.
- Web models use streamed network staging by default. Controlled origins that
  serve valid GGUF byte ranges can explicitly enable worker-thread
  fetch-backed loading to reduce contiguous allocation pressure; this path may
  bypass prefetch cache reuse.
- If optional `llama_webgpu_core_mem64` bridge assets are present and supported by the browser, chat app bridge bootstrapping can prefer wasm64 core and transparently fall back to wasm32.
- Large single-file web model loading requires cross-origin isolation
  (`window.crossOriginIsolated === true`).
- Chat app defaults to wasm32-first for stability. You can opt into wasm64 preference with
  `window.__llamadartBridgeEnableMem64 = true` before bridge bootstrap.
- Fetch-backed loading is disabled by default. Set
  `window.__llamadartBridgeAllowAutoRemoteFetchBackend = true` before bridge
  bootstrap only for a controlled range-capable model origin. This explicit
  opt-in also permits fetch-backed recovery retries after streamed staging
  failures. For diagnostics that must use fetch-backed loading from the first
  attempt, set `window.__llamadartBridgeForceRemoteFetchBackend = true`;
  prefer the automatic opt-in for ordinary deployments.
- You can tune fetch-backed model read chunk size by setting
  `window.__llamadartBridgeRemoteFetchChunkBytes = <bytes>` before bridge bootstrap
  (default `4 * 1024 * 1024`, clamped to `4KiB..16MiB`).
- You can align runtime thread usage with your bridge build by setting
  `window.__llamadartBridgeThreadPoolSize = <N>` before bridge bootstrap
  (chat app infers `1` when not cross-origin isolated, else `2..4` from
  hardware concurrency; explicit override wins).
- Bridge bootstrap console logs are quiet by default. Enable verbose startup logs with
  `window.__llamadartBridgeBootstrapVerbose = true` before bridge bootstrap.
- For autonomous browser smoke tests without downloading a real model, run
  `dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-mock-smoke`.
  The scenario builds the web app, serves it with COOP/COEP headers, appends
  `?llamadart_mock_bridge=echo`, and validates prompt/response wiring through
  Playwright.
- For the real Gemma 4 LiteRT-LM web path, use
  `dart run tool/testing/run_local_e2e.dart --scenario chat-app-web-litert-gemma4-smoke`.
  This builds the Flutter web app, serves it with COOP/COEP headers, loads the
  `gemma-4-E2B-it-web.litertlm` bundle through `@litert-lm/core`, and captures
  streamed single-turn LiteRT-LM text output in Playwright. LiteRT-LM web does
  not yet preserve chat history, system prompts, or tool declarations through
  `@litert-lm/core`.
- `.litertlm` web loads do **not** use the browser Cache Storage prefetch (that
  cache is only read back by the llama.cpp/GGUF bridge); `@litert-lm/core`
  fetches the model URL itself. Browser HTTP cache may avoid some network
  transfer, but engine creation still has to initialize the large model and GPU
  resources on each load. Per-message token counts are also not shown for web
  LiteRT-LM models because the backend exposes no tokenizer API.
- Runtime details expose execution mode, core, cache, worker fallback, and
  runtime notes, so non-COI or worker fallback constraints remain visible
  without crowding the conversation.
- On web, multimodal projector loading is eager by default for stability: if an
  mmproj is configured, it is loaded together with the model.

### Android Qwen Notes

- On recent Pixel-class Android devices, Qwen3.5 `0.8B` currently runs faster
  in `CPU` mode than `Vulkan` in this app, so its Android preset prefers `CPU`.
- Runtime details include native llama.cpp timing breakdowns: `p_eval`, `eval`,
  `sample`, and `reuse`.
- Android text-only chat is stable even when `mmproj` is loaded.
- Android real image prompting is currently recommended in `CPU` mode for
  Qwen3.5 `0.8B`; `Vulkan` multimodal is still not reliable enough.

### Hugging Face static deployment (CI)

- Workflow: `.github/workflows/chat_app_hf_static_deploy.yml`
- Triggered on pushes to `main/master` when chat app files change, and by manual dispatch.
- Required repository secret: `HF_TOKEN` (write access to your Space repo).
- Required repository variable: `HF_CHAT_APP_SPACE_REPO` in `owner/space` format.
- Manual dispatch can override target Space via `space_repo` input and deploy a specific ref via `deploy_ref`.
- The workflow-generated Space `README.md` already injects required COI headers
  for large-model web runtime support.

### Hugging Face PR preview deployment (CI)

- Workflow: `.github/workflows/chat_app_hf_pr_preview.yml`
- Triggered for same-repository pull requests that touch the chat app, package
  sources, or the web bridge asset script.
- Creates or updates a per-PR static Space named
  `llamadart-chat-pr-<number>` and comments the preview URL on the PR.
- Deletes the preview Space when the PR is closed.
- Required repository secret: `HF_TOKEN` with write/create access to the preview
  namespace.
- Optional repository variable: `HF_CHAT_APP_PREVIEW_NAMESPACE`. If omitted,
  the workflow uses the owner portion of `HF_CHAT_APP_SPACE_REPO`.
- Fork PRs are skipped so repository secrets are not exposed to untrusted code.
- The automated PR workflow becomes available after the workflow file exists on
  the base branch. For a one-off preview before that, manually dispatch
  `.github/workflows/chat_app_hf_static_deploy.yml` with `space_repo` set to a
  temporary Space and `deploy_ref` set to the branch or commit to preview.

If deploying outside this workflow, set this frontmatter in Space README (all
lowercase):

```yaml
custom_headers:
  cross-origin-embedder-policy: require-corp
  cross-origin-opener-policy: same-origin
  cross-origin-resource-policy: cross-origin
```


## Implemented Highlights ✅

- [x] Conversation history maintenance
- [x] Multiple model support & switching
- [x] Per-model sampling/runtime presets
- [x] Model capability badges in selection cards
- [x] Professional layered architecture
- [x] Real-time streaming UI
- [x] Persistent settings & split Dart/native log control
- [x] Advanced sampling parameters (Temp/Top-K/Top-P)
