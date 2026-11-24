@TestOn('browser')
// ignore_for_file: deprecated_member_use_from_same_package
library;

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('exports LiteRT-LM runtime value types on web', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 1,
      outputTokens: 2,
      timeToFirstTokenSeconds: null,
      initSeconds: null,
      prefillTokensPerSecond: null,
      decodeTokensPerSecond: null,
      wallMilliseconds: 3,
    );
    const result = LiteRtLmRuntimeResult(text: 'web', metrics: metrics);

    expect(result.text, 'web');
    expect(result.metrics.toJson(), {
      'inputTokens': 1,
      'outputTokens': 2,
      'timeToFirstTokenSeconds': null,
      'initSeconds': null,
      'prefillTokensPerSecond': null,
      'decodeTokensPerSecond': null,
      'wallMilliseconds': 3,
    });
  });

  test('reports native-only LiteRT-LM runtime APIs as unsupported on web', () {
    void configureThinkingTags(LiteRtLmRuntimeClient client) {
      client.configureResponseThinkingTags(
        startTag: '<thought>',
        endTag: '</thought>',
      );
    }

    expect(configureThinkingTags, isA<void Function(LiteRtLmRuntimeClient)>());
    expect(LiteRtLmRuntimeClient.new, throwsUnsupportedError);
  });

  test(
    'Web CPU load check reports the MTP refusal through the public API',
    () async {
      final engine = LlamaEngine(LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      final report = await engine.checkLoad(
        LlamaModel(ModelSource.path('model.litertlm')),
        params: const LiteRtLmModelParams(
          device: ComputeDevice.cpu,
          loadMtp: true,
        ),
      );
      expect(report.status, LlamaLoadCheckStatus.unsupported);
      expect(
        report.error?.message,
        allOf(contains('loadMtp'), contains('Web CPU')),
      );
    },
  );

  test('exports LiteRT-LM web backend constructor on web', () async {
    final backend = LiteRtLmBackend(
      initialSendPort: null,
      preferredBackend: 'cpu',
    );

    expect(backend.supportsUrlLoading, isTrue);
    expect(
      (backend as BackendGrammarConstraintsSupport).supportsGrammarConstraints,
      isFalse,
    );
    expect(await backend.getBackendName(), 'LiteRT-LM web cpu');
  });
}
