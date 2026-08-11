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
| Native llama.cpp / GGUF | Model + projector dependent | Experimental Qwen3-ASR adapter; complete WAV/MP3/FLAC file or bytes, final transcript only | No public Dart API |
| WebGPU / GGUF | Bridge + model dependent | Unsupported | Unsupported |
| Native LiteRT-LM / `.litertlm` | Bundle dependent through normal generation | Unsupported by the pinned native artifact | Unsupported by the pinned native artifact |
| LiteRT-LM Web | Unsupported | Unsupported | Unsupported |

“Generic audio-input chat” means an audio content part is processed by normal
generation. It does not imply a transcript schema, stable ASR behavior, or TTS.
The typed STT API adds a stable Dart result/cancellation boundary, but the first
backend still performs whole-audio llama.cpp generation internally. Its
`SpeechToTextImplementation.multimodalPromptAdapter` capability makes that
distinction inspectable; it is not a dedicated native ASR engine.

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

The Flutter chat example exposes three different audio actions on compatible
native GGUF models:

- **Attach Audio** sends audio through normal multimodal chat.
- **Transcribe Audio** selects one file and uses `SpeechToTextEngine`.
- The microphone button records a temporary foreground WAV. **Stop &
  transcribe** finalizes that file and passes it to `SpeechToTextEngine`, while
  **Discard** cancels capture and removes the partial file.

The transcription action is hidden on Web and for current LiteRT-LM bundles.
Microphone recordings are capped at five minutes, cancelled when the app is
backgrounded, and deleted after transcription. This remains a whole-file
workflow: it does not produce live partial transcripts while the user speaks.
The recorder requests 16 kHz mono WAV, but hardware may choose another valid
sample rate; the downstream native decoder reads the WAV metadata.
Capture is enabled on Android, iOS, macOS, and Windows. It remains disabled on
Linux with the current recorder plugin because its external-tool startup is not
safe to expose without a stronger preflight; selected-file transcription is
unchanged there.

The chat app's desktop catalog includes the validated Qwen3-ASR 0.6B Q8_0
model/projector pair. Its immutable artifact revision, byte sizes, and SHA-256
digests are pinned, and the native downloader verifies both files before the
model can be selected.

## Known limits

- Qwen3-ASR may emit a leading `language English<asr_text>` marker. llamadart
  strips that marker, but does not expose it as reliable detected-language
  metadata until language behavior has a dedicated validation contract.
- There are no word/segment timestamps, confidence scores, speaker
  diarization, or incremental audio frames in the current backend.
- Native inference backend correctness and performance remain device dependent;
  establish a CPU baseline before claiming GPU support for a deployment.
- The local real-model smoke has passed on macOS arm64 CPU. A separate
  chat-app/manual smoke has passed on Metal. The redistributable fixture and
  Linux, Windows, Android, and iOS validation remain tracked in
  [issue #325](https://github.com/leehack/llamadart/issues/325).
- TTS is not exposed. llama.cpp's current Qwen3-TTS helper is experimental and
  requires a stable downstream native wrapper before it can support a public
  Dart `TextToSpeechEngine`.
