---
name: llamadart-speech
description: >-
  Use when adding speech to a llamadart app: transcribing audio files with
  Qwen3-ASR through SpeechToTextEngine, streaming live PCM dictation with
  LiteRT-LM ASR, synthesizing speech with Qwen3-TTS through
  TextToSpeechEngine, saving WAV output, handling LlamaAudioFormatException or
  LlamaSpeechTranscriptTruncatedException, or checking speech support on
  native and Web runtimes.
---

# Speech to text and text to speech with llamadart

## Guidelines

- Speech uses the experimental typed `SpeechToTextEngine` and
  `TextToSpeechEngine`, not chat. `LlamaAudioContent` in `engine.create` is
  plain audio chat with no transcript contract (see the multimodal guide).
- Pick the path by model family:
  - Qwen3-ASR (whole file, one final transcript):
    `SpeechToTextEngine(engine, modelProfile: SpeechToTextModelProfile.qwen3Asr)`
    over a `LlamaEngine` with the Qwen3-ASR GGUF and its mmproj loaded. Native
    llama.cpp, or WebGPU with bridge assets `v0.1.30+`.
  - LiteRT-LM ASR (live partials, then a final transcript):
    `SpeechToTextEngine.liteRtLm(LiteRtLmAsrRuntimeConfig.source(...))` with
    a `.tflite` model and tokenizer JSON as `ModelSource`s; remote ones are
    downloaded into the model cache before the first task (`download`,
    `onProgress`, `store` on `liteRtLm`). The path constructor is deprecated. Native only, CPU only
    (`LiteRtLmAsrBackend.cpu`). Presets: `parakeetTdt0_6bV3`,
    `parakeetCtc0_6b`, `moonshineTiny`, `whisperTiny`, `qwen3Asr0_6b`; the
    files must match the preset. It does not use any loaded chat model.
  - Qwen3-TTS: `TextToSpeechEngine(engine, modelProfile:
    TextToSpeechModelProfile.qwen3Tts)` with the Qwen3-TTS GGUF and its
    audio-generation mmproj. Native llama.cpp, or WebGPU with bridge assets
    `v0.1.33+`. LiteRT-LM (native and Web) has no TTS.
- The `modelProfile` is a required declaration; audio support alone never
  makes a model ASR. `SpeechToTextModelProfile.liteRtLmDedicated` is only
  valid through `SpeechToTextEngine.liteRtLm` (the default constructor throws
  `ArgumentError`).
- Always `await recognizer.capabilities` / `synthesizer.capabilities` after
  both model and projector load, and gate on `isSupported`, showing
  `unsupportedReason`. A loaded projector does not prove audio support or a
  matching model. A chat-model LiteRT-LM engine reports unsupported for STT.
- Use the capability fields instead of assuming: `inputKinds`,
  `encodedAudioFormats`, `supportsPartialResults`, `supportsStreamingInput`
  (STT); `sampleRateHz`, `supportedLanguages`, `supportsSpeakerReference`,
  `speakerReferenceInputKinds` (TTS).
- Audio input types are `SpeechAudioFileInput(path)`,
  `SpeechAudioBytesInput(bytes)` and `SpeechAudioPcmInput(Float32List)`, each
  with optional `SpeechAudioFormat(sampleRateHz, channelCount, encoding,
  mimeType)`.
  - Qwen3-ASR takes encoded WAV, MP3 or FLAC files or bytes; raw PCM throws
    `LlamaUnsupportedException`.
  - On Web, file paths are rejected; pass bytes with
    `SpeechAudioFormat(encoding: 'wav' | 'mp3' | 'flac')`. Missing or other
    encodings throw `LlamaAudioFormatException`.
  - LiteRT-LM takes mono 16 kHz `pcm-f32le` samples in -1.0..1.0 only
    (`SpeechAudioPcmInput`'s default format). Other formats or empty samples
    throw `LlamaAudioFormatException`. The API does not record or resample.
- `transcribe` / `synthesize` throw typed errors during preflight (invalid
  input, `LlamaUnsupportedException`, `LlamaStateException` when a speech task
  is already active). After a task starts, failures arrive as an error on the
  single-subscription `task.events` stream and as
  `SpeechToTextCompletionState.failed` / `TextToSpeechCompletionState.failed`
  with `error` on `task.done`.
- Qwen3-ASR limits:
  - It is validated only up to 30 seconds per input; longer audio can
    silently drop or repeat sentences. Split recordings into windows of 30
    seconds or less.
  - The audio prompt costs about 13 tokens per second and shares context
    with the transcript. On native llama.cpp, reaching the context size or
    `maxOutputTokens` (default 1024) fails with
    `LlamaSpeechTranscriptTruncatedException`. Read `limit`
    (`LlamaSpeechTranscriptLimit.maxOutputTokens` or `.contextSize`) and
    `partialTranscript`. On Web, truncation is not detected and the task
    completes.
  - An empty transcript (for example silence) fails with
    `LlamaSpeechException`.
  - A nonempty `languageHint` throws `LlamaUnsupportedException`; use
    `contextPrompt` for vocabulary. LiteRT-LM rejects `contextPrompt`.
- Results carry no timestamps, confidence or diarization. Qwen3-ASR returns
  one untimed segment. Only LiteRT-LM emits `SpeechToTextPartialEvent`:
  `confirmedText` is stable, while `pendingText` can change on the next
  window.
- LiteRT-LM streaming: `await recognizer.startStream()`, then `await` every
  `session.addPcm(chunk)` so native backpressure throttles the producer.
  Call `await session.finish()` to flush the last window, then
  `await session.done`. Inference runs in a worker isolate; direct
  `LiteRtLmRuntimeClient` / `LiteRtLmAsrRuntimeSession` calls are synchronous
  and must stay off a Flutter UI isolate.
- Cancellation is cooperative: `task.cancel()` or `await session.cancel()`.
  `done` then reports `cancelled`. Cancelling or pausing the `events`
  subscription does not stop or throttle inference. `unloadModel()` and
  `dispose()` cancel an active Qwen3 speech task.
- One typed speech task per `LlamaEngine`: all STT and TTS wrappers over an
  engine share a lease. Do not start chat generation on that engine until
  `task.done` completes. A LiteRT-LM recognizer allows one task per instance.
- TTS returns one complete buffer of interleaved float32 PCM (24 kHz mono for
  Qwen3-TTS; read `result.sampleRateHz` and `channelCount` rather than
  hard-coding). There are no playable chunks (`supportsIncrementalAudio` is
  false).
  - `TextToSpeechProgressEvent` (`phase`, `promptTokensRemaining`,
    `framesGenerated`) is for status UI only.
  - `result.truncated` is true when generation hit `maxFrames` (default
    512); it is not an error.
  - Use `result.toWavBytes()` for 16-bit WAV and `result.duration` for
    length.
- TTS `language` accepts the codes in `supportedLanguages` (`zh`, `en`, `ja`,
  `ko`, `de`, `fr`, `ru`, `pt`, `es`, `it`) or their English names
  (`'English'` becomes `en`). Anything else, empty text, or bad sampling values
  throw `LlamaTextToSpeechException` before the task starts.
- Speaker references must be encoded audio (`SpeechAudioBytesInput` is
  portable; file paths are native only; PCM throws). Treat them as sensitive
  user data.
- Web needs enough browser memory. The Qwen3-ASR 0.6B Q8_0 pair is about
  1.02 GB. The Qwen3-TTS pair is about 1.48 GB and also needs WebAssembly
  memory64. Model loading itself is covered by the llamadart-getting-started
  skill.

## Examples

Transcribe a file with Qwen3-ASR and handle truncation:

```dart
import 'package:llamadart/llamadart.dart';

Future<String> transcribeFile(LlamaEngine engine, String wavPath) async {
  final SpeechToTextEngine recognizer = SpeechToTextEngine(
    engine,
    modelProfile: SpeechToTextModelProfile.qwen3Asr,
  );
  final SpeechToTextCapabilities capabilities = await recognizer.capabilities;
  if (!capabilities.isSupported) {
    throw LlamaUnsupportedException(capabilities.unsupportedReason!);
  }

  final SpeechToTextTask task = await recognizer.transcribe(
    SpeechToTextRequest(
      audio: SpeechAudioFileInput(wavPath),
      contextPrompt: 'llamadart, Qwen3-ASR',
    ),
  );

  String transcript = '';
  try {
    await for (final SpeechToTextEvent event in task.events) {
      if (event is SpeechToTextFinalEvent) {
        transcript = event.result.text;
      }
    }
  } on LlamaSpeechTranscriptTruncatedException catch (error) {
    print('Stopped at ${error.limit.name}; split the audio into shorter windows.');
    return error.partialTranscript;
  } on LlamaAudioFormatException catch (error) {
    print('Unsupported audio: $error');
    rethrow;
  }

  final SpeechToTextCompletion completion = await task.done;
  print(completion.state);
  return transcript;
}
```

Live dictation with LiteRT-LM (native only):

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<String?> dictate(Stream<Float32List> mono16KhzChunks) async {
  final SpeechToTextEngine recognizer = SpeechToTextEngine.liteRtLm(
    LiteRtLmAsrRuntimeConfig.source(
      model: ModelSource.path('/models/moonshine_tiny.tflite'),
      tokenizer: ModelSource.path('/models/tokenizer.json'),
      modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
    ),
  );
  final SpeechToTextCapabilities capabilities = await recognizer.capabilities;
  if (!capabilities.isSupported) {
    throw LlamaUnsupportedException(capabilities.unsupportedReason!);
  }

  final SpeechToTextStreamingSession session = await recognizer.startStream();
  final StreamSubscription<SpeechToTextEvent> events = session.events.listen(
    (SpeechToTextEvent event) {
      if (event is SpeechToTextPartialEvent) {
        print('stable=${event.confirmedText} pending=${event.pendingText}');
      }
    },
    onError: (Object error) => print('Recognition failed: $error'),
  );

  try {
    await for (final Float32List chunk in mono16KhzChunks) {
      await session.addPcm(chunk);
    }
    await session.finish();
  } catch (_) {
    await session.cancel();
  }

  final SpeechToTextCompletion completion = await session.done;
  await events.cancel();
  print(completion.state);
  return completion.result?.text;
}
```

Synthesize speech with Qwen3-TTS and save a WAV file (native):

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<void> speak(LlamaEngine engine, String text, String outPath) async {
  final TextToSpeechEngine synthesizer = TextToSpeechEngine(
    engine,
    modelProfile: TextToSpeechModelProfile.qwen3Tts,
  );
  final TextToSpeechCapabilities capabilities = await synthesizer.capabilities;
  if (!capabilities.isSupported) {
    throw LlamaUnsupportedException(capabilities.unsupportedReason!);
  }

  final TextToSpeechTask task = await synthesizer.synthesize(
    TextToSpeechRequest(text: text, language: 'English', maxFrames: 1024),
  );

  try {
    await for (final TextToSpeechEvent event in task.events) {
      if (event is TextToSpeechProgressEvent) {
        print('${event.phase.name}: ${event.framesGenerated} frames');
      } else if (event is TextToSpeechFinalEvent) {
        final TextToSpeechResult result = event.result;
        if (result.truncated) {
          print('Hit maxFrames; audio may end early.');
        }
        final Uint8List wav = result.toWavBytes();
        await File(outPath).writeAsBytes(wav);
        print('Wrote ${result.duration} at ${result.sampleRateHz} Hz');
      }
    }
  } on LlamaException catch (error) {
    print('Synthesis failed: $error');
  }

  final TextToSpeechCompletion completion = await task.done;
  print(completion.state);
}
```

## More

- Speech to text: https://llamadart.leehack.com/docs/guides/speech-to-text
- Text to speech: https://llamadart.leehack.com/docs/guides/text-to-speech
- Multimodal audio chat: https://llamadart.leehack.com/docs/guides/multimodal
- WebGPU bridge: https://llamadart.leehack.com/docs/platforms/webgpu-bridge
- Support matrix: https://llamadart.leehack.com/docs/platforms/support-matrix
