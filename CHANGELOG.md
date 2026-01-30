## 0.3.0+b7883

*   **Version Alignment**: Aligned package versioning and binary distribution with `llama.cpp` release tags (starting with `b7883`).

*   **Pure Native Assets**: Migrated to the modern Dart Native Assets mechanism (`hook/build.dart`).
*   **Zero Setup**: Native binaries are now automatically downloaded and bundled at runtime based on the target platform.
*   **Streamlined Bindings**: Switched to `@Native` top-level FFI bindings for better performance and simpler code.
*   **Stable Submodule**: Pinned `llama.cpp` to a stable release tag (`b7883`).
*   **Consolidated Build Infra**: Moved all native source, submodules, and build scripts into a unified `third_party/` directory.
*   **Clean Repository**: Removed obsolete platform folders (`macos/`, `android/`, `ios/`) and legacy build scripts.

## 0.2.0

*   **Project Rename**: Renamed package from `llama_dart` to `llamadart`.
*   **New Build System**: Refactored native build system into modular platform-specific scripts (`tool/native_build/`).
*   **Cleaner Architecture**: Switched to a standard Flutter FFI plugin structure for better maintainability.
*   **Cross-Platform GPU**: Verified and improved hardware acceleration on macOS (Metal), iOS (Metal), Android (Vulkan), and Linux (Vulkan).
*   **Windows Support**: Added robust Docker-based cross-compilation pipeline for Windows (MinGW + Vulkan).
*   **Optimization**: Enabled symbol stripping on all platforms for significantly smaller binaries.
*   **CI/CD**: Added GitHub Actions workflow for analysis, formatting, and native builds.
*   **Robustness**: Improved `loader.dart` with multi-arch support for Windows.
*   **Fix**: Resolved missing symbols in Windows DLL by ensuring all static libraries are exported.

## 0.1.0

*   **WASM Support**: Full support for running the Flutter app and LLM inference in WASM on the web.
*   **Performance Improvements**: Optimized memory usage and loading times for web models.
*   **Enhanced Web Interop**: Improved `wllama` integration with better error handling and progress reporting.
*   **Bug Fixes**: Resolved minor UI issues on mobile and web layouts.

## 0.0.1

*   Initial release.
*   Supported platforms: iOS, macOS, Android, Linux, Windows, Web.
*   Features:
    *   Text generation with `llama.cpp` backend.
    *   GGUF model support.
    *   Hardware acceleration (Metal, Vulkan).
    *   Flutter Chat Example.
    *   CLI Basic Example.
