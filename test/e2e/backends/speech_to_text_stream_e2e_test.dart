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

const String _lfm3Model =
    '/opt/UnitySrc/personal/llama/models/lfm3-audio-2b-02355c1a/LFM3-Audio-2B-Q4_K_M.gguf';
const String _lfm3Mmproj =
    '/opt/UnitySrc/personal/llama/models/lfm3-audio-2b-02355c1a/mmproj-LFM3-Audio-2B-Q8_0.gguf';
const String _voxtralModel =
    '/opt/UnitySrc/personal/llama/models/voxtral-mini-4b-realtime-0b0f7ac9/Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf';
const String _voxtralMmproj =
    '/opt/UnitySrc/personal/llama/models/voxtral-mini-4b-realtime-0b0f7ac9/mmproj-Voxtral-Mini-4B-Realtime-2602-Q8_0.gguf';
const String _qwen3AsrModel =
    '/opt/UnitySrc/personal/llama/models/qwen3-asr-0.6b-ggml-org/Qwen3-ASR-0.6B-Q8_0.gguf';
const String _qwen3AsrMmproj =
    '/opt/UnitySrc/personal/llama/models/qwen3-asr-0.6b-ggml-org/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf';
const String _jfkWav = 'packages/llamadart_validation/assets/speech/jfk.wav';

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
  final hasJfk = File(_jfkWav).existsSync();
  final hasVoxtral =
      File(_voxtralModel).existsSync() && File(_voxtralMmproj).existsSync();
  final hasLfm3 =
      File(_lfm3Model).existsSync() && File(_lfm3Mmproj).existsSync();
  final hasQwen =
      File(_qwen3AsrModel).existsSync() && File(_qwen3AsrMmproj).existsSync();

  test(
    'Voxtral Realtime public parity, irregular chunkings, truncation, cancel/reuse, and 300s run',
    () async {
      final jfk = _decodeWavPcm16Mono16k(_jfkWav);
      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(_voxtralModel),
          projector: ModelSource.path(_voxtralMmproj),
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
            _voxtralModel,
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
            _voxtralMmproj,
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

        // Cancel before first step, during push, while idle, after first text, and 10x alternate.
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
        }
        final flushSw = Stopwatch()..start();
        await s300.finish();
        final completion300 = await s300.done;
        flushSw.stop();
        sw.stop();
        await sub300.cancel();
        final peakRss = ProcessInfo.maxRss;
        expect(completion300.state, SpeechToTextCompletionState.completed);
        final voxtral300Text = completion300.result!.text;
        expect(_normalizeWords(voxtral300Text), contains('fellow americans'));
        expect(_normalizeWords(voxtral300Text), contains('country'));
        stderr.writeln(
          '[Voxtral 300s fast] wall=${sw.elapsedMilliseconds}ms '
          'flush=${flushSw.elapsedMilliseconds}ms '
          'firstPartialWall=${firstPartialWall?.inMilliseconds}ms '
          'firstPartialAudio=${firstPartialAudio?.inMilliseconds}ms '
          'baselineRssMB=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} '
          'peakRssMB=${(peakRss / (1024 * 1024)).toStringAsFixed(1)}',
        );
        stderr.writeln('[Voxtral 300s fast] transcript=$voxtral300Text');

        if (Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1') {
          final liveBaselineRss = ProcessInfo.currentRss;
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
          final livePeakRss = ProcessInfo.maxRss;
          expect(liveCompletion.state, SpeechToTextCompletionState.completed);
          final liveText = liveCompletion.result!.text;
          expect(_normalizeWords(liveText), contains('fellow americans'));
          expect(_normalizeWords(liveText), contains('country'));
          stderr.writeln(
            '[Voxtral 300s live-paced] wall=${liveSw.elapsedMilliseconds}ms '
            'flush=${liveFlushSw.elapsedMilliseconds}ms '
            'firstPartialWall=${liveFirstPartialWall?.inMilliseconds}ms '
            'firstPartialAudio=${liveFirstPartialAudio?.inMilliseconds}ms '
            'baselineRssMB=${(liveBaselineRss / (1024 * 1024)).toStringAsFixed(1)} '
            'peakRssMB=${(livePeakRss / (1024 * 1024)).toStringAsFixed(1)}',
          );
          stderr.writeln('[Voxtral 300s live-paced] transcript=$liveText');
        }
      } finally {
        await engine.dispose();
      }

      // Voxtral 512 context truncation on 55s clip.
      final smallEngine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(_voxtralModel),
          projector: ModelSource.path(_voxtralMmproj),
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
    skip: !(hasJfk && hasVoxtral),
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'LFM3-Audio 2048 floor restart, chunking parity, and 300s run',
    () async {
      final jfk = _decodeWavPcm16Mono16k(_jfkWav);
      final engine2048 = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(_lfm3Model),
          projector: ModelSource.path(_lfm3Mmproj),
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
          ModelSource.path(_lfm3Model),
          projector: ModelSource.path(_lfm3Mmproj),
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
        }
        final flushSw = Stopwatch()..start();
        await s300.finish();
        final completion300 = await s300.done;
        flushSw.stop();
        sw.stop();
        await sub300.cancel();
        final peakRss = ProcessInfo.maxRss;
        expect(completion300.state, SpeechToTextCompletionState.completed);
        final lfm300Text = completion300.result!.text;
        expect(_normalizeWords(lfm300Text), contains('fellow americans'));
        expect(_normalizeWords(lfm300Text), contains('country'));
        stderr.writeln(
          '[LFM3 300s fast] wall=${sw.elapsedMilliseconds}ms '
          'flush=${flushSw.elapsedMilliseconds}ms '
          'firstPartialWall=${firstPartialWall?.inMilliseconds}ms '
          'firstPartialAudio=${firstPartialAudio?.inMilliseconds}ms '
          'baselineRssMB=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} '
          'peakRssMB=${(peakRss / (1024 * 1024)).toStringAsFixed(1)}',
        );
        stderr.writeln('[LFM3 300s fast] transcript=$lfm300Text');

        if (Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1') {
          final liveBaselineRss = ProcessInfo.currentRss;
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
          final livePeakRss = ProcessInfo.maxRss;
          expect(liveCompletion.state, SpeechToTextCompletionState.completed);
          final liveText = liveCompletion.result!.text;
          expect(_normalizeWords(liveText), contains('fellow americans'));
          expect(_normalizeWords(liveText), contains('country'));
          stderr.writeln(
            '[LFM3 300s live-paced] wall=${liveSw.elapsedMilliseconds}ms '
            'flush=${liveFlushSw.elapsedMilliseconds}ms '
            'firstPartialWall=${liveFirstPartialWall?.inMilliseconds}ms '
            'firstPartialAudio=${liveFirstPartialAudio?.inMilliseconds}ms '
            'baselineRssMB=${(liveBaselineRss / (1024 * 1024)).toStringAsFixed(1)} '
            'peakRssMB=${(livePeakRss / (1024 * 1024)).toStringAsFixed(1)}',
          );
          stderr.writeln('[LFM3 300s live-paced] transcript=$liveText');
        }
      } finally {
        await engine4096.dispose();
      }
    },
    skip: !(hasJfk && hasLfm3),
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test('Qwen3-ASR projector refuses LlamaCppLiveAsrAdapter', () async {
    await expectLater(
      () => SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(_qwen3AsrModel),
          projector: ModelSource.path(_qwen3AsrMmproj),
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
  }, skip: !hasQwen);
}
