# llamadart Studio

Experimental cross-platform AI studio showcasing the [`llamadart`](../..) runtime surface across macOS, Windows, Linux, iOS, Android, and WebGPU.

Studio is under active qualification. Passing tests or a successful build does not
qualify every model, workflow, or platform for production use.

## Architecture

- **[`llamadart_studio_core`](../llamadart_studio_core)**: 100% pure-Dart domain models, ports, adapters, and reactive `StateStore` controllers (zero Flutter imports—reusable directly in Jaspr web apps or CLI hosts, and ready for `genkit_llamadart` integration via `StudioInferencePort`).
- **`llamadart_studio` (this package)**: Adaptive Material 3 Flutter desktop/mobile/web client with incremental streaming updates, keyboard Command Palette (`Cmd/Ctrl+K`), declarative workspace routing, and safe native shutdown.

## Workspaces

1. **Chat & Multimodal**: Non-destructive message branching (`< 1 / 2 >`), vision & audio attachments, expandable reasoning (`<think>`), live tool execution cards, persona/JSON Schema presets, and Markdown/JSON export/import.
2. **Model Hub & Cache Manager**: Curated GGUF & LiteRT-LM catalog, live Hugging Face Hub search with automatic `mmproj` pairing, VRAM/RAM fit badges, SHA-256 verified downloads, and guarded storage management.
3. **Speech Studio**: Neural Text-to-Speech (`Qwen3-TTS`) with speaker-reference cloning & WAV playback, plus Speech-to-Text (`Qwen3-ASR` & `LiteRT Moonshine`).
4. **Image Studio**: Local Stable Diffusion (`SDXS-512` & `SD-Turbo + TAESD`) with live step progress and seed lock.
5. **Developer Playground**: Semantic Embeddings + Cosine Similarity heatmap, Cross-Encoder Reranker, Laya System-1 Decision Head (`systemOne`), Token Inspector, and Prefill/Decode Throughput Benchmark.
6. **Notes**: Persistent notes, source indexing with embeddings, optional reranking, and source-grounded answers.
7. **Coding**: Workspace-scoped chat with file tools, command execution, and explicit trust for repository MCP servers.

## Running Locally

The default Linux image runtime uses Vulkan. Studio preflights the system
loader before probing or loading images and shows an unsupported reason if a
compatible driver/ICD is unavailable, allowing the other workspaces to start.
This preflight does not qualify image inference or every driver failure. A
custom build selecting `llamadart_stable_diffusion_backends: [cpu]` should also
set `requiresLinuxVulkan: false` when constructing its `DirectLlamaImagePort`.

Use Flutter 3.50.0 (Dart 3.14.0), pinned in this package's
`.flutter-version`. Studio uses its own SDK pin independently of the root package.

Studio retains the SDK's Material library for compatibility with
`flutter_markdown`, whose theme API accepts the SDK's `ThemeData`. Flutter 3.50
deprecates that library in favor of `material_ui`, which defines distinct theme
types. Imports carry a narrow deprecation ignore until the Markdown dependency
can migrate with the UI.

```bash
cd packages/llamadart_studio
flutter pub get
flutter run -d macos
```

For Web, build with the package helper so the pinned runtime bridge assets are
included and validated:

```bash
./tool/build_web.sh
```

Serve `build/web` with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` response headers.

A successful Web build verifies packaging, not model inference or browser GPU
compatibility. Local model acceptance tests are opt-in and require explicit model
paths; see the `local_*_acceptance_test.dart` files under `test/` and
`integration_test/` in the two Studio packages for their inputs.

## Qualification scope

Acceptance evidence covers macOS model-backed workflows, Chrome UI tests and
release-browser startup/persistence, and Android emulator/iOS simulator smoke
checks. A physical Pixel 8a (Android 15) passed Qwen3.5 0.8B CPU Chat inference
and Unicode Notes persistence through a fresh native file store.

Linux passed core/UI tests, a release build, and startup on a host without a
Vulkan driver, with Image reported unsupported. Windows passed core/UI tests,
a release build, and real Qwen3.5 0.8B CPU Chat and Coding tool execution.
Windows tests ran in a service session and do not qualify interactive desktop
input or media playback.

WebGPU inference, large-model browser storage, physical iOS inference,
microphone/camera workflows, long-session memory pressure, Linux image inference,
and the full model catalog remain unqualified. Keep these limits separate from
analyzer and unit-test results.
