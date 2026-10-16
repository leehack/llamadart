import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('LiteRT-LM ASR config keeps bounded streaming defaults', () {
    const config = LiteRtLmAsrRuntimeConfig(
      modelPath: '/models/moonshine.tflite',
      tokenizerPath: '/models/tokenizer.json',
      modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
    );

    expect(config.backend, LiteRtLmAsrBackend.cpu);
    expect(LiteRtLmAsrBackend.values, [LiteRtLmAsrBackend.cpu]);
    expect(config.numberOfThreads, 4);
    expect(config.maxBufferedAudio, const Duration(seconds: 30));
    expect(config.overlapRatio, 0.6);
  });

  test('LiteRT-LM ASR source config names its files as the runtime paths', () {
    final config = LiteRtLmAsrRuntimeConfig.source(
      model: ModelSource.path('/models/moonshine.tflite'),
      tokenizer: ModelSource.parse('https://example.com/tokenizer.json'),
      modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
      numberOfThreads: 2,
    );

    expect(config.model!.path, '/models/moonshine.tflite');
    expect(config.modelPath, '/models/moonshine.tflite');
    expect(config.tokenizerPath, 'https://example.com/tokenizer.json');
    expect(config.numberOfThreads, 2);
    expect(config.overlapRatio, 0.6);
  });

  for (final preset in LiteRtLmAsrModelPreset.values) {
    test('$preset preserves explicit overlaps in both config constructors', () {
      for (final overlap in [0.0, 0.2, 0.4, 0.6, 0.9]) {
        final legacy = LiteRtLmAsrRuntimeConfig(
          modelPath: 'model.tflite',
          tokenizerPath: 'tokenizer.json',
          modelPreset: preset,
          overlapRatio: overlap,
        );
        final source = LiteRtLmAsrRuntimeConfig.source(
          model: ModelSource.path('model.tflite'),
          tokenizer: ModelSource.path('tokenizer.json'),
          modelPreset: preset,
          overlapRatio: overlap,
        );
        expect(legacy.overlapRatio, overlap);
        expect(source.overlapRatio, overlap);
      }
    });
    if (preset != LiteRtLmAsrModelPreset.moonshineTiny) {
      test(
        '$preset keeps its existing default in both config constructors',
        () {
          final legacy = LiteRtLmAsrRuntimeConfig(
            modelPath: 'model.tflite',
            tokenizerPath: 'tokenizer.json',
            modelPreset: preset,
          );
          final source = LiteRtLmAsrRuntimeConfig.source(
            model: ModelSource.path('model.tflite'),
            tokenizer: ModelSource.path('tokenizer.json'),
            modelPreset: preset,
          );
          expect(legacy.overlapRatio, 0.4);
          expect(source.overlapRatio, 0.4);
        },
      );
    }
  }

  test('LiteRT-LM ASR flow-control results stay explicit', () {
    const push = LiteRtLmAsrPushResult(acceptedSamples: 1600, wouldBlock: true);
    const process = LiteRtLmAsrProcessResult(
      state: LiteRtLmAsrProcessState.update,
      confirmedText: 'confirmed',
      unconfirmedText: 'pending',
    );

    expect(push.acceptedSamples, 1600);
    expect(push.wouldBlock, isTrue);
    expect(process.confirmedText, 'confirmed');
    expect(process.unconfirmedText, 'pending');
    expect(process.isFinal, isFalse);
  });
}
