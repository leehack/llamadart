# llamadart Chat Example

A Flutter chat application demonstrating real-world usage of llamadart with UI.

## Features

- 🦙 Real-time chat with local LLM
- 🖼️ **Runtime-checked multimodal support**: The app enables image/audio inputs
  only when the loaded projector/runtime path actually reports those
  capabilities.
- 📱 Material Design 3 UI
- ⚙️ Model configuration (path, runtime-detected backend selection, GPU layers, context size)
- 🧩 Capability badges per model (Tools / Thinking / Vision / Audio / Video)
- 🧪 GGUF and LiteRT-LM model routing through the same high-level engine APIs
- 🎯 Per-model presets for temperature, Top-K, Top-P, context, and max tokens
- 🛠️ Tool-calling toggles with template support checks
- 💾 Settings persistence
- 🔇 Separate Dart vs native log level controls
- 🔄 Streaming generation
- 🎨 User and AI message bubbles

## Setup

### 1. Run the App
```bash
cd example/chat_app
flutter pub get
flutter run
```

If you run this app on Apple platforms, set the Xcode project deployment target
to iOS `16.4` or macOS `14.0` or newer first.

Unlike the smaller GGUF-only examples, this app intentionally opts into both
native runtime families in `pubspec.yaml` so native `.litertlm` presets work on
supported targets. If you copy this app and only ship GGUF models, set
`llamadart_native_runtimes` to `[llama_cpp]` to reduce bundle size.

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
1. The app will open to a **Manage Models** screen.
2. Select one of the pre-configured models (for example: FunctionGemma 270M, Qwen3.5 0.8B/2B/4B/9B, Llama 3.2 3B, Gemma 3/3n, DeepSeek R1 distills).
   - Qwen3.5 presets now use Unsloth `Q4_K_M` GGUFs across platforms.
   - Quick picks: `0.8B` for web/older phones, `2B` for mobile + low-RAM laptops, `4B` for most native desktop/laptop runs, `9B` for desktop-class devices with more headroom.
   - Qwen3.5 small presets default to non-thinking mode for smoother latency and fewer reasoning loops; turn thinking on only when you need extra reasoning.
3. Tap the **Download** icon. The app uses `Dio` to download the model directly to your device's documents directory.
4. Once downloaded, tap **Select** to load the model.
   - Gemma 4 E2B is included as a GGUF + `mmproj` bundle. In the current
     `llama.cpp` mtmd path used here, that projector exposes vision support but
     not audio support, so the chat UI keeps image input enabled and audio input
     disabled for this model.
   - LiteRT-LM `.litertlm` presets, when present, use the same model library
     flow. The example `pubspec.yaml` enables the `litert_lm` native runtime
     family for supported native targets, while Web builds load web-compatible
     `.litertlm` URLs through `@litert-lm/core`; `web/index.html` sets a
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
     the `-web.litertlm` bundle on Flutter Web. iOS x86_64 simulator and
     Windows arm64 are kept GGUF-only because no matching LiteRT-LM native
     bundle is published.

### 3. Advanced Configuration (Optional)
1. Tap the settings icon (⚙️) in the app bar.
2. Adjust **GPU Layers**, **Context Size**, **Preferred Backend**, **Dart Log Level**, and **Native Log Level**.
   - Backend choices are concrete runtime-detected options (for example:
     CPU/Vulkan/CUDA for GGUF, or CPU/GPU/NPU where LiteRT-LM exposes them), not
     `Auto`.
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

## Screenshots

_(Add screenshots here when complete)_

## Troubleshooting

**"Failed to load library" or "Native asset not found" on first run:**
- Ensure you have an active internet connection. The `llamadart` build hook needs to download the selected native runtime bundles for your platform.
- Check the console for download progress logs.
- If behind a proxy, ensure Dart/Flutter can access GitHub.
- If a native `.litertlm` load fails, confirm `pubspec.yaml` includes
  `litert_lm` for your target. This example does that for supported native
  targets and keeps iOS x86_64 simulator / Windows arm64 GGUF-only.
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

**Multimodal instability or decode crashes (Qwen3.5 VLMs):**
- Keep Qwen3.5 model defaults unless you are tuning carefully (`0.8B` uses `Context Size` 4096; `2B`/`4B`/`9B` use 8192; all ship with `Max Tokens` 1024).
- The chat app now downscales picked multimodal images to a `384px` max edge before staging them, which reduces prompt/context pressure on Android, iOS, macOS, and Web.
- Start a fresh conversation before large image prompts to avoid context-slot pressure.
- If a follow-up turn after an image reports that the active context window was exceeded, retry with a smaller image, a larger `Context Size`, or fewer earlier image turns in the same chat.
- If crashes persist on lower-memory devices, keep thinking off, switch to the 0.8B/2B variants, or disable multimodal for that run.

**Gemma 4 audio does not appear in the attachment menu:**
- This is expected with the currently published Gemma 4 GGUF projector assets
  used by the chat app.
- The Gemma 4 E2B/E4B family supports audio in principle, but the current
  `llama.cpp` mtmd projector path exposed to `llamadart` reports `vision=true`
  and `audio=false` for the shipped `mmproj` files.
- Image input should still work for Gemma 4 once the matching projector is
  loaded.

**`Invalid argument(s): string is not well-formed UTF-16` in Flutter painting:**
- This indicates malformed streamed text (broken surrogate pair) reached text rendering.
- Upgrade to the latest chat app code (stream-boundary + text-sanitization fixes are included).
- Restart the app fully after upgrade (`flutter clean` + `flutter run`) to ensure stale binaries are not reused.

**Slow model downloads on iOS/Android:**
- Run on a release/profile build (`flutter run --release`) for realistic transfer performance.
- Large multimodal bundles download both model and mmproj files; expect two-stage transfer.
- Optional Hugging Face auth can improve throughput/rate-limits:
  `flutter run --dart-define=HF_TOKEN=<your_token>`
- Optional experimental parallel range downloader for large files:
  `flutter run --dart-define=LLAMADART_CHAT_PARALLEL_DOWNLOAD=true`

**Backend list/selection notes:**
- The settings sheet shows detected runtime backends/devices, not only packaged modules.
- Legacy saved `Auto` backend preferences are resolved to the best detected backend at runtime.


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
- On web, model files are loaded by URL (local file download/cache flow differs from native).
- On web, **Download** prefetches model/mmproj bytes into browser Cache Storage with progress.
- Qwen3.5 `0.8B` WebGPU loads are capped to a low layer count for stable browser text output.
- Qwen3.5 multimodal web runs currently use CPU-safe fallback for stability even when the text model was loaded with WebGPU acceleration.
- For very large web models, runtime may switch to worker-thread fetch-backed loading to reduce contiguous allocation pressure; this path may bypass prefetch cache reuse.
- If optional `llama_webgpu_core_mem64` bridge assets are present and supported by the browser, chat app bridge bootstrapping can prefer wasm64 core and transparently fall back to wasm32.
- Large single-file web model loading requires cross-origin isolation
  (`window.crossOriginIsolated === true`).
- Chat app defaults to wasm32-first for stability. You can opt into wasm64 preference with
  `window.__llamadartBridgeEnableMem64 = true` before bridge bootstrap.
- You can skip auto fetch-backed pre-attempts by setting
  `window.__llamadartBridgeAllowAutoRemoteFetchBackend = false` before bridge bootstrap.
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
- Runtime status chips expose execution mode/core/cache/worker fallback/runtime notes,
  so non-COI or worker fallback perf constraints are visible in-app.
- On web, multimodal projector loading is eager by default for stability: if an
  mmproj is configured, it is loaded together with the model.

### Android Qwen Notes

- On recent Pixel-class Android devices, Qwen3.5 `0.8B` and `2B` currently run
  faster in `CPU` mode than `Vulkan` in this app, so the Android preset flow now
  prefers `CPU` for those two models.
- Qwen3.5 `4B` is closer: `CPU` still wins on short prompts, but `Vulkan` is now
  much faster than before and may be worth comparing for longer generations.
- Runtime chips now include native llama.cpp timing breakdowns: `p_eval`,
  `eval`, `sample`, and `reuse`.
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
