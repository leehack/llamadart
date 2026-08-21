// ignore_for_file: deprecated_member_use_from_same_package
library;

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime_stub.dart';
import 'package:llamadart/src/experimental/litert_lm/litert_lm_benchmark_stub.dart';
import 'package:test/test.dart';

void main() {
  test(
    'constructing the deprecated client reports the platform requirement',
    () {
      expect(
        LiteRtLmBenchmarkClient.new,
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            'LiteRT-LM runtime requires a native platform.',
          ),
        ),
      );
    },
  );

  test('the deprecated aliases copy every runtime field', () {
    const runtime = LiteRtLmRuntimeResult(
      text: 'hello',
      metrics: LiteRtLmRuntimeMetrics(
        inputTokens: 1,
        outputTokens: 2,
        timeToFirstTokenSeconds: 0.25,
        initSeconds: 0.75,
        prefillTokensPerSecond: 10.0,
        decodeTokensPerSecond: 5.0,
        wallMilliseconds: 99,
      ),
    );

    final aliased = LiteRtLmBenchmarkResult.fromRuntime(runtime);

    expect(aliased.text, 'hello');
    expect(aliased.metrics.toJson(), runtime.metrics.toJson());
  });
}
