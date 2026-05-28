@TestOn('vm')
library;

import 'dart:ffi';

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('LiteRtLmRuntimeMetrics serializes runtime counters', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 12,
      outputTokens: 34,
      timeToFirstTokenSeconds: 0.5,
      initSeconds: 1.25,
      prefillTokensPerSecond: 20.0,
      decodeTokensPerSecond: 30.0,
      wallMilliseconds: 4567,
    );

    expect(metrics.toJson(), {
      'inputTokens': 12,
      'outputTokens': 34,
      'timeToFirstTokenSeconds': 0.5,
      'initSeconds': 1.25,
      'prefillTokensPerSecond': 20.0,
      'decodeTokensPerSecond': 30.0,
      'wallMilliseconds': 4567,
    });
  });

  test('LiteRtLmRuntimeResult keeps generated text with metrics', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 1,
      outputTokens: 2,
      timeToFirstTokenSeconds: null,
      initSeconds: null,
      prefillTokensPerSecond: null,
      decodeTokensPerSecond: null,
      wallMilliseconds: 3,
    );

    const result = LiteRtLmRuntimeResult(text: 'hello', metrics: metrics);

    expect(result.text, 'hello');
    expect(result.metrics, same(metrics));
  });

  test('macOS LiteRT-LM cache lookup follows the current runtime ABI', () {
    expect(
      liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.macosArm64),
      const <String>['macos_arm64', 'macos/arm64'],
    );
    expect(
      liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.macosX64),
      const <String>['macos_x64', 'macos/x64'],
    );
    expect(liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.linuxX64), isEmpty);
  });

  test('engine create failure diagnostics include fallback guidance', () {
    expect(
      liteRtLmEngineCreateFailureMessage(
        backend: 'npu',
        modelPath: '/models/gemma-4-E2B-it.litertlm',
      ),
      allOf(
        contains('backend "npu"'),
        contains('gemma-4-E2B-it.litertlm'),
        contains('Android NPU delegate'),
        contains('backend "gpu"'),
        contains('backend "cpu"'),
      ),
    );
    expect(
      liteRtLmEngineCreateFailureMessage(
        backend: 'gpu',
        modelPath: '/models/gemma-4-E2B-it.litertlm',
      ),
      allOf(contains('GPU delegate'), contains('backend "cpu"')),
    );
  });

  test(
    'LiteRtLmRuntimeClient validates counts before native initialization',
    () {
      final client = LiteRtLmRuntimeClient();

      expect(
        client.initialize(modelPath: 'model.litertlm', maxTokens: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'maxTokens',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', outputTokens: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'outputTokens',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', prefillTokens: -1),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'prefillTokens',
          ),
        ),
      );
    },
  );

  test('LiteRtLmRuntimeClient validates benchmark loop counts', () {
    final client = LiteRtLmRuntimeClient();

    expect(
      client.run(prompt: 'hello', warmupRuns: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'warmupRuns',
        ),
      ),
    );
    expect(
      client.run(prompt: 'hello', measuredRuns: 0),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'measuredRuns',
        ),
      ),
    );
  });
}
