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

/// Builds a repo whose docs and native pin describe [bridgeTag]/[nativeTag].
Directory _fakeRuntimeRepo({
  required String bridgeTag,
  required String nativeTag,
}) {
  final root = Directory.systemTemp.createTempSync('bridge_runtime_gate');
  addTearDown(() => root.deleteSync(recursive: true));
  final entries = <String, String>{
    nativeLlamaCppTagPath: "const _llamaCppTag = '$nativeTag';\n",
    'doc/webgpu_bridge.md':
        'That release embeds llama.cpp `$bridgeTag`, which now trails the '
        '`hook/build.dart`\n',
    'website/docs/platforms/webgpu-bridge.md':
        '- `v0.1.37+` bridge assets embed llama.cpp `$bridgeTag`, which now '
        'trails the\n',
  };
  for (final entry in entries.entries) {
    File('${root.path}/${entry.key}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
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
      'ASSETS_TAG[0]=v2.0.0',
      r'ASSETS_TAG[$i]=v2.0.0',
      r'ASSETS_TAG[$((0))]=v2.0.0',
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

  test('an unregistered pin holding a stale tag is still caught', () {
    final root = _fakeRepo('v9.9.9');
    Process.runSync('git', <String>[
      'init',
      '--quiet',
    ], workingDirectory: root.path);
    File(
      '${root.path}/notes.md',
    ).writeAsStringSync('Uses `leehack/llama-web-bridge-assets@v0.1.36`.\n');
    Process.runSync('git', <String>['add', '-A'], workingDirectory: root.path);

    expect(
      findUnregisteredTagSites(root, 'v9.9.9'),
      contains(contains('notes.md:1: a bridge asset pin is not covered')),
    );
  });

  test('quoted machine-readable pins are recognised', () {
    for (final form in const <String>[
      'const defaultBridgeAssetsTag = "v0.1.36";',
      "const defaultBridgeAssetsTag = 'v0.1.36';",
      'WEBGPU_BRIDGE_ASSETS_TAG="v0.1.36" ./x.sh',
      'const defaultBridgeAssetsTag = `v0.1.36`;',
      'Uses `leehack/llama-web-bridge-assets@v0.1.36`.',
    ]) {
      final root = _fakeRepo('v9.9.9');
      Process.runSync('git', <String>[
        'init',
        '--quiet',
      ], workingDirectory: root.path);
      File('${root.path}/notes.md').writeAsStringSync('$form\n');
      Process.runSync('git', <String>[
        'add',
        '-A',
      ], workingDirectory: root.path);

      expect(
        findUnregisteredTagSites(root, 'v9.9.9'),
        contains(contains('notes.md:1: a bridge asset pin is not covered')),
        reason: 'unregistered pin "$form" evaded the scan',
      );
    }
  });

  test('a shorter tag does not match inside a longer floor', () {
    final root = _fakeRepo('v0.1.3');
    Process.runSync('git', <String>[
      'init',
      '--quiet',
    ], workingDirectory: root.path);
    // `v0.1.30+` is a floor for a different version; it merely starts with the
    // pinned tag.
    File(
      '${root.path}/notes.md',
    ).writeAsStringSync('Typed ASR needs bridge assets `v0.1.30+`.\n');
    Process.runSync('git', <String>['add', '-A'], workingDirectory: root.path);

    expect(findUnregisteredTagSites(root, 'v0.1.3'), isEmpty);
  });

  test('a binary file does not crash the scan', () {
    final root = _fakeRepo('v9.9.9');
    Process.runSync('git', <String>[
      'init',
      '--quiet',
    ], workingDirectory: root.path);
    File(
      '${root.path}/blob.bin',
    ).writeAsBytesSync(<int>[0xff, 0xfe, 0x00, 0x80]);
    Process.runSync('git', <String>['add', '-A'], workingDirectory: root.path);

    expect(() => findUnregisteredTagSites(root, 'v9.9.9'), returnsNormally);
  });

  test('a missing source of truth fails instead of passing vacuously', () {
    final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/$bridgeTagSourcePath')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('ASSETS_TAG="whatever"\n');

    expect(() => readPinnedBridgeTag(root), throwsFormatException);
  });

  test('an unreadable registered pin is reported without throwing', () {
    final root = _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        'README.md':
            '| Web llama.cpp / GGUF | '
            '`leehack/llama-web-bridge-assets@v9.9.9` |\n',
      },
    );
    final file = File('${root.path}/README.md');
    expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
    addTearDown(() => Process.runSync('chmod', ['600', file.path]));

    final problems = findBridgeTagDrift(root, 'v9.9.9');
    expect(problems, contains(contains('README.md: could not be read:')));
  }, skip: Platform.isWindows ? 'requires POSIX file permissions' : false);

  group('Web/native llama.cpp relationship', () {
    test('the checked-in repo agrees with its recorded divergence', () {
      expect(
        findBridgeRuntimeDrift(
          Directory.current,
          bridgeLlamaCppTag,
          bridgeLlamaCppDivergence,
        ),
        isEmpty,
      );
    });

    test('an unrecorded divergence is reported', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10514', nativeTag: 'b10545');

      expect(
        findBridgeRuntimeDrift(root, 'b10514', null),
        contains(
          'bridge assets embed llama.cpp b10514 but $nativeLlamaCppTagPath '
          'pins b10545 — move the bridge asset pin, or set '
          'bridgeLlamaCppDivergence and say so in the docs',
        ),
      );
    });

    test('a recorded divergence permits the mismatch', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10514', nativeTag: 'b10545');

      expect(findBridgeRuntimeDrift(root, 'b10514', 'because'), isEmpty);
    });

    test('a divergence record left behind after convergence is reported', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10545', nativeTag: 'b10545');

      expect(
        findBridgeRuntimeDrift(root, 'b10545', 'because'),
        contains(
          'bridgeLlamaCppDivergence records a divergence, but the bridge '
          'assets and $nativeLlamaCppTagPath both use b10545 — clear the '
          'record and restore the parity wording in the docs, then update '
          'the anchored bridgeLlamaCppTagPins patterns with the wording',
        ),
      );
    });

    test('a doc naming a different bridge build is reported', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b9999', nativeTag: 'b10545');

      expect(
        findBridgeRuntimeDrift(root, 'b10514', 'because'),
        contains('doc/webgpu_bridge.md: states b9999, expected b10514'),
      );
    });

    test('a reworded parity sentence is reported rather than skipped', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10514', nativeTag: 'b10545');
      File('${root.path}/doc/webgpu_bridge.md').writeAsStringSync(
        'That release embeds llama.cpp `b10514`, matching.\n',
      );

      expect(
        findBridgeRuntimeDrift(root, 'b10514', 'because').join('\n'),
        contains('matches 0 lines, expected 1'),
      );
    });

    test('a missing native pin fails instead of passing vacuously', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10514', nativeTag: 'b10545');
      File(
        '${root.path}/$nativeLlamaCppTagPath',
      ).writeAsStringSync('// nothing here\n');

      expect(
        findBridgeRuntimeDrift(root, 'b10514', 'because'),
        contains(
          '$nativeLlamaCppTagPath: no _llamaCppTag constant; the gate cannot '
          'run',
        ),
      );
    });

    test('an unreadable native pin is reported without throwing', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'b10514', nativeTag: 'b10545');
      final file = File('${root.path}/$nativeLlamaCppTagPath');
      expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
      addTearDown(() => Process.runSync('chmod', ['600', file.path]));

      expect(
        findBridgeRuntimeDrift(root, 'b10514', 'because'),
        contains(contains('$nativeLlamaCppTagPath: could not be read:')),
      );
    }, skip: Platform.isWindows ? 'requires POSIX file permissions' : false);
  });

  test('malformed remote manifest JSON is reported without throwing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('{not-json')
        ..close();
    });

    final errors = await verifyManifestLlamaCppTag(
      'v9.9.9',
      'b10514',
      manifestUrl: Uri.parse(
        'http://${server.address.host}:${server.port}/manifest.json',
      ),
    );

    expect(errors, hasLength(1));
    expect(errors.single, contains('returned invalid manifest JSON'));
  });

  test('a stalled remote manifest request times out', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"llama_cpp_tag":"b10514"');
    });

    final errors = await verifyManifestLlamaCppTag(
      'v9.9.9',
      'b10514',
      manifestUrl: Uri.parse(
        'http://${server.address.host}:${server.port}/manifest.json',
      ),
      timeout: const Duration(milliseconds: 50),
    );

    expect(errors, hasLength(1));
    expect(errors.single, contains('timed out reading'));
  });
}
