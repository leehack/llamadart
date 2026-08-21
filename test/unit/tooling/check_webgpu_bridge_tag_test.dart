@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/check_webgpu_bridge_tag.dart';

Directory _fakeRepo(String assetsTag, {Map<String, String> files = const {}}) {
  final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
  addTearDown(() => root.deleteSync(recursive: true));
  final entries = <String, String>{
    bridgeTagSourcePath:
        'ASSETS_TAG="\${WEBGPU_BRIDGE_ASSETS_TAG:-$assetsTag}"\n',
    ...files,
  };
  for (final entry in entries.entries) {
    final file = File('${root.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return root;
}

void main() {
  test('the checked-in pins all quote the source of truth', () {
    final repoRoot = Directory.current;
    expect(
      findBridgeTagDrift(repoRoot, readPinnedBridgeTag(repoRoot)),
      isEmpty,
    );
  });

  test('a pin quoting a different tag is reported', () {
    final root = _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        'README.md':
            '| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v0.0.1` |\n',
      },
    );

    expect(
      findBridgeTagDrift(root, readPinnedBridgeTag(root)),
      contains('README.md: pins v0.0.1, expected v9.9.9'),
    );
  });

  test('a reworded pin is reported rather than skipped', () {
    final root = _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        'README.md': '| Web llama.cpp / GGUF | somewhere else entirely |\n',
      },
    );

    expect(
      findBridgeTagDrift(root, readPinnedBridgeTag(root)),
      contains(
        allOf(
          startsWith('README.md:'),
          contains('matches 0 lines, expected 1'),
        ),
      ),
    );
  });

  test('a duplicated pin is reported rather than half-covered', () {
    final root = _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        'README.md':
            '| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v9.9.9` |\n'
            '| Web llama.cpp / GGUF | `leehack/llama-web-bridge-assets@v9.9.9` |\n',
      },
    );

    expect(
      findBridgeTagDrift(root, readPinnedBridgeTag(root)),
      contains(contains('matches 2 lines, expected 1')),
    );
  });

  test('every bash assignment form is counted', () {
    const overrides = <String>[
      'ASSETS_TAG=v2.0.0',
      '  ASSETS_TAG=v2.0.0',
      '  export ASSETS_TAG=v2.0.0',
      'readonly ASSETS_TAG=v2.0.0',
      'declare ASSETS_TAG=v2.0.0',
      'true; ASSETS_TAG=v2.0.0',
      'ASSETS_TAG+=-patched',
      ': "\${ASSETS_TAG:=v2.0.0}"',
    ];

    for (final override in overrides) {
      final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/$bridgeTagSourcePath')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          'ASSETS_TAG="\${WEBGPU_BRIDGE_ASSETS_TAG:-v1.0.0}"\n$override\n',
        );

      expect(
        () => readPinnedBridgeTag(root),
        throwsFormatException,
        reason: 'bash honours "$override" but the gate did not count it',
      );
    }
  });

  test('the source-of-truth line itself counts only once', () {
    final root = _fakeRepo('v9.9.9');

    expect(readPinnedBridgeTag(root), 'v9.9.9');
  });

  test('no live occurrence of the tag escapes the pin table', () {
    // Read the tag rather than spelling it out, so this file never becomes an
    // occurrence the scan has to exclude.
    final repoRoot = Directory.current;
    expect(
      findUnregisteredTagSites(repoRoot, readPinnedBridgeTag(repoRoot)),
      isEmpty,
      reason: 'run against the real tree; see the message for what to register',
    );
  });

  test('a missing source of truth fails instead of passing vacuously', () {
    final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/$bridgeTagSourcePath')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('ASSETS_TAG="whatever"\n');

    expect(() => readPinnedBridgeTag(root), throwsFormatException);
  });
}
