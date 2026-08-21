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
      contains(startsWith('README.md: no line matches')),
    );
  });

  test('a second assignment fails rather than validating the wrong one', () {
    final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/$bridgeTagSourcePath')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        'ASSETS_TAG="\${WEBGPU_BRIDGE_ASSETS_TAG:-v1.0.0}"\n'
        'ASSETS_TAG="\${WEBGPU_BRIDGE_ASSETS_TAG:-v2.0.0}"\n',
      );

    expect(() => readPinnedBridgeTag(root), throwsFormatException);
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
