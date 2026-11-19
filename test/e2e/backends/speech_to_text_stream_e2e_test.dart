@TestOn('vm')
@Tags(['local-only'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:test/test.dart';

import '../../support/speech_stream_qualification.dart';

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

String? _requireStreamInput(String? path, String envKey) =>
    requireSpeechStreamInput(
      path,
      envKey,
      qualify: _isQualifyMode(),
      onSkip: markTestSkipped,
    );

String _requestedBackend() =>
    (Platform.environment['LLAMADART_STT_STREAM_BACKEND'] ?? 'auto')
        .trim()
        .toLowerCase();

bool _isQualifyMode() =>
    Platform.environment['LLAMADART_STT_STREAM_QUALIFY'] == '1';

bool _isCollectBaselineMode() =>
    Platform.environment['LLAMADART_STT_STREAM_COLLECT_BASELINE'] == '1';

bool _shouldRunPaced() =>
    _isQualifyMode() || Platform.environment['LLAMADART_STT_LIVE_PACED'] == '1';

ModelParams _buildModelParams({
  required int contextSize,
  required String requestedBackend,
}) {
  switch (requestedBackend) {
    case 'cpu':
      return ModelParams(
        contextSize: contextSize,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        device: ComputeDevice.cpu,
        preferredBackend: GpuBackend.cpu,
        gpuLayers: 0,
      );
    case 'cuda':
      return ModelParams(
        contextSize: contextSize,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        device: ComputeDevice.gpu,
        preferredBackend: GpuBackend.cuda,
        gpuLayers: 99,
      );
    case 'metal':
      return ModelParams(
        contextSize: contextSize,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        device: ComputeDevice.gpu,
        preferredBackend: GpuBackend.metal,
        gpuLayers: 99,
      );
    default:
      return ModelParams(
        contextSize: contextSize,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      );
  }
}

Future<
  ({
    String backendName,
    List<String> availableBackends,
    int resolvedGpuLayers,
    int? vramTotalBytes,
    int? vramFreeBytes,
  })
>
_captureDiagnostics(NativeLlamaBackend backend, String requestedBackend) async {
  final backendName = await backend.getBackendName();
  final rawAvailable = await backend.getAvailableBackends();
  final availableBackends = rawAvailable
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final resolvedGpuLayers = await backend.getResolvedGpuLayers() ?? 0;
  int? vramTotalBytes;
  int? vramFreeBytes;
  try {
    final vram = await backend.getVramInfo();
    vramTotalBytes = vram.total;
    vramFreeBytes = vram.free;
  } catch (_) {
    // CPU-only builds may not report VRAM.
  }

  if (requestedBackend == 'cpu') {
    expect(
      resolvedGpuLayers,
      0,
      reason: 'Strict CPU placement must offload 0 GPU layers.',
    );
  } else if (requestedBackend == 'cuda') {
    expect(
      resolvedGpuLayers,
      greaterThan(0),
      reason: 'Strict CUDA placement requires nonzero GPU layer offload.',
    );
    expect(
      backendName.toLowerCase(),
      contains('cuda'),
      reason: 'Strict CUDA placement requires CUDA backend, got $backendName.',
    );
  }

  return (
    backendName: backendName,
    availableBackends: availableBackends,
    resolvedGpuLayers: resolvedGpuLayers,
    vramTotalBytes: vramTotalBytes,
    vramFreeBytes: vramFreeBytes,
  );
}

void _writeReceiptIfConfigured(SpeechStreamLegReceipt receipt) {
  final dirPath = Platform.environment['LLAMADART_STT_STREAM_RECEIPT_DIR']
      ?.trim();
  if (dirPath == null || dirPath.isEmpty) {
    return;
  }
  final dir = Directory(dirPath)..createSync(recursive: true);
  final file = File('${dir.path}/${receipt.legId}.json');
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(receipt.toJson()),
  );
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

Future<void> _exercisePausedConsumerAndCancellations(
  SpeechToTextEngine engine,
  Float32List jfk,
  String expectedFixedText,
) async {
  // Paused consumer during streaming, then resumed before finish.
  final pausedSession = await engine.startStream();
  final pausedFinals = <SpeechToTextFinalEvent>[];
  final pausedSub = pausedSession.events.listen((event) {
    if (event is SpeechToTextFinalEvent) {
      pausedFinals.add(event);
    }
  });
  pausedSub.pause();
  try {
    var offset = 0;
    while (offset < jfk.length) {
      final end = min(offset + 5120, jfk.length);
      await pausedSession.addPcm(Float32List.sublistView(jfk, offset, end));
      offset = end;
    }
    pausedSub.resume();
    await pausedSession.finish();
    final completion = await pausedSession.done;
    expect(completion.state, SpeechToTextCompletionState.completed);
    expect(completion.result!.text, expectedFixedText);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pausedFinals, hasLength(1));
  } finally {
    await pausedSession.cancel();
    await pausedSub.cancel();
  }

  // Cancel before first step.
  final sBeforePush = await engine.startStream();
  await sBeforePush.cancel();
  expect((await sBeforePush.done).state, SpeechToTextCompletionState.cancelled);
  expect(await _streamChunks(engine, jfk, const [5120]), expectedFixedText);

  // Cancel during an active push; verify blocked producer settles and no late
  // final is emitted.
  final sMidPush = await engine.startStream();
  final midFinals = <SpeechToTextFinalEvent>[];
  final midSub = sMidPush.events.listen((event) {
    if (event is SpeechToTextFinalEvent) {
      midFinals.add(event);
    }
  });
  final blockedPush = sMidPush.addPcm(jfk).then<void>((_) {}, onError: (_) {});
  await sMidPush.cancel();
  await blockedPush;
  expect((await sMidPush.done).state, SpeechToTextCompletionState.cancelled);
  await midSub.cancel();
  expect(midFinals, isEmpty);
  expect(await _streamChunks(engine, jfk, const [5120]), expectedFixedText);

  // Cancel after first partial text; verify no late final.
  final sAfterFirstText = await engine.startStream();
  final firstTextSeen = Completer<void>();
  final afterFinals = <SpeechToTextFinalEvent>[];
  final afterFirstSub = sAfterFirstText.events.listen((event) {
    if (event is SpeechToTextPartialEvent &&
        event.text.trim().isNotEmpty &&
        !firstTextSeen.isCompleted) {
      firstTextSeen.complete();
    } else if (event is SpeechToTextFinalEvent) {
      afterFinals.add(event);
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
  expect(afterFinals, isEmpty);

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
}

Future<void> _run300sTimedLeg({
  required String legId,
  required SpeechStreamFamily family,
  required SpeechStreamPacingMode mode,
  required String modelPath,
  required String mmprojPath,
  required String jfkPath,
}) async {
  final requestedBackend = _requestedBackend();
  final params = _buildModelParams(
    contextSize: 4096,
    requestedBackend: requestedBackend,
  );
  final backend = NativeLlamaBackend();
  final engine = await SpeechToTextEngine.load(
    SpeechToTextModel(
      ModelSource.path(modelPath),
      projector: ModelSource.path(mmprojPath),
      adapter: const LlamaCppLiveAsrAdapter(),
    ),
    params: params,
    backend: backend,
  );

  final jfk = _decodeWavPcm16Mono16k(jfkPath);
  var engineDisposed = false;

  try {
    final diag = await _captureDiagnostics(backend, requestedBackend);
    final outcome = await runTimedSpeechStreamLeg(
      legId: legId,
      family: family,
      mode: mode,
      hostOs: currentHostOs(),
      arch: currentHostArch(),
      requestedBackend: requestedBackend,
      backendUsed: diag.backendName,
      exposedDevices: diag.availableBackends,
      resolvedGpuLayers: diag.resolvedGpuLayers,
      unitPcm: jfk,
      vramTotalBytes: diag.vramTotalBytes,
      vramFreeBytes: diag.vramFreeBytes,
      qualify: _isQualifyMode(),
      collectBaseline: _isCollectBaselineMode(),
      receiptDir: Platform.environment['LLAMADART_STT_STREAM_RECEIPT_DIR'],
      runWarmup: () async {
        final warmupText = await _streamChunks(engine, jfk, const [5120]);
        expect(_normalizeWords(warmupText), contains('fellow americans'));
      },
      runMeasuredSession: (driveProducer) async {
        final sw = Stopwatch()..start();
        Duration? firstPartialWall;
        Duration? firstPartialAudio;
        final partials = <SpeechToTextPartialEvent>[];
        final finals = <SpeechToTextFinalEvent>[];
        late final Duration flushDuration;
        late final SpeechToTextCompletion completion;

        final session = await engine.startStream();
        final sub = session.events.listen((event) {
          switch (event) {
            case SpeechToTextPartialEvent():
              partials.add(event);
              if (event.text.trim().isNotEmpty && firstPartialWall == null) {
                firstPartialWall = sw.elapsed;
                firstPartialAudio = event.acceptedAudioDuration;
              }
            case SpeechToTextFinalEvent():
              finals.add(event);
          }
        });

        try {
          await driveProducer(session.addPcm, () {});
          final flushSw = Stopwatch()..start();
          await session.finish();
          completion = await session.done;
          flushSw.stop();
          sw.stop();
          flushDuration = flushSw.elapsed;
        } finally {
          await session.cancel();
          await sub.cancel();
        }

        expect(completion.state, SpeechToTextCompletionState.completed);
        final result = completion.result!;
        expect(finals, hasLength(1));
        expect(partials, isNotEmpty);
        expect(firstPartialWall, isNotNull);
        expect(
          result.audioDuration,
          const Duration(seconds: speechStreamTargetSeconds300s),
        );
        _assertMonotonicPartials(partials, result.text);

        final norm = _normalizeWords(result.text);
        expect(norm, contains('fellow americans'));
        expect(norm, contains('country'));
        expect(
          _countOccurrences(norm, 'fellow americans'),
          greaterThanOrEqualTo(25),
        );

        return SpeechStreamTimedSessionResult(
          flushDuration: flushDuration,
          audioDurationMs: result.audioDuration!.inMilliseconds,
          firstPartialWallMs: firstPartialWall?.inMilliseconds,
          firstPartialAudioMs: firstPartialAudio?.inMilliseconds,
        );
      },
      disposeEngine: () async {
        await engine.dispose();
        engineDisposed = true;
      },
    );

    const mib = 1024 * 1024;
    final rssSummary = outcome.rssSummary;
    final producerStats = outcome.producerStats;
    final ceilingBytes = outcome.receipt.ceilingBytes;
    stderr.writeln(
      '[$legId] profile=${outcome.profileKey} backend=${diag.backendName} '
      'gpuLayers=${diag.resolvedGpuLayers} wallMs=${outcome.receipt.wallMs} '
      'flushMs=${outcome.receipt.flushMs} '
      'rtf=${outcome.receipt.rtf!.toStringAsFixed(3)} '
      'firstPartialWallMs=${outcome.receipt.firstPartialWallMs} '
      'firstPartialAudioMs=${outcome.receipt.firstPartialAudioMs} '
      'p95PushMs=${producerStats.p95PushMs.toStringAsFixed(2)} '
      'maxPushMs=${producerStats.maxPushMs.toStringAsFixed(2)} '
      'maxLagMs=${producerStats.maxLagMs} '
      'baselineMiB=${(rssSummary.baselineRssBytes / mib).toStringAsFixed(1)} '
      'peakMiB=${(rssSummary.peakRssBytes / mib).toStringAsFixed(1)} '
      'deltaMiB=${(rssSummary.peakDeltaBytes / mib).toStringAsFixed(1)} '
      'endMiB=${(rssSummary.endRssBytes / mib).toStringAsFixed(1)} '
      'postDisposeMiB=${(rssSummary.postDisposeRssBytes / mib).toStringAsFixed(1)} '
      'samples=${rssSummary.sampleCount} '
      'ceilingMiB=${ceilingBytes != null ? (ceilingBytes / mib).toStringAsFixed(1) : 'uncalibrated'} '
      'memoryStatus=${outcome.receipt.memoryStatus}',
    );
  } finally {
    if (!engineDisposed) {
      await engine.dispose();
    }
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
  final runPaced = _shouldRunPaced();
  final arch = currentHostArch();
  final backend = _requestedBackend();
  final voxtralShortTimeout = Timeout(
    voxtralSpeechStreamTimeout(
      const Duration(minutes: 10),
      arch: arch,
      backend: backend,
    ),
  );
  final voxtralTimedTimeout = Timeout(
    voxtralSpeechStreamTimeout(
      const Duration(minutes: 15),
      arch: arch,
      backend: backend,
    ),
  );

  test(
    'Voxtral Realtime short parity, irregular chunkings, truncation, cancel/reuse',
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

      final requestedBackend = _requestedBackend();
      final params4096 = _buildModelParams(
        contextSize: 4096,
        requestedBackend: requestedBackend,
      );
      final jfk = _decodeWavPcm16Mono16k(resolvedJfk);
      final backend = NativeLlamaBackend();
      final engine = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: params4096,
        backend: backend,
      );

      try {
        final diag = await _captureDiagnostics(backend, requestedBackend);
        final caps = await engine.capabilities;
        expect(caps.isSupported, isTrue);
        expect(caps.supportsStreamingInput, isTrue);
        expect(caps.supportsPartialResults, isTrue);

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

        // Direct worker parity check with the same placement settings.
        final directBackend = NativeLlamaBackend();
        try {
          final m = await directBackend.modelLoad(resolvedModel, params4096);
          final c = await directBackend.contextCreate(m, params4096);
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

        await _exercisePausedConsumerAndCancellations(engine, jfk, fixedText);

        _writeReceiptIfConfigured(
          SpeechStreamLegReceipt(
            legId: 'voxtral_short',
            family: 'voxtral',
            mode: 'short',
            hostOs: currentHostOs(),
            arch: currentHostArch(),
            backendRequested: requestedBackend,
            backendUsed: diag.backendName,
            exposedDevices: diag.availableBackends,
            usedDevices: [diag.backendName],
            gpuLayersOffloaded: diag.resolvedGpuLayers,
            threads: 2,
            threadsBatch: 2,
            contextSize: 4096,
            pushedSamples: jfk.length,
            audioDurationMs: (jfk.length * 1000) ~/ 16000,
            wallMs: 0,
            flushMs: 0,
            baselineRssBytes: 0,
            peakRssBytes: 0,
            ceilingBytes: null,
            outcome: 'pass',
          ),
        );
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
        params: _buildModelParams(
          contextSize: 512,
          requestedBackend: requestedBackend,
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
    timeout: voxtralShortTimeout,
  );

  test(
    'Voxtral Realtime 300s fast-producer memory and throughput',
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
      await _run300sTimedLeg(
        legId: 'voxtral_fast',
        family: SpeechStreamFamily.voxtral,
        mode: SpeechStreamPacingMode.fast,
        modelPath: resolvedModel,
        mmprojPath: resolvedMmproj,
        jfkPath: resolvedJfk,
      );
    },
    skip: !(hasJfk && hasVoxtral)
        ? 'Set LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH and '
              'LLAMADART_STT_STREAM_VOXTRAL_MMPROJ_PATH (and jfk.wav).'
        : false,
    timeout: voxtralTimedTimeout,
  );

  test(
    'Voxtral Realtime 300s live-paced memory and throughput',
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
      await _run300sTimedLeg(
        legId: 'voxtral_paced',
        family: SpeechStreamFamily.voxtral,
        mode: SpeechStreamPacingMode.paced,
        modelPath: resolvedModel,
        mmprojPath: resolvedMmproj,
        jfkPath: resolvedJfk,
      );
    },
    skip: !(hasJfk && hasVoxtral && runPaced)
        ? 'Set LLAMADART_STT_LIVE_PACED=1 (or LLAMADART_STT_STREAM_QUALIFY=1) '
              'and Voxtral model/mmproj paths.'
        : false,
    timeout: voxtralTimedTimeout,
  );

  test(
    'LFM3-Audio 2048 floor restart, chunking parity, and cancel/reuse',
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

      final requestedBackend = _requestedBackend();
      final params2048 = _buildModelParams(
        contextSize: 2048,
        requestedBackend: requestedBackend,
      );
      final jfk = _decodeWavPcm16Mono16k(resolvedJfk);
      final backend = NativeLlamaBackend();
      final engine2048 = await SpeechToTextEngine.load(
        SpeechToTextModel(
          ModelSource.path(resolvedModel),
          projector: ModelSource.path(resolvedMmproj),
          adapter: const LlamaCppLiveAsrAdapter(),
        ),
        params: params2048,
        backend: backend,
      );

      try {
        final diag = await _captureDiagnostics(backend, requestedBackend);
        final fixedText = await _streamChunks(engine2048, jfk, const [5120]);
        expect(_normalizeWords(fixedText), contains('fellow americans'));

        final completeResult = await engine2048.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(jfk)),
        );
        expect(completeResult.text, fixedText);

        for (var seed = 1; seed <= 5; seed++) {
          final rng = Random(seed * 131);
          final sizes = List<int>.generate(16, (_) => 400 + rng.nextInt(4800));
          final irregularText = await _streamChunks(engine2048, jfk, sizes);
          expect(irregularText, fixedText);
        }

        // Direct worker parity check at 2048 floor.
        final directBackend = NativeLlamaBackend();
        try {
          final m = await directBackend.modelLoad(resolvedModel, params2048);
          final c = await directBackend.contextCreate(m, params2048);
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

        // 44s crossing a restart at 2048 floor.
        final clip44s = _repeatPcm(jfk, 44);
        final res44 = await engine2048.transcribeOnce(
          SpeechToTextRequest(audio: SpeechAudioPcmInput(clip44s)),
        );
        expect(res44.text.length, greaterThan(fixedText.length * 2));

        await _exercisePausedConsumerAndCancellations(
          engine2048,
          jfk,
          fixedText,
        );

        _writeReceiptIfConfigured(
          SpeechStreamLegReceipt(
            legId: 'lfm3_short',
            family: 'lfm3',
            mode: 'short',
            hostOs: currentHostOs(),
            arch: currentHostArch(),
            backendRequested: requestedBackend,
            backendUsed: diag.backendName,
            exposedDevices: diag.availableBackends,
            usedDevices: [diag.backendName],
            gpuLayersOffloaded: diag.resolvedGpuLayers,
            threads: 2,
            threadsBatch: 2,
            contextSize: 2048,
            pushedSamples: jfk.length,
            audioDurationMs: (jfk.length * 1000) ~/ 16000,
            wallMs: 0,
            flushMs: 0,
            baselineRssBytes: 0,
            peakRssBytes: 0,
            ceilingBytes: null,
            outcome: 'pass',
          ),
        );
      } finally {
        await engine2048.dispose();
      }
    },
    skip: !(hasJfk && hasLfm3)
        ? 'Set LLAMADART_STT_STREAM_LFM3_MODEL_PATH and '
              'LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH (and jfk.wav).'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'LFM3-Audio 300s fast-producer memory and throughput',
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
      await _run300sTimedLeg(
        legId: 'lfm3_fast',
        family: SpeechStreamFamily.lfm3,
        mode: SpeechStreamPacingMode.fast,
        modelPath: resolvedModel,
        mmprojPath: resolvedMmproj,
        jfkPath: resolvedJfk,
      );
    },
    skip: !(hasJfk && hasLfm3)
        ? 'Set LLAMADART_STT_STREAM_LFM3_MODEL_PATH and '
              'LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH (and jfk.wav).'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'LFM3-Audio 300s live-paced memory and throughput',
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
      await _run300sTimedLeg(
        legId: 'lfm3_paced',
        family: SpeechStreamFamily.lfm3,
        mode: SpeechStreamPacingMode.paced,
        modelPath: resolvedModel,
        mmprojPath: resolvedMmproj,
        jfkPath: resolvedJfk,
      );
    },
    skip: !(hasJfk && hasLfm3 && runPaced)
        ? 'Set LLAMADART_STT_LIVE_PACED=1 (or LLAMADART_STT_STREAM_QUALIFY=1) '
              'and LFM3 model/mmproj paths.'
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

      final requestedBackend = _requestedBackend();
      await expectLater(
        () => SpeechToTextEngine.load(
          SpeechToTextModel(
            ModelSource.path(resolvedModel),
            projector: ModelSource.path(resolvedMmproj),
            adapter: const LlamaCppLiveAsrAdapter(),
          ),
          params: _buildModelParams(
            contextSize: 2048,
            requestedBackend: requestedBackend,
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );

      _writeReceiptIfConfigured(
        SpeechStreamLegReceipt(
          legId: 'qwen_refusal',
          family: 'qwen',
          mode: 'refusal',
          hostOs: currentHostOs(),
          arch: currentHostArch(),
          backendRequested: requestedBackend,
          backendUsed: requestedBackend,
          exposedDevices: const [],
          usedDevices: const [],
          gpuLayersOffloaded: 0,
          threads: 2,
          threadsBatch: 2,
          contextSize: 2048,
          pushedSamples: 0,
          audioDurationMs: 0,
          wallMs: 0,
          flushMs: 0,
          baselineRssBytes: 0,
          peakRssBytes: 0,
          ceilingBytes: null,
          outcome: 'pass',
        ),
      );
    },
    skip: !hasQwen
        ? 'Set LLAMADART_STT_STREAM_QWEN_MODEL_PATH and '
              'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH.'
        : false,
  );
}
