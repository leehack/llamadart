import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int speechStreamSampleRate = 16000;
const int speechStreamTargetSeconds300s = 300;
const int speechStreamTargetSamples300s =
    speechStreamSampleRate * speechStreamTargetSeconds300s;
const int speechStreamMaxSlabSamples = 5120;
const int _mibBytes = 1024 * 1024;
const int speechStreamMinCeilingBytes = 64 * _mibBytes;
const int speechStreamCeilingStepBytes = 32 * _mibBytes;

/// Locked SHA-256 digests for the qualification model/projector/WAV inputs.
const Map<String, String> speechStreamLockedDigests = <String, String>{
  'voxtralModel':
      'aa7a91fd78a896562642c61950887ec18c999425ab064bfc5ca9e64f8f5b29be',
  'voxtralMmproj':
      'f28ae3e40f2b610c1c39b5c936ae854b73d0fc487518c6f69b76c22dbcea9ee3',
  'lfm3Model':
      '9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2',
  'lfm3Mmproj':
      '2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365',
  'qwenModel':
      'bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971',
  'qwenMmproj':
      '41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d',
  'jfkAudio':
      '59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e',
};

enum SpeechStreamFamily { voxtral, lfm3 }

enum SpeechStreamPacingMode { fast, paced }

enum SpeechStreamMemoryStatus { pass, fail, unboundedQualificationPending }

final class SpeechStreamProfileKey {
  const SpeechStreamProfileKey({
    required this.family,
    required this.hostOs,
    required this.arch,
    required this.backend,
    required this.mode,
    this.contextSize = 4096,
    this.threads = 2,
  });

  final SpeechStreamFamily family;
  final String hostOs;
  final String arch;
  final String backend;
  final SpeechStreamPacingMode mode;
  final int contextSize;
  final int threads;

  @override
  bool operator ==(Object other) =>
      other is SpeechStreamProfileKey &&
      other.family == family &&
      other.hostOs == hostOs &&
      other.arch == arch &&
      other.backend == backend &&
      other.mode == mode &&
      other.contextSize == contextSize &&
      other.threads == threads;

  @override
  int get hashCode =>
      Object.hash(family, hostOs, arch, backend, mode, contextSize, threads);

  @override
  String toString() =>
      '${family.name}/$hostOs/$arch/$backend/${mode.name}'
      '(ctx=$contextSize,t=$threads)';
}

/// Checked-in calibrated memory ceilings in bytes, keyed per family, host,
/// arch, backend, and pacing mode.
///
/// Any profile absent from this map returns `null` from
/// [lookupMemoryCeilingBytes] and produces
/// [SpeechStreamMemoryStatus.unboundedQualificationPending].
final Map<SpeechStreamProfileKey, int> speechStreamMemoryCeilings =
    Map<SpeechStreamProfileKey, int>.unmodifiable(<SpeechStreamProfileKey, int>{
      SpeechStreamProfileKey(
        family: SpeechStreamFamily.voxtral,
        hostOs: 'macos',
        arch: 'arm64',
        backend: 'cpu',
        mode: SpeechStreamPacingMode.fast,
      ): 416 * _mibBytes,
      SpeechStreamProfileKey(
        family: SpeechStreamFamily.lfm3,
        hostOs: 'macos',
        arch: 'arm64',
        backend: 'cpu',
        mode: SpeechStreamPacingMode.fast,
      ): 64 * _mibBytes,
    });

String currentHostOs() => Platform.operatingSystem.toLowerCase();

String currentHostArch() {
  final abi = Abi.current();
  if (abi == Abi.macosArm64 ||
      abi == Abi.linuxArm64 ||
      abi == Abi.windowsArm64) {
    return 'arm64';
  }
  if (abi == Abi.macosX64 || abi == Abi.linuxX64 || abi == Abi.windowsX64) {
    return 'x64';
  }
  return abi.toString();
}

/// Computes `max(64 MiB, ceil_32MiB(1.25 * max(observedDeltasBytes)))`.
int computeCalibratedCeilingBytes(List<int> observedDeltasBytes) {
  if (observedDeltasBytes.isEmpty) {
    throw ArgumentError.value(
      observedDeltasBytes,
      'observedDeltasBytes',
      'At least one observed delta is required.',
    );
  }
  var maxDelta = 0;
  for (final delta in observedDeltasBytes) {
    if (delta > maxDelta) {
      maxDelta = delta;
    }
  }
  final scaled = (maxDelta * 5 + 3) ~/ 4; // ceil(1.25 * maxDelta)
  final roundedUp =
      ((scaled + speechStreamCeilingStepBytes - 1) ~/
          speechStreamCeilingStepBytes) *
      speechStreamCeilingStepBytes;
  return max(speechStreamMinCeilingBytes, roundedUp);
}

int? lookupMemoryCeilingBytes(
  SpeechStreamProfileKey key, {
  Map<SpeechStreamProfileKey, int>? table,
}) {
  return (table ?? speechStreamMemoryCeilings)[key];
}

final class SpeechStreamBudgetEvaluation {
  const SpeechStreamBudgetEvaluation({
    required this.status,
    required this.passed,
    required this.baselineRssBytes,
    required this.peakRssBytes,
    required this.peakDeltaBytes,
    required this.ceilingBytes,
  });

  final SpeechStreamMemoryStatus status;
  final bool passed;
  final int baselineRssBytes;
  final int peakRssBytes;
  final int peakDeltaBytes;
  final int? ceilingBytes;
}

SpeechStreamBudgetEvaluation evaluateMemoryBudget({
  required int baselineRssBytes,
  required int peakRssBytes,
  required int? ceilingBytes,
}) {
  final peakDeltaBytes = max(0, peakRssBytes - baselineRssBytes);
  if (ceilingBytes == null) {
    return SpeechStreamBudgetEvaluation(
      status: SpeechStreamMemoryStatus.unboundedQualificationPending,
      passed: false,
      baselineRssBytes: baselineRssBytes,
      peakRssBytes: peakRssBytes,
      peakDeltaBytes: peakDeltaBytes,
      ceilingBytes: null,
    );
  }
  final ok = peakDeltaBytes <= ceilingBytes;
  return SpeechStreamBudgetEvaluation(
    status: ok ? SpeechStreamMemoryStatus.pass : SpeechStreamMemoryStatus.fail,
    passed: ok,
    baselineRssBytes: baselineRssBytes,
    peakRssBytes: peakRssBytes,
    peakDeltaBytes: peakDeltaBytes,
    ceilingBytes: ceilingBytes,
  );
}

final class SpeechStreamRssSummary {
  const SpeechStreamRssSummary({
    required this.baselineRssBytes,
    required this.peakRssBytes,
    required this.peakDeltaBytes,
    required this.endRssBytes,
    required this.postDisposeRssBytes,
    required this.sampleCount,
    required this.timestampsMicros,
  });

  final int baselineRssBytes;
  final int peakRssBytes;
  final int peakDeltaBytes;
  final int endRssBytes;
  final int postDisposeRssBytes;
  final int sampleCount;
  final List<int> timestampsMicros;
}

class SpeechStreamRssMeter {
  SpeechStreamRssMeter({
    int Function()? readRssBytes,
    int Function()? nowMicros,
    this.sampleInterval = const Duration(milliseconds: 50),
  }) : _readRssBytes = readRssBytes ?? (() => ProcessInfo.currentRss),
       _nowMicros = nowMicros;

  final int Function() _readRssBytes;
  final int Function()? _nowMicros;
  final Duration sampleInterval;
  final Stopwatch _clock = Stopwatch();

  Timer? _timer;
  int? _baselineRssBytes;
  int _peakRssBytes = 0;
  int _lastRssBytes = 0;
  int _lastTimestampMicros = -1;
  final List<int> _timestampsMicros = <int>[];

  int get baselineRssBytes {
    final baseline = _baselineRssBytes;
    if (baseline == null) {
      throw StateError('Call startBaseline() before reading baselineRssBytes.');
    }
    return baseline;
  }

  int _nextTimestamp() {
    final raw = _nowMicros != null ? _nowMicros() : _clock.elapsedMicroseconds;
    final monotonic = raw > _lastTimestampMicros
        ? raw
        : _lastTimestampMicros + 1;
    _lastTimestampMicros = monotonic;
    return monotonic;
  }

  void startBaseline() {
    _clock
      ..reset()
      ..start();
    final rss = _readRssBytes();
    _baselineRssBytes = rss;
    _peakRssBytes = rss;
    _lastRssBytes = rss;
    _timestampsMicros
      ..clear()
      ..add(_nextTimestamp());
  }

  int sampleNow() {
    if (_baselineRssBytes == null) {
      throw StateError('Call startBaseline() before sampling.');
    }
    final rss = _readRssBytes();
    _lastRssBytes = rss;
    if (rss > _peakRssBytes) {
      _peakRssBytes = rss;
    }
    _timestampsMicros.add(_nextTimestamp());
    return rss;
  }

  void startPeriodicSampling() {
    stopPeriodicSampling();
    _timer = Timer.periodic(sampleInterval, (_) => sampleNow());
  }

  void stopPeriodicSampling() {
    _timer?.cancel();
    _timer = null;
  }

  SpeechStreamRssSummary finish({int? postDisposeRssBytes}) {
    stopPeriodicSampling();
    final endRss = sampleNow();
    final baseline = baselineRssBytes;
    final postDispose = postDisposeRssBytes ?? endRss;
    return SpeechStreamRssSummary(
      baselineRssBytes: baseline,
      peakRssBytes: _peakRssBytes,
      peakDeltaBytes: max(0, _peakRssBytes - baseline),
      endRssBytes: _lastRssBytes,
      postDisposeRssBytes: postDispose,
      sampleCount: _timestampsMicros.length,
      timestampsMicros: List<int>.unmodifiable(_timestampsMicros),
    );
  }
}

final class SpeechStreamProducerStats {
  const SpeechStreamProducerStats({
    required this.pushedSamples,
    required this.wallMs,
    required this.p95PushMs,
    required this.maxPushMs,
    required this.maxLagMs,
  });

  final int pushedSamples;
  final int wallMs;
  final double p95PushMs;
  final double maxPushMs;
  final int maxLagMs;
}

/// Streams [targetSamples] (default 4,800,000 = 300s at 16 kHz) cyclically from
/// [unit] using a single reusable slab of at most [slabSize] (<= 5120) samples.
Future<SpeechStreamProducerStats> streamCyclicPcm300s({
  required Float32List unit,
  required Future<void> Function(Float32List slab) onSlab,
  int targetSamples = speechStreamTargetSamples300s,
  int slabSize = speechStreamMaxSlabSamples,
  bool paced = false,
  void Function()? onAfterPush,
}) async {
  if (unit.isEmpty) {
    throw ArgumentError.value(unit, 'unit', 'Unit PCM clip cannot be empty.');
  }
  if (slabSize <= 0 || slabSize > speechStreamMaxSlabSamples) {
    throw ArgumentError.value(
      slabSize,
      'slabSize',
      'slabSize must be in 1..$speechStreamMaxSlabSamples.',
    );
  }

  final reusableSlab = Float32List(slabSize);
  final pushMicros = <int>[];
  final wallSw = Stopwatch()..start();
  final pushSw = Stopwatch();
  var pushedSamples = 0;
  var unitOffset = 0;
  var maxLagMs = 0;

  while (pushedSamples < targetSamples) {
    final chunkLen = min(slabSize, targetSamples - pushedSamples);
    var filled = 0;
    while (filled < chunkLen) {
      final available = unit.length - unitOffset;
      final copyLen = min(available, chunkLen - filled);
      reusableSlab.setRange(filled, filled + copyLen, unit, unitOffset);
      filled += copyLen;
      unitOffset = (unitOffset + copyLen) % unit.length;
    }

    final view = chunkLen == slabSize
        ? reusableSlab
        : Float32List.sublistView(reusableSlab, 0, chunkLen);

    pushSw
      ..reset()
      ..start();
    await onSlab(view);
    pushSw.stop();
    pushMicros.add(pushSw.elapsedMicroseconds);

    pushedSamples += chunkLen;
    onAfterPush?.call();

    final targetAudioMs = (pushedSamples * 1000) ~/ speechStreamSampleRate;
    final elapsedMs = wallSw.elapsedMilliseconds;
    final lagMs = elapsedMs - targetAudioMs;
    if (lagMs > maxLagMs) {
      maxLagMs = lagMs;
    }
    if (paced) {
      final remainingMs = targetAudioMs - elapsedMs;
      if (remainingMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: remainingMs));
      }
    }
  }

  wallSw.stop();
  pushMicros.sort();
  final p95Index = pushMicros.isEmpty
      ? 0
      : min(pushMicros.length - 1, ((pushMicros.length - 1) * 0.95).ceil());
  final p95PushMs = pushMicros.isEmpty ? 0.0 : pushMicros[p95Index] / 1000.0;
  final maxPushMs = pushMicros.isEmpty ? 0.0 : pushMicros.last / 1000.0;

  return SpeechStreamProducerStats(
    pushedSamples: pushedSamples,
    wallMs: wallSw.elapsedMilliseconds,
    p95PushMs: p95PushMs,
    maxPushMs: maxPushMs,
    maxLagMs: maxLagMs,
  );
}

Future<String> computeFileSha256(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('File does not exist: $path');
  }
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString().toLowerCase();
}

Future<Map<String, String>> preflightSpeechStreamInputs({
  required Map<String, String?> pathsByInputKey,
  bool verifyDigests = true,
}) async {
  final resolved = <String, String>{};
  for (final entry in speechStreamLockedDigests.entries) {
    final key = entry.key;
    final expectedSha = entry.value;
    final path = pathsByInputKey[key]?.trim();
    if (path == null || path.isEmpty) {
      throw StateError('Missing required speech stream input for $key.');
    }
    if (!File(path).existsSync()) {
      throw StateError('Missing speech stream input file for $key: $path');
    }
    if (verifyDigests) {
      final actualSha = await computeFileSha256(path);
      if (actualSha != expectedSha) {
        throw StateError(
          'SHA-256 mismatch for $key ($path): expected $expectedSha, got $actualSha',
        );
      }
      resolved[key] = actualSha;
    } else {
      resolved[key] = '';
    }
  }
  return resolved;
}

const List<String> requiredSpeechStreamQualificationLegIds = <String>[
  'voxtral_short',
  'voxtral_fast',
  'voxtral_paced',
  'lfm3_short',
  'lfm3_fast',
  'lfm3_paced',
  'qwen_refusal',
];

final class SpeechStreamLegReceipt {
  const SpeechStreamLegReceipt({
    required this.legId,
    required this.family,
    required this.mode,
    required this.hostOs,
    required this.arch,
    required this.backendRequested,
    required this.backendUsed,
    required this.exposedDevices,
    required this.usedDevices,
    required this.gpuLayersOffloaded,
    required this.threads,
    required this.threadsBatch,
    required this.contextSize,
    required this.pushedSamples,
    required this.audioDurationMs,
    required this.wallMs,
    required this.flushMs,
    required this.baselineRssBytes,
    required this.peakRssBytes,
    required this.ceilingBytes,
    required this.outcome,
    this.coreSha,
    this.sdkVersion,
    this.modelSha256,
    this.mmprojSha256,
    this.audioSha256,
    this.firstPartialWallMs,
    this.firstPartialAudioMs,
    this.p95PushMs,
    this.maxPushMs,
    this.maxLagMs,
    this.rtf,
    this.endRssBytes,
    this.postDisposeRssBytes,
    this.rssSampleCount,
    this.vramTotalBytes,
    this.vramFreeBytes,
    this.memoryStatus,
    this.failureReason,
  });

  final String legId;
  final String family;
  final String mode;
  final String hostOs;
  final String arch;
  final String backendRequested;
  final String backendUsed;
  final List<String> exposedDevices;
  final List<String> usedDevices;
  final int gpuLayersOffloaded;
  final int threads;
  final int threadsBatch;
  final int contextSize;
  final int pushedSamples;
  final int audioDurationMs;
  final int wallMs;
  final int flushMs;
  final int baselineRssBytes;
  final int peakRssBytes;
  final int? ceilingBytes;
  final String outcome;
  final String? coreSha;
  final String? sdkVersion;
  final String? modelSha256;
  final String? mmprojSha256;
  final String? audioSha256;
  final int? firstPartialWallMs;
  final int? firstPartialAudioMs;
  final double? p95PushMs;
  final double? maxPushMs;
  final int? maxLagMs;
  final double? rtf;
  final int? endRssBytes;
  final int? postDisposeRssBytes;
  final int? rssSampleCount;
  final int? vramTotalBytes;
  final int? vramFreeBytes;
  final String? memoryStatus;
  final String? failureReason;

  int get peakDeltaBytes => max(0, peakRssBytes - baselineRssBytes);

  Map<String, Object?> toJson() => <String, Object?>{
    'legId': legId,
    'family': family,
    'mode': mode,
    'hostOs': hostOs,
    'arch': arch,
    'backendRequested': backendRequested,
    'backendUsed': backendUsed,
    'exposedDevices': exposedDevices,
    'usedDevices': usedDevices,
    'gpuLayersOffloaded': gpuLayersOffloaded,
    'threads': threads,
    'threadsBatch': threadsBatch,
    'contextSize': contextSize,
    'pushedSamples': pushedSamples,
    'audioDurationMs': audioDurationMs,
    'wallMs': wallMs,
    'flushMs': flushMs,
    'baselineRssBytes': baselineRssBytes,
    'peakRssBytes': peakRssBytes,
    'peakDeltaBytes': peakDeltaBytes,
    'ceilingBytes': ceilingBytes,
    'outcome': outcome,
    if (coreSha != null) 'coreSha': coreSha,
    if (sdkVersion != null) 'sdkVersion': sdkVersion,
    if (modelSha256 != null) 'modelSha256': modelSha256,
    if (mmprojSha256 != null) 'mmprojSha256': mmprojSha256,
    if (audioSha256 != null) 'audioSha256': audioSha256,
    if (firstPartialWallMs != null) 'firstPartialWallMs': firstPartialWallMs,
    if (firstPartialAudioMs != null) 'firstPartialAudioMs': firstPartialAudioMs,
    if (p95PushMs != null) 'p95PushMs': p95PushMs,
    if (maxPushMs != null) 'maxPushMs': maxPushMs,
    if (maxLagMs != null) 'maxLagMs': maxLagMs,
    if (rtf != null) 'rtf': rtf,
    if (endRssBytes != null) 'endRssBytes': endRssBytes,
    if (postDisposeRssBytes != null) 'postDisposeRssBytes': postDisposeRssBytes,
    if (rssSampleCount != null) 'rssSampleCount': rssSampleCount,
    if (vramTotalBytes != null) 'vramTotalBytes': vramTotalBytes,
    if (vramFreeBytes != null) 'vramFreeBytes': vramFreeBytes,
    if (memoryStatus != null) 'memoryStatus': memoryStatus,
    if (failureReason != null) 'failureReason': failureReason,
  };

  factory SpeechStreamLegReceipt.fromJson(Map<String, Object?> json) {
    return SpeechStreamLegReceipt(
      legId: json['legId']! as String,
      family: json['family']! as String,
      mode: json['mode']! as String,
      hostOs: json['hostOs']! as String,
      arch: json['arch']! as String,
      backendRequested: json['backendRequested']! as String,
      backendUsed: json['backendUsed']! as String,
      exposedDevices: (json['exposedDevices']! as List<Object?>).cast<String>(),
      usedDevices: (json['usedDevices']! as List<Object?>).cast<String>(),
      gpuLayersOffloaded: json['gpuLayersOffloaded']! as int,
      threads: json['threads']! as int,
      threadsBatch: json['threadsBatch']! as int,
      contextSize: json['contextSize']! as int,
      pushedSamples: json['pushedSamples']! as int,
      audioDurationMs: json['audioDurationMs']! as int,
      wallMs: json['wallMs']! as int,
      flushMs: json['flushMs']! as int,
      baselineRssBytes: json['baselineRssBytes']! as int,
      peakRssBytes: json['peakRssBytes']! as int,
      ceilingBytes: json['ceilingBytes'] as int?,
      outcome: json['outcome']! as String,
      coreSha: json['coreSha'] as String?,
      sdkVersion: json['sdkVersion'] as String?,
      modelSha256: json['modelSha256'] as String?,
      mmprojSha256: json['mmprojSha256'] as String?,
      audioSha256: json['audioSha256'] as String?,
      firstPartialWallMs: json['firstPartialWallMs'] as int?,
      firstPartialAudioMs: json['firstPartialAudioMs'] as int?,
      p95PushMs: (json['p95PushMs'] as num?)?.toDouble(),
      maxPushMs: (json['maxPushMs'] as num?)?.toDouble(),
      maxLagMs: json['maxLagMs'] as int?,
      rtf: (json['rtf'] as num?)?.toDouble(),
      endRssBytes: json['endRssBytes'] as int?,
      postDisposeRssBytes: json['postDisposeRssBytes'] as int?,
      rssSampleCount: json['rssSampleCount'] as int?,
      vramTotalBytes: json['vramTotalBytes'] as int?,
      vramFreeBytes: json['vramFreeBytes'] as int?,
      memoryStatus: json['memoryStatus'] as String?,
      failureReason: json['failureReason'] as String?,
    );
  }
}

final class SpeechStreamQualificationReport {
  const SpeechStreamQualificationReport({
    required this.requestedBackend,
    required this.isBaselineCollection,
    required this.legs,
  });

  final String requestedBackend;
  final bool isBaselineCollection;
  final List<SpeechStreamLegReceipt> legs;
}

final class SpeechStreamEvaluationResult {
  const SpeechStreamEvaluationResult({
    required this.passed,
    required this.failures,
  });

  final bool passed;
  final List<String> failures;
}

SpeechStreamEvaluationResult evaluateQualificationReport(
  SpeechStreamQualificationReport report,
) {
  final failures = <String>[];
  if (report.isBaselineCollection) {
    failures.add(
      'A baseline-collection invocation cannot issue a qualification PASS.',
    );
  }
  if (report.legs.isEmpty) {
    failures.add('Qualification report has no legs.');
    return SpeechStreamEvaluationResult(passed: false, failures: failures);
  }

  final byId = <String, SpeechStreamLegReceipt>{
    for (final leg in report.legs) leg.legId: leg,
  };
  for (final requiredId in requiredSpeechStreamQualificationLegIds) {
    if (!byId.containsKey(requiredId)) {
      failures.add('Missing required qualification leg: $requiredId');
    }
  }

  final requested = report.requestedBackend.toLowerCase();
  for (final leg in report.legs) {
    if (leg.outcome != 'pass') {
      failures.add(
        'Leg ${leg.legId} did not pass (outcome=${leg.outcome}'
        '${leg.failureReason != null ? ', reason=${leg.failureReason}' : ''}).',
      );
    }

    if (leg.mode != 'refusal') {
      if (requested == 'cpu' && leg.gpuLayersOffloaded != 0) {
        failures.add(
          'Leg ${leg.legId} requested cpu placement but offloaded '
          '${leg.gpuLayersOffloaded} GPU layers.',
        );
      }
      if (requested == 'cuda') {
        if (leg.gpuLayersOffloaded <= 0 ||
            !leg.backendUsed.toLowerCase().contains('cuda')) {
          failures.add(
            'Leg ${leg.legId} requested cuda placement but used '
            'backend=${leg.backendUsed}, gpuLayers=${leg.gpuLayersOffloaded}.',
          );
        }
      }
    }

    if (leg.mode == 'fast' || leg.mode == 'paced') {
      if (leg.pushedSamples != speechStreamTargetSamples300s ||
          leg.audioDurationMs != speechStreamTargetSeconds300s * 1000) {
        failures.add(
          'Leg ${leg.legId} sample accounting mismatch: '
          'pushedSamples=${leg.pushedSamples}, '
          'audioDurationMs=${leg.audioDurationMs}.',
        );
      }
      final eval = evaluateMemoryBudget(
        baselineRssBytes: leg.baselineRssBytes,
        peakRssBytes: leg.peakRssBytes,
        ceilingBytes: leg.ceilingBytes,
      );
      if (!eval.passed) {
        failures.add(
          'Leg ${leg.legId} failed memory budget: status=${eval.status.name}, '
          'peakDeltaBytes=${eval.peakDeltaBytes}, '
          'ceilingBytes=${eval.ceilingBytes}.',
        );
      }
    }
  }

  return SpeechStreamEvaluationResult(
    passed: failures.isEmpty,
    failures: failures,
  );
}
