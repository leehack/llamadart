---
title: On-device speech to text
sidebar_label: Speech to text
description: Transcribe audio files with Qwen3-ASR or stream live PCM with LiteRT-LM through the experimental typed SpeechToTextEngine API.
---

`SpeechToTextEngine` is the typed, experimental API for speech recognition. It
is separate from `LlamaEngine` because transcript events, cancellation, and
audio metadata have a different contract from chat-completion tokens.
Recognition quality and language behavior are model dependent. For speech
synthesis, see [Text to Speech](./text-to-speech).

## Choose an approach

A `SpeechToTextModel` names the model's files, each a `ModelSource`, and the
adapter that drives it. The adapter picks the runtime.

| Approach | API | Runtimes | Input | Output |
| --- | --- | --- | --- | --- |
| Qwen3-ASR, whole file | `SpeechToTextEngine.load` with `Qwen3AsrAdapter`, or `attach` | Native llama.cpp; WebGPU (pinned bridge assets) | A complete WAV, MP3, or FLAC file or bytes; bytes only on Web | One final transcript |
| Qwen3-ASR, windowed live (opt-in) | `SpeechToTextEngine.load` with `Qwen3WindowedAsrAdapter` | Native llama.cpp (`qwen3a` projector required) | Mono 16 kHz finite normalized float32 PCM, pushed incrementally or as one buffer | Replaceable 2/4/6 s partials, commits when the 8 s buffer fills, then final |
| Another audio chat model, whole file | `load` or `attach` with your own `SpeechToTextPromptAdapter` | As Qwen3-ASR | As Qwen3-ASR | One final transcript |
| llama.cpp, live streaming | `SpeechToTextEngine.load` with `LlamaCppLiveAsrAdapter` | Native llama.cpp (`llamadart-native@v1.0.0-1`+) | Mono 16 kHz finite normalized float32 PCM, pushed incrementally or as one buffer | Cumulative confirmed partials, then a final transcript |
| LiteRT-LM, live streaming | `SpeechToTextEngine.load` with `LiteRtLmAsrAdapter` | Native LiteRT-LM, CPU only | Mono 16 kHz float PCM, pushed incrementally or as one buffer | Replaceable partial text, then a final transcript |
| Generic audio chat | `LlamaAudioContent` in `engine.create` | Audio-capable GGUF projectors; `.litertlm` bundles with audio | Audio as a chat content part | Ordinary chat output, no transcript contract |

LiteRT-LM Web supports none of these. `Qwen3AsrAdapter` and
`Qwen3WindowedAsrAdapter` report
`SpeechToTextImplementation.multimodalPromptAdapter`;
`SpeechToTextCapabilities.inputMode` distinguishes `wholeInput` from `windowed`.
`LlamaCppLiveAsrAdapter` and `LiteRtLmAsrAdapter` report
`SpeechToTextImplementation.dedicatedBackend` (`inputMode == SpeechToTextInputMode.stateful`).

The adapter is an explicit declaration: an audio-understanding model is not
advertised as ASR merely because it accepts audio.

## Load or attach

`SpeechToTextEngine.load` downloads each remote file into the model cache,
loads the model, and returns a recognizer that owns what it loaded.
`dispose()` releases it. `SpeechToTextEngine.attach` borrows a `LlamaEngine`
you loaded yourself, for example to chat with the same model, and its
`dispose()` leaves that engine loaded. Once that `LlamaEngine` is disposed,
`capabilities` reports unsupported with that reason and `transcribe` throws
`LlamaStateException`: create a new `LlamaEngine` and attach a new recognizer
([The LlamaEngine is disposed](../troubleshooting/common-issues#the-llamaengine-is-disposed-create-a-new-llamaengine)).

| | `load(model, ...)` | `attach(engine, adapter: ...)` |
| --- | --- | --- |
| Adapters | Any | `SpeechToTextPromptAdapter` only |
| Who loads the files | The recognizer, from `ModelSource`s | You |
| Capability check | `load` throws `LlamaUnsupportedException` | Read `capabilities` yourself |
| `dispose()` | Cancels the task and disposes the engine | Cancels the task; the engine stays loaded |

`load` takes `download:` (`ModelLoadOptions` for every remote file: cache
policy and directory, authentication, resume, retries and cancel token),
`onProgress:` (one combined progress for all files; 1 means they have loaded,
before the capability check; on [Web](#web) only the model's fetch reports
progress, up to 0.5 with a projector), `store:` (a `ModelFileStore` with your own
resolver or download manager), and, for a prompt adapter, `params:`
(`ModelParams`) and `backend:` (by default `LlamaBackend()`). Every file resolves, main file first, before anything
loads. A local file takes only the cancel token. The bearer token and headers
are never sent across hosts: when they are set and the remote files span more
than one origin (scheme, host and port), `load` throws
`LlamaArgumentException` before downloading from another host, so load such
files from one host or leave the credentials unset. `ModelLoadOptions.sha256` throws
`LlamaUnsupportedException` for a model of more than one file. The load is
atomic: when it throws, nothing stays loaded, and downloaded files stay in the
cache.

`load` takes ownership of a `backend:` you pass: the recognizer's `dispose()`,
or a failed load, disposes it with the engine, so pass a backend that nothing
else uses.

## Transcribe a file with Qwen3-ASR

Use a matching model and multimodal projector pair. llama.cpp documents
Qwen3-ASR in its
[multimodal model list](https://github.com/ggml-org/llama.cpp/blob/b10356/docs/multimodal.md),
and published GGUF pairs are available from
[`ggml-org/Qwen3-ASR-0.6B-GGUF`](https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF).
Sources may be local paths, HTTP(S) URLs or `hf://owner/repo/file` references.

```dart
final recognizer = await SpeechToTextEngine.load(
  SpeechToTextModel(
    ModelSource.path('/models/Qwen3-ASR-0.6B-Q8_0.gguf'),
    projector: ModelSource.path('/models/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf'),
    adapter: const Qwen3AsrAdapter(),
  ),
);
try {
  final result = await recognizer.transcribeOnce(
    const SpeechToTextRequest(
      audio: SpeechAudioFileInput('/recordings/meeting.wav'),
      contextPrompt: 'llamadart, Qwen3-ASR',
    ),
  );
  print(result.text);
} finally {
  await recognizer.dispose();
}
```

`load` checks `capabilities` after the model and projector load and throws
`LlamaUnsupportedException` with the reason when they cannot recognize speech.
Projector load success alone does not prove audio support.

With `Qwen3AsrAdapter` on native platforms, `capabilities` also reads the
projector's GGUF header and reports unsupported when its audio projector type
is not Qwen3-ASR's `qwen3a`, such as the `qwen3tts_spkenc` projector of a
Qwen3-TTS model. When the type cannot be read, on Web or for a projector file
without one, the model stays supported, and an empty transcript's
`LlamaSpeechException.details` says the model may not match the adapter.

`load` rethrows what the projector load throws. On native llama.cpp that is
`LlamaModelException` for a projector the runtime rejects, such as the
Qwen3-TTS projector with the Qwen3-ASR model, and `LlamaUnsupportedException`
when the runtime lacks the mtmd functions. On Web, it is `LlamaModelException`
when the bridge cannot fetch or load the projector.

With an engine you loaded, attach the adapter and check `capabilities`
yourself:

```dart
final recognizer = SpeechToTextEngine.attach(
  engine,
  adapter: const Qwen3AsrAdapter(),
);
final capabilities = await recognizer.capabilities;
if (!capabilities.isSupported) {
  throw StateError(capabilities.unsupportedReason!);
}
```

`transcribeOnce` returns the final result, and throws the task's failure, or
`LlamaStateException` when the task is cancelled. For events, use
`transcribe`:

```dart
final task = await recognizer.transcribe(
  const SpeechToTextRequest(
    audio: SpeechAudioFileInput('/recordings/meeting.wav'),
    contextPrompt: 'llamadart, Qwen3-ASR',
  ),
);
task.events.listen((event) {
  if (event is SpeechToTextPartialEvent) {
    print('partial: ${event.text}');
  }
});

try {
  final result = await task.result;
  print(result.text);
} on LlamaException catch (error) {
  print('Recognition failed or was cancelled: $error');
}
```

`transcribe` itself throws typed input, state, or unsupported errors when
preflight fails before a task can start. After startup, `events` is a
single-subscription stream of progress that never emits an error: a
prompt adapter emits one `SpeechToTextFinalEvent`, and LiteRT-LM emits
partial events first. `task.result` returns the transcript or throws the
failure, or `LlamaStateException` when the task is cancelled; `task.done`
reports the same outcome as a `SpeechToTextCompletion` and never throws.

`task.cancel()` stops only its request. With the pinned Web bridge assets this
also holds when the speech request is queued behind another active request. Await `task.done` before
reusing a speech context; `engine.cancelGeneration()` is global cancellation.

## Add a model family

To recognize speech with another audio chat model on `LlamaEngine`, extend
`SpeechToTextPromptAdapter`. The recognizer sends one user turn: the text from
`promptFor`, then the audio. Natively the turn goes through the model's chat
template with thinking disabled; on Web the bridge takes the text as the raw
prompt with the audio bytes. Generation is greedy and stops at
`maxOutputTokens`. `parseTranscript` turns the complete output into a
`SpeechToTextTranscript`; an empty transcript fails the task.

```dart
class MyAsrAdapter extends SpeechToTextPromptAdapter {
  const MyAsrAdapter();

  @override
  String get name => 'My-ASR';

  @override
  bool get supportsLanguageHints => true;

  @override
  String promptFor(SpeechToTextRequest request) {
    final language = request.languageHint;
    return language == null
        ? 'Transcribe the audio.'
        : 'Transcribe the audio. It is in $language.';
  }

  @override
  SpeechToTextTranscript parseTranscript(String output) =>
      SpeechToTextTranscript(output.trim());
}

final recognizer = await SpeechToTextEngine.load(
  SpeechToTextModel(
    ModelSource.parse('hf://owner/repo/asr-model.gguf'),
    projector: ModelSource.parse('hf://owner/repo/mmproj-asr-model.gguf'),
    adapter: const MyAsrAdapter(),
  ),
);
```

`supportsLanguageHints` defaults to false, and the recognizer then rejects a
`languageHint` with `LlamaUnsupportedException`. `supportsContextPrompt`
defaults to true; `supportsLanguageDetection` defaults to false and says
whether `parseTranscript` reports `SpeechToTextTranscript.language`.
`capabilities` reports these flags. The recognizer checks only that the loaded
projector supports audio; whether the prompt suits the model is the adapter's
responsibility. An empty transcript's `LlamaSpeechException.details` says the
model may not match the adapter.

## Stream live audio with llama.cpp

`LlamaCppLiveAsrAdapter` runs native incremental live PCM speech recognition on
Voxtral Realtime and LFM3-Audio GGUF models with their matching multimodal
projectors (`llamadart-native@v1.0.0-1` or newer). Load through
`SpeechToTextEngine.load` (leave `tokenizer` unset; `attach` is prompt-only):

```dart
final recognizer = await SpeechToTextEngine.load(
  SpeechToTextModel(
    ModelSource.path('/models/Voxtral-Mini-4B-Realtime.gguf'),
    projector: ModelSource.path('/models/mmproj-Voxtral-Mini-4B-Realtime.gguf'),
    adapter: const LlamaCppLiveAsrAdapter(),
  ),
  params: const ModelParams(contextSize: 4096),
);
try {
  final session = await recognizer.startStream();
  final sub = session.events.listen((event) {
    if (event is SpeechToTextPartialEvent) {
      print(event.confirmedText);
    }
  });
  try {
    await for (final chunk in mono16kPcmChunks) {
      await session.addPcm(chunk);
    }
    await session.finish();
    final completion = await session.done;
    print(completion.result?.text);
  } finally {
    await session.cancel();
    await sub.cancel();
  }
} finally {
  await recognizer.dispose();
}
```

- **Capability branching**: inspect `capabilities.inputMode`
  (`SpeechToTextInputMode`: `wholeInput`, `windowed`, `stateful`, or
  `unavailable`), `capabilities.supportsStreamingInput`, and
  `capabilities.streamingInputUnsupportedReason` before calling `startStream()`.
- **Context policy**: `LFM3-Audio` (prompted-chunks mode) requires an actual
  per-sequence context capacity of at least `2048` (`4096` recommended).
  `Voxtral Realtime` (token-delay mode) runs within a finite context window;
  `4096` gives roughly five minutes of audio. Context exhaustion emits terminal
  text and fails with `LlamaSpeechTranscriptTruncatedException`.
- **Example**: see `example/basic_app/bin/llamadart_live_asr_example.dart` for
  an incremental `.f32le` file streamer.

## Stream live audio with Qwen3-ASR (opt-in windowed)

`Qwen3WindowedAsrAdapter` enables opt-in windowed live PCM transcription on
native `llama.cpp` Qwen3-ASR models with a verified `qwen3a` projector. Unlike
`LlamaCppLiveAsrAdapter` (`SpeechToTextInputMode.stateful`), it re-decodes
2, 4, and 6 second uncommitted prefixes through the prompt path in a bounded 8 s
ring buffer (`SpeechToTextInputMode.windowed`). When the buffer fills, it
commits at a quiet boundary or hard-cuts at 8 s:

```dart
final recognizer = await SpeechToTextEngine.load(
  SpeechToTextModel(
    ModelSource.path('/models/Qwen3-ASR-0.6B-Q8_0.gguf'),
    projector: ModelSource.path('/models/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf'),
    adapter: const Qwen3WindowedAsrAdapter(),
  ),
  params: const ModelParams(contextSize: 4096),
);
try {
  final capabilities = await recognizer.capabilities;
  if (capabilities.inputMode != SpeechToTextInputMode.windowed) {
    throw StateError('Expected windowed mode: ${capabilities.inputMode}');
  }
  final session = await recognizer.startStream();
  final sub = session.events.listen((event) {
    if (event is SpeechToTextPartialEvent) {
      print('confirmed=${event.confirmedText} pending=${event.pendingText}');
    }
  });
  try {
    await for (final chunk in mono16kPcmChunks) {
      await session.addPcm(chunk);
    }
    await session.finish();
    final completion = await session.done;
    print(completion.result?.text);
  } finally {
    await session.cancel();
    await sub.cancel();
  }
} finally {
  await recognizer.dispose();
}
```

- **Example**: pass `--qwen-windowed` to
  `example/basic_app/bin/llamadart_live_asr_example.dart`.
- **Unsupported paths**: `SpeechToTextEngine.attach`, Web, missing/non-`qwen3a`
  projectors, non-PCM inputs, context prompts, and language hints throw
  `LlamaUnsupportedException`.

## Stream live audio with LiteRT-LM

LiteRT-LM's dedicated ASR engines consume PCM
windows instead of an audio part in normal chat. Load the model with its
tokenizer and a `LiteRtLmAsrAdapter` for the model family's preset, start a
stream, and await every input push so bounded native backpressure can
throttle the producer.

```dart
final recognizer = await SpeechToTextEngine.load(
  SpeechToTextModel(
    ModelSource.path('/models/moonshine_tiny.tflite'),
    tokenizer: ModelSource.path('/models/tokenizer.json'),
    adapter: const LiteRtLmAsrAdapter(LiteRtLmAsrModelPreset.moonshineTiny),
  ),
);

final session = await recognizer.startStream();
final events = session.events.listen(
  (event) {
    if (event is SpeechToTextPartialEvent) {
      print('stable=${event.confirmedText} pending=${event.pendingText}');
    } else if (event is SpeechToTextFinalEvent) {
      print('final=${event.result.text}');
    }
  },
  // A session's events report a failure as an error too; done carries it.
  onError: (Object _) {},
);

for (final chunk in mono16KhzFloatPcmChunks) {
  await session.addPcm(chunk);
}
await session.finish();
final completion = await session.done;
await events.cancel();
print(completion.state);
await recognizer.dispose();
```

`load` probes the LiteRT-LM ASR runtime before it downloads anything and
throws `LlamaUnsupportedException` when the runtime is unavailable, including
on Web. It then resolves the model and tokenizer, each a local path, an
HTTP(S) URL or a Hugging Face file, to local files, model first, downloading
remote ones into the model cache as described under
[Load or attach](#load-or-attach); each `transcribe` or `startStream` starts its
own native session on them. The
adapter carries the runtime settings (`backend`, `numberOfThreads`,
`maxBufferedAudio`, `overlapRatio`, and `libraryPath` to use a custom runtime
library),
so `params:` and `backend:` must be null. A `LiteRtLmAsrAdapter` model takes
no projector, and a prompt adapter model no tokenizer.

The model can also be a dedicated ASR `.litertlm` container, such as the
published Whisper tiny container with the `whisperTiny` preset. The container
uses its embedded tokenizer, but `load` still requires a `tokenizer` file.
Flutter iOS and macOS apps run the runtime that `llamadart_litert_lm_flutter`
links, so use the companion with the core's `MAJOR.MINOR`. Boundary and
recognition errors can remain.

The session runs synchronous inference in a worker isolate. `confirmedText` is
stable, while `pendingText` may change after the next inference window.
`finish` flushes a partial final window.

`LiteRtLmAsrBackend.cpu` is the only backend. Metadata presets cover Parakeet
TDT, Parakeet CTC, Moonshine Tiny, Whisper Tiny, and Qwen3-ASR 0.6B, but
callers must supply a matching model and tokenizer. The API does not capture a
microphone or resample audio. Advanced callers can use `LiteRtLmRuntimeClient`
and `LiteRtLmAsrRuntimeSession` from `package:llamadart/backend.dart` directly
with local files, but those synchronous calls must not run on a Flutter UI
isolate.

## Cancel, dispose and concurrency

```dart
final task = await recognizer.transcribe(request);
// Later:
task.cancel();
final completion = await task.done;
assert(completion.state == SpeechToTextCompletionState.cancelled);
```

Cancellation is cooperative: `task.cancel()` for whole-input recognition, or
`await session.cancel()` for a LiteRT-LM session, which stops between native
windows. `task.cancel()` stops only that task: on a prompt adapter it cancels
the task's own generation and no other request on the same `LlamaEngine`. A
session's `cancel()` returns a future because it ends a live input
stream and releases the native recognizer; a session has no single `result`. Cancelling or pausing an event subscription neither cancels nor
throttles native inference; LiteRT-LM producers must await `addPcm` for input
backpressure.

`dispose()` cancels a running task or stream, waits for it to stop, and
disposes the engine that `load` created. Calling it again is safe, and
`isDisposed` reports it. After `dispose()`, `transcribe` and `startStream`
throw `LlamaStateException` and `capabilities` reports unsupported.

All prompt-adapter recognizers and text-to-speech wrappers over one
`LlamaEngine` share a one-task lease. Direct `LlamaEngine.create` calls on a
borrowed engine must not run during a task. A LiteRT-LM recognizer allows one
active task per `SpeechToTextEngine` instance.

## Input formats and length

Qwen3-ASR recognition is validated up to 30 seconds per input. Longer inputs
can drop or repeat sentences without reaching any limit, so split longer
recordings into windows of at most 30 seconds. Built-in windowing is not
available yet.

A Qwen3-ASR prompt grows by about 13 tokens per second of audio, and the
transcript shares the same context. On native llama.cpp, a prompt-adapter task
that reaches the context size or `maxOutputTokens` before the transcript ends
fails with `LlamaSpeechTranscriptTruncatedException`. Its `limit` names the
limit that stopped recognition and `partialTranscript` holds the text produced
before it. A task whose transcript is empty, for example from silent input,
fails with `LlamaSpeechException`.

Native llama.cpp accepts WAV, MP3, and FLAC file or byte inputs. Raw PCM is
unsupported for prompt adapters because projector sample rates are
model-specific. LiteRT-LM accepts `SpeechAudioPcmInput` for a complete mono
16 kHz normalized `Float32List` buffer, or the incremental session above.

`SpeechAudioFormat` carries optional encoding and MIME metadata. Final results
reserve segment and word timing, confidence, and speaker fields for future
backends; prompt adapters return one untimed segment.

## Web

Web runs prompt adapters, such as Qwen3-ASR, through the WebGPU bridge. The hosted chat app derives the capability from the immutable
`llama-web-bridge-assets` tag; custom hosts can set
`window.__llamadartBridgeSpeechToTextSupported` before the backend is created.
An older bridge, no loaded projector, a projector without audio support, or a
failed runtime audio probe makes `load` throw `LlamaUnsupportedException`, and
leaves an attached recognizer's `capabilities.isSupported` false, with an
actionable reason. On Web, `load` passes the sources to the browser runtime,
which fetches each file itself: a `ModelSource.path` is a URL relative to the
document, or a `blob:` URL, and `download` must stay at its defaults.
`onProgress` reports a fraction from 0 to 1, as `DecisionEngine.load` does:
the model fetch fills the first half, and progress reaches 1 once the
projector has loaded.

WebGPU accepts encoded WAV, MP3, and FLAC bytes. Read the selected file into
memory and pass `SpeechAudioBytesInput` with a `SpeechAudioFormat` whose
`encoding` is `'wav'`, `'mp3'` or `'flac'`; local filesystem paths, other
encodings, raw PCM, and bytes without that metadata are rejected. The bridge
reports truncation through `onUsage` when its `supportsCompletionUsage`
probe is true. A cut-off Web transcript then fails with
`LlamaSpeechTranscriptTruncatedException`, whose `limit` is
`LlamaSpeechTranscriptLimit.runtime`: the bridge combines output-token,
context and media caps, so the error cannot name the exact cause. Its
`partialTranscript` holds the text produced before the limit. Bridges
without this signal retain their existing completion behavior. The browser
needs enough memory for the roughly 1.02 GB Qwen3-ASR
0.6B Q8_0 model/projector pair.

## Known limits

- The audio prompt grows with duration, about 13 tokens per second of audio.
  Validated with Qwen3-ASR 0.6B Q8_0 on native macOS and in headless Chromium.
- Qwen3-ASR may emit a leading `language English<asr_text>` marker.
  `Qwen3AsrAdapter` strips that marker, but does not expose it as reliable
  detected-language metadata until language behavior has a dedicated
  validation contract.
- There are no word/segment timestamps, confidence scores, or speaker
  diarization. Incremental audio and partial text are native-only
  (`LlamaCppLiveAsrAdapter` on llama.cpp and `LiteRtLmAsrAdapter` on
  LiteRT-LM for stateful streaming, plus opt-in `Qwen3WindowedAsrAdapter` on
  llama.cpp for windowed live PCM); Web throws `LlamaUnsupportedException` for
  live streaming.
- For `Qwen3WindowedAsrAdapter`:
  - Confirmed windows are joined with `\n` in `confirmedText` and `result.text`.
  - The first window commits after 8 s of audio plus a decode. Later full
    windows need 6.05–8 s of new audio plus a decode. Calling `finish()` flushes
    any remaining audio.
  - Each checkpoint re-decodes the whole uncommitted prefix, and an 8 s hard cut
    under continuous speech or background noise can split a word across windows.
  - `maxOutputTokens` applies per decode (`1024` for `startStream`, configurable
    on `transcribe`/`transcribeOnce`); empty intermediate windows are
    suppressed.
  - Evidence so far covers only English on macOS arm64 CPU.
- Inference backend correctness and performance remain device dependent;
  establish a CPU baseline before claiming GPU support for a deployment.
- On the Web, Qwen3-ASR 0.6B Q8_0 returned the exact transcript of an
  11-second clip on every backend and core combination below, measured in
  Chromium 149 and 157 on an Apple-silicon Mac. Other browsers and GPUs can
  differ.

  | Core | CPU | WebGPU (`gpuLayers: 99`) |
  | --- | --- | --- |
  | wasm32 | about 17 s | offloads, about 3.4 s |
  | wasm64 (memory64) | about 17 s | offloads, about 3.4 s |

  Times are for selecting the file, not the model load. Without WebGPU the
  bridge runs on CPU while `isGpuActive()` reports `false`, and without the
  memory64 core file it loads the wasm32 core; check
  `llamadart.webgpu.core_variant` rather than assuming the requested core.
- The [chat app](../examples/chat-app) shows file transcription, microphone
  capture, and live dictation built on this API.
