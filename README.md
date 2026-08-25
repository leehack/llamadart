# llamadart

[![pub package](https://img.shields.io/pub/v/llamadart.svg)](https://pub.dev/packages/llamadart)
[![API docs](https://img.shields.io/badge/API-pub.dev-blue.svg)](https://pub.dev/documentation/llamadart/latest/)
[![Docs](https://img.shields.io/badge/docs-website-blue.svg)](https://llamadart.leehack.com/docs/intro)

Run local LLMs from Dart and Flutter with one API across native and web
runtimes. `llamadart` routes GGUF models through llama.cpp and `.litertlm`
models through LiteRT-LM.

## Start Here

| Need | Link |
| --- | --- |
| Install the package | [Installation](https://llamadart.leehack.com/docs/getting-started/installation) |
| Load a first model | [Quickstart](https://llamadart.leehack.com/docs/getting-started/quickstart) |
| Build chat history | [First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session) |
| Check runtime support | [Platform & backend matrix](https://llamadart.leehack.com/docs/platforms/support-matrix) |
| Read API reference | [pub.dev API docs](https://pub.dev/documentation/llamadart/latest/) |
| Try the Flutter demo | [Hosted chat app](https://llamadart.leehack.com/) |

## What It Supports

- GGUF model loading and generation through llama.cpp.
- `.litertlm` model loading and generation through LiteRT-LM.
- Native Dart and Flutter targets with downloaded runtime assets.
- Flutter Web through the experimental WebGPU bridge and LiteRT-LM web runtime.
- Streaming chat completions, llama.cpp thinking budgets, tool-call parsing,
  multimodal GGUF projectors, structured JSON output, embeddings, LoRA, state
  persistence, and runtime diagnostics where the active backend supports them.
- Experimental typed speech recognition through `SpeechToTextEngine`:
  llama.cpp whole-file Qwen3-ASR on native and validated WebGPU bridge assets,
  plus worker-isolated, CPU-only native LiteRT-LM streaming ASR with bounded
  16 kHz PCM input and partial transcripts.
- Experimental typed Qwen3-TTS synthesis on native llama.cpp through
  `TextToSpeechEngine`, returning complete PCM with WAV encoding.

Unsupported runtime/option combinations are rejected explicitly instead of
silently degrading. Check the support matrix before relying on a capability for
a specific model format or platform.

## Requirements

- Dart SDK `>=3.10.7`
- Flutter SDK `>=3.38.0` for Flutter apps
- iOS deployment target `16.4` or newer for Flutter iOS apps
- macOS deployment target `14.0` or newer for Flutter macOS apps

Consumers do not need a local C++ toolchain. Native runtime archives are
resolved by the package build hook on first build or run.

## Install

For Dart or Flutter apps:

```yaml
dependencies:
  llamadart: ^0.8.20
```

Flutter iOS/macOS apps that should link Apple XCFrameworks through Swift
Package Manager should also add the runtime companion packages they need:

```yaml
dependencies:
  llamadart: ^0.8.20
  llamadart_llama_cpp_flutter: ^0.0.16 # GGUF / llama.cpp
  llamadart_litert_lm_flutter: ^0.0.10 # Apple .litertlm / LiteRT-LM targets
```

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

## First Generation

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());

  try {
    await engine.loadModelSource(
      ModelSource.parse(
        'hf://unsloth/SmolLM2-135M-Instruct-GGUF/'
        'SmolLM2-135M-Instruct-Q2_K.gguf',
      ),
    );

    final output = StringBuffer();
    await for (final chunk in engine.create(
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Explain local inference in one sentence.',
        ),
      ],
      params: const GenerationParams(maxTokens: 48),
    )) {
      final text = chunk.choices.first.delta.content;
      if (text != null) {
        output.write(text);
      }
    }
    print(output.toString());
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
| Native llama.cpp / GGUF | `leehack/llamadart-native@v0.2.0-1` |
| Native LiteRT-LM / `.litertlm` | `leehack/litert-lm-native@v0.16.0-native.2` |
| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.1.37` |
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
| Generate embeddings | [Embeddings](https://llamadart.leehack.com/docs/guides/embeddings) |
| Load LoRA adapters | [LoRA adapters](https://llamadart.leehack.com/docs/guides/lora-adapters) |
| Save and restore KV state | [API levels](https://llamadart.leehack.com/docs/guides/api-levels) |
| Run Flutter Web / WebGPU | [WebGPU bridge](https://llamadart.leehack.com/docs/platforms/webgpu-bridge) |
| Tune performance | [Performance tuning](https://llamadart.leehack.com/docs/guides/performance-tuning) |

## Examples

- [Basic Dart CLI](https://github.com/leehack/llamadart/tree/main/example/basic_app)
- [Flutter chat app](https://github.com/leehack/llamadart/tree/main/example/chat_app)
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

## Contributing

Keep public behavior, examples, README, website docs, support matrices, and
changelog entries aligned. For non-trivial PRs, record the relevant testing
matrix rows and exact validation evidence in the PR body.

## License

MIT. See [LICENSE](https://github.com/leehack/llamadart/blob/main/LICENSE).
