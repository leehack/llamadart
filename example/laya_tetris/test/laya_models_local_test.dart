import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/laya/benchmark.dart';
import 'package:laya_tetris_example/laya/models.dart';
import 'package:llamadart/llamadart.dart';

/// Folder with `laya-Q8_0.gguf` and `laya-head.safetensors`.
final String? modelDir = Platform.environment['LAYA_MODEL_DIR'];

void main() {
  LayaSetup setup({required String head, String? tunedHead}) => LayaSetup(
    backbone: ModelSource.path('$modelDir/laya-Q8_0.gguf'),
    head: ModelSource.path(head),
    tunedHead: tunedHead == null ? null : ModelSource.path(tunedHead),
    backend: GpuBackend.cpu,
  );

  group(
    'LayaModels.load with local models',
    skip: modelDir == null ? 'Set LAYA_MODEL_DIR to run.' : false,
    () {
      test('reports a tuned head that fails and keeps the base head', () async {
        final models = await LayaModels.load(
          setup(
            head: '$modelDir/laya-head.safetensors',
            tunedHead: '$modelDir/missing-head.safetensors',
          ),
        );
        addTearDown(models.dispose);

        expect(models.tuned, isNull);
        expect(models.tunedError, contains('missing-head.safetensors'));
        final results = await models.base([speedRequest()]);
        expect(results.single.choices['move']!.probabilities, hasLength(6));
      });

      test('throws when the base head fails to load', () async {
        await expectLater(
          LayaModels.load(setup(head: '$modelDir/missing-head.safetensors')),
          throwsA(isA<Exception>()),
        );
      });
    },
  );
}
