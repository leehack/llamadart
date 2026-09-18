@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _modelPathKey = 'LLAMADART_STT_MODEL_PATH';
const _mmprojPathKey = 'LLAMADART_STT_MMPROJ_PATH';
const _audioPathKey = 'LLAMADART_STT_AUDIO_PATH';
const _expectedTextKey = 'LLAMADART_STT_EXPECTED_TEXT';

void main() {
  for (final useBytes in [false, true]) {
    test(
      'transcribes a complete known audio fixture through the public API (bytes: $useBytes)',
      () async {
        final modelPath = _requiredFile(_modelPathKey);
        final mmprojPath = _requiredFile(_mmprojPathKey);
        final audioPath = _requiredFile(_audioPathKey);
        final expectedText = _requiredText(_expectedTextKey);
        if (modelPath == null ||
            mmprojPath == null ||
            audioPath == null ||
            expectedText == null) {
          return;
        }

        final engine = LlamaEngine(LlamaBackend());
        try {
          await engine.loadModel(
            modelPath,
            modelParams: const ModelParams(
              contextSize: 4096,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
            ),
          );
          await engine.loadMultimodalProjector(mmprojPath);

          final recognizer = SpeechToTextEngine(
            engine,
            modelProfile: SpeechToTextModelProfile.qwen3Asr,
          );
          final capabilities = await recognizer.capabilities;
          expect(
            capabilities.isSupported,
            isTrue,
            reason: capabilities.unsupportedReason,
          );

          final bytes = await File(audioPath).readAsBytes();
          final audio = useBytes
              ? SpeechAudioBytesInput(
                  bytes,
                  format: const SpeechAudioFormat(encoding: 'wav'),
                )
              : SpeechAudioFileInput(audioPath);
          final request = SpeechToTextRequest(
            audio: audio,
            maxOutputTokens: 512,
          );
          final prompt = await engine.chatTemplate([
            LlamaChatMessage.withContent(
              role: LlamaChatRole.user,
              content: [
                const LlamaTextContent('Transcribe this audio accurately.'),
                useBytes
                    ? LlamaAudioContent(bytes: bytes)
                    : LlamaAudioContent(path: audioPath),
              ],
            ),
          ], enableThinking: false);
          expect(prompt.tokenCount, lessThan(128));
          expect(prompt.prompt, contains('<__media__>'));
          expect(prompt.prompt, isNot(contains('input_audio')));

          Future<void> verifyTranscript() async {
            final task = await recognizer.transcribe(request);
            final events = await task.events.toList();
            final completion = await task.done;
            expect(completion.state, SpeechToTextCompletionState.completed);
            expect(events.whereType<SpeechToTextFinalEvent>(), hasLength(1));
            final result = completion.result!;
            expect(result.text, expectedText);
            expect(result.text, isNot(contains('<asr_text>')));
            expect(result.text, isNot(startsWith('language ')));
            expect(
              await engine.tokenize(result.text),
              hasLength(lessThanOrEqualTo(512)),
            );
          }

          await verifyTranscript();
          final cancelled = await recognizer.transcribe(request);
          cancelled.cancel();
          final cancellationEvents = await cancelled.events.toList();
          expect(
            (await cancelled.done).state,
            SpeechToTextCompletionState.cancelled,
          );
          expect(
            cancellationEvents.whereType<SpeechToTextFinalEvent>(),
            isEmpty,
          );
          await verifyTranscript();
          if (useBytes) {
            final invalid = await recognizer.transcribe(
              SpeechToTextRequest(
                audio: SpeechAudioBytesInput(
                  Uint8List.fromList([0, 1, 2, 3]),
                  format: const SpeechAudioFormat(encoding: 'wav'),
                ),
                maxOutputTokens: 512,
              ),
            );
            final errors = <Object>[];
            final invalidEvents = <SpeechToTextEvent>[];
            await invalid.events
                .listen(invalidEvents.add, onError: errors.add)
                .asFuture<void>()
                .catchError((Object error) {
                  errors.add(error);
                });
            expect(
              (await invalid.done).state,
              SpeechToTextCompletionState.failed,
            );
            expect(errors, hasLength(1));
            expect(errors.single, isA<LlamaException>());
            expect(invalidEvents.whereType<SpeechToTextFinalEvent>(), isEmpty);
            await verifyTranscript();
          }
        } finally {
          await engine.dispose();
        }
      },
    );
  }
}

String? _requiredText(String environmentKey) {
  final value = Platform.environment[environmentKey]?.trim();
  if (value == null || value.isEmpty) {
    markTestSkipped('Set $environmentKey to run the speech-to-text E2E.');
    return null;
  }
  return value;
}

String? _requiredFile(String environmentKey) {
  final value = Platform.environment[environmentKey];
  if (value == null || value.isEmpty) {
    markTestSkipped('Set $environmentKey to run the speech-to-text E2E.');
    return null;
  }
  if (!File(value).existsSync()) {
    throw StateError('$environmentKey does not exist: $value');
  }
  return value;
}
