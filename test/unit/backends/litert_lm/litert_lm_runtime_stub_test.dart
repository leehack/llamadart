library;

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime_stub.dart';
import 'package:test/test.dart';

void main() {
  test('constructing the stub client reports the platform requirement', () {
    expect(
      LiteRtLmRuntimeClient.new,
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          'LiteRT-LM runtime requires a native platform.',
        ),
      ),
    );
  });

  test('metrics serialize the same keys as the native twin', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 12,
      outputTokens: 34,
      timeToFirstTokenSeconds: 0.5,
      initSeconds: 1.25,
      prefillTokensPerSecond: 100.0,
      decodeTokensPerSecond: 50.0,
      wallMilliseconds: 4200,
    );

    expect(metrics.toJson(), <String, Object?>{
      'inputTokens': 12,
      'outputTokens': 34,
      'timeToFirstTokenSeconds': 0.5,
      'initSeconds': 1.25,
      'prefillTokensPerSecond': 100.0,
      'decodeTokensPerSecond': 50.0,
      'wallMilliseconds': 4200,
    });
  });
}
