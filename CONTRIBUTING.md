# Contributing into llamadart

Thank you for your interest in contributing to `llamadart`! We welcome contributions from the community to help improve this package.

## Prerequisites

Before you begin, ensure you have the following installed:

-   **Dart SDK**: >= 3.0.0
-   **Flutter SDK**: (Optional, for running UI examples)
-   **CMake**: >= 3.10
-   **C++ Compiler**:
    -   **macOS**: Xcode Command Line Tools (`xcode-select --install`)
    -   **Linux**: GCC/G++ (`build-essential`) or Clang
    -   **Windows**: Visual Studio 2022 (Desktop development with C++)

## Project Structure

The project maps closely to the `llama.cpp` structure:

-   `lib/`: Dart source code and FFI bindings.
-   `third_party/`: `llama.cpp` core engine, dependencies (submodules), and build infrastructure.
-   `example/`: Usage examples, Flutter app, and LoRA training notebook.
-   `hook/`: Native Assets build hook for automatic binary management.

## 🛡️ Zero-Patch Strategy

This project follows a **Zero-Patch Strategy** for external submodules (like `llama.cpp` and `Vulkan-Headers`):

*   **No Direct Modifications**: We never modify the source code inside `third_party/llama_cpp`.
*   **Upgradability**: This allows us to update the core engine by simply bumping the submodule pointer.
*   **Wrappers & Hooks**: Any necessary changes should be implemented in `third_party/CMakeLists.txt` or through compiler flags in the build scripts.

## 🏗️ Architecture: Native Assets & CI

`llamadart` uses a modern binary distribution lifecycle:

### 1. Binary Production (CI)
When a maintainer pushes a tag in the format `libs-v*`, the GitHub Action workflow (`.github/workflows/build_native.yml`) is triggered:
- It uses the consolidated build logic in `third_party/` to compile `llama.cpp` for **Android, iOS, macOS, Linux, and Windows**.
- It bundles the submodules (pinned to stable tags) and applies necessary hardware acceleration flags (Metal, Vulkan).
- The resulting binaries are uploaded to **GitHub Releases**.

### 2. Binary Consumption (Hook)
When a user adds `llamadart` as a dependency and runs their app:
- The **`hook/build.dart`** script executes automatically.
- It detects the user's current target OS and architecture.
- It downloads the matching pre-compiled binary from the GitHub Release corresponding to the package version.
- It reports the binary to the Dart VM as a **`CodeAsset`** with the ID `package:llamadart/llamadart`.

### 3. Runtime Resolution (FFI)
- The library uses **`@Native`** top-level bindings in `lib/src/generated/llama_bindings.dart`.
- The Dart VM automatically resolves these calls to the downloaded binary reported by the hook.
- This provides a "Zero-Setup" experience while maintaining high-performance native execution.

## Setting Up the Development Environment

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/leehack/llamadart.git
    cd llamadart
    ```

2.  **Clone submodules**:
    ```bash
    git submodule update --init --recursive
    ```

3.  **Build/Fetch Native Library**:
    In most cases, simply running the examples will handle everything:
    ```bash
    cd example/basic_app
    dart run
    ```
    The `hook/build.dart` will automatically download the correct pre-compiled binaries for your platform.

## Maintainer: Building Binaries

If you need to build binaries for a new release:

1.  **Navigate to the build tool**:
    ```bash
    cd third_party
    ```

2.  **Run platform scripts**:
    -   **Android**: `./build_android.sh`
    -   **Apple (macOS/iOS)**: `./build_apple.sh macos` or `./build_apple.sh ios`
    -   **Linux**: `./build_linux.sh vulkan`

## Running Examples

### Basic App (CLI)
1.  ```bash
    cd example/basic_app
    dart run
    ```

### Chat App (Flutter)
1.  ```bash
    cd example/chat_app
    flutter run -d macos  # or linux, windows, android, ios
    ```

## Development Guidelines

-   **Code Style**: We follow standard Dart linting rules. Run `dart format .` before committing.
-   **Native Assets**: The package uses the modern **Dart Native Assets** (hooks) mechanism.
-   **Testing**: Add unit tests for new features where possible. Use `dart run test/simple_check.dart` for quick verification.

## Submitting a Pull Request

1.  Fork the repository.
2.  Create a new branch (`git checkout -b feature/my-feature`).
3.  Commit your changes.
4.  Push to your fork and submit a Pull Request.

Thank you for contributing!
