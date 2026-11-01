# llamadart

[![pub package](https://img.shields.io/pub/v/llamadart.svg)](https://pub.dev/packages/llamadart)
[![API docs](https://img.shields.io/badge/API-pub.dev-blue.svg)](https://pub.dev/documentation/llamadart/latest/)
[![Docs](https://img.shields.io/badge/docs-website-blue.svg)](https://llamadart.leehack.com/docs/intro)

`llamadart` is a Dart package for on-device inference. It runs GGUF models
through `llama.cpp` and `.litertlm` bundles through LiteRT-LM, on Android, iOS,
macOS, Linux, Windows and the web, behind one Dart API. Web support is
experimental. Native targets need no network once the model is on the device.

- Streaming chat and text generation, with structured JSON output.
- Tool calling driven by the model's chat template.
- Embeddings, reranking, and image and audio input with multimodal models.
- Speech to text, text to speech, and decision models.
- Image generation from text prompts on native platforms (Preview).
- Runtime LoRA adapters, observability hooks and typed capability checks.

Choose [direct llamadart, Genkit, or Flutter Edge AI](https://llamadart.leehack.com/docs/integrations/choosing-an-api)
for your application. Genkit is a
[separate package](https://github.com/leehack/llamadart/tree/main/packages/genkit_llamadart);
the Flutter Edge AI connector is owned upstream and pins its own llamadart
version.

## Install

```yaml
dependencies:
  llamadart: ^0.17.2
```

```bash
dart pub get
# or
flutter pub get
```

Requirements: Dart SDK `>=3.10.7`; for Flutter apps, Flutter SDK `>=3.38.0`,
iOS deployment target `16.4` and macOS deployment target `14.0` or newer.
Consumers need no local C++ toolchain: the package build hook resolves native
runtime archives on first build or run. Windows and other per-platform notes:
[Installation](https://llamadart.leehack.com/docs/getting-started/installation).

Flutter iOS and macOS apps that link the Apple XCFrameworks through Swift
Package Manager add the companion packages for the runtimes they use. A
companion shares its core's `MAJOR.MINOR` and constrains `llamadart` to it.

```yaml
dependencies:
  llamadart: ^0.17.2
  llamadart_llama_cpp_flutter: ^0.17.1 # GGUF / llama.cpp
  llamadart_litert_lm_flutter: ^0.17.1 # Apple .litertlm / LiteRT-LM targets
  llamadart_stable_diffusion_flutter: ^0.17.1 # Apple image generation, opt-in
```

Pairing rules, the SwiftPM bootstrap and the privacy manifest are in
[Installation](https://llamadart.leehack.com/docs/getting-started/installation) and
[Apple setup](https://llamadart.leehack.com/docs/platforms/apple-setup).
Web apps run `dart run llamadart:web_setup` once; see the
[WebGPU bridge](https://llamadart.leehack.com/docs/platforms/webgpu-bridge).

llamadart also ships [agent skills](https://dart.dev/tools/pub/package-skills)
that teach coding agents its APIs. Install them from your app's root:

```bash
dart run skills@ get
```

To check a desktop setup without a model, run `dart run llamadart:doctor`; see
[setup report scope](https://llamadart.leehack.com/docs/platforms/diagnose-setup#desktop-setup-report).

## First generation

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

Dispose every engine before a native host calls C `exit()`; see
[Model lifecycle](https://llamadart.leehack.com/docs/guides/model-lifecycle). For multi-turn chat, wrap the
engine in `ChatSession`:
[First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session).

## Runtimes and platforms

`LlamaBackend()` routes by model file type. After a model loads,
`engine.runtime` names the runtime and `await engine.capabilities` reports what
it supports, so branch on those instead of the file extension. Unsupported
runtime and option combinations are rejected with `LlamaUnsupportedException`
instead of silently degrading.

| Model format | Typical use | Runtime |
| --- | --- | --- |
| GGUF | Broad llama.cpp compatibility, Metal/Vulkan/CUDA/CPU, WebGPU bridge | llama.cpp |
| `.litertlm` | LiteRT-LM deployments, Android GPU/NPU-oriented bundles, Gemma-family LiteRT packages | LiteRT-LM |

llama.cpp uses Metal on Apple platforms, Vulkan on Linux and Windows, and
WebGPU in the browser. Android Vulkan is experimental and opt-in. LiteRT-LM
can also use GPU and, on compatible Android deployments, NPU. Image generation
is not available on the web. Per-target support, device limitations and
runtime options:

- [Platform and backend support matrix](https://llamadart.leehack.com/docs/platforms/support-matrix), including
  [known limitations](https://llamadart.leehack.com/docs/platforms/known-platform-issues)
- [Backend selection](https://llamadart.leehack.com/docs/guides/backend-selection)
- [Runtime parameters](https://llamadart.leehack.com/docs/configuration/runtime-parameters)
- [Native runtime configuration](https://llamadart.leehack.com/docs/platforms/native-build-hooks)

Current default runtime pins:

| Runtime | Pin |
| --- | --- |
| Native llama.cpp / GGUF | `leehack/llamadart-native@v0.8.0-1` |
| Native LiteRT-LM / `.litertlm` | `leehack/litert-lm-native@v0.18.1-4` |
| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.1.79` |
| Web LiteRT-LM / `.litertlm` | `@litert-lm/core@0.18.0` |

Native overrides accept stable `vMAJOR.MINOR.PATCH` releases and explicit
historical or nightly `bNNNN` artifacts. New nightly wrapper rebuilds use
`bNNNN-N`; existing `bNNNN-llamadart.N` artifacts stay valid as
consumption-only overrides. Nightly cores use canonical decimal spelling, and
rebuild counters start at 1 without leading zeros. Build-hook overrides must
always name an explicit tag; `latest` is limited to maintainer synchronization
and header/binding regeneration. On Windows, runtime environment directory
overrides select backend modules; use `llamadart_native_path` to replace the
complete runtime. The full override rules are in [Native runtime configuration](https://llamadart.leehack.com/docs/platforms/native-build-hooks#override-the-llamacpp-release).

## Guides

| Task | Docs |
| --- | --- |
| Resolve local paths, URLs, and Hugging Face sources | [Finding models](https://llamadart.leehack.com/docs/getting-started/finding-models) |
| Stream text and collect output | [Generation and streaming](https://llamadart.leehack.com/docs/guides/generation-and-streaming) |
| Generate typed JSON | [Structured output](https://llamadart.leehack.com/docs/guides/generation-and-streaming#structured-json-output) |
| Use tool calling | [Tool calling](https://llamadart.leehack.com/docs/guides/tool-calling) |
| Use images, audio, or projectors | [Multimodal](https://llamadart.leehack.com/docs/guides/multimodal) |
| Transcribe speech on device | [Speech to text](https://llamadart.leehack.com/docs/guides/speech-to-text) |
| Synthesize speech on device | [Text to speech](https://llamadart.leehack.com/docs/guides/text-to-speech) |
| Generate images on device (Preview) | [Image generation](https://llamadart.leehack.com/docs/guides/image-generation) |
| Answer typed questions with a decision model | [Decision models](https://llamadart.leehack.com/docs/guides/decision-models) |
| Generate embeddings and rerank | [Embeddings](https://llamadart.leehack.com/docs/guides/embeddings) |
| Load LoRA adapters | [LoRA adapters](https://llamadart.leehack.com/docs/guides/lora-adapters) |
| Save and restore KV state, write a custom backend | [API levels](https://llamadart.leehack.com/docs/guides/api-levels) |
| Trace and measure requests | [Observability](https://llamadart.leehack.com/docs/guides/observability) |
| Run Flutter Web / WebGPU | [WebGPU bridge](https://llamadart.leehack.com/docs/platforms/webgpu-bridge) |
| Tune performance | [Performance tuning](https://llamadart.leehack.com/docs/guides/performance-tuning) |
| Upgrade from 0.16.x | [0.17 migration guide](https://llamadart.leehack.com/docs/migration/upgrade-to-0-17) |

## Examples

Run the Flutter chat app from a
[repository checkout](https://github.com/leehack/llamadart/tree/main/example/chat_app),
or try the [hosted chat app](https://leehack-llamadart.static.hf.space).

- [Basic Dart CLI](https://github.com/leehack/llamadart/tree/main/example/basic_app)
- [Flutter chat app](https://github.com/leehack/llamadart/tree/main/example/chat_app)
- [Laya Tetris, a Flutter game played by a decision model](https://github.com/leehack/llamadart/tree/main/example/laya_tetris)
- [HTTP server example](https://github.com/leehack/llamadart/tree/main/example/llamadart_server)
- [TUI coding agent example](https://github.com/leehack/llamadart/tree/main/example/tui_coding_agent)

## Contributing

Repository checks, validation commands, and PR expectations are in
[AGENTS.md](https://github.com/leehack/llamadart/blob/main/AGENTS.md) and the
[maintainer docs](https://llamadart.leehack.com/docs/maintainers/docs-site#validating-changes).

## License

MIT. See [LICENSE](https://github.com/leehack/llamadart/blob/main/LICENSE).
