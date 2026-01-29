# llamadart

A Dart/Flutter plugin for `llama.cpp` - run LLM inference on any platform using GGUF models with high performance.

## Features
- **Cross-platform**: Support for Android, iOS, macOS, Linux, and Windows.
- **GPU Acceleration**: Metal (macOS/iOS), Vulkan (Windows/Android/Linux), and CUDA/ROCm (work in progress).
- **Fast Inference**: Leverages the power of `llama.cpp`'s optimized kernels.
- **Simple API**: Easy-to-use Dart bindings for model loading and text generation.

## Quick Start

### 1. Installation
Add `llamadart` to your `pubspec.yaml`:
```yaml
dependencies:
  llamadart: ^0.2.0
```

### 2. Setup (Native Binaries)
`llamadart` requires native binaries from `llama.cpp`. For Dart CLI applications, you must download them manually:

```bash
dart run llamadart:setup
```

For Flutter applications, the `hook/build.dart` will attempt to automatically download the correct binaries during the build process.

### 3. Usage
```dart
import 'package:llamadart/llamadart.dart';

void main() async {
  // Initialize the native backend
  LlamaService.init();

  // Load a model
  final model = await LlamaService.loadModel('path/to/model.gguf');

  // Generate text
  final stream = model.generate('The capital of France is');
  await for (final token in stream) {
    print(token);
  }
}
```

## Documentation
For more details, see the [Documentation](https://github.com/leehack/llamadart/wiki).

## Contributing
Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License
MIT
