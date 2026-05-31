# llamadart

[![Pub Version](https://img.shields.io/pub/v/llamadart?logo=dart&color=blue)](https://pub.dev/packages/llamadart)
[![codecov](https://codecov.io/gh/leehack/llamadart/graph/badge.svg?token=)](https://codecov.io/gh/leehack/llamadart)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)
[![GitHub](https://img.shields.io/github/stars/leehack/llamadart?style=social)](https://github.com/leehack/llamadart)

**llamadart** is a high-performance Dart and Flutter plugin for local LLMs. It
runs GGUF models through [llama.cpp](https://github.com/ggml-org/llama.cpp)
across native platforms and web (CPU/WebGPU bridge path), and routes
`.litertlm` bundles through LiteRT-LM native runtimes or the LiteRT-LM web
JavaScript runtime.

## 📚 Documentation

- Docs site: https://llamadart.leehack.com/
- API reference: https://pub.dev/documentation/llamadart/latest/
- Chat app demo: https://leehack-llamadart.static.hf.space
- Migration guide: [`MIGRATION.md`](https://github.com/leehack/llamadart/blob/main/MIGRATION.md)
- Backend selection guide: https://llamadart.leehack.com/docs/guides/backend-selection
- Backend benchmark results: https://llamadart.leehack.com/docs/guides/backend-benchmarks

## ✨ Features

- 🚀 **High Performance**: Powered by `llama.cpp` kernels and LiteRT-LM native
  and web runtimes.
- 🧩 **Model Format Routing**: `LlamaBackend()` loads GGUF models with
  llama.cpp and `.litertlm` bundles with LiteRT-LM on native and web targets.
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
  model sources with deterministic cache identities for download/cache workflows.
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
  llamadart: ^0.7.0
```

### 2. Run with defaults

On first `dart run` / `flutter run`, `llamadart` will:
1. Detect platform/architecture.
2. Download the matching native runtime bundles from [`leehack/llamadart-native`](https://github.com/leehack/llamadart-native) and [`leehack/litert-lm-native`](https://github.com/leehack/litert-lm-native).
3. Wire it into your app via native assets.

No manual binary download or C++ build steps are required.

> iOS builds require a minimum deployment target of `16.4` or newer in your
> Xcode project / Podfile (for example `platform :ios, '16.4'`).

### 3. Optional: choose native runtimes for package size

By default, native builds include both runtime families where available:

- `llama_cpp` for GGUF models.
- `litert_lm` for `.litertlm` model bundles.

Use `llamadart_native_runtimes` when an app only ships one model format and
you want to avoid bundling the other runtime family:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp] # or [litert_lm]
```

The setting also supports per-target overrides:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes:
        runtimes: [llama_cpp, litert_lm]
        platforms:
          android-arm64: [litert_lm]
          linux-x64: [llama_cpp]
```

### 4. Optional: choose llama.cpp backend modules per target

```yaml
hooks:
  user_defines:
    llamadart:
      # Optional. Defaults to llamadart's tested native runtime pin.
      # Use a leehack/llamadart-native release tag when testing another build.
      llamadart_native_tag: b9371

      # Optional. GitHub repository slug or github.com URL.
      llamadart_native_repository: leehack/llamadart-native

      # Optional. Takes precedence over GitHub downloads when set.
      # Relative paths are resolved from the pubspec defining this config.
      # llamadart_native_path: ./native-bundles

      llamadart_native_backends:
        platforms:
          android-arm64:
            backends: [vulkan] # opencl is opt-in
            cpu_profile: full # default: full; compact keeps baseline only
          linux-x64: [vulkan, cuda]
          windows-x64: [vulkan, cuda]
```

`llamadart_native_backends` only filters llama.cpp modules inside the
`llama_cpp` runtime family. It does not enable or disable LiteRT-LM. If a
requested module is unavailable for a target, `llamadart` logs a warning and
falls back to target defaults.

If `llamadart_native_tag` points at a release without a matching bundle asset,
the native-assets hook fails while downloading that asset.

Native source overrides are for compatibility testing. They do not regenerate
Dart FFI bindings or symbol lookups, so the selected binary still must be ABI-
and symbol-compatible with the default `leehack/llamadart-native@b9371` runtime.

Available native tags are published on the
[`leehack/llamadart-native` releases page](https://github.com/leehack/llamadart-native/releases).
You can also list them with the GitHub CLI:

```bash
gh release list --repo leehack/llamadart-native --limit 20
```

Before overriding, confirm the release includes the asset for your target. The
hook downloads files named `llamadart-native-<bundle>-<tag>.tar.gz`, for example
`llamadart-native-windows-x64-b9371.tar.gz`.
For local testing, `llamadart_native_path` may point directly at a bundle
archive, at an extracted bundle directory, or at a directory containing
`<tag>/<bundle>/`, `<bundle>/`, or the expected archive file.

### 5. Minimal first model load

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

For LiteRT-LM bundles, use the same high-level API and pass a `.litertlm`
path or URL. Native callers load local bundle paths; web callers load
web-compatible `.litertlm` URLs through the LiteRT-LM JavaScript runtime.
Android callers can opt into the LiteRT-LM NPU delegate through `ModelParams`:

Sandboxed macOS apps must stage LiteRT-LM companion dylibs inside the `.app`
bundle. The chat app example includes a `Prepare LiteRT-LM Frameworks` Xcode
build phase that copies the pinned LiteRT-LM runtime into
`Contents/Frameworks`. Standalone desktop VM tools also search the extracted
`.dart_tool/llamadart/litert_lm/<version>/<platform>/<arch>` cache; set
`LLAMADART_LITERT_LM_LIB_DIR` to that directory for custom CI or launcher
layouts.

```dart
await engine.loadModel(
  'path/to/gemma-4-E2B-it.litertlm',
  modelParams: const ModelParams(
    liteRtLmBackend: LiteRtLmBackendPreference.npu,
  ),
);
```

Chat templates for `.litertlm` bundles are resolved from a built-in,
filename-keyed registry (Gemma 4/3/3n and Qwen 2.5/3 are supported today). For
other models, or to override detection, pass `ModelParams.chatTemplate`. See
[LiteRT-LM chat templates](https://github.com/leehack/llamadart/blob/main/doc/litert_lm_templates.md)
for the template support matrix, real-model smoke commands, and how to add a
family.

### 6. Download and cache a remote model file

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
appended. Local `ModelSource.path(...)` values are already files: only
cancellation and optional `sha256` verification apply, while remote/download-only
options such as cache policies, `cacheDirectory`, authenticated headers, resume,
and retries are rejected for local paths.

`hf://` references point at one Hugging Face file, such as a `.gguf` model or
`.litertlm` LiteRT-LM bundle:
`hf://owner/repo/path/to/model.gguf` uses `main`,
`hf://owner/repo@v1.0.0/model.gguf` pins a simple tag/branch, and
`hf://owner/repo/model.gguf?revision=refs/pr/12` handles revisions containing
slashes. For private or gated repositories, pass `ModelLoadOptions(bearerToken:
hfToken)` or custom headers instead of embedding credentials in the source.
For LiteRT-LM bundles, use the same `loadModelSource(...)` path with a
`.litertlm` source and pass `ModelParams.liteRtLmBackend` when you need to pin
CPU, GPU, or Android NPU execution after the file is cached.
`llamadart` does not list Hugging Face files or expand sharded GGUF manifests;
pick the exact `.gguf` file path from the repository, and use separate model and
`mmproj` sources for multimodal assets.

### 7. Generate embeddings

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

| Target | Bundled llama.cpp runtime modules | Configurable in `pubspec.yaml` |
|--------|-----------------------------------|---------------------------------|
| android-arm64 / android-x64 | cpu, vulkan | yes |
| linux-arm64 / linux-x64 | cpu, vulkan | yes |
| windows-arm64 / windows-x64 | cpu, vulkan | yes |
| macos-arm64 / macos-x86_64 | consolidated cpu + Metal runtime | no |
| ios-arm64 / ios simulators | consolidated cpu + Metal runtime | no |
| web | WebGPU/CPU bridge router for GGUF; LiteRT-LM JS for `.litertlm` URLs | n/a |

`.gguf` models use the llama.cpp runtime matrix above. Native `.litertlm`
models use the LiteRT-LM runtime bundles from `litert-lm-native`; the current
FFI path is validated on Android, iOS, macOS, Linux, and Windows. Web
`.litertlm` URLs route to the official `@litert-lm/core` JavaScript runtime,
which is an early-preview text-in/text-out API and currently supports
web-compatible Gemma 4 LiteRT-LM model variants. iOS LiteRT-LM bundles are
derived from upstream `CLiteRTLM.xcframework` slices, embedded as app
frameworks, and loaded by their absolute bundle path for device and simulator
builds. Native LiteRT-LM
generation works through the same high-level `LlamaEngine` and `ChatSession`
APIs, including native tokenization and detokenization for exact token counts.
On native targets, thinking and tool-call parsing run through the same
high-level template parser for compatible models, but llama.cpp-style GBNF
grammar constraints are not applied to `.litertlm` generation. LiteRT-LM web is
currently limited to single-turn text prompts through `@litert-lm/core`; it does
not yet preserve structured chat history, system prompts, tool declarations, or
thinking/tool-call parsing with the same semantics as native. The current
implementation does not expose embeddings, state persistence, LoRA, or
multimodal operations through LiteRT-LM. `ChatSession` uses a conservative
prompt-size estimate for history pruning only when exact tokenization is
unavailable.
`LiteRtLmBackendPreference.auto` chooses GPU on Android/macOS/web and CPU on
other current LiteRT-LM targets; set `cpu`, `gpu`, or Android-only `npu`
explicitly when benchmarking or pinning deployment behavior.
`ModelParams.contextSize`, `chatTemplate`, `preferredBackend`,
`liteRtLmBackend`, and all-or-CPU `gpuLayers` hints are honored for
`.litertlm` loads; llama.cpp-only tuning knobs such as partial GPU layer
offload, batch/micro-batch sizing, KV-cache type, flash attention, mmap/mlock,
thread counts, LoRA load configs, and rope overrides are rejected instead of
being silently ignored. `.litertlm` generation honors `GenerationParams`
`maxTokens`, `temp`, `topK`, `topP`, and `seed` on native and web, with
`stopSequences` enforced by llamadart. Native LiteRT-LM also honors stream
batching thresholds. llama.cpp-only sampling and constrained-decoding controls
such as Min-P, repeat penalty overrides, grammar/lazy grammar triggers,
preserved tokens, custom grammar roots, and web stream batching thresholds are
rejected until LiteRT-LM exposes equivalent runtime controls.

<details>
<summary>Full module matrix (available modules by target)</summary>

Available llama.cpp module matrix from the default native tag `b9371`:

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

Recognized split-module names for `llamadart_native_backends`:

- `vulkan`
- `cpu`
- `opencl`
- `cuda`
- `blas`
- `hip`

Accepted aliases:

- `vk` -> `vulkan`
- `ocl` -> `opencl`
- `open-cl` -> `opencl`

`llamadart_native_backends` only filters split llama.cpp modules on configurable
Android, Linux, and Windows bundles. Apple Metal is selected at runtime through
`GpuBackend.metal` or `ModelParams.preferredBackend`; it is not a build-hook
module selector.

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

- Module availability depends on the selected native release bundle and may
  change when the native tag updates. Available tags are listed in
  [`leehack/llamadart-native` releases](https://github.com/leehack/llamadart-native/releases).
  The selected release must include `llamadart-native-<bundle>-<tag>.tar.gz`
  for the target being built.
- Native source overrides do not regenerate Dart FFI bindings or symbol
  lookups, so the selected binary must remain compatible with the default
  runtime revision.
- `llamadart_native_runtimes` controls whole native runtime families:
  `llama_cpp`, `litert_lm`, or both. Use it to trim package size when an app
  only ships GGUF or only ships `.litertlm` models.
- `llamadart_native_backends` controls llama.cpp module files inside the
  `llama_cpp` runtime family. It does not affect LiteRT-LM assets.
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
- `ModelParams.preferMemory64` and `ModelParams.modelBytesHint` are web/WebGPU only (ignored on native). They select the 64-bit (wasm64/mem64) bridge core so models larger than the ~4 GiB wasm32 address space (for example Gemma 4 E2B) can load; `null` auto-decides from the size hint (size-driven, no hardcoded model names). See the [WebGPU bridge docs](https://leehack.github.io/llamadart/docs/platforms/webgpu-bridge).
- Apple targets are intentionally non-configurable in this hook path and use consolidated native libraries.
- The native-assets hook refreshes emitted files each build; if you change `hooks.user_defines` or are upgrading from older cached outputs, run `flutter clean && flutter pub get` before rebuilding.
- Some Vulkan drivers can crash when probing cooperative matrix support. This
  is a driver-side failure in the Vulkan property query path, not a llamadart
  loader failure. Use upstream ggml-vulkan's opt-out environment variables
  before starting the process:
  `GGML_VK_DISABLE_COOPMAT=1` and `GGML_VK_DISABLE_COOPMAT2=1`.

If you change `llamadart_native_tag`, `llamadart_native_repository`,
`llamadart_native_path`, `llamadart_native_runtimes`, or
`llamadart_native_backends`, run `flutter clean` once so stale native-asset
outputs do not override new bundle selection.

---

## 🌐 Web Backend Notes (Router)

The default web backend routes `.gguf` URLs to `WebGpuLlamaBackend` and
`.litertlm` URLs to `LiteRtLmBackend`.

- Web mode is currently experimental and depends on an external JS bridge runtime.
- Bridge API contract: [WebGPU bridge contract](https://github.com/leehack/llamadart/blob/main/doc/webgpu_bridge.md).
- Runtime assets are published via:
  - [`leehack/llama-web-bridge`](https://github.com/leehack/llama-web-bridge)
  - [`leehack/llama-web-bridge-assets`](https://github.com/leehack/llama-web-bridge-assets)
- `example/chat_app` prefers vendored local bridge assets on localhost for dev/runtime validation, and otherwise prefers pinned jsDelivr assets with local fallback.
- Web embeddings require bridge assets with embedding APIs (`v0.1.7` or newer).
- Browser Cache Storage is used for repeated model loads when `useCache` is enabled (default). Signed or credentialed model URLs bypass persistent cache storage and load directly so secret-bearing URL parts are not stored as browser cache request keys.
- `loadMultimodalProjector` is supported on web for URL-based model/mmproj assets.
- `supportsVision` and `supportsAudio` reflect loaded projector capabilities.
- LoRA runtime adapters are not currently supported on web.
- `setLogLevel` / `setNativeLogLevel` changes take effect on next model load.
- LiteRT-LM web requires preloading `@litert-lm/core` and exposing
  `window.LiteRtLmEngine = module.Engine`, or setting
  `window.__llamadartLiteRtLmModuleUrl` to an `@litert-lm/core` ESM URL before
  loading a `.litertlm` model.
- LiteRT-LM web currently supports URL/path loading, single-turn text
  generation, CPU/GPU selection, and stop sequences. It does not yet preserve
  `ChatSession` history, system prompts, tool declarations, thinking parsing, or
  tool-call parsing through `@litert-lm/core`. Tokenizer APIs, embeddings, state
  persistence, LoRA, grammar, multimodal, and NPU selection remain unsupported
  on web.

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
- LiteRT-LM native runtime release:
  [`leehack/litert-lm-native`](https://github.com/leehack/litert-lm-native)
- Web bridge source/build:
  [`leehack/llama-web-bridge`](https://github.com/leehack/llama-web-bridge)
- Web bridge runtime assets:
  [`leehack/llama-web-bridge-assets`](https://github.com/leehack/llama-web-bridge-assets)
- This repository consumes pinned published artifacts from those repositories.

Current pinned runtime artifacts:

| Runtime path | Published artifact |
|--------------|--------------------|
| Native llama.cpp / GGUF | `leehack/llamadart-native@b9371` |
| Native LiteRT-LM / `.litertlm` | `leehack/litert-lm-native@v0.12.0` |
| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.1.16` |
| Web LiteRT-LM / `.litertlm` | App-provided `@litert-lm/core` module URL; the chat app defaults to jsDelivr `@litert-lm/core/+esm` |

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
- **Contributor Matrix**: `tool/testing/test_matrix.dart` lists essential,
  targeted, and release validation rows for PR evidence.
- **Local-Only Scenarios**: Slow E2E tests are tagged `local-only` and skipped by default; use `tool/testing/run_local_e2e.dart` to discover the root Dart, Flutter device, and Web smoke commands.
- **CI/CD**: Automatic analysis, linting, and cross-platform test execution on every PR.

```bash
# Run default test suite (VM + Chrome-compatible tests)
dart test

# Discover local-only E2E scenarios
dart run tool/testing/run_local_e2e.dart --list

# Print the PR validation matrix and evidence table
dart run tool/testing/test_matrix.dart --list
dart run tool/testing/test_matrix.dart --pr-template
dart run tool/testing/test_matrix.dart --tier platform

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
