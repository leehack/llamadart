# llamadart Examples

This directory contains example applications demonstrating how to use the llamadart package.

## Available Examples

### 1. Basic App (`basic_app/`)
A simple console application showing:
- Model loading
- Context creation
- Tokenization
- Text generation
- Embedding generation
- Resource cleanup

**Best for:** Understanding the core API

**Run:**
```bash
cd basic_app
dart pub get
dart run

# Embedding demo
dart run bin/llamadart_embedding_example.dart -i "hello world"

# SQLite vector retrieval demo
dart run bin/llamadart_sqlite_vector_example.dart \
  -q "How do I improve embedding throughput?" \
  -d "Increase maxParallelSequences for wider embedding batches." \
  -d "Tune batchSize and ubatchSize together."
```

### 2. Chat App (`chat_app/`)
A Flutter UI application showing:
- Real-time chat interface
- Model configuration
- Settings persistence
- Streaming text generation
- GGUF plus LiteRT-LM `.litertlm` model routing
- Material Design UI

**Best for:** Real-world Flutter integration

**Run:**
```bash
cd chat_app
flutter pub get
flutter run
```

### 3. API Server (`llamadart_server/`)
A Relic-based HTTP server example showing:
- OpenAI-compatible endpoint surface (`/v1/models`, `/v1/chat/completions`)
- OpenAPI spec + Swagger UI (`/openapi.json`, `/docs`)
- SSE streaming responses for chat completions
- Optional Bearer auth and CORS middleware
- Model loading via local path or URL download

**Best for:** Local API integration with OpenAI-style clients

**Run:**
```bash
cd llamadart_server
dart pub get
dart run llamadart_server --model /path/to/model.gguf
```

### 4. llama.cpp-style CLI (`llamadart_cli/`)
A compatibility-focused CLI clone showing:
- llama.cpp-like options (`--model`, `-hf`, `--ctx-size`, `--fit`, `--jinja`)
- Interactive terminal chat with streaming output
- Hugging Face shorthand resolution for GGUF files
- GLM-oriented sampling controls for Unsloth command parity

**Best for:** Running llama.cpp-like local chat flows in pure Dart

**Run:**
```bash
cd llamadart_cli
dart pub get
dart run bin/llamadart_cli.dart --help
```

### 5. TUI coding agent (`tui_coding_agent/`)
A terminal UI coding agent built with `nocterm` and `llamadart` showing:
- Streaming coding-chat UX in a TUI layout
- Built-in tool loop (`list_files`, `read_file`, `search_files`, `write_file`, `run_command`)
- Workspace-scoped path safety guard
- Runtime model switching with `/model <source>`
- Default GLM-4.7-Flash model source with custom model override support

**Best for:** Building local terminal coding-agent workflows in Dart

**Run:**
```bash
cd tui_coding_agent
dart pub get
dart run bin/tui_coding_agent.dart
```

## Testing

- `basic_app` (Dart console):

```bash
cd basic_app
dart test
```

- `chat_app` (Flutter UI):

```bash
cd chat_app
flutter test
```

- `llamadart_server` (Relic HTTP API):

```bash
cd llamadart_server
dart test
```

- `llamadart_cli` (llama.cpp-style Dart CLI):

```bash
cd llamadart_cli
dart test
```

- `tui_coding_agent` (nocterm-based coding agent TUI):

```bash
cd tui_coding_agent
dart test
```

Note: `chat_app` uses Flutter libraries (`dart:ui`), so `dart test` is not
the correct runner for that example.

## Quick Start

1. **Choose an example**: Basic (console), Chat (Flutter), API Server (Relic), llama.cpp-style CLI clone (Dart), or TUI coding agent (Dart + nocterm)
2. **Download a model** (see each example's README)
3. **Run the example**: Follow instructions in each subdirectory

## Testing pub.dev Package

These examples simulate how users will use llamadart when published to pub.dev:
- They add llamadart as a dependency
- They rely on automatic library download
- They don't need to run build scripts

## Common Models for Testing

- **TinyLlama** (1.1B, ~638MB) - Fast, good for testing
- **Llama 2** (7B, ~4GB) - More powerful, slower
- **Mistral** (7B, ~4GB) - Great performance

See HuggingFace for more: https://huggingface.co/models?search=gguf

## Model Formats

Most examples use GGUF models through the llama.cpp runtime. The Flutter
`chat_app` also demonstrates LiteRT-LM `.litertlm` models and explicitly opts
into the `litert_lm` native runtime family for supported native targets.

## Architecture

```
example/
├── basic_app/          # Console application
│   ├── lib/            # Dart code
│   ├── pubspec.yaml    # Dependencies
│   └── README.md       # Instructions
├── llamadart_server/   # OpenAI-compatible API server
│   ├── bin/            # Server entrypoint
│   ├── lib/            # Request/response mapping + middleware
│   ├── pubspec.yaml    # Dependencies
│   └── README.md       # Instructions
├── llamadart_cli/      # llama.cpp-style Dart CLI clone
│   ├── bin/            # CLI entrypoint
│   ├── lib/            # Parser + model resolver + chat runner
│   ├── pubspec.yaml    # Dependencies
│   └── README.md       # Instructions
├── tui_coding_agent/   # Nocterm-based coding agent TUI
│   ├── bin/            # TUI entrypoint
│   ├── lib/            # Session, tools, and TUI components
│   ├── pubspec.yaml    # Dependencies
│   └── README.md       # Instructions
└── chat_app/           # Flutter application
    ├── lib/            # Flutter code
    ├── android/        # Android config
    ├── ios/            # iOS config
    ├── pubspec.yaml    # Dependencies
    └── README.md       # Instructions
```

## Need Help?

- Check individual example README files
- Report issues: https://github.com/leehack/llamadart/issues
- Docs: https://github.com/leehack/llamadart

## Requirements

- Dart SDK 3.10.7 or higher
- For chat_app: Flutter 3.38.0 or higher
- Flutter Apple builds require deployment targets of iOS 16.4 or newer and
  macOS 14.0 or newer
- Internet connection (for first run - downloads selected native runtime
  libraries)
- At least 2GB RAM minimum, 4GB+ recommended

## Platform Compatibility

| Platform | Architecture(s) | GPU Backend | Status |
|----------|-----------------|-------------|--------|
| **macOS** | arm64, x86_64 | Metal | ✅ Tested |
| **iOS** | arm64 (Device), arm64/x86_64 (Sim) | Metal (Device), CPU (Sim) | ✅ Tested |
| **Android** | arm64-v8a, x86_64 | Vulkan | ✅ Tested |
| **Linux** | arm64, x86_64 | Vulkan | 🟡 Expected (Vulkan Untested) |
| **Windows** | x64 | Vulkan | ✅ Tested |
| **Web** | WASM / WebGPU Bridge | CPU / Experimental WebGPU | ✅ Tested |

### Web Notes

- Web examples run on the llama.cpp bridge backend (WebGPU or CPU mode).
- `chat_app` loader prefers local bridge assets on localhost, and otherwise prefers CDN with local fallback.
- You can prefetch a pinned bridge version into `web/webgpu_bridge/` with:
  `WEBGPU_BRIDGE_ASSETS_TAG=<tag> ./scripts/fetch_webgpu_bridge_assets.sh`.
- Fetch script defaults to universal Safari-compatible patching:
  `WEBGPU_BRIDGE_PATCH_SAFARI_COMPAT=1` and
  `WEBGPU_BRIDGE_MIN_SAFARI_VERSION=170400`.
- `chat_app/web/index.html` also applies Safari compatibility patching at
  runtime before bridge initialization (including CDN fallback).
- Web model loading uses browser Cache Storage by default, so repeated loads of
  the same model URL can skip full re-download.
- Safari WebGPU uses a compatibility gate in `llamadart`: legacy bridge assets
  default to CPU fallback, while adaptive bridge assets can probe/cap GPU
  layers and auto-fallback to CPU when unstable.
- You can still bypass the legacy safeguard with
  `window.__llamadartAllowSafariWebGpu = true` before model load.
- Multimodal projector loading works on web via URL-based model/mmproj pairs.
- In `chat_app`, image/audio attachments on web are sent as browser file bytes;
  local file paths are native-only.
- Native LoRA runtime adapter flows are not available on web.
- `chat_app` on web uses model URLs rather than native file download storage.

## Troubleshooting

**Common Issues:**

1. **Failed to load library:**
   - Check console for download messages
   - Ensure internet connection for first run
   - Verify GitHub releases are accessible

2. **Model file not found:**
   - Download a model to the default location
   - Or set LLAMA_MODEL_PATH environment variable
   - Or configure in app settings (chat_app)

3. **Slow performance:**
   - Use smaller quantization (Q4_K_M recommended)
   - Reduce context size (nCtx parameter)
   - Enable GPU layers if available

4. **Flutter build errors:**
   - Ensure Flutter SDK is properly installed
   - Run `flutter doctor` to check setup
   - Reinstall dependencies with `flutter clean && flutter pub get`

## Security Notes

- Models downloaded from the internet should be from trusted sources
- Never share private/sensitive data with open-source models
- The app runs locally - no data is sent to external servers (except library download on first run)

## Contributing

To contribute new examples:
1. Create a new subdirectory in `example/`
2. Add a pubspec.yaml with llamadart as dependency
3. Include a README.md with setup instructions
4. Test on multiple platforms if possible
5. Add integration test to runner.dart if applicable

## License

These examples are part of the llamadart project and follow the same license.
