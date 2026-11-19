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
    SpeechToTextCompletion completion,
    List<SpeechToTextPartialEvent> partials,
    List<SpeechToTextFinalEvent> finals,
    Duration? firstPendingWall,
    Duration? firstConfirmedWall,
    List<int> pushMicros,
    int finishMicros,
    int maxRssBytes,
  })
>
_collectStream(
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

  final drained = Completer<void>();
  final sub = session.events.listen(
    (event) {
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
    },
    onError: (Object _) {},
    onDone: drained.complete,
  );

  final pushMicros = <int>[];
  final pushWatch = Stopwatch();
  var pos = 0;
  var chunkIndex = 0;
  var audioSeconds = 0.0;
  try {
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
    final finishWatch = Stopwatch()..start();
    await session.finish();
    finishWatch.stop();
    final completion = await session.done;
    await drained.future;
    return (
      completion: completion,
      partials: partials,
      finals: finals,
      firstPendingWall: firstPendingWall,
      firstConfirmedWall: firstConfirmedWall,
      pushMicros: pushMicros,
      finishMicros: finishWatch.elapsedMicroseconds,
      maxRssBytes: maxRssBytes,
    );
  } finally {
    await sub.cancel();
    await session.cancel();
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
    int finishMicros,
    int maxRssBytes,
  })
>
_streamChunks(
  SpeechToTextEngine engine,
  Float32List pcm,
  List<int> chunkSizes, {
  bool paced = false,
}) async {
  final run = await _collectStream(engine, pcm, chunkSizes, paced: paced);
  expect(run.completion.state, SpeechToTextCompletionState.completed);
  expect(run.finals, hasLength(1));
  expect(run.finals.single.result, run.completion.result);
  final result = run.finals.single.result;
  return (
    text: result.text,
    duration: result.audioDuration!,
    partials: run.partials,
    firstPendingWall: run.firstPendingWall,
    firstConfirmedWall: run.firstConfirmedWall,
    pushMicros: run.pushMicros,
    finishMicros: run.finishMicros,
    maxRssBytes: run.maxRssBytes,
  );
}

Future<void> _expectEmptyStream(
  SpeechToTextEngine engine,
  Float32List pcm,
  int checkpoints,
) async {
  final run = await _collectStream(engine, pcm, [4000]);
  expect(
    {
      'partials': run.partials
          .map((event) => (event.text, event.confirmedText, event.pendingText))
          .toList(),
      'finals': run.finals.map((event) => event.result.text).toList(),
      'state': run.completion.state,
      'result': run.completion.result?.text,
      'error': run.completion.error,
    },
    {
      'partials': List.filled(checkpoints, ('', '', '')),
      'finals': isEmpty,
      'state': SpeechToTextCompletionState.failed,
      'result': isNull,
      'error': isA<LlamaSpeechException>().having(
        (error) => error.message,
        'message',
        'Speech recognition produced an empty transcript.',
      ),
    },
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
  final echoFixtureDir = _envFile('LLAMADART_STT_WINDOWED_ECHO_FIXTURES');

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

  Future<SpeechToTextEngine> loadWindowed(String model, String projector) {
    return SpeechToTextEngine.load(
      SpeechToTextModel(
        ModelSource.path(model),
        projector: ModelSource.path(projector),
        adapter: const Qwen3WindowedAsrAdapter(),
      ),
      params: params,
    );
  }

  test('Qwen3-ASR suppresses the DC offset 0.008 instruction echo', () async {
    if (modelPath == null || projectorPath == null) {
      markTestSkipped('Set the Qwen model and projector paths.');
      return;
    }

    final engine = await loadWindowed(modelPath, projectorPath);
    try {
      final pcm = _quietNoise(96000, 257);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] += 0.008;
      }
      _addThump(pcm, 45600, 3200, 0.25, seed: 412, decay: 2);
      expect(
        sha256.convert(Uint8List.sublistView(pcm)).toString(),
        'db6bd09f3b116398c0ff0ecdf935025ccf18edd657928d5769a9bbad39aa1e29',
      );

      await _expectEmptyStream(engine, pcm, 3);
    } finally {
      await engine.dispose();
    }
  });

  test('Qwen3-ASR suppresses the original 100 ms thump partial', () async {
    if (modelPath == null || projectorPath == null) {
      markTestSkipped('Set the Qwen model and projector paths.');
      return;
    }
    final engine = await loadWindowed(modelPath, projectorPath);
    try {
      final pcm = _quietNoise(96000, 257);
      _addThump(pcm, 50000, 1600, 0.3, seed: 99, decay: 3);
      expect(
        sha256.convert(Uint8List.sublistView(pcm)).toString(),
        'c93d65754a8bb5649324fcb6433c5b560aa91f059970f4ecba7a3bca9b8f2ba4',
      );
      await _expectEmptyStream(engine, pcm, 3);
    } finally {
      await engine.dispose();
    }
  });

  for (final brownTail in [false, true]) {
    test(
      'Qwen3-ASR preserves speech before the ${brownTail ? 'brown noise' : '300 ms thump'} tail',
      () async {
        if (modelPath == null ||
            projectorPath == null ||
            (brownTail && echoFixtureDir == null)) {
          markTestSkipped(
            'Set the Qwen model, projector and echo fixture paths.',
          );
          return;
        }
        final engine = await loadWindowed(modelPath, projectorPath);
        try {
          final speech = _decodeWavPcm16Mono16k(_defaultSecondWav);
          final Float32List tail;
          if (brownTail) {
            final brown = _hashedWav(
              echoFixtureDir!,
              'i2088-brown.wav',
              'df71c04f2f103a896b5120e6bec5e8ef6868db9a6af58de5a3cd3daea72aee01',
            );
            tail = _repeatPcm(brown, 5);
            _scaleRms(tail, 0.008);
          } else {
            tail = _quietNoise(80000, 327);
            _addThump(tail, 40000, 4800, 0.15, seed: 4242, decay: 3);
          }
          final pcm = Float32List(192000)
            ..setRange(0, speech.length, speech)
            ..setRange(112000, 192000, tail);
          final run = await _streamChunks(engine, pcm, [4000]);
          final expected =
              '${brownTail ? 'Mr.' : 'Mister.'} Quilter is the '
              'apostle of the middle classes, and we are glad to welcome his gospel.';
          expect(run.text, expected);
          expect(run.partials.map((event) => event.text), [
            'Mr. Quilter is the apostle.',
            'Mr. Quilter is the apostle of the middle classes, and we are glad.',
            'Mr. Quilter is the apostle of the middle classes, and we are glad to welcome his gospel.',
            expected,
            expected,
            expected,
          ]);
          expect(
            run.partials
                .skip(3)
                .map((event) => (event.confirmedText, event.pendingText)),
            everyElement((expected, '')),
          );
        } finally {
          await engine.dispose();
        }
      },
    );
  }

  test('Qwen3-ASR preserves the original thump plus gospel behavior', () async {
    if (modelPath == null || projectorPath == null) {
      markTestSkipped('Set the Qwen model and projector paths.');
      return;
    }
    final engine = await loadWindowed(modelPath, projectorPath);
    try {
      final speech = _decodeWavPcm16Mono16k(_defaultSecondWav);
      final word = Float32List.sublistView(speech, 77500, 86700);
      final activeThreshold =
          word.map((sample) => sample.abs()).reduce(max) * 0.02;
      final active = Float32List.fromList(
        word.where((sample) => sample.abs() > activeThreshold).toList(),
      );
      final gain = 0.0004 / _rms(active);
      final isolated = Float32List(64000);
      final withThump = _quietNoise(64000, 327);
      for (var i = 0; i < word.length; i++) {
        isolated[51760 + i] = word[i] * gain;
        withThump[51760 + i] += isolated[51760 + i];
      }
      _addThump(withThump, 50000, 1760, 0.08, seed: 412, decay: 2);
      expect(
        sha256.convert(Uint8List.sublistView(withThump)).toString(),
        '56a88a49db04cea2abe1306ed211d06def7319006f95362459d6db91e05f2610',
      );
      await _expectEmptyStream(engine, withThump, 2);
      final control = await _streamChunks(engine, isolated, [4000]);
      expect(control.text, 'Gospel.');
      expect(control.partials.map((event) => event.text), ['', 'Gospel.']);
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

      final engine = await loadWindowed(modelPath, projectorPath);
      try {
        final speech = _decodeWavPcm16Mono16k(spokenPath);
        _scaleRms(speech, 0.00125);
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

  test('Qwen3-ASR retains eight spoken instruction controls', () async {
    if (modelPath == null || projectorPath == null || echoFixtureDir == null) {
      markTestSkipped('Set the Qwen model, projector and echo fixture paths.');
      return;
    }
    final engine = await loadWindowed(modelPath, projectorPath);
    try {
      for (final (name, hash, expected) in [
        (
          'en',
          '8cdd984e63bea0abab656330e182839b74c1b01f80d23bb10d792d70b77c06e2',
          'Transcribe this audio accurately.',
        ),
        (
          'pt-short',
          'b5071e36e8f8969dbb270abc67ee25046222bba4aa8339cf85b0bdd2f887088b',
          'transcreva este áudio',
        ),
        (
          'pt-alt',
          '2f6728cd6458ea76f89feff4dbc08a7b7b3abe4f581243331e7f27a4483af4e7',
          'transcreva este áudio acertadamente',
        ),
        (
          'pt-long',
          'fb27050e1388d58f336060f20dcd0704e1745c6d82713e7c29bc1e559cc12530',
          'Por favor, transcreva este áudio com precisão para o relatório.',
        ),
      ]) {
        final samples = _hashedWav(echoFixtureDir, 'i2088-$name.wav', hash);
        for (final level in [0.00125, 0.04]) {
          final pcm = Float32List.fromList(samples);
          _scaleRms(pcm, level);
          final run = await _streamChunks(engine, pcm, [4000]);
          final partials = switch ((name, level)) {
            ('pt-alt', 0.00125) => ['transcreva este áudio acerca da'],
            ('pt-alt', _) => [expected],
            ('pt-long', _) => [
              startsWith('Por favor, transcreva '),
              allOf(
                startsWith('Por favor, transcreva '),
                endsWith('com precisão para o relatório.'),
              ),
            ],
            _ => <String>[],
          };
          expect(run.text, expected, reason: '$name RMS $level');
          expect(
            run.partials.map((event) => event.text),
            partials,
            reason: '$name RMS $level',
          );
        }
      }
    } finally {
      await engine.dispose();
    }
  });

  const quilter =
      'Mr. Quilter is the apostle of the middle classes, and we are glad to welcome his gospel.';
  const samantha = '$quilter\nTranscribe this audio accurately.';
  const jfk =
      'And so, my fellow Americans, ask not what your country can do for you.';
  for (final (name, hash, expected, partials) in [
    (
      'samantha-afterlibri',
      '9bf017575f81c8b412f08b9b25f84214de7f7f58e109363538293f5ce87032e8',
      samantha,
      [
        'Mr. Quilter is the apostle.',
        'Mr. Quilter is the apostle of the middle classes, and we are glad.',
        quilter,
        quilter,
        samantha,
      ],
    ),
    (
      'eddy-0.04',
      'a188fe010cacefb9198d40e6fcfb4526a71dfebdcf09a2fb12b6ca883b22f356',
      'Transcreva este áudio com precisão.',
      ['Transcreva este áudio com'],
    ),
    (
      'joana-0.00125',
      '64ba1331ab712c2f10b743e1dd955f26dbd8b83135f8b6b5687b74b5a24f4be2',
      'Transcreva este áudio acertadamente.',
      ['transcreva este áudio assim'],
    ),
    (
      'jfk-floportu',
      '1820cfb3a22fa52b3f3d520bd895ae53b4a49bf4295e4bdd5aadc2455716ee93',
      '$jfk\nTranscreva este audio com precisão.',
      [
        'And so, my fellow Americans.',
        'And so, my fellow Americans, ask.',
        'And so, my fellow Americans, ask not what your country.',
        jfk,
        '$jfk\nAsk what you can do for your.',
        '$jfk\nAsk what you can do for your country.',
        '$jfk\nAsk what you can do for your country.',
      ],
    ),
  ]) {
    test('Qwen3-ASR retains audited dictation ($name)', () async {
      if (modelPath == null ||
          projectorPath == null ||
          echoFixtureDir == null) {
        markTestSkipped(
          'Set the Qwen model, projector and echo fixture paths.',
        );
        return;
      }
      final pcm = _hashedFloatPcm(
        File.fromUri(
          Directory(echoFixtureDir).absolute.uri.resolve('i2088b-$name.f32le'),
        ),
        hash,
      );
      final engine = await loadWindowed(modelPath, projectorPath);
      try {
        final run = await _collectStream(engine, pcm, [4000]);
        expect(
          {
            'partials': run.partials.map((event) => event.text).toList(),
            'finals': run.finals.map((event) => event.result.text).toList(),
            'state': run.completion.state,
            'result': run.completion.result?.text,
            'error': run.completion.error,
          },
          {
            'partials': partials,
            'finals': [expected],
            'state': SpeechToTextCompletionState.completed,
            'result': expected,
            'error': isNull,
          },
        );
      } finally {
        await engine.dispose();
      }
    });
  }

  for (final (name, hash) in [
    (
      'faint tone',
      '3fbe9988176f28b2de77842cad937da9b26be358846cd43a85bc7a2bd9cbee5b',
    ),
    (
      'loud tone',
      '78ed154c0e3a8591528360d6b125a3e3b3f09da8d0b5b7f627bf7100a7543256',
    ),
    (
      'loud filtered noise',
      'b1caf4d67c67213d12b82527911567d21460411e0d6e7f38dde02dc00e0e0ed3',
    ),
  ]) {
    test('Qwen3-ASR rejects a noise burst ($name)', () async {
      if (modelPath == null || projectorPath == null) {
        markTestSkipped('Set the Qwen model and projector paths.');
        return;
      }
      final pcm = _quietNoise(96000, 257);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] += 0.008;
      }
      final faint = name == 'faint tone';
      final offset = faint ? 5000 : 4000;
      final samples = faint ? 6400 : 10400;
      final filtered = _quietNoise(samples, 257);
      for (var i = 0; i < samples; i++) {
        pcm[offset + i] = switch (name) {
          'faint tone' => 0.000005 * sin(2 * pi * 200 * i / 16000),
          'loud tone' => 0.06 * sin(2 * pi * 200 * i / 16000),
          _ => 32 * filtered[i],
        };
      }
      _addThump(pcm, 45600, 3200, 0.25, seed: 412, decay: 2);
      expect(sha256.convert(Uint8List.sublistView(pcm)).toString(), hash);
      final engine = await loadWindowed(modelPath, projectorPath);
      try {
        await _expectEmptyStream(engine, pcm, 3);
      } finally {
        await engine.dispose();
      }
    });
  }

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
          final pcm = _hashedFloatPcm(
            File.fromUri(manifest.absolute.uri.resolve(name)),
            entry['sha256']! as String,
          );
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
          'finishMs=${(run.finishMicros / 1000).toStringAsFixed(1)}, '
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

void _scaleRms(Float32List pcm, double target) {
  final gain = target / _rms(pcm);
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] *= gain;
  }
}

Float32List _hashedWav(String directory, String name, String hash) {
  final file = File.fromUri(Directory(directory).absolute.uri.resolve(name));
  expect(sha256.convert(file.readAsBytesSync()).toString(), hash, reason: name);
  return _decodeWavPcm16Mono16k(file.path);
}

Float32List _hashedFloatPcm(File file, String hash) {
  final samples = file.readAsBytesSync();
  expect(
    sha256.convert(samples).toString(),
    hash,
    reason: file.uri.pathSegments.last,
  );
  final bytes = ByteData.sublistView(samples);
  final pcm = Float32List(samples.length ~/ 4);
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] = bytes.getFloat32(i * 4, Endian.little);
  }
  return pcm;
}

void _addThump(
  Float32List pcm,
  int offset,
  int samples,
  double peak, {
  required int seed,
  required double decay,
}) {
  var state = seed;
  for (var i = 0; i < samples; i++) {
    state = (1664525 * state + 1013904223) & 0xffffffff;
    final white = 2 * (state / 4294967296.0) - 1;
    pcm[offset + i] += peak * white * exp(-decay * i / samples);
  }
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
