@TestOn('vm')
@Tags(['local-only'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/qwen_windowed_asr.dart';
import 'package:test/test.dart';

const String _defaultJfkWav =
    'packages/llamadart_validation/assets/speech/jfk.wav';

const String _defaultSecondWav =
    'test/fixtures/librispeech_dev_clean/1272-128104-0000.wav';

const String _jfkReference =
    'and so my fellow americans ask not what your country can do for you '
    'ask what you can do for your country';

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

List<String> _normalizeWords(String text) {
  final cleaned = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) {
    return const <String>[];
  }
  return cleaned.split(' ');
}

double _wordErrorRate(String reference, String hypothesis) {
  final ref = _normalizeWords(reference);
  final hyp = _normalizeWords(hypothesis);
  if (ref.isEmpty) {
    return hyp.isEmpty ? 0.0 : 1.0;
  }
  final dp = List<int>.generate(hyp.length + 1, (j) => j);
  for (var i = 1; i <= ref.length; i++) {
    var prev = dp[0];
    dp[0] = i;
    for (var j = 1; j <= hyp.length; j++) {
      final temp = dp[j];
      final cost = ref[i - 1] == hyp[j - 1] ? 0 : 1;
      dp[j] = min(min(dp[j] + 1, dp[j - 1] + 1), prev + cost);
      prev = temp;
    }
  }
  return dp[hyp.length] / ref.length;
}

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

Future<
  ({
    String text,
    Duration duration,
    List<SpeechToTextPartialEvent> partials,
    Duration? firstPendingWall,
    Duration? firstConfirmedWall,
    List<int> pushMicros,
    int maxRssBytes,
  })
>
_streamChunks(
  SpeechToTextEngine engine,
  Float32List pcm,
  List<int> chunkSizes, {
  bool paced = false,
}) async {
  final stopwatch = Stopwatch()..start();
  final session = await engine.startStream();
  final partials = <SpeechToTextPartialEvent>[];
  final finals = <SpeechToTextFinalEvent>[];
  Duration? firstPendingWall;
  Duration? firstConfirmedWall;
  var maxRssBytes = ProcessInfo.currentRss;

  final sub = session.events.listen((event) {
    switch (event) {
      case SpeechToTextPartialEvent():
        partials.add(event);
        if (firstPendingWall == null &&
            (event.pendingText?.isNotEmpty ?? false)) {
          firstPendingWall = stopwatch.elapsed;
        }
        if (firstConfirmedWall == null &&
            (event.confirmedText?.isNotEmpty ?? false)) {
          firstConfirmedWall = stopwatch.elapsed;
        }
      case SpeechToTextFinalEvent():
        finals.add(event);
    }
  });

  final pushMicros = <int>[];
  final pushWatch = Stopwatch();
  var pos = 0;
  var chunkIndex = 0;
  var audioSeconds = 0.0;
  while (pos < pcm.length) {
    final size = chunkSizes[chunkIndex % chunkSizes.length];
    final end = min(pos + size, pcm.length);
    final slice = Float32List.sublistView(pcm, pos, end);
    if (paced) {
      final targetWallMicros = (audioSeconds * 1000000).round();
      final lag = targetWallMicros - stopwatch.elapsedMicroseconds;
      if (lag > 0) {
        await Future<void>.delayed(Duration(microseconds: lag));
      }
    }
    pushWatch
      ..reset()
      ..start();
    await session.addPcm(slice);
    pushWatch.stop();
    pushMicros.add(pushWatch.elapsedMicroseconds);
    final rss = ProcessInfo.currentRss;
    if (rss > maxRssBytes) {
      maxRssBytes = rss;
    }
    audioSeconds += (end - pos) / 16000.0;
    pos = end;
    chunkIndex++;
  }
  await session.finish();
  final completion = await session.done;
  await sub.cancel();
  stopwatch.stop();

  expect(completion.state, SpeechToTextCompletionState.completed);
  expect(finals, hasLength(1));
  return (
    text: finals.single.result.text,
    duration: finals.single.result.audioDuration!,
    partials: partials,
    firstPendingWall: firstPendingWall,
    firstConfirmedWall: firstConfirmedWall,
    pushMicros: pushMicros,
    maxRssBytes: maxRssBytes,
  );
}

void main() {
  final modelPath = _envFile(
    'LLAMADART_STT_STREAM_QWEN_MODEL_PATH',
    'LLAMADART_STT_MODEL_PATH',
  );
  final projectorPath = _envFile(
    'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH',
    'LLAMADART_STT_MMPROJ_PATH',
  );
  final jfkPath = _envFile('LLAMADART_STT_STREAM_AUDIO_PATH') ?? _defaultJfkWav;
  final secondAudioOverride = _envFile(
    'LLAMADART_STT_WINDOWED_SECOND_AUDIO_PATH',
  );
  final secondAudioPath = secondAudioOverride ?? _defaultSecondWav;
  final runPaced = Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1';

  const params = ModelParams(
    preferredBackend: GpuBackend.cpu,
    gpuLayers: 0,
    contextSize: 4096,
    numberOfThreads: 2,
    numberOfThreadsBatch: 2,
  );

  test(
    'Qwen3-ASR windowed parity, 44s repetition, boundaries, silence, and second utterance',
    () async {
      if (modelPath == null || projectorPath == null) {
        markTestSkipped(
          'Set LLAMADART_STT_STREAM_QWEN_MODEL_PATH and '
          'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH to run Qwen windowed E2E.',
        );
        return;
      }

      final secondPcm = _decodeWavPcm16Mono16k(secondAudioPath);
      final secondReference =
          (secondAudioOverride == null
              ? null
              : _envFile('LLAMADART_STT_WINDOWED_SECOND_REFERENCE')) ??
          _loadSiblingTranscript(secondAudioPath);
      if (secondReference == null) {
        throw StateError(
          'Missing sibling .txt transcript for $secondAudioPath. '
          'For custom audio, you can also set '
          'LLAMADART_STT_WINDOWED_SECOND_REFERENCE.',
        );
      }
      final secondAudioLabel = secondAudioOverride == null
          ? _defaultSecondWav
          : 'custom audio';

      // 1. Whole-file reference via Qwen3AsrAdapter.
      final wholeEngine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3AsrAdapter(),
        ),
        params: params,
      );
      late final String wholeJfkText;
      late final String wholeSecondText;
      try {
        final jfkResult = await wholeEngine.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioFileInput(jfkPath)),
        );
        wholeJfkText = jfkResult.text;
        final secondResult = await wholeEngine.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioFileInput(secondAudioPath)),
        );
        wholeSecondText = secondResult.text;
      } finally {
        await wholeEngine.dispose();
      }

      final wholeJfkWer = _wordErrorRate(_jfkReference, wholeJfkText);
      stderr.writeln('Whole JFK ($wholeJfkWer WER): $wholeJfkText');

      // 2. Windowed engine.
      final windowedEngine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        params: params,
      );
      try {
        final caps = await windowedEngine.capabilities;
        expect(caps.isSupported, isTrue);
        expect(caps.inputMode, SpeechToTextInputMode.windowed);

        final jfkPcm = _decodeWavPcm16Mono16k(jfkPath);

        // Complete-PCM windowed vs fixed vs 5 seeded irregular chunkings.
        final completeResult = await windowedEngine.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(jfkPcm)),
        );
        final fixedRun = await _streamChunks(windowedEngine, jfkPcm, <int>[
          4000,
        ]);
        final normalizedBase = _normalizeWords(fixedRun.text).join(' ');
        expect(_normalizeWords(completeResult.text).join(' '), normalizedBase);

        final jfkWer = _wordErrorRate(_jfkReference, fixedRun.text);
        stderr.writeln('Windowed JFK ($jfkWer WER): ${fixedRun.text}');
        expect(jfkWer, lessThanOrEqualTo(0.10));
        expect(jfkWer, lessThanOrEqualTo(wholeJfkWer + 0.05));
        expect(normalizedBase, endsWith('do for your country'));

        for (var seed = 1; seed <= 5; seed++) {
          final rng = Random(seed * 131);
          final irregular = List<int>.generate(
            32,
            (_) => 320 + rng.nextInt(12000),
          );
          final run = await _streamChunks(windowedEngine, jfkPcm, irregular);
          expect(
            _normalizeWords(run.text).join(' '),
            normalizedBase,
            reason: 'seed=$seed',
          );
        }

        // 44s repeated JFK (4x 11s = 44s).
        final repeated44s = _repeatPcm(jfkPcm, 44);
        final run44s = await _streamChunks(windowedEngine, repeated44s, <int>[
          4000,
        ]);
        final norm44s = _normalizeWords(run44s.text).join(' ');
        final ref44s = List<String>.filled(4, _jfkReference).join(' ');
        final wer44s = _wordErrorRate(ref44s, run44s.text);
        stderr.writeln(
          '44s repeated JFK ($wer44s WER, duration=${run44s.duration}): '
          '${run44s.text}',
        );
        expect(run44s.duration, const Duration(seconds: 44));
        expect(wer44s, lessThanOrEqualTo(0.10));
        expect(_countOccurrences(norm44s, 'americans'), 4);
        expect(_countOccurrences(norm44s, 'ask not'), 4);
        expect(norm44s, endsWith('do for your country'));

        // Utterance gap across quiet boundary (JFK + 3s silence + JFK).
        final silence3s = Float32List(48000);
        final withSilence = Float32List(jfkPcm.length * 2 + silence3s.length)
          ..setRange(0, jfkPcm.length, jfkPcm)
          ..setRange(
            jfkPcm.length + silence3s.length,
            jfkPcm.length * 2 + silence3s.length,
            jfkPcm,
          );
        final silenceRun = await _streamChunks(
          windowedEngine,
          withSilence,
          <int>[4000],
        );
        final normSilence = _normalizeWords(silenceRun.text).join(' ');
        expect(_countOccurrences(normSilence, 'americans'), 2);

        // Forced 8s hard-cut probe: add deterministic uniform noise (RMS 0.015)
        // across all 44s so no 100ms quiet frame run has RMS <= 0.01.
        final noisy44s = _addUniformNoise(repeated44s, targetRms: 0.015);
        for (
          var offset = 0;
          offset + qwenWindowedMaxSamples <= noisy44s.length;
          offset += qwenWindowedMaxSamples
        ) {
          final slice = Float32List.sublistView(
            noisy44s,
            offset,
            offset + qwenWindowedMaxSamples,
          );
          expect(
            selectQwenWindowCut(slice, slice.length),
            qwenWindowedMaxSamples,
          );
        }
        final hardCutRun = await _streamChunks(windowedEngine, noisy44s, <int>[
          4000,
        ]);
        final hardCutWer = _wordErrorRate(ref44s, hardCutRun.text);
        stderr.writeln(
          'Hard-cut 44s noisy JFK ($hardCutWer WER, duration=${hardCutRun.duration}): '
          '${hardCutRun.text}',
        );
        expect(hardCutRun.duration, const Duration(seconds: 44));
        expect(hardCutWer, lessThanOrEqualTo(0.10));

        // Digital silence only must fail with LlamaSpeechException.
        final silentSession = await windowedEngine.startStream();
        final silentErrors = <Object>[];
        final silentSub = silentSession.events.listen(
          (_) {},
          onError: silentErrors.add,
        );
        await silentSession.addPcm(Float32List(32000));
        await silentSession.finish();
        final silentDone = await silentSession.done;
        await silentSub.cancel();
        expect(silentDone.state, SpeechToTextCompletionState.failed);
        expect(silentDone.error, isA<LlamaSpeechException>());

        final secondRun = await _streamChunks(windowedEngine, secondPcm, <int>[
          4000,
        ]);
        final wholeAbsWer = _wordErrorRate(secondReference, wholeSecondText);
        final windowedAbsWer = _wordErrorRate(secondReference, secondRun.text);
        stderr.writeln(
          'Second utterance ($secondAudioLabel, ref="$secondReference", '
          'whole="$wholeSecondText" [abs WER=$wholeAbsWer], '
          'windowed="${secondRun.text}" [abs WER=$windowedAbsWer])',
        );
        expect(windowedAbsWer, lessThanOrEqualTo(0.15));

        // Active cancellation and immediate reuse.
        final cancelSession = await windowedEngine.startStream();
        await cancelSession.addPcm(Float32List.sublistView(jfkPcm, 0, 32000));
        await cancelSession.cancel();
        expect(
          (await cancelSession.done).state,
          SpeechToTextCompletionState.cancelled,
        );
        final afterCancel = await _streamChunks(windowedEngine, jfkPcm, <int>[
          4000,
        ]);
        expect(_normalizeWords(afterCancel.text).join(' '), normalizedBase);
      } finally {
        await windowedEngine.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final (label, noiseSeconds, seed, scale, click) in [
    ('4s', 4, 257, 1.0, 0.0),
    ('5s', 5, 327, 1.0, 0.0),
    ('4s click 0.06', 4, 257, 1.0, 0.06),
    ('5s click 0.06', 5, 327, 1.0, 0.06),
    ('4s click 0.2', 4, 257, 1.0, 0.2),
    ('5s click 0.2', 5, 327, 1.0, 0.2),
    ('5s checkpoint-to-final RMS 0.00506', 5, 257, 4.0, 0.0),
    ('5s RMS 0.0063', 5, 257, 5.0, 0.0),
  ]) {
    test('Qwen3-ASR does not transcribe a quiet noise tail ($label)', () async {
      if (modelPath == null || projectorPath == null) {
        markTestSkipped('Set the Qwen model and projector paths.');
        return;
      }

      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        params: params,
      );
      try {
        const speechEnd = 112000;
        final speech = _decodeWavPcm16Mono16k(_defaultSecondWav);
        final noise = _quietNoise(noiseSeconds * 16000, seed, scale: scale);
        for (var i = 0; i < 40 && click > 0; i++) {
          noise[40000 + i] += click * exp(-i / 8) * (i.isEven ? 1 : -1);
        }
        final pcm = Float32List(speechEnd + noise.length)
          ..setRange(0, speech.length, speech)
          ..setRange(speechEnd, speechEnd + noise.length, noise);
        final run = await _streamChunks(engine, pcm, [4000]);

        expect(run.duration, Duration(seconds: 7 + noiseSeconds));
        final committed = run.partials.firstWhere(
          (event) => event.confirmedText!.isNotEmpty,
        );
        final tailPartials = run.partials.skipWhile(
          (event) => !identical(event, committed),
        );
        expect(tailPartials.length, greaterThan(1));
        expect([
          run.text,
          ...tailPartials.map((event) => event.text),
        ], everyElement(committed.confirmedText));
        expect(
          _normalizeWords(run.text),
          _normalizeWords(_loadSiblingTranscript(_defaultSecondWav)!),
        );
      } finally {
        await engine.dispose();
      }
    });
  }

  test('Qwen3-ASR retains quiet speech and a quieter final word', () async {
    if (modelPath == null || projectorPath == null) {
      markTestSkipped('Set the Qwen model and projector paths.');
      return;
    }

    final engine = await SpeechToTextEngine.load(
      SpeechToTextModel(
        ModelSource.path(modelPath),
        projector: ModelSource.path(projectorPath),
        adapter: const Qwen3WindowedAsrAdapter(),
      ),
      params: params,
    );
    try {
      final speech = _decodeWavPcm16Mono16k(_defaultSecondWav);
      final gain = 0.003 / _rms(speech);
      final noise = _quietNoise(speech.length, 257);
      for (var i = 0; i < speech.length; i++) {
        final endGain = i < speech.length - 16000 ? 1.0 : 0.35;
        final hum = 0.0001 * sin(2 * pi * 60 * i / 16000);
        speech[i] = speech[i] * gain * endGain + noise[i] * 0.1 + hum;
      }
      final run = await _streamChunks(engine, speech, [4000]);
      final words = _normalizeWords(run.text);
      if (words.first == 'mr') words[0] = 'mister';
      expect(
        words,
        _normalizeWords(_loadSiblingTranscript(_defaultSecondWav)!),
      );
    } finally {
      await engine.dispose();
    }
  });

  test(
    'Qwen3-ASR retains the spoken Portuguese instruction at low gain',
    () async {
      final spokenPath = _envFile(
        'LLAMADART_STT_WINDOWED_PORTUGUESE_AUDIO_PATH',
      );
      if (modelPath == null || projectorPath == null || spokenPath == null) {
        markTestSkipped(
          'Set the Qwen model/projector and '
          'LLAMADART_STT_WINDOWED_PORTUGUESE_AUDIO_PATH.',
        );
        return;
      }

      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        params: params,
      );
      try {
        final speech = _decodeWavPcm16Mono16k(spokenPath);
        final gain = 0.00125 / _rms(speech);
        for (var i = 0; i < speech.length; i++) {
          speech[i] *= gain;
        }
        final run = await _streamChunks(engine, speech, [4000]);
        expect(
          run.text.trim().toLowerCase().replaceFirst(RegExp(r'[.!?]$'), ''),
          'transcreva este áudio com precisão',
        );
      } finally {
        await engine.dispose();
      }
    },
  );

  test(
    'Qwen3-ASR replays all 23 quiet-speech audit controls unchanged',
    () async {
      final manifestPath = _envFile(
        'LLAMADART_STT_WINDOWED_QUIET_SPEECH_MANIFEST',
      );
      if (modelPath == null || projectorPath == null || manifestPath == null) {
        markTestSkipped(
          'Set the Qwen model/projector and quiet-speech manifest paths.',
        );
        return;
      }

      final manifest = File(manifestPath);
      final cases = (jsonDecode(manifest.readAsStringSync()) as List)
          .cast<Map<String, Object?>>();
      expect(cases.map((entry) => entry['file']).toSet(), hasLength(23));
      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        params: params,
      );
      try {
        for (final entry in cases) {
          final name = entry['file']! as String;
          final samples = File.fromUri(
            manifest.absolute.uri.resolve(name),
          ).readAsBytesSync();
          expect(
            sha256.convert(samples).toString(),
            entry['sha256'],
            reason: name,
          );
          final bytes = ByteData.sublistView(samples);
          final pcm = Float32List(samples.length ~/ 4);
          for (var i = 0; i < pcm.length; i++) {
            pcm[i] = bytes.getFloat32(i * 4, Endian.little);
          }
          final run = await _streamChunks(engine, pcm, [4000]);
          expect(run.text, entry['text'], reason: name);
          expect(
            run.partials.map((event) => event.text).toSet().toList(),
            entry['partials'],
            reason: name,
          );
        }
      } finally {
        await engine.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'Qwen3-ASR 300s sustained public-session run with RSS and lag metrics',
    () async {
      if (modelPath == null || projectorPath == null) {
        markTestSkipped(
          'Set LLAMADART_STT_STREAM_QWEN_MODEL_PATH and '
          'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH to run Qwen 300s E2E.',
        );
        return;
      }

      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(projectorPath),
          adapter: const Qwen3WindowedAsrAdapter(),
        ),
        params: params,
      );
      try {
        final jfkPcm = _decodeWavPcm16Mono16k(jfkPath);
        // Warm-up 11s before sampling baseline RSS.
        await engine.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(jfkPcm)),
        );
        final baselineRss = ProcessInfo.currentRss;

        final quietTails =
            Platform
                .environment['LLAMADART_STT_WINDOWED_SUSTAINED_QUIET_TAILS'] ==
            '1';
        final pcm300s = quietTails
            ? _repeatPcm(_speechAndNoiseBlock(), 300)
            : _repeatPcm(jfkPcm, 300);
        final wallWatch = Stopwatch()..start();
        final run = await _streamChunks(engine, pcm300s, <int>[
          4000,
        ], paced: runPaced);
        wallWatch.stop();
        final endRss = ProcessInfo.currentRss;

        final sortedPush = List<int>.from(run.pushMicros)..sort();
        final p95PushMs = sortedPush[(sortedPush.length * 0.95).floor()] / 1000;
        final maxPushMs = sortedPush.last / 1000;
        final rtf = wallWatch.elapsedMilliseconds / 300000.0;
        final deltaRssMiB = (run.maxRssBytes - baselineRss) / (1024 * 1024);

        stderr.writeln(
          'Qwen3-ASR 300s (${runPaced ? "paced" : "fast"}${quietTails ? ", quiet tails" : ""}): '
          'elapsed=${wallWatch.elapsed}, rtf=${rtf.toStringAsFixed(3)}, '
          'firstPending=${run.firstPendingWall}, '
          'firstConfirmed=${run.firstConfirmedWall}, '
          'p95PushMs=${p95PushMs.toStringAsFixed(1)}, '
          'maxPushMs=${maxPushMs.toStringAsFixed(1)}, '
          'baselineRssMiB=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)}, '
          'peakRssMiB=${(run.maxRssBytes / (1024 * 1024)).toStringAsFixed(1)}, '
          'deltaRssMiB=${deltaRssMiB.toStringAsFixed(1)}, '
          'endRssMiB=${(endRss / (1024 * 1024)).toStringAsFixed(1)}',
        );

        expect(run.duration, const Duration(seconds: 300));
        expect(run.partials, isNotEmpty);
        var prevConfirmed = '';
        for (final p in run.partials) {
          expect(p.confirmedText!.startsWith(prevConfirmed), isTrue);
          prevConfirmed = p.confirmedText!;
        }
        final norm300s = _normalizeWords(run.text).join(' ');
        if (quietTails) {
          final reference = _normalizeWords(
            _loadSiblingTranscript(_defaultSecondWav)!,
          ).join(' ');
          final normalized = norm300s.replaceAll(
            'mr quilter',
            'mister quilter',
          );
          final repetitions = List.filled(22, reference).join(' ');
          expect(normalized, repetitions);
        } else {
          expect(
            _countOccurrences(norm300s, 'americans'),
            greaterThanOrEqualTo(25),
          );
        }
      } finally {
        await engine.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Float32List _speechAndNoiseBlock() {
  const speechInterval = 7 * 16000;
  final speech = _decodeWavPcm16Mono16k(_defaultSecondWav);
  final noise = _quietNoise(5 * 16000, 257, scale: 4.0);
  return Float32List(speechInterval * 2)
    ..setRange(0, speech.length, speech)
    ..setRange(speechInterval, speechInterval + noise.length, noise);
}

double _rms(Float32List pcm) {
  var sumSquares = 0.0;
  for (final sample in pcm) {
    sumSquares += sample * sample;
  }
  return sqrt(sumSquares / pcm.length);
}

Float32List _quietNoise(int sampleCount, int seed, {double scale = 1.0}) {
  final noise = Float32List(sampleCount);
  var state = seed;
  var filtered = 0.0;
  for (var i = 0; i < noise.length; i++) {
    state = (1664525 * state + 1013904223) & 0xffffffff;
    final white = 2.0 * (state / 4294967296.0) - 1.0;
    filtered = 0.96 * filtered + 0.04 * white;
    noise[i] = 0.015 * scale * filtered;
  }
  return noise;
}

Float32List _addUniformNoise(
  Float32List input, {
  required double targetRms,
  int seed = 7,
}) {
  final rng = Random(seed);
  final amplitude = targetRms * sqrt(3.0);
  final out = Float32List(input.length);
  for (var i = 0; i < input.length; i++) {
    final noise = (rng.nextDouble() * 2.0 - 1.0) * amplitude;
    final sample = input[i] + noise;
    out[i] = sample < -1.0 ? -1.0 : (sample > 1.0 ? 1.0 : sample);
  }
  return out;
}

String? _loadSiblingTranscript(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  final txtPath = dot > 0
      ? '${audioPath.substring(0, dot)}.txt'
      : '$audioPath.txt';
  final file = File(txtPath);
  if (!file.existsSync()) {
    return null;
  }
  final text = file.readAsStringSync().trim();
  return text.isEmpty ? null : text;
}
