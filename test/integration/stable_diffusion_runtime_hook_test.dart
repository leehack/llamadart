@TestOn('vm && mac-os')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

// Builds throwaway consumers of this checkout so the real build hook downloads,
// verifies and bundles the pinned stable_diffusion runtime, then probes it
// through its native-asset id in a fresh process.
void main() {
  test('opting in bundles a runtime that loads and lists devices', () async {
    final status = await _probeConsumer(
      runtimes: '[llama_cpp, stable_diffusion]',
    );

    expect(status['available'], isTrue, reason: '$status');
    expect(
      status['hookLog'],
      contains('Selected native runtimes: llama_cpp, stable_diffusion.'),
    );
    expect(
      status['version'],
      isA<String>().having((v) => v, 'version', isNotEmpty),
    );
    expect(status['commit'], '5dcfa79');
    expect(status['abi'], {
      'size': 560,
      'controlType': 0,
      'controlTypeAt552': 0,
      'width': 512,
      'height': 512,
      'canariesIntact': true,
    });
    final devices = (status['devices'] as List).cast<String>();
    expect(devices, contains(startsWith('CPU')));
    expect(devices, contains(startsWith('MTL')));
  });

  test('all bundles it beside the default runtimes', () async {
    for (final runtimes in const ['all', '{runtimes: [all]}']) {
      final status = await _probeConsumer(runtimes: runtimes);

      expect(status['available'], isTrue, reason: '$runtimes $status');
      expect(
        status['hookLog'],
        contains(
          'Selected native runtimes: llama_cpp, litert_lm, stable_diffusion.',
        ),
        reason: runtimes,
      );
    }
  });

  test('without opting in the runtime is reported as not bundled', () async {
    for (final runtimes in const [null, 'both']) {
      final status = await _probeConsumer(runtimes: runtimes);

      expect(status['available'], isFalse, reason: '$runtimes');
      expect(
        status['reason'],
        contains('stable_diffusion runtime is not bundled'),
        reason: '$runtimes',
      );
      expect(
        status['hookLog'],
        contains('Selected native runtimes: llama_cpp, litert_lm.'),
        reason: '$runtimes',
      );
    }
  });
}

/// The probe's status for a consumer whose `llamadart_native_runtimes` is the
/// YAML value [runtimes], plus the llamadart hook's output under `hookLog`.
Future<Map<String, Object?>> _probeConsumer({required String? runtimes}) async {
  final consumer = await Directory.systemTemp.createTemp('llamadart-sd-hook-');
  addTearDown(() => consumer.delete(recursive: true));
  final hooks = runtimes == null
      ? ''
      : '''
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: $runtimes
''';
  await File(path.join(consumer.path, 'pubspec.yaml')).writeAsString('''
name: llamadart_sd_hook_consumer
publish_to: none
environment:
  sdk: ^3.10.7
dependencies:
  llamadart:
    path: ${jsonEncode(Directory.current.path)}
$hooks''');
  final bin = await Directory(path.join(consumer.path, 'bin')).create();
  await File(path.join(bin.path, 'probe.dart')).writeAsString(r'''
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime.dart';

void main() {
  final status = probeStableDiffusionRuntime();
  print('SD_PROBE ${jsonEncode({
    'available': status.isAvailable,
    'version': status.version,
    'commit': status.commit,
    'devices': [for (final d in status.devices) '${d.name}\t${d.description}'],
    'reason': status.unavailableReason?.message,
    'abi': status.isAvailable
        ? checkImageParams(StableDiffusionCalls.tryResolve()!)
        : null,
  })}');
}

Map<String, Object?> checkImageParams(StableDiffusionCalls calls) =>
  using((arena) {
    const paramsSize = 560;
    const guardSize = 32;
    const sentinel = 0xA5;
    final storage = arena<Uint8>(paramsSize + 2 * guardSize);
    final bytes = storage.asTypedList(paramsSize + 2 * guardSize);
    bytes.fillRange(0, bytes.length, sentinel);
    final params = (storage + guardSize).cast<sd.sd_img_gen_params_t>();
    calls.imageGenerationParamsInit(params);
    return {
      'size': sizeOf<sd.sd_img_gen_params_t>(),
      'controlType': params.ref.control_type.value,
      'controlTypeAt552': params.cast<Uint32>()[552 ~/ sizeOf<Uint32>()],
      'width': params.ref.width,
      'height': params.ref.height,
      'canariesIntact': [
        ...bytes.take(guardSize),
        ...bytes.skip(guardSize + paramsSize),
      ].every((byte) => byte == sentinel),
    };
  });
''');

  await _expectSuccess(Platform.resolvedExecutable, [
    'pub',
    'get',
  ], consumer.path);
  final output = await _expectSuccess(Platform.resolvedExecutable, [
    'run',
    'bin/probe.dart',
  ], consumer.path);
  final line = LineSplitter.split(
    output,
  ).singleWhere((line) => line.startsWith('SD_PROBE '));
  final hookLog =
      Directory(
            path.join(consumer.path, '.dart_tool', 'hooks_runner', 'llamadart'),
          )
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => path.basename(file.path) == 'stdout.txt');
  return {
    ...jsonDecode(line.substring('SD_PROBE '.length)) as Map<String, Object?>,
    'hookLog': hookLog.map((file) => file.readAsStringSync()).join(),
  };
}

Future<String> _expectSuccess(
  String command,
  List<String> arguments,
  String cwd,
) async {
  final result = await Process.run(command, arguments, workingDirectory: cwd);
  final output = '${result.stdout}\n${result.stderr}';
  expect(result.exitCode, 0, reason: output);
  return output;
}
