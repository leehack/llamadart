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
| Native llama.cpp / GGUF | Model + projector dependent | Experimental; complete file/bytes/PCM input, final transcript only | No public Dart API |
| WebGPU / GGUF | Bridge + model dependent | Unsupported | Unsupported |
| Native LiteRT-LM / `.litertlm` | Bundle dependent through normal generation | Unsupported by the pinned native artifact | Unsupported by the pinned native artifact |
| LiteRT-LM Web | Unsupported | Unsupported | Unsupported |

“Generic audio-input chat” means an audio content part is processed by normal
generation. It does not imply a transcript schema, stable ASR behavior, or TTS.
The typed STT API adds a stable Dart result/cancellation boundary, but the first
backend still performs whole-audio llama.cpp generation internally.

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

final recognizer = SpeechToTextEngine(engine);
final capabilities = await recognizer.capabilities;
if (!capabilities.isSupported) {
  throw StateError(capabilities.unsupportedReason!);
}
```

Always check `capabilities` after both artifacts are loaded. Projector load
success alone does not prove audio support.

## Transcribe a complete file

```dart
final task = await recognizer.transcribe(
  const SpeechToTextRequest(
    audio: SpeechAudioFileInput('/recordings/meeting.wav'),
    languageHint: 'en',
    contextPrompt: 'llamadart, Qwen3-ASR',
  ),
);

await for (final event in task.events) {
  if (event is SpeechToTextFinalEvent) {
    print(event.result.text);
    print(event.result.language);
  }
}

final completion = await task.done;
print(completion.state);
```

Native llama.cpp currently decodes WAV, MP3, and FLAC file or byte inputs. Raw
PCM uses `SpeechPcmInput` and currently requires mono 16 kHz `Float32` samples:

```dart
final input = SpeechPcmInput(
  samples,
  format: const SpeechAudioFormat(
    sampleRateHz: 16000,
    channelCount: 1,
    sampleFormat: SpeechAudioSampleFormat.float32,
  ),
);
```

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

Cancelling a stream subscription does not cancel the native task. One
`SpeechToTextEngine` wrapper allows one active task because its `LlamaEngine`
owns a single generation context.

## Chat app

The Flutter chat example exposes two different audio actions on compatible
native GGUF models:

- **Attach Audio** sends audio through normal multimodal chat.
- **Transcribe Audio** selects one file and uses `SpeechToTextEngine`.

The transcription action is hidden on Web and for current LiteRT-LM bundles.
It is a file workflow, not live microphone capture.

## Known limits

- Qwen3-ASR may emit a leading `language English<asr_text>` marker. llamadart
  normalizes that leading marker and exposes the language separately.
- There are no word/segment timestamps, confidence scores, speaker
  diarization, or incremental audio frames in the current backend.
- Native inference backend correctness and performance remain device dependent;
  establish a CPU baseline before claiming GPU support for a deployment.
- TTS is not exposed. llama.cpp's current Qwen3-TTS helper is experimental and
  requires a stable downstream native wrapper before it can support a public
  Dart `TextToSpeechEngine`.
