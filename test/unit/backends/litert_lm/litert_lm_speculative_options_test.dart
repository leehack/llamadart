import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_speculative_options.dart';
import 'package:test/test.dart';

void main() {
  test('accepts bundled MTP and the runtime default without tuning', () {
    for (final params in const [
      GenerationParams(),
      GenerationParams(speculativeDecoding: true),
      GenerationParams(
        speculativeDecodingConfig: SpeculativeDecodingConfig.mtp(),
      ),
    ]) {
      expect(liteRtLmUnsupportedSpeculativeOptions(params), isEmpty);
    }
  });

  test('names every unsupported option of a mixed request', () {
    final params = GenerationParams(
      speculativeDecodingConfig: SpeculativeDecodingConfig(
        strategies: [
          SpeculativeDecodingStrategy.backendDefault,
          SpeculativeDecodingStrategy.mtp,
        ],
        draftTokenMax: 2,
        draftModel: ModelSource.path('drafter.litertlm'),
        ngramCacheDynamicPath: 'cache',
      ),
    );
    expect(liteRtLmUnsupportedSpeculativeOptions(params), [
      'speculativeDecodingConfig.strategy',
      'speculativeDecodingConfig.draftTokenMax',
      'speculativeDecodingConfig.draftModel',
      'speculativeDecodingConfig.ngramCacheDynamicPath',
    ]);
  });
}
