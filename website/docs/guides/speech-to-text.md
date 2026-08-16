---
title: Speech to Text
description: Transcribe complete audio files with the experimental typed native llama.cpp speech API.
---

`SpeechToTextEngine` is the typed API for speech recognition. It is separate
from `LlamaEngine` because transcript events, timestamps, confidence, language,
speaker labels, cancellation, and audio metadata have a different contract from
chat-completion tokens.

The first implementation is experimental and deliberately narrow: it adapts
native llama.cpp audio input to whole-file transcription. It has been validated
with Qwen3-ASR 0.6B, but recognition quality and language behavior remain model
dependent. Generic `LlamaAudioContent` chat input still exists separately for
audio-capable multimodal models.

## Current support matrix

| Runtime | Generic audio-input chat | Typed `SpeechToTextEngine` | Text to speech |
| --- | --- | --- | --- |
| Native llama.cpp / GGUF | Model + projector dependent | Experimental Qwen3-ASR adapter; complete WAV/MP3/FLAC file or bytes, final transcript only | Experimental Qwen3-TTS adapter; see [Text to Speech](./text-to-speech) |
| WebGPU / GGUF | Bridge + model dependent | Unsupported | Unsupported |
| Native LiteRT-LM | Separate `.litertlm` audio chat remains bundle dependent | Experimental CPU-only dedicated ASR runtime sessions; not yet wired to `SpeechToTextEngine` | Unsupported |
| LiteRT-LM Web | Unsupported | Unsupported | Unsupported |

“Generic audio-input chat” means an audio content part is processed by normal
generation. It does not imply a transcript schema, stable ASR behavior, or TTS.
The typed STT API adds a stable Dart result/cancellation boundary, but the first
backend still performs whole-audio llama.cpp generation internally. Its
`SpeechToTextImplementation.multimodalPromptAdapter` capability makes that
distinction inspectable; it is not a dedicated native ASR engine.

## Dedicated LiteRT-LM ASR sessions

LiteRT-LM v0.16 adds a different speech path: dedicated ASR engines that
consume streaming PCM windows instead of an audio part in normal chat. The
experimental `LiteRtLmRuntimeClient` bridge exposes that low-level native
session boundary while the higher-level `SpeechToTextEngine` adapter is still
being designed.

```dart
final runtime = LiteRtLmRuntimeClient();
if (!runtime.supportsAsrBridge) {
  throw StateError('Install the pinned speech-capable LiteRT-LM runtime.');
}

final session = runtime.createAsrSession(
  const LiteRtLmAsrRuntimeConfig(
    modelPath: '/models/moonshine_tiny.tflite',
    tokenizerPath: '/models/tokenizer.json',
    modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
  ),
);

try {
  var offset = 0;
  while (offset < mono16KhzFloatPcm.length) {
    final push = session.pushAudio(
      Float32List.sublistView(mono16KhzFloatPcm, offset),
    );
    offset += push.acceptedSamples;
    if (push.acceptedSamples == 0 && !push.wouldBlock) {
      throw StateError('ASR input made no progress.');
    }
    if (!push.wouldBlock) continue;

    final update = session.processNext();
    print('${update.confirmedText}${update.unconfirmedText}');
  }

  session.finishAudio();
  while (true) {
    final update = session.processNext();
    if (update.state == LiteRtLmAsrProcessState.endOfStream) break;
    if (update.state == LiteRtLmAsrProcessState.needsMoreAudio) {
      throw StateError('Finalized ASR input requested more audio.');
    }
    print('${update.confirmedText}${update.unconfirmedText}');
    if (update.isFinal) break;
  }
} finally {
  session.dispose();
  runtime.dispose();
}
```

The input contract is mono 16 kHz `Float32List` PCM. `pushAudio` can accept a
prefix and report backpressure; callers must process a window before retrying
the unaccepted suffix. `confirmedText` is stable, while `unconfirmedText` may
change after the next window. `finishAudio` flushes a partial final window,
`reset` reuses the session for another stream, and `cancel` is cooperative
between native inference windows.

Inference is synchronous and potentially expensive. Own the session from a
worker isolate rather than calling `processNext` on a Flutter UI isolate. The
validated v0.16 contract is CPU-only; accelerator enum values are deliberately
not exposed until their transcripts pass the same real-model correctness
gates. Supported metadata presets currently cover Parakeet TDT, Parakeet CTC,
Moonshine Tiny, Whisper Tiny, and Qwen3-ASR 0.6B, but callers must provide the
matching model and tokenizer artifacts.

This low-level API does not itself provide microphone capture, a Dart event
stream, timestamps, confidence, diarization, or automatic resampling. The chat
example now demonstrates an app-owned microphone/worker wrapper with selectable
Moonshine Tiny and Parakeet TDT sidecars. That example integration is not yet a
public streaming `SpeechToTextEngine` adapter.

## Load a Qwen3-ASR model

Use a matching model and multimodal projector pair. llama.cpp documents
Qwen3-ASR in its
[multimodal model list](https://github.com/ggml-org/llama.cpp/blob/b10356/docs/multimodal.md),
and published GGUF pairs are available from
[`ggml-org/Qwen3-ASR-0.6B-GGUF`](https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF).

```dart
final engine = LlamaEngine(LlamaBackend());
await engine.loadModel('/models/Qwen3-ASR-0.6B-Q8_0.gguf');
await engine.loadMultimodalProjector(
  '/models/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
);

final recognizer = SpeechToTextEngine(
  engine,
  modelProfile: SpeechToTextModelProfile.qwen3Asr,
);
final capabilities = await recognizer.capabilities;
if (!capabilities.isSupported) {
  throw StateError(capabilities.unsupportedReason!);
}
```

Always check `capabilities` after both artifacts are loaded. Projector load
success alone does not prove audio support. The required `modelProfile` is an
explicit declaration that prevents an ordinary audio-understanding model from
being advertised as ASR merely because it accepts audio.

## Transcribe a complete file

```dart
final task = await recognizer.transcribe(
  const SpeechToTextRequest(
    audio: SpeechAudioFileInput('/recordings/meeting.wav'),
    contextPrompt: 'llamadart, Qwen3-ASR',
  ),
);

try {
  await for (final event in task.events) {
    if (event is SpeechToTextFinalEvent) {
      print(event.result.text);
    }
  }
} on LlamaException catch (error) {
  print('Recognition failed: $error');
}

final completion = await task.done;
print(completion.state);
```

`transcribe` itself throws typed input, state, or unsupported errors when
preflight fails before a task can start. After startup, `events` is a
single-subscription stream: runtime failure is emitted as a stream error and
the same terminal condition is available through `task.done`.

Native llama.cpp currently decodes WAV, MP3, and FLAC file or byte inputs. Raw
PCM is intentionally not exposed by the typed API yet: projector sample rates
are model-specific, and the current public engine capability does not report
the loaded projector's required rate.

`SpeechAudioFormat` also carries optional encoding and MIME metadata. Final
results reserve segment and word timing, confidence, and speaker fields so a
future backend can add them without changing the top-level API. The current
llama.cpp adapter returns one untimed segment and no confidence or diarization.

## Streaming, cancellation, and concurrency

The event stream is future-compatible with partial transcripts, but the first
backend consumes the complete input before inference and emits only one final
event. It does not accept live microphone frames, and pausing the Dart event
subscription does not throttle native inference.

Call `task.cancel()` to request cooperative cancellation:

```dart
final task = await recognizer.transcribe(request);
// Later:
task.cancel();
final completion = await task.done;
assert(completion.state == SpeechToTextCompletionState.cancelled);
```

Cancelling a stream subscription does not cancel the native task. All
`SpeechToTextEngine` wrappers over one `LlamaEngine` share a one-task lease.
Do not call `LlamaEngine.create` on that engine until the speech task completes.

## Chat app

The Flutter chat example keeps transcription and generic audio chat as
different user actions:

- **Attach Audio** sends audio through normal multimodal chat.
- **Transcribe Audio** selects one file and uses `SpeechToTextEngine` with a
  compatible native GGUF ASR model.
- With Qwen3-ASR, the microphone records a temporary foreground WAV for up to
  five minutes. **Stop & transcribe** finalizes that file and passes it to
  `SpeechToTextEngine`, while **Discard** cancels capture and removes the
  partial file.
- With a native chat model, **Live transcription** uses a separately installed,
  checksum-pinned LiteRT model and tokenizer. Moonshine Tiny is the recommended
  54 MB default; Parakeet TDT 0.6B is an optional higher-capacity, heavier
  615 MB choice. The selector remembers the choice and reports model size,
  installed state, determinate download progress, cancellation, and retry. The
  app captures mono 16 kHz PCM, owns the synchronous LiteRT-LM session in a
  worker isolate, and renders monotonic confirmed text plus a replaceable
  pending suffix after each five-second window. **Use text** finalizes the
  session and inserts the result into the editable composer; it never submits
  the message automatically. Generic audio-chat models retain **Ask with
  voice** as a separate action.
- With native Gemma 4 E2B, **Ask with voice** uses either the LiteRT-LM
  direct-media bundle or the GGUF model with its matching audio-capable
  projector. It records up to 30 seconds and **Stop & ask** sends the WAV bytes
  through normal multimodal chat. The model is prompted to answer the spoken
  request; this path does not promise a transcript, timestamps, confidence,
  detected language, or live partial text. An ASR profile takes precedence
  when both capability declarations are present.

The dedicated **Transcribe Audio** action remains hidden on Web and for normal
LiteRT-LM chat bundles. Live dictation is a separate app-owned sidecar flow,
not a capability of the selected chat bundle or the current public
`SpeechToTextEngine`.
ASR microphone recordings are capped at five minutes, cancelled when the app is
backgrounded, and deleted after transcription. This remains a whole-file
workflow: it does not produce live partial transcripts while the user speaks.
The recorder requests 16 kHz mono WAV, but hardware may choose another valid
sample rate; the downstream native decoder reads the WAV metadata.
The live sidecar path instead requests PCM16 mono 16 kHz streaming, preserves
samples split across arbitrary byte-chunk boundaries, applies one in-flight
worker push at a time, and caps each session at five minutes. It is currently
English-only and CPU-only. The composer integration is enabled on Android,
iOS, macOS, and Windows, cancelled on foreground lifecycle changes, and
disabled on Linux and Web.
Capture for both microphone workflows is code-supported on Android, iOS, macOS,
and Windows. It remains disabled on Linux with the current recorder plugin
because its external-tool startup is not safe to expose without a stronger
preflight; selected-file transcription is unchanged there. **Ask with voice**
also requires a native direct-media audio model or an audio-capable projector
and is unavailable on Web. These capability gates do not establish real-model
behavior on every platform. The experimental llama.cpp GGUF voice path has
engine-level Metal evidence on macOS, while current packaged microphone UI
evidence is LiteRT-LM on macOS. Android, iOS, and Windows still require
real-model/device evidence through the `chat-app-voice-question-smoke`
test-matrix row before making a platform validation claim.

The voice-question path makes a best-effort attempt to delete its temporary WAV
after reading it, but keeps the encoded audio bytes in the in-memory
conversation history so later turns and regeneration preserve context. Those
operations can reprocess the audio and consume additional memory. It remains
generic audio-input chat and does not change the typed STT support matrix above.

LiteRT-LM first initializes audio preprocessing on the selected backend, then
transparently retries CPU if that executor is incompatible and remembers the
working choice for the loaded model. For the validated Gemma 4 E2B bundle, GPU
text/vision with CPU audio is the resolved path. This is bundle/runtime
compatibility behavior, not a universal LiteRT-LM CPU-audio limitation.

The chat app's native mobile-and-desktop catalog includes the Qwen3-ASR 0.6B
Q8_0 model/projector pair. It remains excluded from the Web catalog. Its
immutable artifact revision, byte sizes, and SHA-256 digests are pinned, and
the native downloader verifies both files before the model can be selected.

## Known limits

- Qwen3-ASR may emit a leading `language English<asr_text>` marker. llamadart
  strips that marker, but does not expose it as reliable detected-language
  metadata until language behavior has a dedicated validation contract.
- There are no word/segment timestamps, confidence scores, speaker
  diarization, or incremental audio frames in the current backend.
- Native inference backend correctness and performance remain device dependent;
  establish a CPU baseline before claiming GPU support for a deployment.
- The local real-model smoke has passed on macOS arm64 CPU, and a separate
  chat-app/manual smoke has passed on Metal. The full chat-app
  model/projector, microphone, and final-transcript flow has also passed on a
  physical Pixel using CPU inference and in the iOS Simulator. A physical
  iPhone and Windows remain unverified; Linux keeps selected-file STT but not
  microphone capture. Web enablement is tracked separately in
  [issue #329](https://github.com/leehack/llamadart/issues/329).
- TTS is a separate typed API with different models, projector capabilities,
  inputs, and output events. See [Text to Speech](./text-to-speech).
