# llamadart

[![Pub Version](https://img.shields.io/pub/v/llamadart?logo=dart&color=blue)](https://pub.dev/packages/llamadart)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)
[![GitHub](https://img.shields.io/github/stars/leehack/llamadart?style=social)](https://github.com/leehack/llamadart)

**llamadart** is a high-performance Dart and Flutter plugin for [llama.cpp](https://github.com/ggml-org/llama.cpp). It allows you to run Large Language Models (LLMs) locally using GGUF models across all major platforms with minimal setup.

## ✨ Features

- 🚀 **High Performance**: Powered by `llama.cpp`'s optimized C++ kernels.
- 🛠️ **Zero Configuration**: Uses the modern **Pure Native Asset** mechanism—no manual build scripts or platform folders required.
- 📱 **Cross-Platform**: Full support for Android, iOS, macOS, Linux, and Windows.
- ⚡ **GPU Acceleration**:
  - **Apple**: Metal (macOS/iOS)
  - **Android/Linux/Windows**: Vulkan
- 🌐 **Web Support**: Run inference in the browser via WASM (powered by `wllama`).
- 💎 **Dart-First API**: Streamlined FFI bindings with a clean, isolate-safe Dart interface.
- 🔇 **Logging Control**: Granular control over native engine output (debug, info, warn, error, none).

---

## 📊 Compatibility & Test Status

| Platform | Architecture(s) | GPU Backend | Status |
|----------|-----------------|-------------|--------|
| **macOS** | arm64, x86_64 | Metal | ✅ Tested (CPU, Metal) |
| **iOS** | arm64 (Device), x86_64 (Sim) | Metal (Device), CPU (Sim) | ✅ Tested (CPU, Metal) |
| **Android** | arm64-v8a, x86_64 | Vulkan | ✅ Tested (CPU, Vulkan) |
| **Linux** | arm64, x86_64 | Vulkan | ⚠️ Tested (CPU Verified, Vulkan Untested) |
| **Windows** | x64 | Vulkan | ✅ Tested (CPU, Vulkan) |
| **Web** | WASM | CPU | ✅ Tested (WASM) |

---

## 🚀 Quick Start

### 1. Installation

Add `llamadart` to your `pubspec.yaml`:

```yaml
dependencies:
  llamadart: ^0.2.0
```

### 2. Zero Setup (Native Assets)

`llamadart` leverages the **Dart Native Assets** (build hooks) system. When you run your app for the first time (`dart run` or `flutter run`), the package automatically:
1. Detects your target platform and architecture.
2. Downloads the appropriate pre-compiled stable binary from GitHub.
3. Bundles it seamlessly into your application.

No manual binary downloads or CMake configuration are needed.

### 3. Basic Usage

```dart
import 'dart:io';
import 'package:llamadart/llamadart.dart';

void main() async {
  // 1. Create the service
  final service = LlamaService();

  // 2. Initialize with a GGUF model
  // This loads the model and prepares the native backend (GPU/CPU)
  await service.init('path/to/your_model.gguf');

  // 3. Generate text (streaming)
  final stream = service.generate('The capital of France is');
  
  await for (final token in stream) {
    stdout.write(token);
    await stdout.flush();
  }
  
  // 4. Clean up resources
  service.dispose();
}
```

---

## 📂 Examples

Explore the `example/` directory for full implementations:
- **`basic_app`**: A lightweight CLI example for quick verification.
- **`chat_app`**: A feature-rich Flutter chat application with streaming UI and model management.

---

## 🐳 Docker (Linux)

You can build and run the examples using Docker on Linux. This ensures all build dependencies (like `libgtk-3-dev`, `cmake`, etc.) are correctly configured.

### 1. Build and Run CLI Basic Example
```bash
./docker/build-docker.sh basic-run
```

### 2. Build Flutter Chat App for Linux
```bash
./docker/build-docker.sh chat-build
```

The Dockerfile is multi-stage and optimized to minimize context size. It handles the downloading of native assets and compilation of Flutter Linux binaries.

---

## 🏗️ Architecture

This package follows the "Pure Native Asset" philosophy:
- **Maintenance**: All native build logic and submodules are isolated in `third_party/`.
- **Distribution**: Binaries are produced via GitHub Actions and hosted on GitHub Releases.
- **Integration**: The `hook/build.dart` manages the lifecycle of native dependencies, keeping your project root clean.

---

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for architecture details and maintainer instructions for building native binaries.

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
