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
- 🧠 **LoRA Support**: Apply fine-tuned adapters (GGUF) dynamically at runtime.
- 🌐 **Web Support**: Run inference in the browser via WASM (powered by `wllama`).
- 💎 **Dart-First API**: Streamlined FFI bindings with a clean, isolate-safe Dart interface.
- 🔇 **Logging Control**: Granular control over native engine output (debug, info, warn, error, none).

---

## 📊 Compatibility & Test Status

| Platform | Architecture(s) | GPU Backend | Status |
|----------|-----------------|-------------|--------|
| **macOS** | arm64, x86_64 | Metal | ✅ Tested |
| **iOS** | arm64 (Device), x86_64 (Sim) | Metal (Device), CPU (Sim) | ✅ Tested |
| **Android** | arm64-v8a, x86_64 | Vulkan | ✅ Tested |
| **Linux** | arm64, x86_64 | Vulkan | ⚠️ Expected (Vulkan Untested) |
| **Windows** | x64 | Vulkan | ✅ Tested |
| **Web** | WASM | CPU | ✅ Tested |

---

## 🚀 Quick Start

### 1. Installation

Add `llamadart` to your `pubspec.yaml`:

```yaml
dependencies:
  llamadart: ^0.3.0
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

  // 2. Initialize with a GGUF model and optional LoRA adapters
  // This loads the model and prepares the native backend (GPU/CPU)
  await service.init(
    'path/to/your_model.gguf',
    modelParams: ModelParams(
      loras: [
        LoraAdapterConfig(path: 'path/to/style.lora.gguf', scale: 0.8),
      ],
    ),
  );

  // 3. You can also update or add LoRA adapters dynamically (Native platforms)
  await service.setLoraAdapter('path/to/emotional_shift.lora.gguf', scale: 1.2);

  // 4. Generate text (streaming)
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

## 🎨 Low-Rank Adaptation (LoRA)

`llamadart` supports applying one or multiple LoRA adapters to your base model. This allows you to customize the model's style, persona, or domain knowledge without replacing the entire 7B+ parameter model.

- **Dynamic Scaling**: Adjust the strength (`scale`) of each adapter at runtime.
- **Isolate-Safe**: Adapters are loaded and managed in the background Isolate.
- **Resource Efficient**: Multiple LoRAs share the memory of a single base model.

### Training your own LoRA
Check out our [LoRA Training Notebook](example/training_notebook/lora_training.ipynb) to learn how to:
1. Fine-tune a small model (like Qwen2.5-0.5B) using Hugging Face tools.
2. Convert the adapter to GGUF format using `llama.cpp`.
3. Run it in your Flutter app with `llamadart`.

---

## 📂 Examples

Explore the `example/` directory for full implementations:
- **`basic_app`**: A lightweight CLI example for quick verification. Supports loading LoRA adapters via `--lora`.
- **`chat_app`**: A feature-rich Flutter chat application with streaming UI and model management.
- **`training_notebook`**: A Jupyter Notebook demonstrating how to train your own LoRA adapters and convert them to GGUF.

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
