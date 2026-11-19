import 'dart:convert';
import 'dart:io';

import '../../test/support/speech_stream_qualification.dart';

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

Future<int> _runPreflight() async {
  final paths = <String, String?>{
    'voxtralModel': _envFile('LLAMADART_STT_STREAM_VOXTRAL_MODEL_PATH'),
    'voxtralMmproj': _envFile('LLAMADART_STT_STREAM_VOXTRAL_MMPROJ_PATH'),
    'lfm3Model': _envFile('LLAMADART_STT_STREAM_LFM3_MODEL_PATH'),
    'lfm3Mmproj': _envFile('LLAMADART_STT_STREAM_LFM3_MMPROJ_PATH'),
    'qwenModel': _envFile(
      'LLAMADART_STT_STREAM_QWEN_MODEL_PATH',
      'LLAMADART_STT_MODEL_PATH',
    ),
    'qwenMmproj': _envFile(
      'LLAMADART_STT_STREAM_QWEN_MMPROJ_PATH',
      'LLAMADART_STT_MMPROJ_PATH',
    ),
    'jfkAudio': _envFile('LLAMADART_STT_STREAM_AUDIO_PATH') ?? _defaultJfkWav,
  };

  try {
    final verified = await preflightSpeechStreamInputs(
      pathsByInputKey: paths,
      verifyDigests: true,
    );
    stdout.writeln('Speech stream qualification preflight passed:');
    for (final entry in verified.entries) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }
    return 0;
  } on StateError catch (error) {
    stderr.writeln('Speech stream qualification preflight FAILED: $error');
    return 1;
  }
}

int _runEvaluate(String receiptDir, String backend) {
  final dir = Directory(receiptDir);
  if (!dir.existsSync()) {
    stderr.writeln('Receipt directory does not exist: $receiptDir');
    return 1;
  }

  final legs = <SpeechStreamLegReceipt>[];
  for (final entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.json')) {
      final decoded =
          jsonDecode(entity.readAsStringSync()) as Map<String, Object?>;
      legs.add(SpeechStreamLegReceipt.fromJson(decoded));
    }
  }

  final isBaselineCollection =
      Platform.environment['LLAMADART_STT_STREAM_COLLECT_BASELINE'] == '1';
  final result = evaluateQualificationReport(
    SpeechStreamQualificationReport(
      requestedBackend: backend,
      isBaselineCollection: isBaselineCollection,
      legs: legs,
    ),
  );

  if (result.passed) {
    stdout.writeln(
      'Speech stream qualification PASS (${legs.length} legs, backend=$backend).',
    );
    return 0;
  }

  stderr.writeln('Speech stream qualification FAIL (backend=$backend):');
  for (final failure in result.failures) {
    stderr.writeln('  - $failure');
  }
  return 1;
}

Future<void> main(List<String> args) async {
  if (args.contains('--preflight')) {
    exitCode = await _runPreflight();
    return;
  }
  if (args.contains('--evaluate')) {
    String? receiptDir;
    var backend = 'auto';
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--receipt-dir' && i + 1 < args.length) {
        receiptDir = args[++i];
      } else if (args[i] == '--backend' && i + 1 < args.length) {
        backend = args[++i];
      }
    }
    if (receiptDir == null || receiptDir.isEmpty) {
      stderr.writeln('--receipt-dir is required with --evaluate.');
      exitCode = 64;
      return;
    }
    exitCode = _runEvaluate(receiptDir, backend);
    return;
  }

  stderr.writeln(
    'Usage: dart run tool/testing/verify_speech_stream_qualification.dart '
    '[--preflight | --evaluate --receipt-dir <dir> --backend <cpu|cuda|auto>]',
  );
  exitCode = 64;
}
