import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:test/test.dart';

void main() {
  group('requestedSamplerControls dry', () {
    test('reports DRY only while dryMultiplier is nonzero', () {
      expect(requestedSamplerControls(const GenerationParams()), isEmpty);
      expect(
        requestedSamplerControls(const GenerationParams(dryMultiplier: 0.8)),
        {SamplerControl.dry},
      );
      expect(
        requestedSamplerControls(const GenerationParams(dryMultiplier: -1)),
        {SamplerControl.dry},
      );
      expect(
        requestedSamplerControls(
          const GenerationParams(dryMultiplier: double.nan),
        ),
        {SamplerControl.dry},
      );
    });

    test('ignores tuning values left behind by disabling DRY', () {
      const on = GenerationParams(
        dryMultiplier: 0.8,
        dryBase: 2,
        dryAllowedLength: 4,
        dryPenaltyLastN: 128,
        drySequenceBreakers: ['.'],
      );
      final off = on.copyWith(dryMultiplier: 0);
      expect(requestedSamplerControls(off), isEmpty);
      expect(
        () => rejectUnsupportedSamplerControls(off, 'WebGPU'),
        returnsNormally,
      );
      expect(
        () => rejectUnsupportedSamplerControls(on, 'WebGPU'),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(contains('WebGPU'), contains('dry')),
          ),
        ),
      );
    });
  });

  group('BackendPerfContextData', () {
    test('computes speculative acceptance rate when counts are available', () {
      const perf = BackendPerfContextData(
        loadMs: 0,
        promptEvalMs: 0,
        evalMs: 0,
        sampleMs: 0,
        promptEvalTokens: 0,
        evalTokens: 0,
        sampleCount: 0,
        reusedGraphs: 0,
        speculativeDraftTokens: 8,
        speculativeAcceptedDraftTokens: 6,
      );

      expect(perf.speculativeAcceptanceRate, 0.75);
    });

    test('returns null speculative acceptance rate without draft count', () {
      const perf = BackendPerfContextData(
        loadMs: 0,
        promptEvalMs: 0,
        evalMs: 0,
        sampleMs: 0,
        promptEvalTokens: 0,
        evalTokens: 0,
        sampleCount: 0,
        reusedGraphs: 0,
      );

      expect(perf.speculativeAcceptanceRate, isNull);
    });

    test('keeps explicit zero speculative counters', () {
      const perf = BackendPerfContextData(
        loadMs: 0,
        promptEvalMs: 0,
        evalMs: 0,
        sampleMs: 0,
        promptEvalTokens: 0,
        evalTokens: 0,
        sampleCount: 0,
        reusedGraphs: 0,
        speculativeDraftTokens: 0,
        speculativeAcceptedDraftTokens: 0,
        speculativeDraftAttempts: 0,
        speculativeVerifyTokens: 0,
        speculativeReplayTokens: 0,
        speculativeDraftMs: 0,
        speculativeVerifyMs: 0,
      );

      expect(perf.speculativeDraftTokens, 0);
      expect(perf.speculativeAcceptedDraftTokens, 0);
      expect(perf.speculativeDraftAttempts, 0);
      expect(perf.speculativeVerifyTokens, 0);
      expect(perf.speculativeReplayTokens, 0);
      expect(perf.speculativeDraftMs, 0);
      expect(perf.speculativeVerifyMs, 0);
      expect(perf.speculativeAcceptanceRate, isNull);
    });
  });
}
