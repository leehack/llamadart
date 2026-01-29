# Agent Guidelines for llamadart

This repository is a Dart/Flutter plugin for `llama.cpp` using FFI. It allows running LLM inference directly in Dart and Flutter applications.

## 1. Build, Lint, and Test Commands

### Setup
Before running any code, ensure the test model is available:
```bash
dart run test/simple_tokenizer.dart # Or use a local model path
```

### Build (Full Platform Matrix)
Automated scripts are provided for all platforms. These generate the necessary artifacts in the correct locations.

| Platform | Command | Output | Notes |
|----------|---------|--------|-------|
| **macOS** | `./scripts/build_apple.sh macos [clean]` | `macos/Frameworks/libllama.dylib` | Universal Binary (x86_64, arm64). Metal supported. |
| **iOS** | `./scripts/build_apple.sh ios [clean]` | `ios/Frameworks/llama.xcframework` | XCFramework (Simulators + Devices). Metal supported. |
| **Android**| `./scripts/build_android.sh` | `android/src/main/jniLibs/` | Supports arm64-v8a, x86_64. Vulkan supported. |
| **Linux (x64)** | `./scripts/build_linux_x64.sh` | `linux/lib/x64/libllama.so` | Uses Docker. Vulkan supported. |
| **Linux (arm64)**| `./scripts/build_linux_arm64.sh` | `linux/lib/arm64/libllama.so` | Uses Docker. Vulkan supported. |
| **Windows** | `./scripts/build_windows_docker.sh` | `windows/lib/x64/libllama.dll` | Uses Docker (MinGW). Vulkan supported. |

**Manual Windows Cross-Compile (No Docker):**
```bash
./scripts/build_windows_cross.sh vulkan clean
```

### Build (Web / WASM)
Standard builds use CDN. For local assets, use:
```bash
dart run llamadart:download_wllama
```

### Build (Dart Bindings)
If the C API changes, regenerate the FFI bindings:
```bash
dart run ffigen --config ffigen.yaml
```

### Linting & Formatting
Enforce zero lint issues and standard formatting.
```bash
# formatting
dart format .

# analysis (must return "No issues found!")
dart analyze
```

### Testing
There are currently two types of tests:

**1. Smoke Tests (Manual Scripts)**
These are standalone scripts in `test/` that do not use `package:test`.
```bash
# Run inference smoke test
cd example/basic_app && dart run bin/llamadart_basic_example.dart


# Run basic check
dart run test/simple_tokenizer.dart
```

**2. Unit Tests (Future)**
Standard Dart tests should be placed in `test/` ending with `_test.dart`.
```bash
# Run all unit tests
dart test

# Run a single unit test file
dart test test/my_new_test.dart
```

**3. Linux Verification (Docker)**
To verify Linux support (native build + inference):
```bash
./scripts/verify_linux_docker.sh vulkan
# or
./scripts/verify_app_linux.sh vulkan
```

## 2. Code Style & Conventions

### General
- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines.
- **Strict Linting**: The project uses `package:lints/recommended.yaml` plus strict rules like `public_member_api_docs`. ALL public members must have documentation comments (`///`).

### Imports
Sort imports alphabetically in this order:
1. `dart:` imports
2. `package:` imports
3. Relative imports

```dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/generated/llama_bindings.dart';

import 'src/utils.dart';
```

### Naming
- **Dart Classes/Types**: `PascalCase` (e.g., `LlamaService`, `ModelParams`).
- **Variables/Methods**: `camelCase` (e.g., `loadModel`, `contextSize`).
- **FFI Bindings**: Keep `snake_case` when mirroring C API functions directly (e.g., `llama_backend_init`).
- **File Names**: `snake_case` (e.g., `llama_service.dart`).

### FFI & Memory Management
- **Explicit Freeing**: This project uses manual memory management for C interop. ALWAYS free memory allocated with `malloc`.
- **Scopes**: Use `try/finally` blocks to ensure resources (models, contexts, pointers) are freed even if errors occur.
- **Strings**: Use `.toNativeUtf8()` for passing strings to C. Remember to `malloc.free()` the pointer.

### Architecture
- **`lib/llamadart.dart`**: Entry point with conditional exports for native/web.
- **`lib/src/llama_service_interface.dart`**: Common interface `LlamaServiceBase`.
- **`lib/src/llama_service_native.dart`**: Desktop/Mobile implementation (FFI).
- **`lib/src/llama_service_web.dart`**: Web implementation (wllama/JS).
- **`scripts/build_apple.sh`**: Critical script for generating the iOS/macOS `llama_cpp.xcframework`. 
- **`scripts/build_android.sh`**: Script for building Android `.so` libraries.

### macOS & iOS Integration
- **Symbols**: Symbols must be exported to be visible to `DynamicLibrary.process()`. Ensure `-all_load` and `-Wl,-export_dynamic` are in the linker flags.
- **Stripping**: Prevent symbol stripping in Xcode by setting `STRIP_STYLE = non-global`.
- **Entitlements**: Sandboxed apps (macOS) require `com.apple.security.network.client` for downloading weights.

## 3. Workflow Rules
- **Never commit broken code**: Run `dart analyze` before every commit.
- **Verify Native**: If you touch `llama.cpp` version, you MUST run `test/simple_inference.dart` to verify the native build doesn't crash.
- **iOS Changes**: If modifying iOS configuration, verify on BOTH a physical device (Metal) and the simulator (universal compatibility).
- **Zero-Patch Strategy**: NEVER modify files inside `src/native/llama_cpp` or other submodules. Use our own wrappers or CMake flags for any adaptations.
- **Clean Output**: Remove debug `print` statements from production code. Use a logger or `debugPrint` (if Flutter).
