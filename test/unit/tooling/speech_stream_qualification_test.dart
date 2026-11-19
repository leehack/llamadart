@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import '../../support/speech_stream_qualification.dart';

void main() {
  group('SpeechStreamQualification threshold logic', () {
    test('computes calibrated ceilings with 64 MiB floor and 32 MiB step', () {
      const mib = 1024 * 1024;
      expect(
        computeCalibratedCeilingBytes([
          (324.9 * mib).round(),
          (324.4 * mib).round(),
          (324.1 * mib).round(),
        ]),
        416 * mib,
      );
      expect(
        computeCalibratedCeilingBytes([(1.3 * mib).round(), 0, 0]),
        64 * mib,
      );
      expect(computeCalibratedCeilingBytes([0]), 64 * mib);
      // 64 MiB * 1.25 = 80 MiB -> rounds up to 96 MiB (3 * 32 MiB).
      expect(computeCalibratedCeilingBytes([64 * mib]), 96 * mib);
    });

    test(
      'looks up checked-in ceilings by family, host, arch, backend, mode',
      () {
        const mib = 1024 * 1024;
        expect(
          lookupMemoryCeilingBytes(
            const SpeechStreamProfileKey(
              family: SpeechStreamFamily.voxtral,
              hostOs: 'macos',
              arch: 'arm64',
              backend: 'cpu',
              mode: SpeechStreamPacingMode.fast,
            ),
          ),
          416 * mib,
        );
        expect(
          lookupMemoryCeilingBytes(
            const SpeechStreamProfileKey(
              family: SpeechStreamFamily.lfm3,
              hostOs: 'macos',
              arch: 'arm64',
              backend: 'cpu',
              mode: SpeechStreamPacingMode.fast,
            ),
          ),
          64 * mib,
        );

        // Paced and other hosts are uncalibrated until measured.
        for (final uncalibrated in const [
          SpeechStreamProfileKey(
            family: SpeechStreamFamily.voxtral,
            hostOs: 'macos',
            arch: 'arm64',
            backend: 'cpu',
            mode: SpeechStreamPacingMode.paced,
          ),
          SpeechStreamProfileKey(
            family: SpeechStreamFamily.lfm3,
            hostOs: 'macos',
            arch: 'arm64',
            backend: 'cpu',
            mode: SpeechStreamPacingMode.paced,
          ),
          SpeechStreamProfileKey(
            family: SpeechStreamFamily.voxtral,
            hostOs: 'linux',
            arch: 'x64',
            backend: 'cpu',
            mode: SpeechStreamPacingMode.fast,
          ),
          SpeechStreamProfileKey(
            family: SpeechStreamFamily.voxtral,
            hostOs: 'windows',
            arch: 'x64',
            backend: 'cuda',
            mode: SpeechStreamPacingMode.fast,
          ),
        ]) {
          expect(lookupMemoryCeilingBytes(uncalibrated), isNull);
        }
      },
    );

    test(
      'evaluates budget with exact byte boundary and rejects uncalibrated',
      () {
        const ceiling = 64 * 1024 * 1024;
        const baseline = 100 * 1024 * 1024;

        final exact = evaluateMemoryBudget(
          baselineRssBytes: baseline,
          peakRssBytes: baseline + ceiling,
          ceilingBytes: ceiling,
        );
        expect(exact.status, SpeechStreamMemoryStatus.pass);
        expect(exact.passed, isTrue);
        expect(exact.peakDeltaBytes, ceiling);

        final oneByteOver = evaluateMemoryBudget(
          baselineRssBytes: baseline,
          peakRssBytes: baseline + ceiling + 1,
          ceilingBytes: ceiling,
        );
        expect(oneByteOver.status, SpeechStreamMemoryStatus.fail);
        expect(oneByteOver.passed, isFalse);
        expect(oneByteOver.peakDeltaBytes, ceiling + 1);

        final uncalibrated = evaluateMemoryBudget(
          baselineRssBytes: baseline,
          peakRssBytes: baseline + 1024,
          ceilingBytes: null,
        );
        expect(
          uncalibrated.status,
          SpeechStreamMemoryStatus.unboundedQualificationPending,
        );
        expect(uncalibrated.passed, isFalse);
      },
    );
  });

  group('SpeechStreamRssMeter', () {
    test('tracks true peak across drops and monotonic timestamps', () async {
      final rssValues = <int>[100, 150, 250, 180, 120, 110];
      var rssIndex = 0;
      var tickMicros = 1000;

      final meter = SpeechStreamRssMeter(
        readRssBytes: () =>
            rssValues[rssIndex < rssValues.length
                ? rssIndex++
                : rssValues.length - 1],
        nowMicros: () => tickMicros += 100,
      );

      meter.startBaseline();
      expect(meter.baselineRssBytes, 100);
      meter.sampleNow(); // 150
      meter.sampleNow(); // 250 (peak)
      meter.sampleNow(); // 180 (drops below peak)
      final summary = meter.finish(postDisposeRssBytes: 110); // end=120

      expect(summary.baselineRssBytes, 100);
      expect(summary.peakRssBytes, 250);
      expect(summary.peakDeltaBytes, 150);
      expect(summary.endRssBytes, 120);
      expect(summary.postDisposeRssBytes, 110);
      expect(summary.sampleCount, 5);
      for (var i = 1; i < summary.timestampsMicros.length; i++) {
        expect(
          summary.timestampsMicros[i],
          greaterThan(summary.timestampsMicros[i - 1]),
        );
      }
    });

    test('stops periodic sampler on stop()', () async {
      var calls = 0;
      final meter = SpeechStreamRssMeter(
        readRssBytes: () {
          calls++;
          return 100 + calls;
        },
        sampleInterval: const Duration(milliseconds: 5),
      );
      meter.startBaseline();
      meter.startPeriodicSampling();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      meter.stopPeriodicSampling();
      final countAtStop = calls;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, countAtStop);
    });
  });

  group('streamCyclicPcm300s', () {
    test('streams exact 4,800,000 samples via reusable <=5120 slab', () async {
      final unit = Float32List.fromList(
        List<double>.generate(176000, (i) => (i % 100) / 100.0),
      );
      var totalSamples = 0;
      var maxChunkLen = 0;
      final chunkLengths = <int>[];

      final stats = await streamCyclicPcm300s(
        unit: unit,
        slabSize: 5120,
        paced: false,
        onSlab: (slab) async {
          totalSamples += slab.length;
          if (slab.length > maxChunkLen) {
            maxChunkLen = slab.length;
          }
          chunkLengths.add(slab.length);
        },
      );

      expect(totalSamples, speechStreamTargetSamples300s);
      expect(stats.pushedSamples, 4800000);
      expect(maxChunkLen, lessThanOrEqualTo(5120));
      // 4800000 = 937 * 5120 + 2560
      expect(chunkLengths.length, 938);
      expect(chunkLengths.last, 2560);
    });
  });

  group('evaluateQualificationReport', () {
    SpeechStreamLegReceipt makeLeg({
      required String legId,
      required SpeechStreamFamily? family,
      required String mode,
      String backendRequested = 'cpu',
      String backendUsed = 'CPU',
      int gpuLayersOffloaded = 0,
      int pushedSamples = 4800000,
      int audioDurationMs = 300000,
      int baselineRssBytes = 100 * 1024 * 1024,
      int peakRssBytes = 110 * 1024 * 1024,
      int? ceilingBytes = 64 * 1024 * 1024,
      String outcome = 'pass',
    }) {
      return SpeechStreamLegReceipt(
        legId: legId,
        family: family?.name ?? 'qwen',
        mode: mode,
        hostOs: 'macos',
        arch: 'arm64',
        backendRequested: backendRequested,
        backendUsed: backendUsed,
        exposedDevices: const ['CPU'],
        usedDevices: const ['CPU'],
        gpuLayersOffloaded: gpuLayersOffloaded,
        threads: 2,
        threadsBatch: 2,
        contextSize: 4096,
        pushedSamples: pushedSamples,
        audioDurationMs: audioDurationMs,
        wallMs: 10000,
        flushMs: 100,
        baselineRssBytes: baselineRssBytes,
        peakRssBytes: peakRssBytes,
        ceilingBytes: ceilingBytes,
        outcome: outcome,
      );
    }

    List<SpeechStreamLegReceipt> validLegs({
      String backendRequested = 'cpu',
      String backendUsed = 'CPU',
      int gpuLayersOffloaded = 0,
      int voxtralCeiling = 416 * 1024 * 1024,
      int voxtralPeakDelta = 300 * 1024 * 1024,
      int lfm3Ceiling = 64 * 1024 * 1024,
      int lfm3PeakDelta = 2 * 1024 * 1024,
    }) {
      const base = 100 * 1024 * 1024;
      return [
        makeLeg(
          legId: 'voxtral_short',
          family: SpeechStreamFamily.voxtral,
          mode: 'short',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          pushedSamples: 176000,
          audioDurationMs: 11000,
          ceilingBytes: null,
        ),
        makeLeg(
          legId: 'voxtral_fast',
          family: SpeechStreamFamily.voxtral,
          mode: 'fast',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          baselineRssBytes: base,
          peakRssBytes: base + voxtralPeakDelta,
          ceilingBytes: voxtralCeiling,
        ),
        makeLeg(
          legId: 'voxtral_paced',
          family: SpeechStreamFamily.voxtral,
          mode: 'paced',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          baselineRssBytes: base,
          peakRssBytes: base + voxtralPeakDelta,
          ceilingBytes: voxtralCeiling,
        ),
        makeLeg(
          legId: 'lfm3_short',
          family: SpeechStreamFamily.lfm3,
          mode: 'short',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          pushedSamples: 176000,
          audioDurationMs: 11000,
          ceilingBytes: null,
        ),
        makeLeg(
          legId: 'lfm3_fast',
          family: SpeechStreamFamily.lfm3,
          mode: 'fast',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          baselineRssBytes: base,
          peakRssBytes: base + lfm3PeakDelta,
          ceilingBytes: lfm3Ceiling,
        ),
        makeLeg(
          legId: 'lfm3_paced',
          family: SpeechStreamFamily.lfm3,
          mode: 'paced',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          baselineRssBytes: base,
          peakRssBytes: base + lfm3PeakDelta,
          ceilingBytes: lfm3Ceiling,
        ),
        makeLeg(
          legId: 'qwen_refusal',
          family: null,
          mode: 'refusal',
          backendRequested: backendRequested,
          backendUsed: backendUsed,
          gpuLayersOffloaded: gpuLayersOffloaded,
          pushedSamples: 0,
          audioDurationMs: 0,
          ceilingBytes: null,
        ),
      ];
    }

    test('fails on empty run', () {
      final eval = evaluateQualificationReport(
        const SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: [],
        ),
      );
      expect(eval.passed, isFalse);
      expect(eval.failures, isNotEmpty);
    });

    test('fails on missing LFM3 leg', () {
      final legs = validLegs()..removeWhere((l) => l.legId == 'lfm3_fast');
      final eval = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: legs,
        ),
      );
      expect(eval.passed, isFalse);
      expect(eval.failures.join('\n'), contains('lfm3_fast'));
    });

    test('fails on requested CUDA with zero offload', () {
      final eval = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cuda',
          isBaselineCollection: false,
          legs: validLegs(
            backendRequested: 'cuda',
            backendUsed: 'CPU',
            gpuLayersOffloaded: 0,
          ),
        ),
      );
      expect(eval.passed, isFalse);
      expect(eval.failures.join('\n'), contains('cuda'));
    });

    test('passes on boundary equality and fails 1 byte over budget', () {
      const lfm3Ceiling = 64 * 1024 * 1024;
      final boundary = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: validLegs(lfm3Ceiling: lfm3Ceiling, lfm3PeakDelta: lfm3Ceiling),
        ),
      );
      expect(boundary.passed, isTrue, reason: boundary.failures.join('; '));

      final overByOne = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: validLegs(
            lfm3Ceiling: lfm3Ceiling,
            lfm3PeakDelta: lfm3Ceiling + 1,
          ),
        ),
      );
      expect(overByOne.passed, isFalse);
      expect(overByOne.failures.join('\n'), contains('lfm3_fast'));
    });

    test('baseline collection invocation cannot issue qualification PASS', () {
      final eval = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: true,
          legs: validLegs(),
        ),
      );
      expect(eval.passed, isFalse);
      expect(eval.failures.join('\n'), contains('baseline'));
    });
  });
}
