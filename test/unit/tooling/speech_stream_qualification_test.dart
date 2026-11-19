@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../support/speech_stream_qualification.dart';
import 'support/bounded_process.dart';

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

    for (final (os, arch, voxtralMiB) in const [
      ('macos', 'arm64', 416),
      ('linux', 'x64', 416),
      ('windows', 'x64', 384),
    ]) {
      for (final mode in SpeechStreamPacingMode.values) {
        test('looks up $os/$arch CPU ${mode.name} ceilings', () {
          const mib = 1024 * 1024;
          for (final (family, ceilingMiB) in [
            (SpeechStreamFamily.voxtral, voxtralMiB),
            (SpeechStreamFamily.lfm3, 64),
          ]) {
            final profile = SpeechStreamProfileKey(
              family: family,
              hostOs: os,
              arch: arch,
              backend: 'cpu',
              mode: mode,
            );
            expect(
              lookupMemoryCeilingBytes(profile),
              ceilingMiB * mib,
              reason: '$profile',
            );
          }
        });
      }
    }

    test('leaves Windows x64 CUDA profiles uncalibrated', () {
      for (final family in SpeechStreamFamily.values) {
        for (final mode in SpeechStreamPacingMode.values) {
          expect(
            lookupMemoryCeilingBytes(
              SpeechStreamProfileKey(
                family: family,
                hostOs: 'windows',
                arch: 'x64',
                backend: 'cuda',
                mode: mode,
              ),
            ),
            isNull,
          );
        }
      }
    });

    test('scales both Voxtral timeouts for x64 CPU', () {
      for (final (baseMinutes, scaledMinutes) in const [(10, 30), (15, 45)]) {
        final base = Duration(minutes: baseMinutes);
        expect(
          voxtralSpeechStreamTimeout(base, arch: 'x64', backend: 'cpu'),
          Duration(minutes: scaledMinutes),
        );
        expect(
          voxtralSpeechStreamTimeout(base, arch: 'arm64', backend: 'cpu'),
          base,
        );
        expect(
          voxtralSpeechStreamTimeout(base, arch: 'x64', backend: 'cuda'),
          base,
        );
      }
    });

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

    test('evaluates known receipt files alongside unrelated JSON', () async {
      final dir = Directory.systemTemp.createTempSync('cei-receipt-evaluate-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final leg in validLegs()) {
        File(
          '${dir.path}/${leg.legId}.json',
        ).writeAsStringSync(jsonEncode(leg.toJson()));
      }
      File('${dir.path}/metadata.json').writeAsStringSync('{}');

      final result = await runBoundedProcess(
        Platform.resolvedExecutable,
        [
          'tool/testing/verify_speech_stream_qualification.dart',
          '--evaluate',
          '--receipt-dir',
          dir.path,
          '--backend',
          'cpu',
        ],
        timeout: const Duration(seconds: 15),
        environment: {'LLAMADART_STT_STREAM_COLLECT_BASELINE': '0'},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('qualification PASS (7 legs'));
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
      const mib = 1024 * 1024;
      const lfm3Ceiling = 64 * mib;
      final table = <SpeechStreamProfileKey, int>{
        const SpeechStreamProfileKey(
          family: SpeechStreamFamily.voxtral,
          hostOs: 'macos',
          arch: 'arm64',
          backend: 'cpu',
          mode: SpeechStreamPacingMode.fast,
        ): 416 * mib,
        const SpeechStreamProfileKey(
          family: SpeechStreamFamily.voxtral,
          hostOs: 'macos',
          arch: 'arm64',
          backend: 'cpu',
          mode: SpeechStreamPacingMode.paced,
        ): 416 * mib,
        const SpeechStreamProfileKey(
          family: SpeechStreamFamily.lfm3,
          hostOs: 'macos',
          arch: 'arm64',
          backend: 'cpu',
          mode: SpeechStreamPacingMode.fast,
        ): lfm3Ceiling,
        const SpeechStreamProfileKey(
          family: SpeechStreamFamily.lfm3,
          hostOs: 'macos',
          arch: 'arm64',
          backend: 'cpu',
          mode: SpeechStreamPacingMode.paced,
        ): lfm3Ceiling,
      };
      final boundary = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: validLegs(lfm3Ceiling: lfm3Ceiling, lfm3PeakDelta: lfm3Ceiling),
        ),
        ceilingTable: table,
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
        ceilingTable: table,
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

    test('ignores inflated receipt ceilingBytes and uses checked-in table', () {
      const mib = 1024 * 1024;
      // lfm3/macos/arm64/cpu/fast checked-in ceiling is 64 MiB.
      // Receipt claims 10 GiB, but peak delta is 65 MiB -> must FAIL.
      final eval = evaluateQualificationReport(
        SpeechStreamQualificationReport(
          requestedBackend: 'cpu',
          isBaselineCollection: false,
          legs: validLegs(
            lfm3Ceiling: 10 * 1024 * mib,
            lfm3PeakDelta: 65 * mib,
          ),
        ),
      );
      expect(eval.passed, isFalse);
      expect(eval.failures.join('\n'), contains('lfm3_fast'));
    });
  });

  group('requireSpeechStreamInput and prepareReceiptDir', () {
    test(
      'fails under qualify=true when path is missing and skips when false',
      () {
        String? skippedReason;
        final skipped = requireSpeechStreamInput(
          null,
          'LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH',
          qualify: false,
          onSkip: (msg) => skippedReason = msg,
        );
        expect(skipped, isNull);
        expect(
          skippedReason,
          contains('LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH'),
        );

        expect(
          () => requireSpeechStreamInput(
            null,
            'LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH',
            qualify: true,
            onSkip: (_) => fail('must not skip in qualify mode'),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('clears known leg receipts and preserves unrelated JSON', () {
      final tempDir = Directory.systemTemp.createTempSync('cei-receipts-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final unrelated = File('${tempDir.path}/metadata.json')
        ..writeAsStringSync('{"source":"manual"}');
      final stale = [
        for (final id in requiredSpeechStreamQualificationLegIds)
          File('${tempDir.path}/$id.json')..writeAsStringSync('{}'),
      ];

      expect(
        () => prepareReceiptDir(tempDir.path, refuseNonEmpty: true),
        throwsA(isA<StateError>()),
      );
      expect(stale.every((file) => file.existsSync()), isTrue);
      prepareReceiptDir(tempDir.path);
      expect(stale.any((file) => file.existsSync()), isFalse);
      expect(unrelated.existsSync(), isTrue);
      expect(unrelated.readAsStringSync(), '{"source":"manual"}');
      prepareReceiptDir(tempDir.path, refuseNonEmpty: true);
    });
  });

  group('SpeechStreamRssMeter default reader and runTimedSpeechStreamLeg', () {
    test('default RSS reader reports positive process RSS', () {
      final meter = SpeechStreamRssMeter();
      meter.startBaseline();
      expect(meter.baselineRssBytes, greaterThan(0));
    });

    test('throws for an uncalibrated profile in strict qualify mode', () async {
      await expectLater(
        runTimedSpeechStreamLeg(
          legId: 'voxtral_fast',
          family: SpeechStreamFamily.voxtral,
          mode: SpeechStreamPacingMode.fast,
          hostOs: 'windows',
          arch: 'x64',
          requestedBackend: 'cuda',
          backendUsed: 'CUDA',
          exposedDevices: const ['CPU', 'CUDA'],
          resolvedGpuLayers: 99,
          unitPcm: Float32List(4),
          targetSamples: 4,
          slabSize: 4,
          meter: SpeechStreamRssMeter(readRssBytes: () => 100),
          readPostDisposeRss: () => 100,
          qualify: true,
          runWarmup: () async {},
          runMeasuredSession: (driveProducer) async {
            await driveProducer((_) async {}, () {});
            return const SpeechStreamTimedSessionResult(
              flushDuration: Duration.zero,
              audioDurationMs: 300000,
              firstPartialWallMs: 1,
              firstPartialAudioMs: 1,
            );
          },
          disposeEngine: () async {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              'voxtral/windows/x64/cuda/fast(ctx=4096,t=2) is uncalibrated',
            ),
          ),
        ),
      );
    });

    test(
      'runs warm-up before baseline and enforces budget pass/fail',
      () async {
        final events = <String>[];
        final rssValues = <int>[100, 150, 140, 120];
        var rssIndex = 0;
        var tick = 1000;
        final meter = SpeechStreamRssMeter(
          readRssBytes: () {
            events.add('readRss');
            return rssValues[rssIndex < rssValues.length
                ? rssIndex++
                : rssValues.length - 1];
          },
          nowMicros: () => tick += 100,
        );
        final unit = Float32List.fromList(const [0.1, 0.2, 0.3, 0.4]);

        final outcome = await runTimedSpeechStreamLeg(
          legId: 'lfm3_fast',
          family: SpeechStreamFamily.lfm3,
          mode: SpeechStreamPacingMode.fast,
          hostOs: 'macos',
          arch: 'arm64',
          requestedBackend: 'cpu',
          backendUsed: 'CPU',
          exposedDevices: const ['CPU'],
          resolvedGpuLayers: 0,
          unitPcm: unit,
          targetSamples: 10,
          slabSize: 4,
          meter: meter,
          readPostDisposeRss: () {
            events.add('postDisposeRss');
            return 110;
          },
          ceilingTable: {
            const SpeechStreamProfileKey(
              family: SpeechStreamFamily.lfm3,
              hostOs: 'macos',
              arch: 'arm64',
              backend: 'cpu',
              mode: SpeechStreamPacingMode.fast,
            ): 50,
          },
          runWarmup: () async => events.add('warmup'),
          runMeasuredSession: (driveProducer) async {
            await driveProducer(
              (slab) async => events.add('push:${slab.length}'),
              () {},
            );
            return const SpeechStreamTimedSessionResult(
              flushDuration: Duration(milliseconds: 5),
              audioDurationMs: 300000,
              firstPartialWallMs: 1,
              firstPartialAudioMs: 1,
            );
          },
          disposeEngine: () async => events.add('dispose'),
        );

        expect(outcome.budgetEvaluation.passed, isTrue);
        expect(events.first, 'warmup');
        expect(events.indexOf('warmup'), lessThan(events.indexOf('readRss')));
        expect(
          events.indexOf('dispose'),
          lessThan(events.indexOf('postDisposeRss')),
        );

        // Exceed ceiling by 1 byte -> must throw StateError.
        var overIdx = 0;
        final overValues = <int>[100, 151, 120];
        await expectLater(
          () => runTimedSpeechStreamLeg(
            legId: 'lfm3_fast',
            family: SpeechStreamFamily.lfm3,
            mode: SpeechStreamPacingMode.fast,
            hostOs: 'macos',
            arch: 'arm64',
            requestedBackend: 'cpu',
            backendUsed: 'CPU',
            exposedDevices: const ['CPU'],
            resolvedGpuLayers: 0,
            unitPcm: unit,
            targetSamples: 4,
            slabSize: 4,
            meter: SpeechStreamRssMeter(
              readRssBytes: () =>
                  overValues[overIdx < overValues.length
                      ? overIdx++
                      : overValues.length - 1],
              nowMicros: () => tick += 100,
            ),
            readPostDisposeRss: () => 110,
            ceilingTable: {
              const SpeechStreamProfileKey(
                family: SpeechStreamFamily.lfm3,
                hostOs: 'macos',
                arch: 'arm64',
                backend: 'cpu',
                mode: SpeechStreamPacingMode.fast,
              ): 50,
            },
            runWarmup: () async {},
            runMeasuredSession: (driveProducer) async {
              await driveProducer((_) async {}, () {});
              return const SpeechStreamTimedSessionResult(
                flushDuration: Duration(milliseconds: 5),
                audioDurationMs: 300000,
                firstPartialWallMs: 1,
                firstPartialAudioMs: 1,
              );
            },
            disposeEngine: () async {},
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
