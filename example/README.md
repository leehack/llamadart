# llamadart Examples

This directory contains example applications demonstrating how to use the llamadart package.

## Available Examples

### 1. Basic App (`basic_app/`)
A simple console application showing:
- Model loading
- Context creation
- Tokenization
- Text generation
- Resource cleanup

**Best for:** Understanding the core API

**Run:**
```bash
cd basic_app
dart pub get
dart run
```

### 2. Chat App (`chat_app/`)
A Flutter UI application showing:
- Real-time chat interface
- Model configuration
- Settings persistence
- Streaming text generation
- Material Design UI

**Best for:** Real-world Flutter integration

**Run:**
```bash
cd chat_app
flutter pub get
flutter run
```

## Quick Start

1. **Choose an example**: Basic (console) or Chat (Flutter)
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

llamadart supports GGUF format models (converted for llama.cpp).

## Architecture

```
example/
├── basic_app/          # Console application
│   ├── lib/            # Dart code
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
- Internet connection (for first run - downloads native libraries)
- At least 2GB RAM minimum, 4GB+ recommended

## Platform Compatibility

| Platform | Architecture(s) | GPU Backend | Status |
|----------|-----------------|-------------|--------|
| **macOS** | arm64, x86_64 | Metal | ✅ Tested |
| **iOS** | arm64 (Device), x86_64 (Sim) | Metal (Device), CPU (Sim) | ✅ Tested |
| **Android** | arm64-v8a, x86_64 | Vulkan | ✅ Tested |
| **Linux** | arm64, x86_64 | Vulkan | 🟡 Expected (Vulkan Untested) |
| **Windows** | x64 | Vulkan | ✅ Tested |
| **Web** | WASM | CPU | ✅ Tested |

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
