# llamadart

[![pub package](https://img.shields.io/pub/v/llamadart.svg)](https://pub.dev/packages/llamadart)
[![API docs](https://img.shields.io/badge/API-pub.dev-blue.svg)](https://pub.dev/documentation/llamadart/latest/)
[![Docs](https://img.shields.io/badge/docs-website-blue.svg)](https://llamadart.leehack.com/docs/intro)

Cross-platform, on-device LLM inference for Dart and Flutter. One API runs
models on Android, iOS, macOS, Windows, Linux, and the web, so your app needs
no inference server. GGUF models run through llama.cpp and `.litertlm` models
through LiteRT-LM, whose platform coverage is narrower. Native targets run
offline once the model is on the device; web support is experimental.

llama.cpp uses Metal on Apple platforms, Vulkan on Android, Linux, and Windows,
and WebGPU in the browser. LiteRT-LM can also use GPU and, on compatible
Android deployments, NPU. See the
[support matrix](https://llamadart.leehack.com/docs/platforms/support-matrix)
for each target.

## Start Here

| Need | Link |
| --- | --- |
| Install the package | [Installation](https://llamadart.leehack.com/docs/getting-started/installation) |
| Load a first model | [Quickstart](https://llamadart.leehack.com/docs/getting-started/quickstart) |
| Build chat history | [First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session) |
| Check runtime support | [Platform & backend matrix](https://llamadart.leehack.com/docs/platforms/support-matrix) |
| Read API reference | [pub.dev API docs](https://pub.dev/documentation/llamadart/latest/) |
| Try the Flutter demo | [Hosted chat app](https://leehack-llamadart.static.hf.space) |
| Generate images on device (Preview) | [Image generation](https://llamadart.leehack.com/docs/guides/image-generation) |

## What It Supports

- GGUF model loading and generation through llama.cpp.
- `.litertlm` model loading and generation through LiteRT-LM.
- Native Dart and Flutter targets with downloaded runtime assets.
- Flutter Web through the experimental WebGPU bridge and LiteRT-LM web runtime.
  WebGPU `ToolChoice.auto` skips lazy tool-call grammars; tool calls are best-effort.
- Streaming chat completions, llama.cpp thinking budgets, tool-call parsing
  and a `ChatSession.sendWithTools` loop that runs tool handlers,
  multimodal GGUF projectors, structured JSON output, embeddings, next-token
  log-probabilities, LoRA, state persistence, per-request token usage and
  timings, operation observers for tracing and metrics, and runtime
  diagnostics where the active backend supports them.
- Experimental typed speech recognition through `SpeechToTextEngine.load`
  or `attach`, with a model adapter: llama.cpp whole-file Qwen3-ASR
  (`Qwen3AsrAdapter`, validated up to 30 seconds per input) on native and
  validated WebGPU bridge assets, your own `SpeechToTextPromptAdapter` for
  other audio chat models, plus worker-isolated, CPU-only native LiteRT-LM
  streaming ASR (`LiteRtLmAsrAdapter`) with bounded 16 kHz PCM input and
  partial transcripts.
- Experimental typed Qwen3-TTS synthesis on native llama.cpp and WebGPU
  bridge assets through `TextToSpeechEngine.load` or `attach`
  (`Qwen3TtsAdapter`), returning complete PCM with WAV encoding.
- **Preview:** on-device text-to-image generation through
  `ImageGenerationEngine` on native targets; see
  [Image generation (Preview)](#image-generation-preview).
- Experimental Laya-style decision models on native llama.cpp through
  `DecisionEngine`: typed choice, score, and yes/no answers from a ModernBERT
  encoder GGUF and a safetensors head, one encoder pass per question; validated
  on macOS (Metal, CPU), other native platforms untested. Web runs it through
  WebGPU bridge assets `v0.1.47+`, which the default Web pin includes; checked
  only in headless Chromium on macOS.

Unsupported runtime/option combinations are rejected explicitly instead of
silently degrading. Check the support matrix before relying on a capability for
a specific model format or platform. After a model loads, `engine.runtime`
names the runtime (`llamaCpp` or `liteRtLm`) and `await engine.capabilities`
reports what it supports: image and audio input, embeddings, multi-turn chat,
tools, structured output and grammars, each sampling control
(`penalty`, `presencePenalty`, `minP`, `thinkingBudget`), and the speculative
decoding strategies it runs. Branch on these instead of the model's file
extension or backend name.

## Image generation (Preview)

`ImageGenerationEngine` turns a text prompt into PNG images on the device
through [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp),
with progress events and cancellation. It is a Preview: the API is
experimental and may change, and the runtime is opt-in.

- **Opt in** to the runtime (about 40 to 70 MB per target) in the app's
  `pubspec.yaml`, then run `flutter clean` once:

  ```yaml
  hooks:
    user_defines:
      llamadart:
        llamadart_native_runtimes: [llama_cpp, stable_diffusion]
  ```

  Keep `litert_lm` in the list if the app also loads `.litertlm` models.

- **Flutter iOS/macOS apps** should add the
  `llamadart_stable_diffusion_flutter` companion (see [Install](#install)),
  which links the runtime through Swift Package Manager and selects it without
  the entry above. It needs core `0.10.0` or newer. Without it the hook
  bundles the runtime, App Store Connect rejects that iOS framework's
  `MinimumOSVersion`, and only Xcode and `xcodebuild` show the build warning
  about it.

- **Platforms:** Android arm64 (CPU), iOS and macOS (Metal), Linux arm64/x64
  and Windows x64 (CPU or Vulkan). Not available on the web yet
  ([#780](https://github.com/leehack/llamadart/issues/780)).
- **Validated:** SDXS and SD-Turbo with real models on macOS, iOS, Android,
  Linux x64 and Windows x64
  ([#779](https://github.com/leehack/llamadart/issues/779)). The
  SDXL-Lightning, FLUX.1-schnell, SD 3.5 Large Turbo and Z-Image-Turbo
  desktop models generate 1024x1024 images and are validated on
  macOS Metal only ([#802](https://github.com/leehack/llamadart/issues/802)).
- **Model licenses differ**, including for commercial use. Check each
  model's license before shipping it; the guide lists each model's license.

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  // Downloads SDXS (683 MB) into the model cache once.
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(
      ModelSource.parse(
        'hf://concedo/sdxs-512-tinySDdistilled-GGUF@'
        '3144d898d61492f8382ffcabec055733fc5b2a0e/'
        'sdxs-512-tinySDdistilled_Q8_0.gguf',
      ),
    ),
    onProgress: (progress) => print('${progress.receivedBytes} bytes'),
  );
  try {
    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        steps: 1,
        guidanceScale: 1,
      ),
    );
    await File('fox.png').writeAsBytes(result.images.first.toPng());
  } finally {
    await engine.dispose();
  }
}
```

A split model lists its other files as `components`, in any order: the
engine downloads each `ModelSource` (local path, URL or `hf://`) like
`LlamaEngine.load` and gives it its role from its header. See the
[image generation guide](https://llamadart.leehack.com/docs/guides/image-generation)
for the files and settings of each validated model, download options, memory
checks and known limits.

## Requirements

- Dart SDK `>=3.10.7`
- Flutter SDK `>=3.38.0` for Flutter apps
- iOS deployment target `16.4` or newer for Flutter iOS apps
- macOS deployment target `14.0` or newer for Flutter macOS apps
- Windows: the latest Microsoft Visual C++ v14 Redistributable for the app's
  architecture (x64 or arm64) on every machine that runs it, at least as new
  as the build tools of the bundled DLLs; stock Windows Server lacks it

Consumers do not need a local C++ toolchain. Native runtime archives are
resolved by the package build hook on first build or run.

## Install

For Dart or Flutter apps:

```yaml
dependencies:
  llamadart: ^0.10.0
```

Flutter iOS/macOS apps that should link Apple XCFrameworks through Swift
Package Manager should also add the runtime companion packages they need:

Pair companion `0.0.20` with core `0.10.0` for matching llama.cpp v0.5.0
bindings. Keep core `0.8.23` paired with companion `0.0.18`, and core `0.8.22`
paired with companion `0.0.17`.

Apple builds verify the resolved companion's SwiftPM runtime pin before native
symbol lookup. Incompatible companions or unverified local `Artifacts`
overrides fail the build; resolve the matching companion and rerun
`flutter pub get`. Core native overrides do not replace SPM frameworks.

```yaml
dependencies:
  llamadart: ^0.10.0
  llamadart_llama_cpp_flutter: ^0.0.20 # GGUF / llama.cpp
  llamadart_litert_lm_flutter: ^0.0.12 # Apple .litertlm / LiteRT-LM targets
  llamadart_stable_diffusion_flutter: ^0.0.1 # Apple image generation, opt-in
```

Pair `llamadart_stable_diffusion_flutter` `0.0.1` with core `0.10.0` or
newer; older cores, including `0.9.x`, ignore it. Adding it opts iOS and macOS
builds into the image generation runtime (about 37 MB per Apple target), so
leave it out unless the app uses `ImageGenerationEngine`.

The LiteRT-LM companion manifest includes the complete iOS SwiftPM runtime
targets. Llamadart uses that SwiftPM path for iOS; Flutter macOS LiteRT-LM
builds keep the core package's native-assets fallback because the hook path is
responsible for the complete runtime library set.

The pinned LiteRT-LM runtime supports arm64 iOS devices and arm64 iOS
Simulator builds. Intel/x86_64 iOS Simulator builds are not published.

Then run:

```bash
dart pub get
# or
flutter pub get
```

### AI agent skills

llamadart ships [agent skills](https://dart.dev/tools/pub/package-skills) that
teach coding agents its APIs. Install them into your agent's skills directory
from your app's root:

```bash
dart run skills@ get
```

## First Generation

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = await LlamaEngine.load(
    LlamaModel(
      ModelSource.parse(
        'hf://unsloth/SmolLM2-135M-Instruct-GGUF/'
        'SmolLM2-135M-Instruct-Q2_K.gguf',
      ),
    ),
  );

  try {
    final reply = await engine.create(
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Explain local inference in one sentence.',
        ),
      ],
      params: const GenerationParams(maxTokens: 48),
    ).text();
    print(reply);
  } finally {
    await engine.dispose();
  }
}
```

For multi-turn chat, wrap the same engine in `ChatSession` and let it maintain
history:
[First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session).

## Choosing a Runtime

| Model format | Typical use | Runtime |
| --- | --- | --- |
| GGUF | Broad llama.cpp compatibility, Metal/Vulkan/CUDA/CPU, WebGPU bridge | llama.cpp |
| `.litertlm` | LiteRT-LM deployments, Android GPU/NPU-oriented bundles, Gemma-family LiteRT packages | LiteRT-LM |

`LlamaBackend()` routes by model file type. Use `ModelParams` for load-time
controls such as context size, GPU layers, backend preference, LiteRT-LM backend
selection, and WebGPU mem64 hints. See
[Runtime Parameters](https://llamadart.leehack.com/docs/configuration/runtime-parameters)
for the full list.

Current default runtime pins:

| Runtime | Pin |
| --- | --- |
| Native llama.cpp / GGUF | `leehack/llamadart-native@v0.5.0` |
| Native LiteRT-LM / `.litertlm` | `leehack/litert-lm-native@v0.17.0-6` |
| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.1.54` |
| Web LiteRT-LM / `.litertlm` | `@litert-lm/core@0.15.0` |

Native overrides accept stable `vMAJOR.MINOR.PATCH` releases and preserve
explicit access to historical/nightly `bNNNN` artifacts. New nightly wrapper
rebuilds use `bNNNN-N`; existing `bNNNN-llamadart.N` artifacts remain valid
consumption-only overrides. Stable wrapper-only rebuilds of upstream `vM.m.p`
use `vM.m.p-N`, preserving the exact upstream prefix. Native release policy
treats each `-N` suffix as a forward wrapper rebuild even where generic SemVer
ordering differs. New wrapper and nightly releases are GitHub prereleases and
must be selected explicitly. Immutable historical `bNNNN` and
`bNNNN-llamadart.N` artifacts may retain older `prerelease=false` metadata, but
remain explicit compatibility inputs. Build-hook overrides must always name an
explicit tag; `latest` is limited to maintainer synchronization and
header/binding regeneration, where it accepts only an unsuffixed stable tag
regardless of GitHub metadata. Nightly cores use canonical decimal spelling
(`b0` or a nonzero first digit), and rebuild counters start at 1 without leading
zeros. The default pin above changes only after the matching artifacts,
bindings, runtime behavior, and docs have been validated together.

## Common Tasks

| Task | Docs |
| --- | --- |
| Resolve local paths, URLs, and Hugging Face sources | [Finding models](https://llamadart.leehack.com/docs/getting-started/finding-models) |
| Pick native/Web/LiteRT backends | [Backend selection](https://llamadart.leehack.com/docs/guides/backend-selection) |
| Stream text and collect output | [Generation and streaming](https://llamadart.leehack.com/docs/guides/generation-and-streaming) |
| Generate typed JSON | [Structured output](https://llamadart.leehack.com/docs/guides/generation-and-streaming#structured-json-output) |
| Use tool calling | [Tool calling](https://llamadart.leehack.com/docs/guides/tool-calling) |
| Use images, audio, or projectors | [Multimodal](https://llamadart.leehack.com/docs/guides/multimodal) |
| Transcribe speech on device | [Speech to text](https://llamadart.leehack.com/docs/guides/speech-to-text) |
| Synthesize speech on device | [Text to speech](https://llamadart.leehack.com/docs/guides/text-to-speech) |
| Generate images on device | [Image generation](https://llamadart.leehack.com/docs/guides/image-generation) |
| Answer typed questions with a decision model | [Decision models](https://llamadart.leehack.com/docs/guides/decision-models) |
| Generate embeddings | [Embeddings](https://llamadart.leehack.com/docs/guides/embeddings) |
| Score next-token log-probabilities | [Next-token scores](https://llamadart.leehack.com/docs/guides/generation-and-streaming#next-token-scores) |
| Load LoRA adapters | [LoRA adapters](https://llamadart.leehack.com/docs/guides/lora-adapters) |
| Save and restore KV state | [API levels](https://llamadart.leehack.com/docs/guides/api-levels) |
| Write a custom backend or test fake (`package:llamadart/backend.dart`) | [API levels](https://llamadart.leehack.com/docs/guides/api-levels#entrypoints) |
| Run Flutter Web / WebGPU | [WebGPU bridge](https://llamadart.leehack.com/docs/platforms/webgpu-bridge) |
| Tune performance | [Performance tuning](https://llamadart.leehack.com/docs/guides/performance-tuning) |

## Examples

- [Basic Dart CLI](https://github.com/leehack/llamadart/tree/main/example/basic_app)
- [Flutter chat app](https://github.com/leehack/llamadart/tree/main/example/chat_app)
- [Laya Tetris, a Flutter game played by a decision model](https://github.com/leehack/llamadart/tree/main/example/laya_tetris)
- [HTTP server example](https://github.com/leehack/llamadart/tree/main/example/llamadart_server)
- [TUI coding agent example](https://github.com/leehack/llamadart/tree/main/example/tui_coding_agent)

## Validate Changes

For package changes:

Use the Flutter SDK pinned in `.flutter-version` (`3.47.1`), the same version
CI installs, for repository-wide quality gates. Older Dart formatters produce
different source layouts.

```bash
dart run tool/prepare_workspace.dart
dart format --output=none --set-exit-if-changed .
dart analyze
dart test -p vm -j 1 --exclude-tags local-only
dart test -p chrome --exclude-tags local-only
```

For docs changes:

```bash
dart run tool/testing/verify_release_docs_versions.dart
./tool/docs/build_site.sh
./tool/docs/validate_links.sh
```

For heavier local model checks, list the discoverable scenarios:

```bash
dart run tool/testing/run_local_e2e.dart --list
dart run tool/testing/test_matrix.dart --list
```

## Observability

Use optional engine observers for tracing and metrics without adding an OTel
dependency to core. The [observability guide](https://llamadart.leehack.com/docs/guides/observability)
includes a runnable OpenTelemetry adapter and Langfuse/Grafana recipes.

## Contributing

Keep public behavior, examples, README, website docs, support matrices, and
changelog entries aligned. For non-trivial PRs, record the relevant testing
matrix rows and exact validation evidence in the PR body.

## License

MIT. See [LICENSE](https://github.com/leehack/llamadart/blob/main/LICENSE).
