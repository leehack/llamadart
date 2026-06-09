@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('updates hook native release pins from release metadata', () async {
    final root = await Directory.systemTemp.createTemp(
      'sync_native_release_pins_',
    );
    addTearDown(() => root.delete(recursive: true));

    await Directory(path.join(root.path, 'hook')).create(recursive: true);
    final releaseDir = Directory(path.join(root.path, 'releases'))
      ..createSync(recursive: true);

    await File(path.join(root.path, 'hook', 'build.dart')).writeAsString('''
const _llamaCppTag = 'old';
const _litertLmVersion = '1.0.0';

const _litertLmBundleSpecs = <_LiteRtLmBundleSpec>[
  _LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '${_hex('0')}',
    requiredLibraries: {'libLiteRtLm.so'},
  ),
];
''');

    const llamaTag = 'b9999';
    const litertTag = 'v9.9.9';
    final litertRuntimeChecksum = _hex('1');

    await _writeReleaseFixture(
      releaseDir,
      'leehack/llamadart-native',
      llamaTag,
      const {},
    );
    await _writeReleaseFixture(
      releaseDir,
      'leehack/litert-lm-native',
      litertTag,
      {
        'litert-lm-native-runtime-linux-x64-$litertTag.tar.gz':
            litertRuntimeChecksum,
      },
    );

    final result = await Process.run('python3', [
      'tool/native/sync_native_release_pins.py',
      '--repo-root',
      root.path,
      '--release-json-dir',
      releaseDir.path,
      '--llama-cpp-tag',
      llamaTag,
      '--litert-lm-tag',
      '9.9.9',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('llama.cpp -> leehack/llamadart-native'));
    expect(result.stdout, contains('LiteRT-LM -> leehack/litert-lm-native'));

    final hook = await File(
      path.join(root.path, 'hook', 'build.dart'),
    ).readAsString();
    expect(hook, contains("const _llamaCppTag = '$llamaTag';"));
    expect(hook, contains("const _litertLmVersion = '9.9.9';"));
    expect(hook, contains("sha256: '$litertRuntimeChecksum'"));
  });
}

Future<void> _writeReleaseFixture(
  Directory dir,
  String repo,
  String tag,
  Map<String, String> assets,
) {
  final file = File(
    path.join(dir.path, '${repo.replaceAll('/', '__')}__$tag.json'),
  );
  final payload = {
    'tag_name': tag,
    'assets': [
      for (final entry in assets.entries)
        {'name': entry.key, 'digest': 'sha256:${entry.value}'},
    ],
  };
  return file.writeAsString(jsonEncode(payload));
}

String _hex(String character) => List.filled(64, character).join();
