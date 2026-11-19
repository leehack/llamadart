import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

import 'src/macos_mic_asr.dart';

const _profiles = {
  'voxtral': 'Voxtral Mini 4B Realtime',
  'lfm3': 'LFM3-Audio 2B',
  'qwen': 'Qwen3-ASR windowed',
};
const _phases = ['finish', 'cancel', 'restart'];
final _receiptDirectory =
    Platform.environment['LLAMADART_MIC_RECEIPT_DIR'] ?? 'build/macos-mic-asr';

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) {
    stderr.writeln('The microphone harness requires macOS and FFmpeg.');
    exitCode = 64;
    return;
  }
  final parser = ArgParser()
    ..addOption('profile', allowed: _profiles.keys)
    ..addOption('model')
    ..addOption('mmproj')
    ..addOption('audio')
    ..addOption('expect')
    ..addFlag('list-inputs', negatable: false);
  try {
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty) {
      throw const FormatException('Unexpected arguments.');
    }
    if (args.flag('list-inputs')) {
      _printDevices(await listMicDevices());
      return;
    }
    final profile = args.option('profile');
    final model = args.option('model');
    final mmproj = args.option('mmproj');
    final audio = args.option('audio');
    final expected = args.option('expect');
    if (profile == null ||
        model == null ||
        mmproj == null ||
        (audio != null && (expected == null || expected.trim().isEmpty)) ||
        (audio == null && expected != null)) {
      throw const FormatException(
        'Set --profile voxtral|lfm3|qwen, --model and --mmproj. '
        'Supply --audio and its --expect transcript together for file replay.',
      );
    }
    final files = {model: 'model', mmproj: 'projector', ?audio: 'fixture'};
    String redactError(Object error) {
      var message = error.toString();
      for (final entry in files.entries) {
        final path = File(entry.key);
        message = message
            .replaceAll(path.absolute.path, '<${entry.value}>')
            .replaceAll(path.path, '<${entry.value}>');
      }
      return message;
    }

    for (final entry in files.entries) {
      if (!await File(entry.key).exists()) {
        throw FormatException(
          'The ${entry.value} must be an existing local file.',
        );
      }
    }

    final version = await runFfmpegQuery(['-version']);
    if (version.exitCode != 0) throw StateError('FFmpeg -version failed.');
    MicDevice? device;
    if (audio == null) {
      if (!stdin.hasTerminal) {
        throw StateError(
          'Run from an interactive macOS terminal to select a microphone.',
        );
      }
      final devices = await listMicDevices();
      _printDevices(devices);
      stdout.write('Enter the index of the physical microphone: ');
      final selection = int.tryParse(stdin.readLineSync()?.trim() ?? '');
      device = devices.where((device) => device.index == selection).firstOrNull;
      if (device == null) {
        throw const FormatException('Select a listed audio input.');
      }
    }

    final interrupted = Completer<void>();
    final signals = ProcessSignal.sigint.watch().listen((_) {
      if (!interrupted.isCompleted) interrupted.complete();
    });
    try {
      exitCode = await _run(
        profile: profile,
        model: model,
        mmproj: mmproj,
        audio: audio,
        reference: expected ?? micPhrase,
        device: device,
        ffmpegVersion: (version.stdout as String).split('\n').first,
        interrupted: interrupted,
        redactError: redactError,
      );
    } finally {
      await signals.cancel();
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = error is FormatException ? 64 : 1;
  }
}

void _printDevices(List<MicDevice> devices) {
  for (final device in devices) {
    stdout.writeln('  [${device.index}] ${device.name}');
  }
}

Future<Map<String, String>> _fileIdentity(String path) async => {
  'name': File(path).uri.pathSegments.last,
  'sha256': (await sha256.bind(File(path).openRead()).first).toString(),
};

Future<int> _run({
  required String profile,
  required String model,
  required String mmproj,
  required String? audio,
  required String reference,
  required MicDevice? device,
  required String ffmpegVersion,
  required Completer<void> interrupted,
  required String Function(Object) redactError,
}) async {
  final started = DateTime.now().toUtc();
  final directory = await Directory(_receiptDirectory).create(recursive: true);
  final file = File(
    '${directory.path}/mic-$profile-${device?.index ?? 'simulated'}-'
    '${started.microsecondsSinceEpoch}.json',
  );
  final cycles = <MicCycleReceipt>[];
  final errors = <String>[];
  SpeechToTextEngine? engine;
  final receipt = <String, Object?>{
    'schema_version': 1,
    'started_utc': started.toIso8601String(),
    'input': device == null
        ? 'simulated_file'
        : 'operator_selected_avfoundation',
    'device_name': device?.name ?? 'FFmpeg paced file',
    'device_index': device?.index,
    'ffmpeg': ffmpegVersion,
    'backend': 'llama.cpp CPU',
    'requested_model_profile': _profiles[profile],
    'stream_adapter': profile == 'qwen'
        ? 'Qwen3WindowedAsrAdapter'
        : 'LlamaCppLiveAsrAdapter',
    'sample_rate_hz': micSampleRate,
    'channels': 1,
    'transport': 'FFmpeg stdout pcm_f32le',
    'reference': reference,
  };
  try {
    // Validate the reference before capturing any audio.
    micWordErrorRate(reference, '');
    final revision = await Process.run('git', ['rev-parse', 'HEAD']);
    if (revision.exitCode == 0) {
      receipt['git_head'] = (revision.stdout as String).trim();
      final status = await Process.run('git', ['status', '--porcelain']);
      if (status.exitCode == 0) {
        receipt['git_tree_clean'] = (status.stdout as String).trim().isEmpty;
      }
    }
    final runtime = await collectLlamaRuntimeSetupReport();
    receipt['runtime_setup'] = runtime.toJson();
    stdout.writeln('Hashing inputs and loading ${_profiles[profile]} on CPU…');
    receipt['model'] = await _fileIdentity(model);
    receipt['projector'] = await _fileIdentity(mmproj);
    if (audio != null) receipt['fixture'] = await _fileIdentity(audio);
    if (interrupted.isCompleted) {
      throw StateError('Operator interrupted setup.');
    }
    engine = await SpeechToTextEngine.load(
      SpeechToTextModel(
        ModelSource.path(model),
        projector: ModelSource.path(mmproj),
        adapter: profile == 'qwen'
            ? const Qwen3WindowedAsrAdapter()
            : const LlamaCppLiveAsrAdapter(),
      ),
      params: const ModelParams(
        contextSize: 4096,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        device: ComputeDevice.cpu,
        preferredBackend: GpuBackend.cpu,
        gpuLayers: 0,
      ),
    );
    stdout.writeln('Phrase: $reference');
    for (final phase in _phases) {
      if (interrupted.isCompleted) {
        throw StateError('Operator interrupted run.');
      }
      if (device != null && !(await listMicDevices()).contains(device)) {
        throw StateError('The selected microphone name or index changed.');
      }
      stdout.writeln(switch (phase) {
        'finish' => 'First capture: read the full phrase in 15–18 seconds.',
        'cancel' =>
          'Cancellation: keep reading until capture stops mid-phrase.',
        _ => 'Restart: read the full phrase from the beginning.',
      });
      final cycle = await captureMicCycle(
        phase: phase,
        session: await engine.startStream().timeout(
          const Duration(seconds: 45),
        ),
        startCapture: () => startMicCapture(device: device, audioPath: audio),
        interrupted: interrupted.future,
        cancelAfter: phase == 'cancel' ? micCancelAfter : null,
        report: stdout.writeln,
        redactError: redactError,
      );
      cycles.add(cycle);
      for (final error in [...cycle.captureWarnings, ...cycle.errors]) {
        stderr.writeln('$phase: $error');
      }
      if (cycle.completion == null) break;
    }
  } on Object catch (error) {
    errors.add(redactError(error));
  } finally {
    try {
      await engine?.dispose().timeout(const Duration(seconds: 45));
    } on Object catch (error) {
      errors.add('Engine cleanup: ${redactError(error)}');
    }
    final failed =
        errors.isNotEmpty ||
        cycles.length != _phases.length ||
        cycles.any((cycle) => cycle.errors.isNotEmpty);
    receipt.addAll({
      'lifecycle_checks_passed': !failed,
      'errors': errors,
      'cycles': [for (final cycle in cycles) cycle.toJson(reference)],
    });
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
    );
    for (final error in errors) {
      stderr.writeln(error);
    }
    stdout.writeln('Receipt: ${file.path}');
  }
  if (interrupted.isCompleted) return 130;
  return receipt['lifecycle_checks_passed'] == true ? 0 : 1;
}
