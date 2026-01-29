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

-   `lib/`: Dart source code.
-   `src/native/`: `llama.cpp` source code and native wrappers.
-   `example/`: Usage examples.
    -   `basic_app/`: Simple CLI app.
    -   `chat_app/`: Flutter GUI chat application.
-   `scripts/`: Platform-specific build and verification scripts.
-   `android/`, `ios/`, `linux/`, `macos/`, `windows/`: Platform-specific plugin configurations.
-   `src/native/llama_cpp/`: Git submodule for the core engine.

## 🛡️ Zero-Patch Strategy

This project follows a **Zero-Patch Strategy** for external submodules (like `llama.cpp` and `Vulkan-Headers`):

*   **No Direct Modifications**: We never modify the source code inside `src/native/llama_cpp`.
*   **Upgradability**: This allows us to update the core engine by simply bumping the submodule pointer, without having to re-apply custom patches.
*   **Wrappers & Hooks**: Any necessary changes (like platform-specific fixes or API extensions) should be implemented in:
    *   Our own C++ wrapper files (e.g., `src/native/llamadart_empty.cpp` or new bridge files).
    *   CMake configurations (`src/native/CMakeLists.txt`).
    *   Pre-build hooks or compiler flags in platform-specific scripts.

If you find a bug in `llama.cpp`, the correct path is to contribute the fix to the upstream repository first.

## Setting Up the Development Environment

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/leehack/llamadart.git
    cd llamadart
    ```

2.  **Clone submodules** (if applicable):
    If the project uses submodules for `llama.cpp` (check `src/native/llama_cpp`):
    ```bash
    git submodule update --init --recursive
    ```
    *Note: If `src/native/llama_cpp` is populated, this step might be skipped.*

3.  **Build the Native Library**:
-    In most cases, `flutter run` or `dart run` will handle the native compilation automatically via the plugin's build system (CMake/Gradle/Podspec).
-
-    If you need to build manually for development or verification:
-
-    **Desktop (macOS/Linux):**
-    ```bash
-    mkdir -p src/native/build
-    cd src/native/build
-    cmake .. -DCMAKE_BUILD_TYPE=Release
-    cmake --build . --config Release -j
-    ```
-
-    **Android:**
-    ```bash
-    ./scripts/build_android.sh
-    ```
-
-    **iOS/macOS (XCFramework):**
-    ```bash
-    ./scripts/build_apple.sh
-    ```

## Running Translations & Tests

### Basic App (CLI)
This example automatically looks for the natively built library in `../../src/native/build/bin/` when running in dev mode.

1.  Navigate to the example:
    ```bash
    cd example/basic_app
    ```
2.  Run the app:
    ```bash
    dart run
    ```
    *It will automatically download a model to `tmp/` if needed.*

### Chat App (Flutter)
1.  Navigate to the example:
    ```bash
    cd example/chat_app
    ```
2.  Run on your desktop (macOS/Linux/Windows):
    ```bash
    flutter run -d macos  # or linux, windows
    ```

## Development Guidelines

-   **Code Style**: We follow standard Dart linting rules. Run `dart format .` before committing.
-   **Native Changes**: If you modify C++ code in `src/native/`, remember to rebuild the library to test your changes.
-   **Testing**: Add unit tests for new features where possible.
-   **Documentation**: Update `README.md` and public API docs if you change functionality.

## Submitting a Pull Request

1.  Fork the repository.
2.  Create a new branch (`git checkout -b feature/my-feature`).
3.  Commit your changes.
4.  Push to your fork and submit a Pull Request.
5.  Describe your changes and what they solve.

Thank you for contributing!
