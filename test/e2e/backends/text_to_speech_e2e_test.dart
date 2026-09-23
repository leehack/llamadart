@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:test/test.dart';

const _modelPathKey = 'LLAMADART_TTS_MODEL_PATH';
const _mmprojPathKey = 'LLAMADART_TTS_MMPROJ_PATH';
const _outputPathKey = 'LLAMADART_TTS_OUTPUT_PATH';
const _serviceRequest = BackendTextToSpeechRequest(
  text: 'Hello from llamadart.',
  language: 'english',
  maxFrames: 64,
  seed: 1,
);
final _cancelled = throwsA(
  isA<LlamaTextToSpeechException>().having(
    (error) => error.message,
    'message',
    'Text-to-speech synthesis was cancelled.',
  ),
);

void main() {
  test('synthesizes a playable WAV through the public API', () async {
    final modelPath = _requiredFile(_modelPathKey);
    final mmprojPath = _requiredFile(_mmprojPathKey);
    final outputPath = Platform.environment[_outputPathKey]?.trim();
    if (modelPath == null || mmprojPath == null) {
      return;
    }
    if (outputPath == null || outputPath.isEmpty) {
      markTestSkipped('Set $_outputPathKey to write the synthesized WAV.');
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

      final synthesizer = TextToSpeechEngine(
        engine,
        modelProfile: TextToSpeechModelProfile.qwen3Tts,
      );
      final capabilities = await synthesizer.capabilities;
      expect(
        capabilities.isSupported,
        isTrue,
        reason: capabilities.unsupportedReason,
      );
      expect(capabilities.sampleRateHz, 24000);
      expect(capabilities.channelCount, 1);

      final task = await synthesizer.synthesize(
        const TextToSpeechRequest(
          text:
              'Hello from llamadart. This audio was generated locally on your device.',
          language: 'English',
          maxFrames: 384,
          seed: 1,
        ),
      );
      final events = await task.events.toList();
      final completion = await task.done;

      expect(completion.state, TextToSpeechCompletionState.completed);
      expect(events.whereType<TextToSpeechProgressEvent>(), isNotEmpty);
      expect(events.whereType<TextToSpeechFinalEvent>(), hasLength(1));
      final result = completion.result!;
      expect(result.samples, isNotEmpty);
      expect(result.sampleRateHz, 24000);
      expect(result.channelCount, 1);
      expect(result.duration, greaterThan(Duration.zero));

      final output = File(outputPath);
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(result.toWavBytes(), flush: true);
      expect(output.lengthSync(), greaterThan(44));

      print(
        'RESULT text_to_speech '
        'sampleRate=${result.sampleRateHz} channels=${result.channelCount} '
        'samples=${result.samples.length} frames=${result.framesGenerated} '
        'truncated=${result.truncated}',
      );
    } finally {
      await engine.dispose();
    }
  });

  test('a cancel flag raised before synthesis starts cancels it', () async {
    await _withTextToSpeechService((service, context, projector) async {
      final flag = calloc<Int8>()..value = 1;
      try {
        final progress = <BackendTextToSpeechProgress>[];
        await expectLater(
          service.synthesizeTextToSpeech(
            context,
            projector,
            _serviceRequest,
            flag.address,
            onProgress: progress.add,
          ),
          _cancelled,
        );
        expect(progress, isEmpty);
      } finally {
        calloc.free(flag);
      }
    });
  });

  test('a cancel flag raised between steps stops the next step only when the '
      'runtime can attach it', () async {
    await _withTextToSpeechService((service, context, projector) async {
      final attachable =
          service.debugTtsCancelExportsForTesting()?.setCancelFlag ?? false;
      final flag = calloc<Int8>();
      try {
        var steps = 0;
        final synthesis = service.synthesizeTextToSpeech(
          context,
          projector,
          _serviceRequest,
          flag.address,
          onProgress: (_) {
            steps += 1;
            flag.value = 1;
          },
        );
        if (attachable) {
          await expectLater(synthesis, _cancelled);
          expect(steps, 1);
        } else {
          expect((await synthesis).samples, isNotEmpty);
          expect(steps, greaterThan(1));
        }
      } finally {
        calloc.free(flag);
      }
    });
  });
}

Future<void> _withTextToSpeechService(
  Future<void> Function(LlamaCppService service, int context, int projector)
  body,
) async {
  final modelPath = _requiredFile(_modelPathKey);
  final mmprojPath = _requiredFile(_mmprojPathKey);
  if (modelPath == null || mmprojPath == null) {
    return;
  }
  final service = LlamaCppService()..setLogLevel(LlamaLogLevel.none);
  try {
    service.initializeBackend();
    const modelParams = ModelParams(
      contextSize: 4096,
      preferredBackend: GpuBackend.cpu,
      gpuLayers: 0,
    );
    final model = service.loadModel(modelPath, modelParams);
    final context = service.createContext(model, modelParams);
    final projector = service.createMultimodalContext(model, mmprojPath);
    await body(service, context, projector);
  } finally {
    service.dispose();
  }
}

String? _requiredFile(String environmentKey) {
  final value = Platform.environment[environmentKey];
  if (value == null || value.isEmpty) {
    markTestSkipped('Set $environmentKey to run the text-to-speech E2E.');
    return null;
  }
  if (!File(value).existsSync()) {
    throw StateError('$environmentKey does not exist.');
  }
  return value;
}
