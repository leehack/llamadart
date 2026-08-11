@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _modelPathKey = 'LLAMADART_STT_MODEL_PATH';
const _mmprojPathKey = 'LLAMADART_STT_MMPROJ_PATH';
const _audioPathKey = 'LLAMADART_STT_AUDIO_PATH';
const _expectedTextKey = 'LLAMADART_STT_EXPECTED_TEXT';

void main() {
  test(
    'transcribes a complete known audio fixture through the public API',
    () async {
      final modelPath = _requiredFile(_modelPathKey);
      final mmprojPath = _requiredFile(_mmprojPathKey);
      final audioPath = _requiredFile(_audioPathKey);
      if (modelPath == null || mmprojPath == null || audioPath == null) {
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

        final recognizer = SpeechToTextEngine(engine);
        final capabilities = await recognizer.capabilities;
        expect(
          capabilities.isSupported,
          isTrue,
          reason: capabilities.unsupportedReason,
        );

        final task = await recognizer.transcribe(
          SpeechToTextRequest(
            audio: SpeechAudioFileInput(audioPath),
            maxOutputTokens: 512,
          ),
        );
        final events = await task.events.toList();
        final completion = await task.done;

        expect(completion.state, SpeechToTextCompletionState.completed);
        expect(events.whereType<SpeechToTextFinalEvent>(), hasLength(1));
        final result = completion.result!;
        expect(result.text, isNotEmpty);
        expect(result.text, isNot(contains('<asr_text>')));
        expect(result.text, isNot(startsWith('language ')));

        final expected = Platform.environment[_expectedTextKey]?.trim();
        if (expected != null && expected.isNotEmpty) {
          expect(result.text, expected);
        }
      } finally {
        await engine.dispose();
      }
    },
  );
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
