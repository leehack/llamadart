@TestOn('mac-os')
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
      runtimesDefine: const ['llama_cpp', 'stable_diffusion'],
    );

    expect(status['available'], isTrue, reason: '$status');
    expect(
      status['version'],
      isA<String>().having((v) => v, 'version', isNotEmpty),
    );
    expect(
      status['commit'],
      isA<String>().having((v) => v, 'commit', isNotEmpty),
    );
    final devices = (status['devices'] as List).cast<String>();
    expect(devices, contains(startsWith('CPU')));
    expect(devices, contains(startsWith('MTL')));
  });

  test('without opting in the runtime is reported as not bundled', () async {
    final status = await _probeConsumer(runtimesDefine: null);

    expect(status['available'], isFalse);
    expect(
      status['reason'],
      contains('stable_diffusion runtime is not bundled'),
    );
  });
}

Future<Map<String, Object?>> _probeConsumer({
  required List<String>? runtimesDefine,
}) async {
  final consumer = await Directory.systemTemp.createTemp('llamadart-sd-hook-');
  addTearDown(() => consumer.delete(recursive: true));
  final hooks = runtimesDefine == null
      ? ''
      : '''
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes:
        runtimes: [${runtimesDefine.join(', ')}]
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

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime.dart';

void main() {
  final status = probeStableDiffusionRuntime();
  print('SD_PROBE ${jsonEncode({
    'available': status.isAvailable,
    'version': status.version,
    'commit': status.commit,
    'devices': [for (final d in status.devices) '${d.name}\t${d.description}'],
    'reason': status.unavailableReason?.message,
  })}');
}
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
  return jsonDecode(line.substring('SD_PROBE '.length)) as Map<String, Object?>;
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
