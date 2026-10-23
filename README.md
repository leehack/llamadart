# llamadart

[![pub package](https://img.shields.io/pub/v/llamadart.svg)](https://pub.dev/packages/llamadart)
[![API docs](https://img.shields.io/badge/API-pub.dev-blue.svg)](https://pub.dev/documentation/llamadart/latest/)
[![Docs](https://img.shields.io/badge/docs-website-blue.svg)](https://llamadart.leehack.com/docs/intro)

Cross-platform, on-device LLM inference for Dart and Flutter. One API runs
models on Android, iOS, macOS, Windows, Linux, and the web, so your app needs
no inference server. GGUF models run through llama.cpp and `.litertlm` models
through LiteRT-LM, whose platform coverage is narrower. Native targets run
offline once the model is on the device; web support is experimental.

llama.cpp uses Metal on Apple platforms, Vulkan on Linux, Windows, and
(experimental, opt-in) Android, and WebGPU in the browser. LiteRT-LM can also use GPU and, on compatible
Android deployments, NPU. See the
[support matrix](https://llamadart.leehack.com/docs/platforms/support-matrix)
for each target.

Android llama.cpp excludes the known unsafe Adreno 750 driver `2150604839`:
explicit GPU requests throw, while automatic selection with a Vulkan
preference falls back to CPU with a warning. See the
[device limitations](https://llamadart.leehack.com/docs/platforms/support-matrix#known-limitations).


Choose [direct llamadart, Genkit, or Flutter Edge AI](https://llamadart.leehack.com/docs/next/integrations/choosing-an-api) for your application. Genkit remains a [separate package](https://github.com/leehack/llamadart/tree/main/packages/genkit_llamadart); the Flutter Edge AI connector is an upstream source integration.

## Start Here

| Need | Link |
| --- | --- |
| Install the package | [Installation](https://llamadart.leehack.com/docs/getting-started/installation) |
| Load a first model | [Quickstart](https://llamadart.leehack.com/docs/getting-started/quickstart) |
| Build chat history | [First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session) |
| Check runtime support | [Platform & backend matrix](https://llamadart.leehack.com/docs/platforms/support-matrix) |
| Read API reference | [pub.dev API docs](https://pub.dev/documentation/llamadart/latest/) |
| Upgrade from 0.15.x | [0.16 migration guide](MIGRATION.md#015x-to-0160-upgrade-guide) |
| Try the Flutter demo | [Hosted chat app](https://leehack-llamadart.static.hf.space) |
| Generate images on device (Preview) | [Image generation](https://llamadart.leehack.com/docs/guides/image-generation) |

## Requirements

- Dart SDK `>=3.10.7`
- Flutter SDK `>=3.38.0` for Flutter apps
- iOS deployment target `16.4` or newer for Flutter iOS apps. For LiteRT-LM
  this is a declared floor, not a tested one: on a device it has run only on
  iOS 18.3.2 ([#831](https://github.com/leehack/llamadart/issues/831))
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
  llamadart: ^0.16.0
```

Flutter iOS/macOS apps that should link Apple XCFrameworks through Swift
Package Manager should also add the runtime companion packages they need:

Use companion `0.16.0` with core `0.16.x`, or `0.15.2` with core
`>=0.15.6 <0.16.0`, for llama.cpp `v0.7.0-2`.
Locked `0.15.0`/`0.15.1` companions keep `v0.7.0-1` and work with core `0.15.6`
with an upgrade warning, or pair with core `0.15.0` to `0.15.5`.
Pair companion `0.14.0` with core `0.14.x` for llama.cpp `v0.7.0`.
Use companion `0.13.0` with core `0.13.x`, or `0.0.23` with core `0.12.2`,
for llama.cpp `v0.6.0-3`. Keep `0.0.22` with core `0.12.1` and `0.12.0`
for `v0.6.0-2`.
Keep companion `0.0.21` with core `0.11.1` and `0.11.0` for llama.cpp v0.5.0
bindings, and core `0.10.0` and `0.9.0` with companion `0.0.20`,
core `0.8.23` with companion `0.0.18`, and core `0.8.22` with companion
`0.0.17`.

A fresh macOS SwiftPM build that reports a generated 12.0 floor beside the
companions' 14.0 requirement needs the
[Flutter 3.47.1 bootstrap](https://llamadart.leehack.com/docs/getting-started/installation#fresh-macos-swiftpm-bootstrap).
Keep Runner at 14.0+; the procedure preserves companion artifact verification.

Apple builds verify the resolved companion's SwiftPM runtime pin before native
symbol lookup. Incompatible companions or unverified local `Artifacts`
overrides fail the build; resolve the matching companion and rerun
`flutter pub get`. Core native overrides do not replace SPM frameworks.

```yaml
dependencies:
  llamadart: ^0.16.0
  llamadart_llama_cpp_flutter: ^0.16.0 # GGUF / llama.cpp
  llamadart_litert_lm_flutter: ^0.16.0 # Apple .litertlm / LiteRT-LM targets
  llamadart_stable_diffusion_flutter: ^0.16.0 # Apple image generation, opt-in
```

Use `llamadart_stable_diffusion_flutter` `0.16.0` with core `0.16.x` for SD
`v0.3.0`; core `0.16.x` rejects earlier SD companions, and `0.15.x` cores
reject `0.16.0`. Use `0.15.2` with core `>=0.15.2 <0.16.0` for `v0.2.0-4`.
Locked `0.15.0`/`0.15.1` SD companions keep their older runtime and work with core
`0.15.2` with an upgrade warning. Pair `0.14.0` with core `0.14.x`,
`0.13.0` with core `0.13.x`, and
`0.0.3` with core `0.12.2`, `0.12.1` and `0.12.0`. Keep
`0.0.2` with core `0.11.1` and `0.11.0`, and `0.0.1` with core `0.10.0`;
older cores, including `0.9.x`,
ignore it. Adding it opts iOS and macOS builds into the image generation
runtime (about 37 MB per Apple target), so leave it out unless the app uses
`ImageGenerationEngine`.

Use LiteRT-LM companion `0.16.0` with core `0.16.x` for native `v0.18.1`, or
`0.15.2` with core `>=0.15.6 <0.16.0` for `v0.18.0-3`; both load dedicated ASR
`.litertlm` containers such as Whisper tiny. Locked `0.15.0`/`0.15.1`
companions keep `v0.18.0-2` and work with core `0.15.6` with a macOS upgrade
warning; pair `0.14.0` with core `0.14.x`. From `v0.18.0-2`, the runtime reduces duplicated words at untimed ASR
window boundaries with the default overlap. Other boundary and recognition
errors can remain.

The LiteRT-LM companion manifest links the complete iOS and macOS SwiftPM
runtime, including the macOS WebGPU accelerator, so a sandboxed or distributed
Flutter macOS app loads LiteRT-LM from its own bundle. A Flutter macOS app
without the companion, or with companion `0.0.14` or earlier, needs the
[LiteRT-LM build phase](https://llamadart.leehack.com/docs/getting-started/installation#flutter-macos-litert-lm-build-phase).

The pinned LiteRT-LM runtime supports arm64 iOS devices and arm64 iOS
Simulator builds. Intel/x86_64 iOS Simulator builds are not published.

An app bound for the App Store should use the companion for each runtime it
ships: an Apple privacy manifest reaches an app inside a SwiftPM XCFramework,
never in the dylibs the build hook bundles. The llama.cpp XCFramework carries
one from `llamadart-native` `v0.5.0-1`, which `llamadart_llama_cpp_flutter`
releases after `0.0.20` link; the stable_diffusion XCFramework carries one
from `stable-diffusion-native` `v0.2.0-1`, which
`llamadart_stable_diffusion_flutter` releases after `0.0.1` link. An app that
runs llama.cpp or stable_diffusion on the hook path, or
whose embedded `llama.framework` or `stable_diffusion.framework` has no
`PrivacyInfo.xcprivacy`, declares
`NSPrivacyAccessedAPICategoryFileTimestamp` in its own `PrivacyInfo.xcprivacy`
with reason `C617.1`, plus `3B52.1` only when it ships stable_diffusion. The
LiteRT-LM iOS frameworks carry their own manifests from `litert-lm-native`
`v0.17.0-8`, which `llamadart_litert_lm_flutter` releases after `0.0.12` link.
An app that runs LiteRT-LM on the hook path, or whose embedded LiteRT-LM
frameworks have no `PrivacyInfo.xcprivacy`, declares File Timestamp
(`C617.1`, `3B52.1`), System Boot Time (`35F9.1`) and User Defaults
(`CA92.1`) itself. See
[Apple privacy manifest](https://llamadart.leehack.com/docs/platforms/native-build-hooks#apple-privacy-manifest).

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

If an engine's owner goes away during `setModel` or deprecated
`loadModelSource`, dispose the engine: the load throws `LlamaStateException`
and model/LoRA downloads receive cancellation without changing caller-owned
tokens. See [Model lifecycle](https://llamadart.leehack.com/docs/guides/model-lifecycle)
for lifecycle and cancellation details.

Before a native host calls C `exit()`, await every engine's `dispose()`,
stop and join any other native workers, and shut down its Dart isolates or
Flutter engine. llama.cpp and image-worker disposal wait for worker exit;
requesting an isolate kill alone does not stop an in-flight native call.

For multi-turn chat, wrap the same engine in `ChatSession` and let it maintain
history:
[First chat session](https://llamadart.leehack.com/docs/getting-started/first-chat-session).

## What It Supports

Chat-template errors name the selected source, including the built-in ChatML
fallback when model template metadata is empty. See
[template diagnostics](https://llamadart.leehack.com/docs/guides/template-engine-internals).

- GGUF model loading and generation through llama.cpp.
- `.litertlm` model loading and generation through LiteRT-LM. Automatic tool
  loops require reliable runtime termination reporting and reject the pinned
  LiteRT-LM native and Web runtimes; use manually managed completion there
  ([tool-calling guide](https://llamadart.leehack.com/docs/guides/tool-calling)).
- Gemma 2/3/3n and legacy Mistral tool-result retries fold an immediately
  following user message into the result turn; successfully rendered histories
  stay unchanged ([tool-result rendering](https://llamadart.leehack.com/docs/guides/tool-calling#tool-results-on-templates-without-a-tool-role)).
- Native Dart and Flutter targets with downloaded runtime assets.
- Flutter Web through the experimental WebGPU bridge and LiteRT-LM web runtime.
  WebGPU rejects invalid request arguments with `LlamaArgumentException`;
  `scoreNextToken` vocabulary and int32 bounds retain `RangeError`.
  WebGPU `ToolChoice.auto` skips lazy tool-call grammars; tool calls are best-effort.
- Streaming chat completions, llama.cpp and native LiteRT-LM thinking
  budgets, tool-call parsing
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

Embedded and custom Jinja templates accept hexadecimal `\xHH` string
escapes. See [chat templates](https://llamadart.leehack.com/docs/guides/chat-template-and-parsing)
for rendering and runtime requirements.

Unsupported runtime/option combinations are rejected explicitly instead of
silently degrading. Check the support matrix before relying on a capability for
a specific model format or platform. After a model loads, `engine.runtime`
names the runtime (`llamaCpp` or `liteRtLm`) and `await engine.capabilities`
reports what it supports: image and audio input, embeddings, multi-turn chat,
tools, structured output and grammars, each sampling control
(`penalty`, `presencePenalty`, `minP`, `thinkingBudget`), and the speculative
decoding strategies it runs. Branch on these instead of the model's file
extension or backend name. Native llama.cpp reports thinking-budget support
only when the runtime exports its reasoning-budget API. Native LiteRT-LM
reports `penalty` and `presencePenalty`, which count only the tokens of the
current send, and a thinking budget for bundles with a thinking channel, such
as Gemma 4; it has no Min-P. The llama.cpp `mtp` strategy can
use an external draft model; in-file MTP needs an MTP head and `loadMtp: true`.
Other draft strategies require `draftModel` and throw `LlamaArgumentException`
at generation start when it is missing. Native llama.cpp also takes
`draftMicroBatchSize` to give the draft context a smaller micro-batch than the
target; WebGPU and LiteRT-LM reject it.

For ordered embedding content, use `LlamaEmbeddingInput` with
`engine.embedContent` / `embedContentBatch` and check
`await engine.embeddingCapabilities` after loading. Native llama.cpp supports
image/audio embeddings with EmbeddingGemma-2 and its projector on native
v0.7.0-1 (BF16 qualified on CPU on macOS arm64, Linux x64, Windows x64, Android
and iOS, and on macOS Metal); expanded inputs must fit one micro-batch. Web
llama.cpp also accepts image/audio content with bridge assets v0.1.64+ and an
API-version-1 embedding modality probe. The default pin is qualified with
EmbeddingGemma-2 on Chrome CPU wasm memory64 against native CPU/Metal; repeated
media batches require memory64. Hardware WebGPU remains unqualified. LiteRT-LM
supports text, image and audio embeddings (qualified on macOS arm64 CPU only)
with `LiteRtLmModelParams(embeddingEngine: true)`. Select `ComputeDevice.cpu`
on native; native GPU and all LiteRT-LM Web paths throw
`LlamaUnsupportedException`. GGUF loaders reject this LiteRT-LM-only flag.
llama.cpp text-only content follows `embed`, including causal unpooled models.
Unsupported native media diagnostics name the required v0.7.0-1 ABI. Windows
requires the complete native DLL bundle; missing media symbols leave text
embeddings available.
Adjacent text parts concatenate verbatim. `cancelGeneration()` also cancels
content embedding calls still awaiting capability checks, with
`LlamaInferenceException` before inference starts. Await the embedding future
before reusing the engine.
See the
[embedding guide](https://llamadart.leehack.com/docs/guides/embeddings).
Native llama.cpp rejects embedding requests on a context with active text-to-speech
with `LlamaStateException`; await synthesis or its cancellation before reuse.
LiteRT-LM queues concurrent embedding requests, validates media off the caller
isolate and cancels batches between items. A timeout cancels only its own request;
explicit cancellation, unload and dispose cancel active and queued requests.
`contextSize` selects an encoder
signature without truncation; unsupported conversation tuning options are rejected.

Native llama.cpp rejects nonzero rollback capacity on recurrent or hybrid
models before creating a context. Embedding inputs that need one-pass attention
or MEAN/CLS pooling must fit `microBatchSize`; larger inputs raise a typed error.
See [performance tuning](https://llamadart.leehack.com/docs/guides/performance-tuning)
and [embeddings](https://llamadart.leehack.com/docs/guides/embeddings).
After `cancelGeneration()`, LiteRT-LM Web treats only the runtime's exact
`Task cancelled` error as a normal end. Other runtime failures still surface as
`LlamaInferenceException`; keep an error handler after stopping.
Cancelling a queued native llama.cpp or LiteRT-LM generation before it runs
makes `getPerformanceContext()` return `null`. LiteRT-LM validation failures,
early llama.cpp option-validation failures, and failed dispatches also leave
counters unavailable. Native llama.cpp resets counters before each generation,
embedding batch, next-token scoring or text-to-speech request executes, so
counters describe only that request (embedding and scoring report `0` ms).
Request validation failures in the native worker leave diagnostics unavailable;
argument checks that fail before dispatch leave them unchanged. LiteRT-LM retains
its generation-only recovery behavior. Requests rejected because text-to-speech
is active preserve the synthesis request's counters.
After an early cancellation, pending or failed embedding, scoring and speech
calls keep diagnostics unavailable, including calls started before cancellation.
Generation dispatch restores availability immediately; embedding, scoring and
speech restore it only on success, using the backend's counter semantics.
Web backends return
`null` even after successful generation.
Requests from an unloaded model do not invalidate a reloaded model's counters.

Custom backend load callbacks use `void Function(double progress)?` in 0.14.
Existing `Function(double progress)?` overrides still compile; prefer the
explicit `void` signature in custom backends and fakes. Progress notifications
do not return a control value; see [MIGRATION.md](MIGRATION.md).

Web GGUF completions on bridge assets with `supportsCompletionUsage` (`v0.1.54+`)
preserve runtime `length` termination: tool loops return `truncated` and roll
back the turn. Typed speech recognition reports a runtime truncation error;
the bridge does not identify whether the output, context or media cap was reached.

## Image generation (Preview)

`ImageGenerationEngine` turns a text prompt into PNG images on the device
through [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp),
with progress events and cancellation. It is a Preview: the API is
experimental and may change, and the runtime is opt-in.

Image models can be GGUF or Safetensors files, including mixed-format
components; Safetensors does not need conversion to GGUF. Compatible PyTorch
checkpoints need an explicit role and remain less qualified. See the
[format and layout limits](https://llamadart.leehack.com/docs/next/guides/image-generation#weight-formats-and-layouts)
before choosing files: a supported container does not imply every model works.

- **Opt in** to the runtime (about 40 to 70 MB per target) in the app's
  `pubspec.yaml`, then run `flutter clean` once:

  ```yaml
  hooks:
    user_defines:
      llamadart:
        llamadart_native_runtimes: all
  ```

  Unset, the key bundles `llama_cpp` and `litert_lm`. A list replaces those
  defaults, so it names everything the app loads:
  - `all`: every runtime published for the target, `llama_cpp`, `litert_lm`
    and `stable_diffusion`.
  - `[llama_cpp, stable_diffusion]`: GGUF chat and images, no LiteRT-LM.
  - `[stable_diffusion]`: images only.

- **Flutter iOS/macOS apps** should add the
  `llamadart_stable_diffusion_flutter` companion (see [Install](#install)),
  which links the runtime through Swift Package Manager and selects it without
  the entry above. Use companion `0.16.0` with core `0.16.x` for SD `v0.3.0`,
  or `0.15.2` with core `>=0.15.2 <0.16.0` for SD `v0.2.0-4`. Pair `0.14.0`
  with core `0.14.x`, `0.13.0` with core
  `0.13.x`, `0.0.3` with core `0.12.2`, `0.12.1` and `0.12.0`, and `0.0.2`
  with core `0.11.1` and `0.11.0`.
  Without it, `all` leaves the image runtime out of a Flutter iOS/macOS app
  with a build warning. A list naming `stable_diffusion` bundles it through
  the hook instead, and App Store Connect rejects that iOS framework's
  `MinimumOSVersion`. `flutter build ios` output shows neither warning; Xcode
  and `xcodebuild` show both.

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

## Choosing a Runtime

| Model format | Typical use | Runtime |
| --- | --- | --- |
| GGUF | Broad llama.cpp compatibility, Metal/Vulkan/CUDA/CPU, WebGPU bridge | llama.cpp |
| `.litertlm` | LiteRT-LM deployments, Android GPU/NPU-oriented bundles, Gemma-family LiteRT packages | LiteRT-LM |

`LlamaBackend()` routes by model file type. Use `ModelParams` for load-time
controls such as context size, GPU layers, backend preference, LiteRT-LM backend
selection, and WebGPU mem64 hints, or `LlamaCppModelParams` and
`LiteRtLmModelParams`, which take only the fields their runtime applies. A load
throws `LlamaUnsupportedException` for a field set that the model's runtime
does not apply, before any download when the format is known. See
[Runtime Parameters](https://llamadart.leehack.com/docs/configuration/runtime-parameters)
for the full list.

Native llama.cpp with `device: ComputeDevice.auto`, `splitMode: ModelSplitMode.none`
and `mainGpu: -1` reports its CPU placement in backend diagnostics and zero resolved GPU layers.
Decision heads follow this CPU placement and report `CPU` in
`DecisionModelInfo.deviceName`; see
[head placement](website/docs/guides/decision-models.md#current-support-matrix).

Current default runtime pins:

| Runtime | Pin |
| --- | --- |
| Native llama.cpp / GGUF | `leehack/llamadart-native@v0.7.0-2` |
| Native LiteRT-LM / `.litertlm` | `leehack/litert-lm-native@v0.18.1` |
| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.1.71` |
| Web LiteRT-LM / `.litertlm` | `@litert-lm/core@0.18.0` |

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

Renamed legacy Qwen3 `.litertlm` bundles can opt into native thinking control
with `ModelParams(chatTemplate: liteRtLmQwen3ChatTemplate)` and
`enableThinking: false`. The public accessor follows the installed template
version, so callers do not copy Jinja files. Native runtimes need the
conversation-template setter. Web `@litert-lm/core@0.18.0` cannot apply this
override and throws `LlamaUnsupportedException` at load. See the
[template guide](https://llamadart.leehack.com/docs/guides/chat-template-and-parsing).

### Alongside Flutter Edge AI

`flutter_edge_ai_litertlm` ships its own LiteRT-LM libraries, and
`flutter_edge_ai_llama` uses only llamadart's llama.cpp runtime. When the app,
or any member of its pub workspace, depends on llamadart together with either
package, the native build hook bundles `llama_cpp` only unless
`llamadart_native_runtimes` names `litert_lm`. Naming `litert_lm` next to
`flutter_edge_ai_litertlm` fails the build, because both packages would ship
the same libraries. Details and the pub workspace rules:
[Alongside Flutter Edge AI](https://llamadart.leehack.com/docs/platforms/native-build-hooks#alongside-flutter-edge-ai).

## Common Tasks

| Task | Docs |
| --- | --- |
| Resolve local paths, URLs, and Hugging Face sources | [Finding models](https://llamadart.leehack.com/docs/getting-started/finding-models) |
| Pick native/Web/LiteRT backends | [Backend selection](https://llamadart.leehack.com/docs/guides/backend-selection) |
| Stream text and collect output | [Generation and streaming](https://llamadart.leehack.com/docs/guides/generation-and-streaming) |
| Generate typed JSON | [Structured output](https://llamadart.leehack.com/docs/guides/generation-and-streaming#structured-json-output) |
| Use tool calling | [Tool calling](https://llamadart.leehack.com/docs/guides/tool-calling) |
| Import a tool input schema (length/item bounds up to 2000) | [`ToolDefinition.fromJsonSchema`](https://llamadart.leehack.com/docs/guides/tool-calling#import-a-json-schema) |
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

Raw `responseFormat` and `LlamaStructuredOutput` reject unsupported or shadowed
schema assertions with a schema path before generation. Integer bounds,
`uuid`/`uuid1`–`uuid5`, date/time formats, supported `allOf` merges and fixed tuples are supported;
number bounds, other formats and length/item bounds above 2000 are rejected.
Trivial `uniqueItems: false`, `minProperties: 0` and integer `multipleOf: 1`
assertions are accepted. Array bounds work without `items`, and unused definitions,
annotations and unknown vocabulary remain accepted. Nonempty annotation-only untyped schemas
accept any JSON value. See [0.14 migration](MIGRATION.md#013x---0140-llamacpp-v070-abi-qwen3-overrides-and-load-callbacks)
for the breaking changes.

## Examples

Run the Flutter chat app from a
[repository checkout](https://github.com/leehack/llamadart/tree/main/example/chat_app).
It and its private validation harness are excluded together from the core pub
archive; the smaller console examples remain packaged.

- [Basic Dart CLI](https://github.com/leehack/llamadart/tree/main/example/basic_app)
- [Flutter chat app](https://github.com/leehack/llamadart/tree/main/example/chat_app)
- [Laya Tetris, a Flutter game played by a decision model](https://github.com/leehack/llamadart/tree/main/example/laya_tetris)
- [HTTP server example](https://github.com/leehack/llamadart/tree/main/example/llamadart_server)
- [TUI coding agent example](https://github.com/leehack/llamadart/tree/main/example/tui_coding_agent)

## Observability

Use optional engine observers for tracing and metrics without adding an OTel
dependency to core. The [observability guide](https://llamadart.leehack.com/docs/guides/observability)
includes a runnable OpenTelemetry adapter and Langfuse/Grafana recipes.

## Contributing

Repository checks, validation commands, and PR expectations are in
[AGENTS.md](https://github.com/leehack/llamadart/blob/main/AGENTS.md) and the
[maintainer docs](https://llamadart.leehack.com/docs/next/maintainers/docs-site#validating-changes).

## License

MIT. See [LICENSE](https://github.com/leehack/llamadart/blob/main/LICENSE).
