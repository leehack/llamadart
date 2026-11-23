@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../test_helper.dart';

// stories15M never emits an end-of-generation token, so generation that runs
// past one is checked on Qwen3.5 in
// core/engine/qwen35_ignore_eos_test.dart (local-only).
void main() {
  late LlamaEngine engine;

  setUpAll(() async {
    engine = LlamaEngine(LlamaBackend());
    final file = await TestHelper.getTestModel();
    await engine.loadModel(
      file.path,
      modelParams: const ModelParams(
        contextSize: 256,
        gpuLayers: 0,
        preferredBackend: GpuBackend.cpu,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      ),
    );
  });
  tearDownAll(() => engine.dispose());

  const params = GenerationParams(
    maxTokens: 8,
    temp: 0,
    seed: 1,
    ignoreEos: true,
  );

  test('native llama.cpp reports ignoreEos', () async {
    expect((await engine.capabilities).supportsIgnoreEos, isTrue);
  });

  test(
    'ignoreEos with a grammar is rejected and the engine recovers',
    () async {
      await expectLater(
        engine.generate(
          'Once upon a time',
          params: params.copyWith(grammar: 'root ::= "a"'),
        ),
        emitsError(
          isA<LlamaUnsupportedException>().having(
            (error) => error.toString(),
            'message',
            contains('ignoreEos'),
          ),
        ),
      );
      expect(
        await engine.generate('Once upon a time', params: params).join(),
        isNotEmpty,
      );
    },
  );
}
