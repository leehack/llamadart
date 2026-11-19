import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/qwen_windowed_asr.dart';
import 'package:test/test.dart';

void main() {
  group('selectQwenWindowCut', () {
    test('hard-cuts at 128000 when no >= 100 ms quiet run exists', () {
      final window = Float32List(qwenWindowedMaxSamples);
      window.fillRange(0, window.length, 0.2);

      // 4 contiguous quiet frames (80 ms) aligned to the 20 ms frame grid at
      // 96000 is below the 100 ms (5-frame) threshold.
      window.fillRange(96000, 96000 + 4 * 320, 0.0);

      expect(selectQwenWindowCut(window, window.length), 128000);
    });

    test(
      'accepts 5 aligned frames at RMS == 0.01 and rejects RMS == 0.012',
      () {
        final exact = Float32List(qwenWindowedMaxSamples)
          ..fillRange(0, 128000, 0.2);
        exact.fillRange(96000, 96000 + 5 * 320, 0.01);
        expect(selectQwenWindowCut(exact, exact.length), 96800);

        final above = Float32List(qwenWindowedMaxSamples)
          ..fillRange(0, 128000, 0.2);
        above.fillRange(96000, 96000 + 5 * 320, 0.012);
        expect(selectQwenWindowCut(above, above.length), 128000);
      },
    );

    test('selects the midpoint of the latest >= 100 ms quiet run', () {
      final window = Float32List(qwenWindowedMaxSamples);
      window.fillRange(0, window.length, 0.2);

      // First quiet run: 6 frames at 96000..97920 (midpoint 96960).
      window.fillRange(96000, 97920, 0.0);
      // Latest quiet run: 5 frames at 112000..113600 (midpoint 112800).
      window.fillRange(112000, 113600, 0.005);

      expect(selectQwenWindowCut(window, window.length), 112800);
    });

    test('includes a trailing quiet run that reaches the last sample', () {
      final window = Float32List(qwenWindowedMaxSamples);
      window.fillRange(0, window.length, 0.2);

      // 5 quiet frames at the very end: 126400..128000 (midpoint 127200).
      window.fillRange(126400, 128000, 0.0);

      expect(selectQwenWindowCut(window, window.length), 127200);
    });
  });

  group('encodePcm16WavInto', () {
    test('writes valid RIFF/WAVE header and saturates -1/+1 PCM16', () {
      final samples = Float32List.fromList(<double>[-1.5, -1.0, 0.0, 1.0, 1.5]);
      final target = Uint8List(44 + samples.length * 2);

      final wav = encodePcm16WavInto(samples, samples.length, target);
      final data = ByteData.sublistView(wav);

      expect(wav.length, 44 + 10);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(data.getUint32(4, Endian.little), 36 + 10);
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
      expect(data.getUint32(16, Endian.little), 16);
      expect(data.getUint16(20, Endian.little), 1);
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint32(24, Endian.little), 16000);
      expect(data.getUint32(28, Endian.little), 32000);
      expect(data.getUint16(32, Endian.little), 2);
      expect(data.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      expect(data.getUint32(40, Endian.little), 10);

      expect(data.getInt16(44, Endian.little), -32768);
      expect(data.getInt16(46, Endian.little), -32768);
      expect(data.getInt16(48, Endian.little), 0);
      expect(data.getInt16(50, Endian.little), 32767);
      expect(data.getInt16(52, Endian.little), 32767);
    });
  });

  group('QwenWindowedAsrSession', () {
    test(
      'produces identical intervals and final across fixed, irregular, and offset views',
      () async {
        // 20 seconds = 320,000 samples with a quiet gap at 112000..113600 and
        // a second quiet gap at 216000..217920.
        const totalSamples = 320000;
        final fullBuffer = _buildTaggedSpeech(
          totalSamples,
          quietRanges: const <(int, int)>[(112000, 113600), (216000, 217920)],
        );

        Future<
          ({List<(int, int)> intervals, String finalText, int maxWavBytes})
        >
        runWithChunkSizes(List<int> chunkSizes, {int viewOffset = 0}) async {
          final backing = Float32List(viewOffset + totalSamples + 17);
          backing.setRange(viewOffset, viewOffset + totalSamples, fullBuffer);

          final intervals = <(int, int)>[];
          var maxWavBytes = 0;
          final session = QwenWindowedAsrSession(
            sourceFormat: const SpeechAudioFormat(
              sampleRateHz: 16000,
              channelCount: 1,
              encoding: 'pcm-f32le',
            ),
            onClosed: () {},
            decodeWindow:
                (
                  wavBytes, {
                  required confirmedPrefix,
                  required registerCancel,
                  required isCancelled,
                }) async {
                  if (wavBytes.length > maxWavBytes) {
                    maxWavBytes = wavBytes.length;
                  }
                  final interval = _decodeTaggedInterval(wavBytes);
                  intervals.add(interval);
                  return 'seg(${interval.$1}-${interval.$2})';
                },
          );

          final partials = <SpeechToTextPartialEvent>[];
          final finals = <SpeechToTextFinalEvent>[];
          final sub = session.events.listen((event) {
            switch (event) {
              case SpeechToTextPartialEvent():
                partials.add(event);
              case SpeechToTextFinalEvent():
                finals.add(event);
            }
          });

          var pos = 0;
          var chunkIdx = 0;
          while (pos < totalSamples) {
            final size = chunkSizes[chunkIdx % chunkSizes.length];
            final end = math.min(pos + size, totalSamples);
            final view = Float32List.sublistView(
              backing,
              viewOffset + pos,
              viewOffset + end,
            );
            await session.addPcm(view);
            pos = end;
            chunkIdx++;
          }
          await session.finish();
          final completion = await session.done;
          await sub.cancel();

          expect(completion.state, SpeechToTextCompletionState.completed);
          expect(finals, hasLength(1));
          // Confirmed prefix must be nondecreasing across all partials.
          var previousConfirmed = '';
          for (final partial in partials) {
            expect(
              partial.confirmedText!.startsWith(previousConfirmed),
              isTrue,
            );
            previousConfirmed = partial.confirmedText!;
          }
          return (
            intervals: intervals,
            finalText: finals.single.result.text,
            maxWavBytes: maxWavBytes,
          );
        }

        final fixed = await runWithChunkSizes(<int>[4000]);
        expect(fixed.intervals, const <(int, int)>[
          (0, 32000),
          (0, 64000),
          (0, 96000),
          (0, 112800),
          (112800, 144800),
          (112800, 176800),
          (112800, 208800),
          (112800, 216960),
          (216960, 248960),
          (216960, 280960),
          (216960, 312960),
          (216960, 320000),
        ]);
        final whole = await runWithChunkSizes(<int>[
          totalSamples,
        ], viewOffset: 13);
        expect(whole.intervals, fixed.intervals);
        expect(whole.finalText, fixed.finalText);
        expect(fixed.maxWavBytes, lessThanOrEqualTo(44 + 128000 * 2));

        // 5 seeded irregular chunking schedules.
        for (var seed = 1; seed <= 5; seed++) {
          final rng = math.Random(seed * 97);
          final irregular = List<int>.generate(
            64,
            (_) => 1 + rng.nextInt(19000),
          );
          final run = await runWithChunkSizes(irregular, viewOffset: seed * 7);
          expect(run.intervals, fixed.intervals, reason: 'seed=$seed');
          expect(run.finalText, fixed.finalText, reason: 'seed=$seed');
        }
      },
    );

    test(
      'fixed 8s cuts duplicate a boundary-spanning word while quiet cuts do not',
      () async {
        // Synthetic stream where the word "country" spans sample 126000..130000
        // and a quiet gap sits at 115840..117760 (6 frames, midpoint 116800).
        // A fixed cut at 128000 splits "country" across both windows, emitting
        // "country" at the end of window 1 and again at the start of window 2.
        // A quiet cut at 116800 keeps "country" intact in window 2.
        const totalSamples = 160000;
        final audio = _buildTaggedSpeech(
          totalSamples,
          quietRanges: const <(int, int)>[(115840, 117760)],
        );

        String transcribeSyntheticRange(int start, int end) {
          if (end <= 116800) {
            return 'ask not what your';
          }
          if (start == 0 && end == 128000) {
            return 'ask not what your country';
          }
          if (start == 128000 || start == 116800) {
            return 'country can do';
          }
          return 'ask not what your country can do';
        }

        // Fixed 8 s cuts without quiet-boundary detection.
        final fixedWin1 = transcribeSyntheticRange(0, 128000);
        final fixedWin2 = transcribeSyntheticRange(128000, totalSamples);
        expect(
          '$fixedWin1\n$fixedWin2',
          'ask not what your country\ncountry can do',
        );

        // Session with quiet-boundary detection.
        final session = QwenWindowedAsrSession(
          sourceFormat: const SpeechAudioFormat(
            sampleRateHz: 16000,
            channelCount: 1,
            encoding: 'pcm-f32le',
          ),
          onClosed: () {},
          decodeWindow:
              (
                wavBytes, {
                required confirmedPrefix,
                required registerCancel,
                required isCancelled,
              }) async {
                final (s, e) = _decodeTaggedInterval(wavBytes);
                return transcribeSyntheticRange(s, e);
              },
        );
        await session.addPcm(audio);
        await session.finish();
        final completion = await session.done;
        expect(completion.result!.text, 'ask not what your\ncountry can do');
      },
    );

    test(
      'preserves genuine repeated phrases and non-space-delimited text without lexical dedupe',
      () async {
        // Two 8s windows with no silence -> hard cut at 128000.
        final audio = Float32List(200000)..fillRange(0, 200000, 0.25);
        var windowCalls = 0;
        final session = QwenWindowedAsrSession(
          sourceFormat: const SpeechAudioFormat(
            sampleRateHz: 16000,
            channelCount: 1,
            encoding: 'pcm-f32le',
          ),
          onClosed: () {},
          decodeWindow:
              (
                wavBytes, {
                required confirmedPrefix,
                required registerCancel,
                required isCancelled,
              }) async {
                final sampleCount = (wavBytes.length - 44) ~/ 2;
                if (sampleCount == 128000) {
                  windowCalls++;
                  return 'ask not 你好';
                }
                if (confirmedPrefix.isNotEmpty) {
                  return 'ask not 你好';
                }
                return 'partial';
              },
        );

        await session.addPcm(audio);
        await session.finish();
        final completion = await session.done;

        expect(windowCalls, 1);
        expect(completion.result!.text, 'ask not 你好\nask not 你好');
      },
    );

    test(
      'replaces pending text at 2/4/6s checkpoints and reuses exact hypothesis at finish',
      () async {
        final audio = Float32List(32000)..fillRange(0, 32000, 0.2);
        var decodeCount = 0;
        final session = QwenWindowedAsrSession(
          sourceFormat: const SpeechAudioFormat(
            sampleRateHz: 16000,
            channelCount: 1,
            encoding: 'pcm-f32le',
          ),
          onClosed: () {},
          decodeWindow:
              (
                wavBytes, {
                required confirmedPrefix,
                required registerCancel,
                required isCancelled,
              }) async {
                decodeCount++;
                final sampleCount = (wavBytes.length - 44) ~/ 2;
                return 'hyp-${sampleCount ~/ 16000}s';
              },
        );

        final partials = <SpeechToTextPartialEvent>[];
        final sub = session.events.listen((event) {
          if (event is SpeechToTextPartialEvent) {
            partials.add(event);
          }
        });

        await session.addPcm(audio);
        await session.addPcm(audio);
        await session.addPcm(audio);
        await session.finish();
        final completion = await session.done;
        await sub.cancel();

        expect(decodeCount, 3);
        expect(partials.map((p) => p.pendingText).toList(), <String>[
          'hyp-2s',
          'hyp-4s',
          'hyp-6s',
        ]);
        expect(partials.every((p) => p.confirmedText == ''), isTrue);
        expect(completion.result!.text, 'hyp-6s');
      },
    );

    test(
      'handles exact 8s boundary (±1 sample) without double-decoding',
      () async {
        for (final length in <int>[127999, 128000, 128001]) {
          final audio = Float32List(length)..fillRange(0, length, 0.2);
          final decodedLengths = <int>[];
          final session = QwenWindowedAsrSession(
            sourceFormat: const SpeechAudioFormat(
              sampleRateHz: 16000,
              channelCount: 1,
              encoding: 'pcm-f32le',
            ),
            onClosed: () {},
            decodeWindow:
                (
                  wavBytes, {
                  required confirmedPrefix,
                  required registerCancel,
                  required isCancelled,
                }) async {
                  final samples = (wavBytes.length - 44) ~/ 2;
                  decodedLengths.add(samples);
                  return 'w$samples';
                },
          );

          await session.addPcm(audio);
          await session.finish();
          final completion = await session.done;
          expect(completion.state, SpeechToTextCompletionState.completed);
          expect(
            completion.result!.audioDuration,
            Duration(
              microseconds: (length * Duration.microsecondsPerSecond) ~/ 16000,
            ),
          );

          if (length == 128000) {
            // 2s, 4s, 6s, 8s — finish must not decode again.
            expect(decodedLengths, <int>[32000, 64000, 96000, 128000]);
          } else if (length == 127999) {
            expect(decodedLengths, <int>[32000, 64000, 96000, 127999]);
          } else {
            expect(decodedLengths, <int>[32000, 64000, 96000, 128000, 1]);
          }
        }
      },
    );

    test(
      'suppresses empty intermediate windows and fails an all-empty session',
      () async {
        // 10 s: first 8 s silent (returns ''), last 2 s speech (returns 'hello').
        final audio = Float32List(160000);
        audio.fillRange(128000, 160000, 0.3);

        final session = QwenWindowedAsrSession(
          sourceFormat: const SpeechAudioFormat(
            sampleRateHz: 16000,
            channelCount: 1,
            encoding: 'pcm-f32le',
          ),
          onClosed: () {},
          decodeWindow:
              (
                wavBytes, {
                required confirmedPrefix,
                required registerCancel,
                required isCancelled,
              }) async {
                final data = ByteData.sublistView(wavBytes);
                final sampleCount = (wavBytes.length - 44) ~/ 2;
                for (var i = 0; i < sampleCount; i++) {
                  if (data.getInt16(44 + i * 2, Endian.little).abs() > 1000) {
                    return 'hello';
                  }
                }
                return '';
              },
        );

        await session.addPcm(audio);
        await session.finish();
        final completion = await session.done;
        expect(completion.state, SpeechToTextCompletionState.completed);
        expect(completion.result!.text, 'hello');

        // All-empty session fails with LlamaSpeechException.
        final emptySession = QwenWindowedAsrSession(
          sourceFormat: const SpeechAudioFormat(
            sampleRateHz: 16000,
            channelCount: 1,
            encoding: 'pcm-f32le',
          ),
          onClosed: () {},
          decodeWindow:
              (
                wavBytes, {
                required confirmedPrefix,
                required registerCancel,
                required isCancelled,
              }) async => '',
        );
        final errors = <Object>[];
        final sub = emptySession.events.listen((_) {}, onError: errors.add);
        await emptySession.addPcm(Float32List(16000));
        await emptySession.finish();
        final emptyCompletion = await emptySession.done;
        await sub.cancel();

        expect(emptyCompletion.state, SpeechToTextCompletionState.failed);
        expect(emptyCompletion.error, isA<LlamaSpeechException>());
        expect(errors, hasLength(1));
      },
    );

    test(
      'cancel takes precedence over decode error mid-push and during finish tail',
      () async {
        for (final duringFinish in <bool>[false, true]) {
          final decodeStarted = Completer<void>();
          final decodeGate = Completer<void>();
          final session = QwenWindowedAsrSession(
            sourceFormat: const SpeechAudioFormat(
              sampleRateHz: 16000,
              channelCount: 1,
              encoding: 'pcm-f32le',
            ),
            onClosed: () {},
            decodeWindow:
                (
                  wavBytes, {
                  required confirmedPrefix,
                  required registerCancel,
                  required isCancelled,
                }) async {
                  registerCancel(() async {
                    if (!decodeGate.isCompleted) {
                      decodeGate.complete();
                    }
                  });
                  if (!decodeStarted.isCompleted) {
                    decodeStarted.complete();
                  }
                  await decodeGate.future;
                  throw LlamaInferenceException('aborted by cancel');
                },
          );

          final errors = <Object>[];
          final sub = session.events.listen((_) {}, onError: errors.add);

          final Future<void> activeOp;
          if (duringFinish) {
            await session.addPcm(Float32List(16000)..fillRange(0, 16000, 0.2));
            activeOp = session.finish();
          } else {
            activeOp = session.addPcm(
              Float32List(32000)..fillRange(0, 32000, 0.2),
            );
          }

          await decodeStarted.future;
          await session.cancel();
          await activeOp;
          final completion = await session.done;
          await sub.cancel();

          expect(
            completion.state,
            SpeechToTextCompletionState.cancelled,
            reason: 'duringFinish=$duringFinish',
          );
          expect(errors, isEmpty, reason: 'duringFinish=$duringFinish');
        }
      },
    );
  });
}

/// Encodes each 320-sample frame's global frame index into the first two samples
/// of that frame so a fake decoder can recover the exact `[start, end)` sample
/// range from the WAV bytes.
Float32List _buildTaggedSpeech(
  int totalSamples, {
  List<(int, int)> quietRanges = const <(int, int)>[],
}) {
  final samples = Float32List(totalSamples);
  for (var frameStart = 0; frameStart < totalSamples; frameStart += 320) {
    final frameIndex = frameStart ~/ 320;
    final frameEnd = math.min(frameStart + 320, totalSamples);
    final isQuiet = quietRanges.any(
      (range) => frameStart >= range.$1 && frameEnd <= range.$2,
    );
    if (isQuiet) {
      continue;
    }
    for (var i = frameStart; i < frameEnd; i++) {
      samples[i] = 0.25;
    }
    // Encode frameIndex into samples[frameStart] and samples[frameStart + 1]
    // using values in [0.25, 0.75] so RMS stays well above 0.01.
    final low = frameIndex % 1000;
    final high = frameIndex ~/ 1000;
    samples[frameStart] = 0.25 + low * 0.0005;
    if (frameStart + 1 < frameEnd) {
      samples[frameStart + 1] = 0.25 + high * 0.0005;
    }
  }
  return samples;
}

(int, int) _decodeTaggedInterval(Uint8List wavBytes) {
  final data = ByteData.sublistView(wavBytes);
  final sampleCount = (wavBytes.length - 44) ~/ 2;
  int decodeFrameAt(int sampleOffset) {
    final s0 = data.getInt16(44 + sampleOffset * 2, Endian.little) / 32767.0;
    final s1 =
        data.getInt16(44 + (sampleOffset + 1) * 2, Endian.little) / 32767.0;
    final low = ((s0 - 0.25) / 0.0005).round();
    final high = ((s1 - 0.25) / 0.0005).round();
    return high * 1000 + low;
  }

  // Find the first non-silent 160-aligned frame boundary.
  for (var offset = 0; offset + 320 <= sampleCount; offset += 160) {
    final sample = data.getInt16(44 + offset * 2, Endian.little) / 32767.0;
    if (sample > 0.2) {
      final isMidpointStart =
          offset == 0 &&
          (sample - 0.25).abs() < 0.0001 &&
          sampleCount > 160 &&
          (data.getInt16(44 + 160 * 2, Endian.little) / 32767.0) > 0.2502;
      if (isMidpointStart) {
        final startSample = decodeFrameAt(160) * 320 - 160;
        return (startSample, startSample + sampleCount);
      }
      final prevOffset = offset >= 160 ? offset - 160 : -1;
      if (prevOffset < 0 ||
          (data.getInt16(44 + prevOffset * 2, Endian.little) / 32767.0).abs() <
              0.1) {
        final startSample = decodeFrameAt(offset) * 320 - offset;
        return (startSample, startSample + sampleCount);
      }
    }
  }
  return (0, sampleCount);
}
