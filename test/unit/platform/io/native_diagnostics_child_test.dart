@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  test('child validates request nonce before writing any result', () async {
    final config = (await Isolate.packageConfig)!;
    for (final nonce in ['0' * 48, 'PRIVATE_DIAGNOSTIC_TOKEN']) {
      final directory = await Directory.systemTemp.createTemp(
        'llamadart_native_diagnostic_',
      );
      try {
        final output = File('${directory.path}/result.json');
        final manifest = File('${directory.path}/native_assets.yaml');
        await manifest.writeAsString(
          jsonEncode({
            'format-version': [1, 0, 0],
            'native-assets': {
              'macos_arm64': {
                'package:llamadart/llamadart': [
                  'absolute',
                  File('${directory.path}/missing').absolute.path,
                ],
              },
            },
          }),
        );
        final process = await Process.start(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          '--packages=${config.toFilePath()}',
          File(
            'lib/src/platform/io/native_diagnostics_child.dart',
          ).absolute.path,
        ]);
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        process.stdin.write(
          jsonEncode({
            'runtime': 'llama_cpp',
            'nonce': nonce,
            'output': output.path,
            'phase': '${directory.path}/phase',
            'manifest': manifest.path,
            'abi': 'macos_arm64',
          }),
        );
        await process.stdin.close();
        expect(await process.exitCode, nonce.startsWith('0') ? 0 : 1);
        expect(await output.exists(), nonce.startsWith('0'));
        if (await output.exists()) {
          expect(
            (jsonDecode(await output.readAsString()) as Map)['code'],
            'ARTIFACT_MISSING',
          );
        }
        expect(await out, isEmpty);
        expect(await err, isEmpty);
      } finally {
        await directory.delete(recursive: true);
      }
    }
  });
  test(
    'packaged child rejects malformed/unbounded requests without raw output',
    () async {
      for (final input in ['PRIVATE_DIAGNOSTIC_TOKEN', 'x' * 33000, '{}']) {
        final config = (await Isolate.packageConfig)!;
        final process = await Process.start(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          '--packages=${config.toFilePath()}',
          File(
            'lib/src/platform/io/native_diagnostics_child.dart',
          ).absolute.path,
        ]);
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        process.stdin.write(input);
        await process.stdin.close();
        expect(await process.exitCode, 1);
        expect(await out, isEmpty);
        expect(await err, isEmpty);
      }
    },
  );
}
