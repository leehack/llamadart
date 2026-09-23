@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:test/test.dart';

const _modelPathKey = 'LLAMADART_STT_MODEL_PATH';
const _mmprojPathKey = 'LLAMADART_STT_MMPROJ_PATH';
const _audioPathKey = 'LLAMADART_STT_AUDIO_PATH';
const _expectedTextKey = 'LLAMADART_STT_EXPECTED_TEXT';
const _asrPrompt =
    '<|im_start|>user\n<__media__>Transcribe this audio accurately.'
    '<|im_end|>\n<|im_start|>assistant\n';

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

  for (final (route, chunkEval) in [
    ('primary mtmd', null),
    ('wrapper mtmd fallback', true),
    ('wrapper mtmd fallback without chunk-level functions', false),
  ]) {
    test(
      'an audio generate whose cancel is already set yields nothing ($route)',
      () async {
        await _withSpeechContext(chunkEval, 4096, (
          service,
          context,
          audioPath,
          expectedText,
        ) async {
          final cancelToken = calloc<Int8>();
          try {
            Future<(String, int)> generate({required bool cancelled}) async {
              cancelToken.value = cancelled ? 1 : 0;
              final bytes = <int>[];
              await for (final piece in service.generate(
                context,
                _asrPrompt,
                const GenerationParams(
                  maxTokens: 64,
                  temp: 0,
                  topK: 1,
                  seed: 1,
                ),
                cancelToken.address,
                parts: [LlamaAudioContent(path: audioPath)],
              )) {
                bytes.addAll(piece);
              }
              return (
                utf8.decode(bytes),
                service.getPerformanceContext(context).promptEvalTokens,
              );
            }

            final (transcript, promptTokens) = await generate(cancelled: false);
            expect(transcript, contains(expectedText));
            expect(promptTokens, greaterThan(1));

            final (cancelledOutput, cancelledPromptTokens) = await generate(
              cancelled: true,
            );
            expect(cancelledOutput, isEmpty);
            expect(
              cancelledPromptTokens,
              chunkEval == false ? promptTokens : lessThanOrEqualTo(1),
            );

            expect(await generate(cancelled: false), (
              transcript,
              promptTokens,
            ));
          } finally {
            calloc.free(cancelToken);
          }
        });
      },
    );

    test(
      'an audio prompt larger than the context names the failed chunk ($route)',
      () async {
        await _withSpeechContext(chunkEval, 256, (
          service,
          context,
          audioPath,
          _,
        ) async {
          final cancelToken = calloc<Int8>();
          try {
            await expectLater(
              service
                  .generate(
                    context,
                    _asrPrompt.replaceFirst(
                      '<__media__>',
                      '<__media__><__media__>',
                    ),
                    const GenerationParams(maxTokens: 8, temp: 0, topK: 1),
                    cancelToken.address,
                    parts: [
                      LlamaAudioContent(path: audioPath),
                      LlamaAudioContent(path: audioPath),
                    ],
                  )
                  .drain<void>(),
              throwsA(
                isA<Exception>().having(
                  (error) => '$error',
                  'message',
                  contains(
                    chunkEval == false
                        ? 'Multimodal prompt evaluation failed: 1. '
                        : 'Multimodal prompt evaluation failed: 1 '
                              '(failed to decode audio chunk 4). ',
                  ),
                ),
              ),
            );
          } finally {
            calloc.free(cancelToken);
          }
        });
      },
    );
  }
}

Future<void> _withSpeechContext(
  bool? chunkEval,
  int contextSize,
  Future<void> Function(
    LlamaCppService service,
    int context,
    String audioPath,
    String expectedText,
  )
  body,
) async {
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

  final service = LlamaCppService()..setLogLevel(LlamaLogLevel.none);
  try {
    service.initializeBackend();
    if (chunkEval != null) {
      expect(
        service.debugUseWrapperMtmdFallbackForTesting(chunkEval: chunkEval),
        isTrue,
      );
    }
    final modelParams = ModelParams(
      contextSize: contextSize,
      preferredBackend: GpuBackend.cpu,
      gpuLayers: 0,
    );
    final model = service.loadModel(modelPath, modelParams);
    final context = service.createContext(model, modelParams);
    service.createMultimodalContext(model, mmprojPath);
    await body(service, context, audioPath, expectedText);
  } finally {
    service.dispose();
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
