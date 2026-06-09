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
    await _writePackageSwift(
      root,
      'packages/llamadart_llama_cpp_flutter/darwin/'
          'llamadart_llama_cpp_flutter/Package.swift',
      'llamaCppTag',
      const ['llama'],
    );
    await _writePackageSwift(
      root,
      'packages/llamadart_litert_lm_flutter/darwin/'
          'llamadart_litert_lm_flutter/Package.swift',
      'liteRtLmTag',
      _litertAppleTargets.keys,
    );
    await _writeCompanionDocs(
      root,
      'packages/llamadart_llama_cpp_flutter',
      'leehack/llamadart-native',
      includeExistingUnreleasedEntry: true,
    );
    await _writeCompanionDocs(
      root,
      'packages/llamadart_litert_lm_flutter',
      'leehack/litert-lm-native',
    );

    const llamaTag = 'b9999';
    const litertTag = 'v9.9.9';
    final litertRuntimeChecksum = _hex('1');
    final llamaAppleChecksum = _hex('2');
    final litertAppleChecksums = {
      for (final entry in _litertAppleTargets.entries)
        entry.key: _hex(entry.value.$2),
    };

    await _writeReleaseFixture(
      releaseDir,
      'leehack/llamadart-native',
      llamaTag,
      {'llamadart-native-apple-xcframework-$llamaTag.zip': llamaAppleChecksum},
    );
    await _writeReleaseFixture(
      releaseDir,
      'leehack/litert-lm-native',
      litertTag,
      {
        'litert-lm-native-runtime-linux-x64-$litertTag.tar.gz':
            litertRuntimeChecksum,
        for (final entry in _litertAppleTargets.entries)
          entry.value.$1.replaceAll('{tag}', litertTag):
              litertAppleChecksums[entry.key]!,
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

    final llamaSwift = await File(
      path.join(
        root.path,
        'packages/llamadart_llama_cpp_flutter/darwin/'
        'llamadart_llama_cpp_flutter/Package.swift',
      ),
    ).readAsString();
    expect(llamaSwift, contains('let llamaCppTag = "$llamaTag"'));
    expect(llamaSwift, contains('checksum: "$llamaAppleChecksum"'));
    final llamaReadme = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/README.md'),
    ).readAsString();
    expect(
      llamaReadme,
      contains(
        'The Apple SwiftPM manifest pins '
        '`leehack/llamadart-native@$llamaTag`.',
      ),
    );
    final llamaChangelog = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(
      llamaChangelog,
      contains(
        '* Updated Apple SwiftPM native pin to '
        '`leehack/llamadart-native@$llamaTag`.',
      ),
    );
    expect(llamaChangelog, isNot(contains('stale')));

    final litertSwift = await File(
      path.join(
        root.path,
        'packages/llamadart_litert_lm_flutter/darwin/'
        'llamadart_litert_lm_flutter/Package.swift',
      ),
    ).readAsString();
    expect(litertSwift, contains('let liteRtLmTag = "$litertTag"'));
    for (final checksum in litertAppleChecksums.values) {
      expect(litertSwift, contains('checksum: "$checksum"'));
    }
    final litertReadme = await File(
      path.join(root.path, 'packages/llamadart_litert_lm_flutter/README.md'),
    ).readAsString();
    expect(
      litertReadme,
      contains(
        'The Apple SwiftPM manifest pins '
        '`leehack/litert-lm-native@$litertTag`.',
      ),
    );
    final litertChangelog = await File(
      path.join(root.path, 'packages/llamadart_litert_lm_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(litertChangelog, startsWith('## Unreleased'));
    expect(
      litertChangelog,
      contains(
        '* Updated Apple SwiftPM native pin to '
        '`leehack/litert-lm-native@$litertTag`.',
      ),
    );
  });
}

Future<void> _writePackageSwift(
  Directory root,
  String relativePath,
  String tagVariable,
  Iterable<String> targetNames,
) async {
  final file = File(path.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString('''
let $tagVariable = "old"

let package = Package(
    targets: [
${targetNames.map((target) => '''
        nativeRepoBinaryTarget(
            name: "$target",
            checksum: "${_hex('0')}"
        ),
''').join()}
    ]
)
''');
}

Future<void> _writeCompanionDocs(
  Directory root,
  String relativePackagePath,
  String repo, {
  bool includeExistingUnreleasedEntry = false,
}) async {
  final packageDir = Directory(path.join(root.path, relativePackagePath));
  await packageDir.create(recursive: true);
  await File(path.join(packageDir.path, 'README.md')).writeAsString('''
# Test package

The Apple SwiftPM manifest pins `$repo@old`.
''');
  final unreleased = includeExistingUnreleasedEntry
      ? '''
## Unreleased

* Updated Apple SwiftPM native pin to `$repo@stale`.

'''
      : '';
  await File(path.join(packageDir.path, 'CHANGELOG.md')).writeAsString('''
$unreleased## 0.8.0

* Initial package.
''');
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

const Map<String, (String, String)> _litertAppleTargets = {
  'LiteRtLm': ('litert-lm-native-apple-LiteRtLm-xcframework-{tag}.zip', '3'),
  'CLiteRTLM': ('litert-lm-native-apple-CLiteRTLM-xcframework-{tag}.zip', '4'),
  'GemmaModelConstraintProvider': (
    'litert-lm-native-apple-GemmaModelConstraintProvider-xcframework-{tag}.zip',
    '5',
  ),
  'LiteRt': ('litert-lm-native-apple-LiteRt-xcframework-{tag}.zip', '6'),
  'LiteRtMetalAccelerator': (
    'litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-{tag}.zip',
    '7',
  ),
  'LiteRtTopKMetalSampler': (
    'litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-{tag}.zip',
    '8',
  ),
  'LiteRtTopKWebGpuSampler': (
    'litert-lm-native-apple-LiteRtTopKWebGpuSampler-xcframework-{tag}.zip',
    '9',
  ),
  'LiteRtWebGpuAccelerator': (
    'litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-{tag}.zip',
    'a',
  ),
};
