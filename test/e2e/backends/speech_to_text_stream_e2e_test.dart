@TestOn('vm')
@Tags(['local-only'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:test/test.dart';

const String _defaultJfkWav =
    'packages/llamadart_validation/assets/speech/jfk.wav';

String? _envFile(String key, [String? fallbackKey]) {
  final raw = Platform.environment[key]?.trim();
  if (raw != null && raw.isNotEmpty) {
    return raw;
  }
  if (fallbackKey != null) {
    final fallback = Platform.environment[fallbackKey]?.trim();
    if (fallback != null && fallback.isNotEmpty) {
      return fallback;
    }
  }
  return null;
}

bool _exists(String? path) => path != null && File(path).existsSync();

String? _requireStreamInput(String? path, String envKey) {
  if (path == null || path.isEmpty) {
    markTestSkipped('Set $envKey to run the live ASR stream E2E.');
    return null;
  }
  if (!File(path).existsSync()) {
    throw StateError('$envKey does not exist: $path');
  }
  return path;
}

Float32List _decodeWavPcm16Mono16k(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (chunkId == 'data') {
      final sampleCount = chunkSize ~/ 2;
      final pcm = Float32List(sampleCount);
      for (var i = 0; i < sampleCount; i++) {
        pcm[i] = data.getInt16(offset + i * 2, Endian.little) / 32768.0;
      }
      return pcm;
    }
    offset += chunkSize + (chunkSize.isOdd ? 1 : 0);
  }
  throw StateError('No WAV data chunk found in $path');
}

Float32List _repeatPcm(Float32List unit, int targetSeconds) {
  final targetSamples = targetSeconds * 16000;
  final out = Float32List(targetSamples);
  var written = 0;
  while (written < targetSamples) {
    final copyLen = min(unit.length, targetSamples - written);
    out.setRange(written, written + copyLen, unit);
    written += copyLen;
  }
  return out;
}

String _normalizeWords(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var index = 0;
  while (true) {
    final found = haystack.indexOf(needle, index);
    if (found < 0) {
      return count;
    }
    count++;
    index = found + needle.length;
  }
}

void _assertMonotonicPartials(
  List<SpeechToTextPartialEvent> partials,
  String finalText,
) {
  var prev = '';
  for (final p in partials) {
    expect(p.confirmedText, p.text);
    expect(p.pendingText, '');
    expect(p.text.startsWith(prev), isTrue);
    prev = p.text;
  }
  expect(finalText.startsWith(prev), isTrue);
}

Future<String> _streamChunks(
  SpeechToTextEngine engine,
  Float32List pcm,
  List<int> chunkSizes, {
  List<SpeechToTextPartialEvent>? partialsOut,
}) async {
  final session = await engine.startStream();
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
  try {
    var offset = 0;
    var idx = 0;
    while (offset < pcm.length) {
      final size = chunkSizes[idx % chunkSizes.length];
      final end = min(offset + size, pcm.length);
      await session.addPcm(Float32List.sublistView(pcm, offset, end));
      offset = end;
      idx++;
    }
    await session.finish();
    final completion = await session.done;
    expect(completion.state, SpeechToTextCompletionState.completed);
    final result = completion.result!;
    expect(finals, hasLength(1));
    expect(finals.single.result.text, result.text);
    expect(
      result.audioDuration,
      Duration(
        microseconds: (pcm.length * Duration.microsecondsPerSecond) ~/ 16000,
      ),
    );
    _assertMonotonicPartials(partials, result.text);
    partialsOut?.addAll(partials);
    return result.text;
  } finally {
    await session.cancel();
    await sub.cancel();
  }
}

void main() {
  final jfkPath = _envFile('LLAMADART_STT_STREAM_AUDIO_PATH') ?? _defaultJfkWav;
  final voxtralModel = _envFile('LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH');
  final voxtralMmproj = _envFile('LLAMADART_STT_STREAM_VOXTRAL_MMPROJ_PATH');
  final lfm3Model = _envFile('LLAMADART_STT_STREAM_LFM3_MODEL_PATH');
  final lfm3Mmproj = _envFile('LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH');
  final qwenModel = _envFile(
    'LLAMADART_STT_STREAM_QWEN_MODEL_PATH',
    'LLAMADART_STT_MODEL_PATH',
  );
  final qwenMmproj = _envFile(
    'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH',
    'LLAMADART_STT_MMPROJ_PATH',
  );

  final hasJfk = _exists(jfkPath);
  final hasVoxtral = _exists(voxtralModel) && _exists(voxtralMmproj);
  final hasLfm3 = _exists(lfm3Model) && _exists(lfm3Mmproj);
  final hasQwen = _exists(qwenModel) && _exists(qwenMmproj);

  test(
    'Voxtral Realtime public parity, irregular chunkings, truncation, cancel/reuse, and 300s run',
    () async {
      final resolvedJfk = _requireStreamInput(
        jfkPath,
        'LLAMADART_STT_STREAM_AUDIO_PATH',
      );
      final resolvedModel = _requireStreamInput(
        voxtralModel,
        'LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH',
      );
      final resolvedMmproj = _requireStreamInput(
        voxtralMmproj,
        'LLAMADART_STT_STREAM_VOXTRAL_MMPROJ_PATH',
      );
      if (resolvedJfk == null ||
          resolvedModel == null ||
          resolvedMmproj == null) {
        return;
      }

      final jfk = _decodeWavPcm16Mono16k(resolvedJfk);
      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: const ModelParams(
          contextSize: 4096,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );

      try {
        final caps = await engine.capabilities;
        expect(caps.isSupported, isTrue);
        expect(caps.supportsStreamingInput, isTrue);
        expect(caps.supportsPartialResults, isTrue);

        // Fixed chunking vs 5 seeded irregular chunkings + complete PCM parity.
        final fixedPartials = <SpeechToTextPartialEvent>[];
        final fixedText = await _streamChunks(engine, jfk, const [
          5120,
        ], partialsOut: fixedPartials);
        expect(fixedPartials, isNotEmpty);
        final normalized = _normalizeWords(fixedText);
        expect(normalized, contains('fellow americans'));
        expect(normalized, contains('what your country can do for you'));

        final completeResult = await engine.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(jfk)),
        );
        expect(completeResult.text, fixedText);

        for (var seed = 1; seed <= 5; seed++) {
          final rng = Random(seed * 97);
          final sizes = List<int>.generate(16, (_) => 400 + rng.nextInt(4800));
          final irregularText = await _streamChunks(engine, jfk, sizes);
          expect(irregularText, fixedText);
        }

        // Direct worker parity check.
        final directBackend = NativeLlamaBackend();
        try {
          final m = await directBackend.modelLoad(
            resolvedModel,
            const ModelParams(
              contextSize: 4096,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
            ),
          );
          final c = await directBackend.contextCreate(
            m,
            const ModelParams(
              contextSize: 4096,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
            ),
          );
          final p = await directBackend.multimodalContextCreate(
            m,
            resolvedMmproj,
          );
          final directSession = await directBackend.startAsrStreamSession(
            c,
            p!,
          );
          await directSession.pushAudio(jfk);
          final directText = await directSession.finish();
          expect(directText, fixedText);
        } finally {
          await directBackend.dispose();
        }

        // Cancel before first step, during an active push, while idle, and after
        // first text, verifying immediate reuse after each.
        final sBeforePush = await engine.startStream();
        await sBeforePush.cancel();
        expect(
          (await sBeforePush.done).state,
          SpeechToTextCompletionState.cancelled,
        );
        expect(await _streamChunks(engine, jfk, const [5120]), fixedText);

        final sMidPush = await engine.startStream();
        final blockedPush = sMidPush
            .addPcm(jfk)
            .then<void>((_) {}, onError: (_) {});
        await sMidPush.cancel();
        await blockedPush;
        expect(
          (await sMidPush.done).state,
          SpeechToTextCompletionState.cancelled,
        );
        expect(await _streamChunks(engine, jfk, const [5120]), fixedText);

        final sAfterFirstText = await engine.startStream();
        final firstTextSeen = Completer<void>();
        final afterFirstSub = sAfterFirstText.events.listen((event) {
          if (event is SpeechToTextPartialEvent &&
              event.text.trim().isNotEmpty &&
              !firstTextSeen.isCompleted) {
            firstTextSeen.complete();
          }
        });
        await sAfterFirstText.addPcm(Float32List.sublistView(jfk, 0, 32000));
        await firstTextSeen.future.timeout(const Duration(seconds: 30));
        await sAfterFirstText.cancel();
        await afterFirstSub.cancel();
        expect(
          (await sAfterFirstText.done).state,
          SpeechToTextCompletionState.cancelled,
        );

        // 10x alternating idle cancel / finish reuse.
        for (var i = 0; i < 10; i++) {
          final s = await engine.startStream();
          if (i.isEven) {
            await s.addPcm(Float32List.sublistView(jfk, 0, 16000));
            await s.cancel();
            expect((await s.done).state, SpeechToTextCompletionState.cancelled);
          } else {
            await s.addPcm(Float32List.sublistView(jfk, 0, 32000));
            await s.finish();
            expect((await s.done).state, SpeechToTextCompletionState.completed);
          }
        }

        // 300s fast-producer run.
        final baselineRss = ProcessInfo.currentRss;
        var peakCurrentRss = baselineRss;
        final clip300s = _repeatPcm(jfk, 300);
        final sw = Stopwatch()..start();
        Duration? firstPartialWall;
        Duration? firstPartialAudio;
        var pushedSamples = 0;
        final s300 = await engine.startStream();
        final sub300 = s300.events.listen((event) {
          if (event is SpeechToTextPartialEvent &&
              event.text.trim().isNotEmpty &&
              firstPartialWall == null) {
            firstPartialWall = sw.elapsed;
            firstPartialAudio = event.acceptedAudioDuration;
          }
        });
        while (pushedSamples < clip300s.length) {
          final next = min(5120, clip300s.length - pushedSamples);
          await s300.addPcm(
            Float32List.sublistView(
              clip300s,
              pushedSamples,
              pushedSamples + next,
            ),
          );
          pushedSamples += next;
          peakCurrentRss = max(peakCurrentRss, ProcessInfo.currentRss);
        }
        final flushSw = Stopwatch()..start();
        await s300.finish();
        final completion300 = await s300.done;
        flushSw.stop();
        sw.stop();
        await sub300.cancel();
        peakCurrentRss = max(peakCurrentRss, ProcessInfo.currentRss);
        expect(completion300.state, SpeechToTextCompletionState.completed);
        final voxtral300Text = completion300.result!.text;
        final voxtral300Norm = _normalizeWords(voxtral300Text);
        expect(voxtral300Norm, contains('fellow americans'));
        expect(voxtral300Norm, contains('country'));
        expect(
          _countOccurrences(voxtral300Norm, 'fellow americans'),
          greaterThanOrEqualTo(25),
        );
        stderr.writeln(
          '[Voxtral 300s fast] wall=${sw.elapsedMilliseconds}ms '
          'flush=${flushSw.elapsedMilliseconds}ms '
          'firstPartialWall=${firstPartialWall?.inMilliseconds}ms '
          'firstPartialAudio=${firstPartialAudio?.inMilliseconds}ms '
          'baselineRssMB=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} '
          'peakCurrentRssMB=${(peakCurrentRss / (1024 * 1024)).toStringAsFixed(1)}',
        );
        stderr.writeln('[Voxtral 300s fast] transcript=$voxtral300Text');

        if (Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1') {
          final liveBaselineRss = ProcessInfo.currentRss;
          var livePeakCurrentRss = liveBaselineRss;
          final liveSw = Stopwatch()..start();
          Duration? liveFirstPartialWall;
          Duration? liveFirstPartialAudio;
          var livePushed = 0;
          final sLive = await engine.startStream();
          final subLive = sLive.events.listen((event) {
            if (event is SpeechToTextPartialEvent &&
                event.text.trim().isNotEmpty &&
                liveFirstPartialWall == null) {
              liveFirstPartialWall = liveSw.elapsed;
              liveFirstPartialAudio = event.acceptedAudioDuration;
            }
          });
          while (livePushed < clip300s.length) {
            final next = min(5120, clip300s.length - livePushed);
            await sLive.addPcm(
              Float32List.sublistView(clip300s, livePushed, livePushed + next),
            );
            livePushed += next;
            livePeakCurrentRss = max(
              livePeakCurrentRss,
              ProcessInfo.currentRss,
            );
            final targetMs = (livePushed * 1000) ~/ 16000;
            final remainingMs = targetMs - liveSw.elapsedMilliseconds;
            if (remainingMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: remainingMs));
            }
          }
          final liveFlushSw = Stopwatch()..start();
          await sLive.finish();
          final liveCompletion = await sLive.done;
          liveFlushSw.stop();
          liveSw.stop();
          await subLive.cancel();
          livePeakCurrentRss = max(livePeakCurrentRss, ProcessInfo.currentRss);
          expect(liveCompletion.state, SpeechToTextCompletionState.completed);
          final liveText = liveCompletion.result!.text;
          final liveNorm = _normalizeWords(liveText);
          expect(liveNorm, contains('fellow americans'));
          expect(liveNorm, contains('country'));
          expect(
            _countOccurrences(liveNorm, 'fellow americans'),
            greaterThanOrEqualTo(25),
          );
          stderr.writeln(
            '[Voxtral 300s live-paced] wall=${liveSw.elapsedMilliseconds}ms '
            'flush=${liveFlushSw.elapsedMilliseconds}ms '
            'firstPartialWall=${liveFirstPartialWall?.inMilliseconds}ms '
            'firstPartialAudio=${liveFirstPartialAudio?.inMilliseconds}ms '
            'baselineRssMB=${(liveBaselineRss / (1024 * 1024)).toStringAsFixed(1)} '
            'peakCurrentRssMB=${(livePeakCurrentRss / (1024 * 1024)).toStringAsFixed(1)}',
          );
          stderr.writeln('[Voxtral 300s live-paced] transcript=$liveText');
        }
      } finally {
        await engine.dispose();
      }

      // Voxtral 512 context truncation on 55s clip.
      final smallEngine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: const ModelParams(
          contextSize: 512,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
      try {
        final clip55s = _repeatPcm(jfk, 55);
        await expectLater(
          () => smallEngine.transcribeOnce(
            SpeechToTextRequest(audio: SpeechAudioPcmInput(clip55s)),
          ),
          throwsA(
            isA<LlamaSpeechTranscriptTruncatedException>()
                .having(
                  (e) => e.limit,
                  'limit',
                  LlamaSpeechTranscriptLimit.contextSize,
                )
                .having((e) => e.partialTranscript, 'partial', isNotEmpty),
          ),
        );
      } finally {
        await smallEngine.dispose();
      }
    },
    skip: !(hasJfk && hasVoxtral)
        ? 'Set LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH and '
              'LLAMADART_STT_STREAM_VOXTRAL_MMPROJ_PATH (and jfk.wav).'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'LFM3-Audio 2048 floor restart, chunking parity, and 300s run',
    () async {
      final resolvedJfk = _requireStreamInput(
        jfkPath,
        'LLAMADART_STT_STREAM_AUDIO_PATH',
      );
      final resolvedModel = _requireStreamInput(
        lfm3Model,
        'LLAMADART_STT_STREAM_LFM3_MODEL_PATH',
      );
      final resolvedMmproj = _requireStreamInput(
        lfm3Mmproj,
        'LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH',
      );
      if (resolvedJfk == null ||
          resolvedModel == null ||
          resolvedMmproj == null) {
        return;
      }

      final jfk = _decodeWavPcm16Mono16k(resolvedJfk);
      final engine2048 = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: const ModelParams(
          contextSize: 2048,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
      try {
        final fixedText = await _streamChunks(engine2048, jfk, const [5120]);
        expect(_normalizeWords(fixedText), contains('fellow americans'));

        for (var seed = 1; seed <= 5; seed++) {
          final rng = Random(seed * 131);
          final sizes = List<int>.generate(16, (_) => 400 + rng.nextInt(4800));
          final irregularText = await _streamChunks(engine2048, jfk, sizes);
          expect(irregularText, fixedText);
        }

        // 44s crossing a restart at 2048 floor.
        final clip44s = _repeatPcm(jfk, 44);
        final res44 = await engine2048.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(clip44s)),
        );
        expect(res44.text.length, greaterThan(fixedText.length * 2));
      } finally {
        await engine2048.dispose();
      }

      final engine4096 = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: const ModelParams(
          contextSize: 4096,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
      try {
        final baselineRss = ProcessInfo.currentRss;
        var peakCurrentRss = baselineRss;
        final clip300s = _repeatPcm(jfk, 300);
        final sw = Stopwatch()..start();
        Duration? firstPartialWall;
        Duration? firstPartialAudio;
        var pushedSamples = 0;
        final s300 = await engine4096.startStream();
        final sub300 = s300.events.listen((event) {
          if (event is SpeechToTextPartialEvent &&
              event.text.trim().isNotEmpty &&
              firstPartialWall == null) {
            firstPartialWall = sw.elapsed;
            firstPartialAudio = event.acceptedAudioDuration;
          }
        });
        while (pushedSamples < clip300s.length) {
          final next = min(5120, clip300s.length - pushedSamples);
          await s300.addPcm(
            Float32List.sublistView(
              clip300s,
              pushedSamples,
              pushedSamples + next,
            ),
          );
          pushedSamples += next;
          peakCurrentRss = max(peakCurrentRss, ProcessInfo.currentRss);
        }
        final flushSw = Stopwatch()..start();
        await s300.finish();
        final completion300 = await s300.done;
        flushSw.stop();
        sw.stop();
        await sub300.cancel();
        peakCurrentRss = max(peakCurrentRss, ProcessInfo.currentRss);
        expect(completion300.state, SpeechToTextCompletionState.completed);
        final lfm300Text = completion300.result!.text;
        final lfm300Norm = _normalizeWords(lfm300Text);
        expect(lfm300Norm, contains('fellow americans'));
        expect(lfm300Norm, contains('country'));
        expect(
          _countOccurrences(lfm300Norm, 'fellow americans'),
          greaterThanOrEqualTo(25),
        );
        stderr.writeln(
          '[LFM3 300s fast] wall=${sw.elapsedMilliseconds}ms '
          'flush=${flushSw.elapsedMilliseconds}ms '
          'firstPartialWall=${firstPartialWall?.inMilliseconds}ms '
          'firstPartialAudio=${firstPartialAudio?.inMilliseconds}ms '
          'baselineRssMB=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} '
          'peakCurrentRssMB=${(peakCurrentRss / (1024 * 1024)).toStringAsFixed(1)}',
        );
        stderr.writeln('[LFM3 300s fast] transcript=$lfm300Text');

        if (Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1') {
          final liveBaselineRss = ProcessInfo.currentRss;
          var livePeakCurrentRss = liveBaselineRss;
          final liveSw = Stopwatch()..start();
          Duration? liveFirstPartialWall;
          Duration? liveFirstPartialAudio;
          var livePushed = 0;
          final sLive = await engine4096.startStream();
          final subLive = sLive.events.listen((event) {
            if (event is SpeechToTextPartialEvent &&
                event.text.trim().isNotEmpty &&
                liveFirstPartialWall == null) {
              liveFirstPartialWall = liveSw.elapsed;
              liveFirstPartialAudio = event.acceptedAudioDuration;
            }
          });
          while (livePushed < clip300s.length) {
            final next = min(5120, clip300s.length - livePushed);
            await sLive.addPcm(
              Float32List.sublistView(clip300s, livePushed, livePushed + next),
            );
            livePushed += next;
            livePeakCurrentRss = max(
              livePeakCurrentRss,
              ProcessInfo.currentRss,
            );
            final targetMs = (livePushed * 1000) ~/ 16000;
            final remainingMs = targetMs - liveSw.elapsedMilliseconds;
            if (remainingMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: remainingMs));
            }
          }
          final liveFlushSw = Stopwatch()..start();
          await sLive.finish();
          final liveCompletion = await sLive.done;
          liveFlushSw.stop();
          liveSw.stop();
          await subLive.cancel();
          livePeakCurrentRss = max(livePeakCurrentRss, ProcessInfo.currentRss);
          expect(liveCompletion.state, SpeechToTextCompletionState.completed);
          final liveText = liveCompletion.result!.text;
          final liveNorm = _normalizeWords(liveText);
          expect(liveNorm, contains('fellow americans'));
          expect(liveNorm, contains('country'));
          expect(
            _countOccurrences(liveNorm, 'fellow americans'),
            greaterThanOrEqualTo(25),
          );
          stderr.writeln(
            '[LFM3 300s live-paced] wall=${liveSw.elapsedMilliseconds}ms '
            'flush=${liveFlushSw.elapsedMilliseconds}ms '
            'firstPartialWall=${liveFirstPartialWall?.inMilliseconds}ms '
            'firstPartialAudio=${liveFirstPartialAudio?.inMilliseconds}ms '
            'baselineRssMB=${(liveBaselineRss / (1024 * 1024)).toStringAsFixed(1)} '
            'peakCurrentRssMB=${(livePeakCurrentRss / (1024 * 1024)).toStringAsFixed(1)}',
          );
          stderr.writeln('[LFM3 300s live-paced] transcript=$liveText');
        }
      } finally {
        await engine4096.dispose();
      }
    },
    skip: !(hasJfk && hasLfm3)
        ? 'Set LLAMADART_STT_STREAM_LFM3_MODEL_PATH and '
              'LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH (and jfk.wav).'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'Qwen3-ASR projector refuses LlamaCppLiveAsrAdapter',
    () async {
      final resolvedModel = _requireStreamInput(
        qwenModel,
        'LLAMADART_STT_STREAM_QWEN_MODEL_PATH',
      );
      final resolvedMmproj = _requireStreamInput(
        qwenMmproj,
        'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH',
      );
      if (resolvedModel == null || resolvedMmproj == null) {
        return;
      }

      await expectLater(
        () => SpeechToTextEngine.load(
          SpeechToTextModel(
            ModelSource.path(resolvedModel),
            projector: ModelSource.path(resolvedMmproj),
            adapter: const LlamaCppLiveAsrAdapter(),
          ),
          params: const ModelParams(
            contextSize: 2048,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    },
    skip: !hasQwen
        ? 'Set LLAMADART_STT_STREAM_QWEN_MODEL_PATH and '
              'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH.'
        : false,
  );
}
