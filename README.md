# llamadart

[![Pub Version](https://img.shields.io/pub/v/llamadart?logo=dart&color=blue)](https://pub.dev/packages/llamadart)
[![codecov](https://codecov.io/gh/leehack/llamadart/graph/badge.svg?token=)](https://codecov.io/gh/leehack/llamadart)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)
[![GitHub](https://img.shields.io/github/stars/leehack/llamadart?style=social)](https://github.com/leehack/llamadart)

**llamadart** is a high-performance Dart and Flutter plugin for [llama.cpp](https://github.com/ggml-org/llama.cpp). It lets you run GGUF LLMs locally across native platforms and web (CPU/WebGPU bridge path).

## 📚 Documentation

- Docs site: https://llamadart.leehack.com/
- API reference: https://pub.dev/documentation/llamadart/latest/
- Chat app demo: https://leehack-llamadart.static.hf.space
- Migration guide: [`MIGRATION.md`](https://github.com/leehack/llamadart/blob/main/MIGRATION.md)

## ✨ Features

- 🚀 **High Performance**: Powered by `llama.cpp` kernels.
- 🛠️ **Zero Configuration**: Uses Pure Native Assets; no manual CMake or platform project edits.
- 📱 **Cross-Platform**: Android, iOS, macOS, Linux, Windows, and web.
- ⚡ **GPU Acceleration**:
  - Apple: Metal
  - Linux/Windows: Vulkan by default, with optional target-specific modules
  - Android: CPU by default, with bundled Vulkan available for opt-in
  - Web: WebGPU via bridge runtime (with CPU fallback)
- 🧭 **Embeddings API**: Generate vectors with `embed(...)` and
  `embedBatch(...)`.
- 📦 **Structured Model Sources**: Describe local, HTTP(S), and Hugging Face
  GGUF sources with deterministic cache identities for download/cache workflows.
- 💾 **KV-cache State Persistence**: Save and restore llama.cpp KV-cache state
  with `stateSaveFile(...)` / `stateLoadFile(...)` for fast raw-prompt resumes.
- 🖼️ **Multimodal Support**: Vision/audio model runtime support.
- **LoRA Support**: Runtime GGUF adapter application.
- 🔇 **Split Logging Control**: Dart logs and native logs can be configured independently.

---

## 🚀 Start Here (Plugin Users)

### 1. Add dependency

```yaml
dependencies:
  llamadart: ^0.6.12
```

### 2. Run with defaults

On first `dart run` / `flutter run`, `llamadart` will:
1. Detect platform/architecture.
2. Download the matching native runtime bundle from [`leehack/llamadart-native`](https://github.com/leehack/llamadart-native).
3. Wire it into your app via native assets.

No manual binary download or C++ build steps are required.

> iOS builds require a minimum deployment target of `16.4` or newer in your
> Xcode project / Podfile (for example `platform :ios, '16.4'`).

### 3. Optional: choose backend modules per target (non-Apple)

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_backends:
        platforms:
          android-arm64:
            backends: [vulkan] # opencl is opt-in
            cpu_profile: full # default: full; compact keeps baseline only
          linux-x64: [vulkan, cuda]
          windows-x64: [vulkan, cuda]
```

If a requested module is unavailable for a target, `llamadart` logs a warning and falls back to target defaults.

### 4. Minimal first model load

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel('path/to/model.gguf');
    await for (final token in engine.generate('Hello')) {
      print(token);
    }
  } finally {
    await engine.dispose();
  }
}
```

### 5. Download and cache a remote GGUF

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModelSource(
      ModelSource.parse('hf://owner/repo/model-Q4_K_M.gguf'),
      options: ModelLoadOptions(
        cachePolicy: ModelCachePolicy.preferCached,
        cacheDirectory: '/path/to/app/model-cache',
      ),
      onProgress: (progress) {
        final fraction = progress.fraction;
        if (fraction != null) {
          print('download ${(fraction * 100).toStringAsFixed(1)}%');
        }
      },
    );
  } finally {
    await engine.dispose();
  }
}
```

Native/file-backed backends stream remote models into the package-managed cache,
resume partial `.part` downloads when the server supports HTTP Range and the
partial has a safe validator (ETag/Last-Modified) or caller-provided SHA-256,
verify optional SHA-256 checksums, and redact signed URL credentials from
metadata. Validator-less partial files restart from byte zero instead of being
appended.

### 6. Generate embeddings

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel('path/to/embedding-model.gguf');

    final vector = await engine.embed('hello world');
    final batch = await engine.embedBatch([
      'semantic search',
      'document retrieval',
    ]);

    print('Single embedding dims: ${vector.length}');
    print('Batch size: ${batch.length}');
  } finally {
    await engine.dispose();
  }
}
```

Note: embedding support depends on backend/runtime capabilities.

- Native runtime supports single and batched embeddings.
- Web runtime requires bridge assets with embedding APIs (`v0.1.7` or newer).
- See the full guide: https://llamadart.leehack.com/docs/guides/embeddings

### 7. Optional: save and restore KV-cache state

Native backends and WebGPU bridge assets `v0.1.15+` can persist llama.cpp
KV-cache state for fast raw-prompt resume/fork workflows. On native platforms,
`path` is an app-writable filesystem path. On web, `path` is a bridge WASMFS
virtual path; use an app-managed browser storage layer if you need durable state
across page reloads.

```dart
final prompt = 'You are a concise assistant. Summarize llamadart.';
final tokens = await engine.tokenize(prompt);

if (!engine.supportsStatePersistence) {
  throw UnsupportedError('State persistence is not available on this backend.');
}

// Populate the KV cache, then save it with the token sequence that produced it.
await engine
    .generate(prompt, params: const GenerationParams(maxTokens: 1))
    .drain<void>();
await engine.stateSaveFile('assistant.state', tokens: tokens);

// Later, after loading the same model with a compatible runtime build:
final restored = await engine.stateLoadFile(
  'assistant.state',
  tokenCapacity: await engine.getContextSize(),
);
print('Restored ${restored.tokens.length} prompt tokens');
```

State files are opaque llama.cpp artifacts tied to the same model and
runtime/build. `ChatSession` message history is not restored automatically, so
persist chat messages separately when using the high-level chat API.

---

## ✅ Platform Defaults and Configurability

| Target | Default runtime backends | Configurable in `pubspec.yaml` |
|--------|--------------------------|---------------------------------|
| android-arm64 / android-x64 | cpu, vulkan | yes |
| linux-arm64 / linux-x64 | cpu, vulkan | yes |
| windows-arm64 / windows-x64 | cpu, vulkan | yes |
| macos-arm64 / macos-x86_64 | cpu, METAL | no |
| ios-arm64 / ios simulators | cpu, METAL | no |
| web | webgpu, cpu (bridge router) | n/a |

<details>
<summary>Full module matrix (available modules by target)</summary>

Backend module matrix from pinned native tag `b9016`:

| Target | Available backend modules in bundle |
|--------|-------------------------------------|
| android-arm64 | cpu, vulkan, opencl |
| android-x64 | cpu, vulkan, opencl |
| linux-arm64 | cpu, vulkan, blas |
| linux-x64 | cpu, vulkan, blas, cuda, hip |
| windows-arm64 | cpu, vulkan, blas |
| windows-x64 | cpu, vulkan, blas, cuda |
| macos-arm64 | n/a (single consolidated native lib) |
| macos-x86_64 | n/a (single consolidated native lib) |
| ios-arm64 | n/a (single consolidated native lib) |
| ios-arm64-sim | n/a (single consolidated native lib) |
| ios-x86_64-sim | n/a (single consolidated native lib) |

</details>

Recognized backend names for `llamadart_native_backends`:

- `vulkan`
- `cpu`
- `opencl`
- `cuda`
- `blas`
- `metal`
- `hip`

Accepted aliases:

- `vk` -> `vulkan`
- `ocl` -> `opencl`
- `open-cl` -> `opencl`

Android arm64 CPU profile options (`platforms.android-arm64`):

- `cpu_profile: full` (default) bundles all Android ARM CPU variants.
- `cpu_profile: compact` bundles baseline CPU variant only.
- `cpu_variants: [...]` (advanced) overrides `cpu_profile` with an exact
  variant list.

Supported canonical `cpu_variants` values:

- `android_armv8.0_1`
- `android_armv8.2_1`
- `android_armv8.2_2`
- `android_armv8.6_1`
- `android_armv9.0_1`
- `android_armv9.2_1`
- `android_armv9.2_2`

Variant feature differences:

| Variant | Optional feature set used by that module |
|--------|------------------------------------------|
| `android_armv8.0_1` | baseline |
| `android_armv8.2_1` | `DOTPROD` |
| `android_armv8.2_2` | `DOTPROD` + `FP16_VECTOR_ARITHMETIC` |
| `android_armv8.6_1` | `DOTPROD` + `FP16_VECTOR_ARITHMETIC` + `MATMUL_INT8` |
| `android_armv9.0_1` | `DOTPROD` + `FP16_VECTOR_ARITHMETIC` + `MATMUL_INT8` + `SVE2` |
| `android_armv9.2_1` | `DOTPROD` + `FP16_VECTOR_ARITHMETIC` + `MATMUL_INT8` + `SVE` + `SME` |
| `android_armv9.2_2` | `DOTPROD` + `FP16_VECTOR_ARITHMETIC` + `MATMUL_INT8` + `SVE` + `SVE2` + `SME` |

Accepted `cpu_variants` input forms are normalized, for example:

- `baseline`
- `armv8_6_1`
- `v9_0_1`
- `android-armv9.2_2`
- `libggml-cpu-android_armv8.2_2.so`

Selection precedence for Android arm64 CPU variants:

1. `cpu_variants` (if present and valid)
2. `cpu_profile`
3. default profile (`full`)

Notes:

- Module availability depends on the pinned native release bundle and may change when the native tag updates.
- Configurable targets always keep `cpu` bundled as a fallback.
- Backend-owned runtime dependencies follow the selected backend module. For
  example, CUDA runtime DLLs (`cudart64_*`, `cublas64_*`, `cublaslt64_*`) are
  bundled only when `cuda` is selected, and OpenBLAS runtime libraries are
  bundled only when `blas` is selected. Unknown runtime libraries are kept for
  compatibility with future native bundle layouts.
- Android arm64 defaults to `cpu_profile: full` for best runtime CPU
  optimization coverage.
- Android keeps OpenCL and Vulkan available for opt-in, but `auto` now prefers CPU by default.
- Use `cpu_profile: compact` if you prefer smaller Android arm64 package size
  over CPU-path optimization coverage.
- If `cpu_variants` contains unknown entries, they are ignored with warnings.
- If all provided `cpu_variants` are invalid, hook selection falls back to
  `cpu_profile`/default.
- `KleidiAI` and `ZenDNN` are CPU-path optimizations in `llama.cpp`, not standalone backend module files.
- `example/chat_app` backend settings list bundled backend options without forcing optional GPU backend initialization.
- `example/chat_app` active backend status reflects the effective backend used for model load (for example `CPU` when GPU fallback is applied).
- `example/chat_app` exposes `Auto` only on web; native selectors list concrete backend options.
- CPU mode (`preferredBackend: cpu` or effective `gpuLayers == 0`) also disables context-time GPU offload so context creation stays CPU-only.
- `ModelParams.splitMode` passes through to llama.cpp `split_mode`; it defaults to upstream `layer` behavior.
- `ModelParams.mainGpu` passes through to llama.cpp `main_gpu`. To select one GPU for the full model, use `splitMode: ModelSplitMode.none` with the desired `mainGpu` index.
- `ModelParams.batchSize` (`n_batch`) and `ModelParams.microBatchSize` (`n_ubatch`) can be set independently for memory/performance tuning; defaults keep legacy behavior (`n_batch = n_ctx`, `n_ubatch = n_batch`).
- Apple targets are intentionally non-configurable in this hook path and use consolidated native libraries.
- The native-assets hook refreshes emitted files each build; if you change `hooks.user_defines` or are upgrading from older cached outputs, run `flutter clean && flutter pub get` before rebuilding.
- Some Vulkan drivers can crash when probing cooperative matrix support. This
  is a driver-side failure in the Vulkan property query path, not a llamadart
  loader failure. Use upstream ggml-vulkan's opt-out environment variables
  before starting the process:
  `GGML_VK_DISABLE_COOPMAT=1` and `GGML_VK_DISABLE_COOPMAT2=1`.

If you change `llamadart_native_backends`, run `flutter clean` once so stale native-asset outputs do not override new bundle selection.

---

## 🌐 Web Backend Notes (Router)

The default web backend uses `WebGpuLlamaBackend` as a router for WebGPU and CPU paths.

- Web mode is currently experimental and depends on an external JS bridge runtime.
- Bridge API contract: [WebGPU bridge contract](https://github.com/leehack/llamadart/blob/main/doc/webgpu_bridge.md).
- Runtime assets are published via:
  - [`leehack/llama-web-bridge`](https://github.com/leehack/llama-web-bridge)
  - [`leehack/llama-web-bridge-assets`](https://github.com/leehack/llama-web-bridge-assets)
- `example/chat_app` prefers vendored local bridge assets on localhost for dev/runtime validation, and otherwise prefers pinned jsDelivr assets with local fallback.
- Web embeddings require bridge assets with embedding APIs (`v0.1.7` or newer).
- Browser Cache Storage is used for repeated model loads when `useCache` is enabled (default).
- `loadMultimodalProjector` is supported on web for URL-based model/mmproj assets.
- `supportsVision` and `supportsAudio` reflect loaded projector capabilities.
- LoRA runtime adapters are not currently supported on web.
- `setLogLevel` / `setNativeLogLevel` changes take effect on next model load.

If your app targets both native and web, gate feature toggles by capability checks.

---

## 🐧 Linux Runtime Prerequisites

Linux targets may need host runtime dependencies based on selected backends:

- `cpu`: no extra GPU runtime dependency.
- `vulkan`: Vulkan loader + valid GPU driver/ICD.
- `blas`: OpenBLAS runtime (`libopenblas.so.0`).
- `cuda` (linux-x64): NVIDIA driver + compatible CUDA runtime libs.
- `hip` (linux-x64): ROCm runtime libs (for example `libhipblas.so.2`).

Example (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y libvulkan1 vulkan-tools libopenblas0
```

Example (Fedora/RHEL/CentOS):

```bash
sudo dnf install -y vulkan-loader vulkan-tools openblas
```

Example (Arch Linux):

```bash
sudo pacman -S --needed vulkan-icd-loader vulkan-tools openblas
```

Quick verification:

```bash
for f in .dart_tool/lib/libggml-*.so; do
  LD_LIBRARY_PATH=.dart_tool/lib ldd "$f" | grep "not found" || true
done
```

<details>
<summary>Docker-based Linux link/runtime validation (power users and maintainers)</summary>

```bash
# 1) Prepare linux-x64 native modules in .dart_tool/lib
docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace" \
  -v "/absolute/path/to/model.gguf:/models/your.gguf:ro" \
  -w /workspace/example/llamadart_cli \
  ghcr.io/cirruslabs/flutter:stable \
  bash -lc '
    rm -rf .dart_tool /workspace/.dart_tool/lib &&
    dart pub get &&
    dart run bin/llamadart_cli.dart --model /models/your.gguf --no-interactive --predict 1 --gpu-layers 0
  '

# 2) Baseline CPU/Vulkan/BLAS link-check
docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace" \
  -w /workspace/example/llamadart_cli \
  ghcr.io/cirruslabs/flutter:stable \
  bash -lc '
    apt-get update &&
    apt-get install -y --no-install-recommends libvulkan1 vulkan-tools libopenblas0 &&
    /workspace/scripts/check_native_link_deps.sh .dart_tool/lib \
      libggml-cpu.so libggml-vulkan.so libggml-blas.so
  '

# Optional CUDA module link-check without GPU execution
docker build --platform linux/amd64 \
  -f docker/validation/Dockerfile.cuda-linkcheck \
  -t llamadart-linkcheck-cuda .

docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace" \
  -w /workspace/example/llamadart_cli \
  llamadart-linkcheck-cuda \
  bash -lc '
    /workspace/scripts/check_native_link_deps.sh .dart_tool/lib \
      libggml-cuda.so libggml-blas.so libggml-vulkan.so
  '

# Optional HIP module link-check without GPU execution
docker build --platform linux/amd64 \
  -f docker/validation/Dockerfile.hip-linkcheck \
  -t llamadart-linkcheck-hip .

docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace" \
  -w /workspace/example/llamadart_cli \
  llamadart-linkcheck-hip \
  bash -lc '
    export LD_LIBRARY_PATH=".dart_tool/lib:/opt/rocm/lib:/opt/rocm-6.3.0/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}" &&
    /workspace/scripts/check_native_link_deps.sh .dart_tool/lib libggml-hip.so
  '
```

Notes:

- Docker can validate module packaging and shared-library resolution.
- GPU execution still requires host device/runtime passthrough.
- CUDA validation requires NVIDIA runtime-enabled container execution.
- HIP validation requires ROCm passthrough.

</details>

---

## 🏗️ Runtime Repositories (Maintainer Context)

llamadart has decoupled runtime ownership:

- Native source/build/release:
  [`leehack/llamadart-native`](https://github.com/leehack/llamadart-native)
- Web bridge source/build:
  [`leehack/llama-web-bridge`](https://github.com/leehack/llama-web-bridge)
- Web bridge runtime assets:
  [`leehack/llama-web-bridge-assets`](https://github.com/leehack/llama-web-bridge-assets)
- This repository consumes pinned published artifacts from those repositories.

Core abstractions in this package:

- `LlamaEngine`: orchestrates model lifecycle, generation, and templates.
- `ChatSession`: stateful helper for chat history and sliding-window context.
- `LlamaBackend`: platform-agnostic backend interface with native/web routing.
- Optional runtime diagnostics are exposed through `LlamaEngine` helpers such as `getBackendName()`, `getAvailableBackends()`, and `getResolvedGpuLayers()` when supported by the active backend.

---
## ⚠️ Breaking Changes in 0.6.x

If you are upgrading from `0.5.x`, read:

- [MIGRATION.md](https://github.com/leehack/llamadart/blob/main/MIGRATION.md)

High-impact changes:

- Removed legacy custom template-handler/override APIs from `ChatTemplateEngine`:
  - `registerHandler(...)`, `unregisterHandler(...)`, `clearCustomHandlers(...)`
  - `registerTemplateOverride(...)`, `unregisterTemplateOverride(...)`,
    `clearTemplateOverrides(...)`
- Removed legacy per-call handler routing:
  - `customHandlerId` and parse `handlerId`
- Render/parse paths no longer silently downgrade to content-only output when
  a handler/parser fails; failures are surfaced to the caller.

---

## 🛠️ Usage

### 1. Simple Usage

The easiest way to get started is by using the default `LlamaBackend`.

```dart
import 'package:llamadart/llamadart.dart';

void main() async {
  // Automatically selects Native or Web backend
  final engine = LlamaEngine(LlamaBackend());

  try {
    // Initialize with a local GGUF model
    await engine.loadModel('path/to/model.gguf');

    // Generate text (streaming)
    await for (final token in engine.generate('The capital of France is')) {
      print(token);
    }
  } finally {
    // CRITICAL: Always dispose the engine to release native resources
    await engine.dispose();
  }
}
```

### 2. Advanced Usage (ChatSession)

Use `ChatSession` for most chat applications. It automatically manages conversation history, system prompts, and handles context window limits.

```dart
import 'package:llamadart/llamadart.dart';

void main() async {
  final engine = LlamaEngine(LlamaBackend());

  try {
    await engine.loadModel('model.gguf');

    // Create a session with a system prompt
    final session = ChatSession(
      engine, 
      systemPrompt: 'You are a helpful assistant.',
    );

    // Send a message
    await for (final chunk in session.create([LlamaTextContent('What is the capital of France?')])) {
      stdout.write(chunk.choices.first.delta.content ?? '');
    }
  } finally {
    await engine.dispose();
  }
}
```

### 3. Tool Calling
  
`llamadart` supports intelligent tool calling where the model can use external functions to help it answer questions.
  
```dart
final tools = [
  ToolDefinition(
    name: 'get_weather',
    description: 'Get the current weather',
    parameters: [
      ToolParam.string('location', description: 'City name', required: true),
    ],
    handler: (params) async {
      final location = params.getRequiredString('location');
      return 'It is 22°C and sunny in $location';
    },
  ),
];

final session = ChatSession(engine);

// Pass tools per-request
await for (final chunk in session.create(
  [LlamaTextContent("how's the weather in London?")],
  tools: tools,
)) {
  final delta = chunk.choices.first.delta;
  if (delta.content != null) stdout.write(delta.content);
}
```

Notes:

- Built-in template handlers automatically select model-specific tool-call grammar and parser behavior; you usually do not need to set `GenerationParams.grammar` manually for normal tool use.
- Some handlers use lazy grammar activation (triggered when a tool-call prefix appears) to match llama.cpp behavior.
- If you implement a custom handler grammar, prefer Dart raw strings (`r'''...'''`) for GBNF blocks to avoid escaping bugs.

### 3.5 Template Routing (Strict llama.cpp parity)

Template/render/parse routing is intentionally strict to match llama.cpp:

- Built-in format detection and built-in handlers are always used.
- `customTemplate` is supported per call.
- Legacy custom handler/override registry APIs were removed.

If you need deterministic template customization, use `customTemplate`,
`chatTemplateKwargs`, and `templateNow`:

```dart
final result = await engine.chatTemplate(
  [
    const LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'hello',
    ),
  ],
  customTemplate: '{{ "CUSTOM:" ~ messages[0]["content"] }}',
  chatTemplateKwargs: {'my_flag': true, 'tenant': 'demo'},
  templateNow: DateTime.utc(2026, 1, 1),
);

print(result.prompt);
```

### 3.6 Logging Control

Use separate log levels for Dart and native output when debugging:

```dart
import 'package:llamadart/llamadart.dart';

final engine = LlamaEngine(LlamaBackend());

// Dart-side logs (template routing, parser diagnostics, etc.)
await engine.setDartLogLevel(LlamaLogLevel.info);

// Native llama.cpp / ggml logs
await engine.setNativeLogLevel(LlamaLogLevel.warn);

// Convenience: set both at once
await engine.setLogLevel(LlamaLogLevel.none);
```

### 4. Multimodal Usage (Vision/Audio)

`llamadart` supports multimodal models (vision and audio) using `LlamaChatMessage.withContent`.

```dart
import 'package:llamadart/llamadart.dart';

void main() async {
  final engine = LlamaEngine(LlamaBackend());
  
  try {
    await engine.loadModel('vision-model.gguf');
    await engine.loadMultimodalProjector('mmproj.gguf');

    final session = ChatSession(engine);

    // Create a multimodal message
    final messages = [
      LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          LlamaImageContent(path: 'image.jpg'),
          LlamaTextContent('What is in this image?'),
        ],
      ),
    ];

    // Use stateless engine.create for one-off multimodal requests
    final response = engine.create(messages);
    await for (final chunk in response) {
      stdout.write(chunk.choices.first.delta.content ?? '');
    }
  } finally {
    await engine.dispose();
  }
}
```

Web-specific note:

- Load model/mmproj with URL-based assets (`loadModelFromUrl` + URL projector).
- For user-picked browser files, send media as bytes (`LlamaImageContent(bytes: ...)`,
  `LlamaAudioContent(bytes: ...)`) rather than local file paths.

### 💡 Model-Specific Notes

#### Moondream 2 & Phi-2
These models use a unique architecture where the Start-of-Sequence (BOS) and End-of-Sequence (EOS) tokens are identical. `llamadart` includes a specialized handler for these models that:
- **Disables Auto-BOS**: Prevents the model from stopping immediately upon generation.
- **Manual Templates**: Automatically applies the required `Question: / Answer:` format if the model metadata is missing a chat template.
- **Stop Sequences**: Injects `Question:` as a stop sequence to prevent rambling in multi-turn conversations.

---

## 🧹 Resource Management


Since `llamadart` allocates significant native memory and manages background worker Isolates/Threads, it is essential to manage its lifecycle correctly.

- **Explicit Disposal**: Always call `await engine.dispose()` when you are finished with an engine instance. 
- **Native Stability**: On mobile and desktop, failing to dispose can lead to "hanging" background processes or memory pressure.
- **Hot Restart Support**: In Flutter, placing the engine inside a `Provider` or `State` and calling `dispose()` in the appropriate lifecycle method ensures stability across Hot Restarts.

```dart
@override
void dispose() {
  _engine.dispose();
  super.dispose();
}
```

---

## 🎨 Low-Rank Adaptation (LoRA)

`llamadart` supports applying multiple LoRA adapters dynamically at runtime.

- **Dynamic Scaling**: Adjust the strength (`scale`) of each adapter on the fly.
- **Isolate-Safe**: Native adapters are managed in a background Isolate to prevent UI jank.
- **Efficient**: Multiple LoRAs share the memory of a single base model.

Check out our [LoRA Training Notebook](https://github.com/leehack/llamadart/blob/main/example/training_notebook/lora_training.ipynb) to learn how to train and convert your own adapters.

---

## 🧪 Testing & Quality

This project maintains a high standard of quality with **>=70% line coverage on maintainable `lib/` code** (auto-generated files marked with `// coverage:ignore-file` are excluded).

- **Multi-Platform Testing**: `dart test` runs VM and Chrome-compatible suites automatically.
- **Local-Only Scenarios**: Slow E2E tests are tagged `local-only` and skipped by default.
- **CI/CD**: Automatic analysis, linting, and cross-platform test execution on every PR.

```bash
# Run default test suite (VM + Chrome-compatible tests)
dart test

# Run local-only E2E scenarios
dart test --run-skipped -t local-only

# Run VM tests with coverage
dart test -p vm --coverage=coverage

# Format lcov for maintainable code (respects // coverage:ignore-file)
dart pub global run coverage:format_coverage --lcov --in=coverage/test --out=coverage/lcov.info --report-on=lib --check-ignore

# Enforce >=70% threshold
dart run tool/testing/check_lcov_threshold.dart coverage/lcov.info 70

# Benchmark embedding throughput (sequential vs batch)
dart run tool/testing/native_embedding_benchmark.dart --model path/to/model.gguf --cpu --mode both --input-count 8 --max-seq 8

# Sweep max-seq and export CSV for plotting
dart run tool/testing/native_embedding_sweep.dart --model path/to/model.gguf --cpu --max-seq-values 1,2,4,8 --csv-out embedding_speedup.csv
```

---

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](https://github.com/leehack/llamadart/blob/main/CONTRIBUTING.md) for architecture details and maintainer instructions for building native binaries.

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](https://github.com/leehack/llamadart/blob/main/LICENSE) file for details.
