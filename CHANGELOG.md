## 0.3.0
*   **LoRA Support**: Added full support for Low-Rank Adaptation (LoRA) on all native platforms (iOS, Android, macOS, Linux, Windows).
*   **Dynamic Adapters**: Implemented APIs to dynamically add, update scale, or remove LoRA adapters at runtime without reloading the base model.
*   **LoRA Training Pipeline**: Added a comprehensive Jupyter Notebook for fine-tuning models and converting adapters to GGUF format.
*   **CLI Tooling**: Updated the `basic_app` example to support testing LoRA adapters via the `--lora` flag.
*   **API Enhancements**: Updated `ModelParams` to include initial LoRA configurations.

## 0.2.0+b7883

*   **Project Rebrand**: Renamed package from `llama_dart` to `llamadart`.
*   **Pure Native Assets**: Migrated to the modern Dart Native Assets mechanism (`hook/build.dart`).
*   **Zero Setup**: Native binaries are now automatically downloaded and bundled at runtime based on the target platform and architecture.
*   **Version Alignment**: Aligned package versioning and binary distribution with `llama.cpp` release tags (starting with `b7883`).
*   **Logging Control**: Implemented comprehensive logging interception for both `llama` and `ggml` backends with configurable log levels.
*   **Performance Optimization**: Added token caching to message processing, significantly reducing latency in long conversations.
*   **Architecture Overhaul**:
    *   Refactored Flutter Chat Example into a clean, layered architecture (Models, Services, Providers, Widgets).
    *   Rebuilt CLI Basic Example into a robust conversation tool with interactive and single-response modes.
*   **Cross-Platform GPU**: Verified and improved hardware acceleration on macOS/iOS (Metal) and Android/Linux/Windows (Vulkan).
*   **New Build System**: Consolidated all native source and build infrastructure into a unified `third_party/` directory.
*   **Windows Support**: Added robust MinGW + Vulkan cross-compilation pipeline.
*   **UI Enhancements**: Added fine-grained rebuilds using Selectors and isolated painting with RepaintBoundaries.

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
