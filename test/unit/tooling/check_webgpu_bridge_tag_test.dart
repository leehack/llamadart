@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../../tool/testing/check_webgpu_bridge_tag.dart';

Directory _fakeRepo(
  String assetsTag, {
  String version = '1.2.3',
  Map<String, String> files = const {},
}) {
  final root = Directory.systemTemp.createTempSync('bridge_tag_gate');
  addTearDown(() => root.deleteSync(recursive: true));
  final entries = <String, String>{
    bridgeTagSourcePath:
        'ASSETS_TAG="\${WEBGPU_BRIDGE_ASSETS_TAG:-$assetsTag}"\n',
    rootPubspecPath: 'name: llamadart\nversion: $version\n',
    ...files,
  };
  for (final entry in entries.entries) {
    final file = File('${root.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return root;
}

/// Builds a repo whose docs, chat bootstrap and native pin describe
/// [bridgeTag]/[nativeTag].
Directory _fakeRuntimeRepo({
  required String bridgeTag,
  required String nativeTag,
  bool parityWording = true,
}) {
  final root = Directory.systemTemp.createTempSync('bridge_runtime_gate');
  addTearDown(() => root.deleteSync(recursive: true));
  final entries = <String, String>{
    nativeLlamaCppTagPath: "const _llamaCppTag = '$nativeTag';\n",
    'example/chat_app/web/index.html':
        "    const defaultBridgeLlamaCppTag = '$bridgeTag';\n",
    'doc/webgpu_bridge.md': parityWording
        ? 'That release embeds llama.cpp `$bridgeTag`, matching the '
              '`hook/build.dart` native pin\n'
        : 'That release embeds llama.cpp `$bridgeTag`, which now trails the '
              '`hook/build.dart`\n',
    'website/docs/platforms/webgpu-bridge.md': parityWording
        ? '- The pinned `v1.2.3` bridge assets embed llama.cpp `$bridgeTag`, matching '
              'the native runtime\n'
        : '- The pinned `v1.2.3` bridge assets embed llama.cpp `$bridgeTag`, which now '
              'trails the\n',
  };
  for (final entry in entries.entries) {
    File('${root.path}/${entry.key}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  return root;
}

const String _approvedManifestJson = '''
{
  "artifacts": {
    "llama_webgpu_bridge.d.ts": {
      "sha256": "be584430457c76cf991c39ebfd19f771424f86f6304899840bf9e50f1b32cafc",
      "size_bytes": 6330
    },
    "llama_webgpu_bridge.js": {
      "sha256": "a704115fe87d3defff4a02c5a2b1d1bf0ab3bc1f00de3f40ed2c9b2d5983fd73",
      "size_bytes": 210601
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
      "size_bytes": 257
    },
    "llama_webgpu_core.js": {
      "sha256": "d98327b43cd30b8ac25523255f53a8873ebd7756de2de96d7f1ea5c279029d96",
      "size_bytes": 113962
    },
    "llama_webgpu_core.wasm": {
      "sha256": "85dee0979f80a41108351b3298c0e96fc79e92db602b2bd2ddbd652fb0f08e20",
      "size_bytes": 8629961
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "451ed2bfc99fc33e0de6b09eb96f03914a194c91bcd0bda968048c2d5efa7e2d",
      "size_bytes": 131045
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "31de051ee7dfe8703a54c4ef91d68c59d9a08beb15eec5f0b26d4e344a6b57cd",
      "size_bytes": 8845657
    }
  },
  "assets_repository": "leehack/llama-web-bridge-assets",
  "bridge_assets_tag": "v0.1.41",
  "bridge_commit": "646037ac816c066d3f7d9e357139ca20800dc7ee",
  "bridge_repository": "leehack/llama-web-bridge",
  "capabilities": {
    "memory64": true,
    "multimodal": {
      "direct": true,
      "worker": true
    },
    "speech_to_text": {
      "advertised": true,
      "direct": true,
      "memory64": true,
      "wasm32": true,
      "worker": true
    },
    "state_persistence": {
      "direct": true,
      "worker": true
    },
    "text_to_speech": {
      "advertised": true,
      "direct": true,
      "memory64": true,
      "wasm32": false,
      "worker": true
    },
    "wasm32": true
  },
  "emscripten_version": "6.0.8",
  "files": {
    "llama_webgpu_bridge.d.ts": {
      "sha256": "be584430457c76cf991c39ebfd19f771424f86f6304899840bf9e50f1b32cafc",
      "size_bytes": 6330
    },
    "llama_webgpu_bridge.js": {
      "sha256": "a704115fe87d3defff4a02c5a2b1d1bf0ab3bc1f00de3f40ed2c9b2d5983fd73",
      "size_bytes": 210601
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
      "size_bytes": 257
    },
    "llama_webgpu_core.js": {
      "sha256": "d98327b43cd30b8ac25523255f53a8873ebd7756de2de96d7f1ea5c279029d96",
      "size_bytes": 113962
    },
    "llama_webgpu_core.wasm": {
      "sha256": "85dee0979f80a41108351b3298c0e96fc79e92db602b2bd2ddbd652fb0f08e20",
      "size_bytes": 8629961
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "451ed2bfc99fc33e0de6b09eb96f03914a194c91bcd0bda968048c2d5efa7e2d",
      "size_bytes": 131045
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "31de051ee7dfe8703a54c4ef91d68c59d9a08beb15eec5f0b26d4e344a6b57cd",
      "size_bytes": 8845657
    }
  },
  "github_run_id": "33731854100",
  "github_run_url": "https://github.com/leehack/llama-web-bridge/actions/runs/33731854100",
  "llama_cpp_commit": "c1d0e7a004015f23bc0233470b747b596f29b264",
  "llama_cpp_tag": "v0.3.0",
  "native_commit": "28fca14873d4b4c531bef4425b261e2b911bdcce",
  "native_manifest_sha256": "811fda999e70c3ad2716d1c196688dd38db62cf11a78044855ca94f71fabed45",
  "native_release_tag": "v0.3.0",
  "native_repository": "leehack/llamadart-native",
  "orchestrator_correlation_id": "auto-stable-v0.3.0-811fda999e70c3ad-build-eb5f166a4f9d118a",
  "qualification_gates": {
    "multimodal": "passed",
    "speech_to_text": "required-automated-qualification",
    "state_persistence": "passed",
    "text_to_speech": "required-automated-qualification"
  },
  "release_channel": "stable",
  "release_rebuild": 0,
  "release_tag": "v0.1.41",
  "schema_version": 2,
  "source_commit": "646037ac816c066d3f7d9e357139ca20800dc7ee",
  "source_repository": "leehack/llama-web-bridge",
  "unproven_capabilities": {
    "hardware_gpu_acceleration": "unavailable-on-hosted-runners",
    "real_device_intelligibility": "unproven",
    "real_device_playback": "unproven",
    "speaker_reference_fidelity": "unproven",
    "wasm32_text_to_speech": "unsupported"
  },
  "upstream_commit": "c1d0e7a004015f23bc0233470b747b596f29b264",
  "upstream_repository": "ggml-org/llama.cpp",
  "upstream_tag": "v0.3.0"
}
''';

Future<List<String>> _verifyManifestJson(
  String manifestJson, {
  String? expectedManifestSha256,
}) {
  final bytes = utf8.encode(manifestJson);
  return verifyManifest(
    expectedTag: 'v0.1.41',
    expectedLlamaCppTag: bridgeLlamaCppTag,
    expectedLlamaCppCommit: bridgeLlamaCppCommit,
    expectedBridgeCommit: bridgeSourceCommit,
    expectedNativeReleaseTag: bridgeNativeReleaseTag,
    expectedManifestSha256:
        expectedManifestSha256 ?? sha256.convert(bytes).toString(),
    fetcher: (_) async => ManifestResponse(HttpStatus.ok, bytes),
  );
}

String _currentReleaseNotes(String path) {
  final section = currentReleaseNotesSection(
    File(path).readAsStringSync(),
    readRootPackageVersion(Directory.current),
  );
  expect(
    section,
    isNotNull,
    reason: '$path has no current release-notes section',
  );
  return section!;
}

void main() {
  test(
    'aggregate gate runs offline checks and opt-in byte verification',
    () async {
      final bytes = utf8.encode(_approvedManifestJson);
      final repoRoot = Directory.current;

      expect(
        await findBridgeProblems(
          repoRoot,
          readPinnedBridgeTag(repoRoot),
          verifyPublishedManifest: true,
          manifestFetcher: (_) async => ManifestResponse(HttpStatus.ok, bytes),
        ),
        isEmpty,
      );
    },
  );

  test('the checked-in pins all quote the source of truth', () {
    final repoRoot = Directory.current;
    expect(
      findBridgeTagDrift(repoRoot, readPinnedBridgeTag(repoRoot)),
      isEmpty,
    );
  });

  test(
    'current release notes keep exact Web provenance and LiteRT separation',
    () {
      for (final path in const <String>[
        'CHANGELOG.md',
        'website/docs/changelog/recent-releases.md',
      ]) {
        final current = _currentReleaseNotes(path);
        expect(current, contains('`v0.1.41`'), reason: path);
        expect(current, contains(bridgeManifestSha256), reason: path);
        expect(
          current,
          contains('$bridgeLlamaCppTag@$bridgeLlamaCppCommit'),
          reason: path,
        );
        expect(current, contains(bridgeNativeReleaseTag), reason: path);
        expect(current, contains('@litert-lm/core@0.15.0'), reason: path);
      }

      expect(
        File('example/chat_app/web/index.html').readAsStringSync(),
        contains('@litert-lm/core@0.15.0/+esm'),
      );
      expect(
        File(nativeLlamaCppTagPath).readAsStringSync(),
        contains("const _litertLmReleaseTag = 'v0.16.0-native.2';"),
      );
    },
  );

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

  group('current release-notes section', () {
    /// A repo whose top release-notes section is headed [heading] and claims
    /// [currentTag], over a frozen `## 1.0.0` section claiming `v1.0.0`.
    Directory releaseNotesRepo(
      String heading, {
      String currentTag = 'v9.9.9',
      String currentClaim = 'Aligned the default WebGPU bridge assets to',
      String websiteClaim = 'Aligned default WebGPU bridge assets to',
    }) => _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        'CHANGELOG.md':
            '## $heading\n\n'
            '* $currentClaim `$currentTag`.\n\n'
            '## 1.0.0\n\n'
            '* Aligned the default WebGPU bridge assets to `v1.0.0`.\n',
        'website/docs/changelog/recent-releases.md':
            '## $heading\n\n'
            '- $websiteClaim `$currentTag`.\n\n'
            '## 1.0.0\n\n'
            '- Aligned default WebGPU bridge assets to `v1.0.0`.\n',
      },
    );

    test('accepts `## Unreleased` and ignores frozen release history', () {
      expect(
        findCurrentReleaseNotesDrift(releaseNotesRepo('Unreleased'), 'v9.9.9'),
        isEmpty,
      );
    });

    test('accepts the promoted `## <pubspec version>` heading', () {
      expect(
        findCurrentReleaseNotesDrift(releaseNotesRepo('1.2.3'), 'v9.9.9'),
        isEmpty,
      );
    });

    test('a heading naming another version is reported', () {
      expect(
        findCurrentReleaseNotesDrift(releaseNotesRepo('1.2.4'), 'v9.9.9'),
        everyElement(
          contains('the top section is neither `## Unreleased` nor `## 1.2.3`'),
        ),
      );
    });

    test('a stale tag in the current section is reported', () {
      expect(
        findCurrentReleaseNotesDrift(
          releaseNotesRepo('1.2.3', currentTag: 'v0.0.1'),
          'v9.9.9',
        ),
        everyElement(contains('pins v0.0.1, expected v9.9.9')),
      );
    });

    test('frozen history cannot satisfy a reworded current claim', () {
      expect(
        findCurrentReleaseNotesDrift(
          releaseNotesRepo(
            '1.2.3',
            currentClaim: 'Moved the WebGPU bridge assets to',
            websiteClaim: 'Moved the WebGPU bridge assets to',
          ),
          'v9.9.9',
        ),
        everyElement(
          contains(
            'matches 0 lines in the current release-notes section, expected 1',
          ),
        ),
      );
    });

    test('a duplicated claim in the current section is reported', () {
      final root = releaseNotesRepo('1.2.3');
      for (final pin in releaseNotesPins) {
        final file = File('${root.path}/${pin.path}');
        final line = pin.pattern.firstMatch(file.readAsStringSync())!.group(0)!;
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(line, '$line\n$line'),
        );
      }

      expect(
        findCurrentReleaseNotesDrift(root, 'v9.9.9'),
        everyElement(
          contains(
            'matches 2 lines in the current release-notes section, expected 1',
          ),
        ),
      );
    });

    test('a missing release-notes file fails instead of passing vacuously', () {
      expect(
        findCurrentReleaseNotesDrift(_fakeRepo('v9.9.9'), 'v9.9.9'),
        everyElement(contains('file is missing')),
      );
    });

    test('a missing root pubspec version fails closed', () {
      final root = releaseNotesRepo('Unreleased');
      File('${root.path}/$rootPubspecPath').writeAsStringSync('name: x\n');

      expect(
        findCurrentReleaseNotesDrift(root, 'v9.9.9'),
        contains(contains('Expected exactly one version field')),
      );
    });
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
    test('the checked-in repo agrees on upstream family parity', () {
      expect(
        findBridgeRuntimeDrift(Directory.current, bridgeLlamaCppTag),
        isEmpty,
      );
    });

    test('a malformed native wrapper tag is reported', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: 'v0.2.0',
        nativeTag: 'v0.2.0-custom',
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(contains('malformed native llama.cpp tag "v0.2.0-custom"')),
      );
    });

    test('a wrapper tag cannot masquerade as the upstream bridge tag', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-1');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0-1'),
        contains(
          'bridgeLlamaCppTag v0.2.0-1 is not a canonical upstream llama.cpp '
          'release tag',
        ),
      );
    });

    test('an upstream-family mismatch is reported', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.3.0-1');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          'bridge assets embed llama.cpp v0.2.0 but $nativeLlamaCppTagPath '
          'pins v0.3.0-1 (upstream family v0.3.0) — Web and native must share '
          'the same upstream llama.cpp release',
        ),
      );
    });

    test('a different wrapper in the same family is not the approved anchor', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-2');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          '$nativeLlamaCppTagPath pins v0.2.0-2, expected the bridge-qualified '
          'native anchor $bridgeNativeReleaseTag',
        ),
      );
    });

    test('stale divergence prose is reported', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: 'v0.2.0',
        nativeTag: 'v0.2.0-1',
        parityWording: false,
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0').join('\n'),
        contains('matches 0 lines, expected 1'),
      );
    });

    test('parity prose is accepted for matching upstream tags', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: 'v0.3.0',
        nativeTag: 'v0.3.0',
        parityWording: true,
      );

      expect(findBridgeRuntimeDrift(root, 'v0.3.0'), isEmpty);
    });

    test('a doc naming a different bridge build is reported', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: 'v0.1.0',
        nativeTag: 'v0.2.0-1',
        parityWording: true,
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains('doc/webgpu_bridge.md: states v0.1.0, expected v0.2.0'),
      );
    });

    test('a reworded parity sentence is reported rather than skipped', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: 'v0.2.0',
        nativeTag: 'v0.2.0-1',
        parityWording: true,
      );
      File('${root.path}/doc/webgpu_bridge.md').writeAsStringSync(
        'That release embeds llama.cpp `v0.2.0`, matching.\n',
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0').join('\n'),
        contains('matches 0 lines, expected 1'),
      );
    });

    test('a missing native pin fails instead of passing vacuously', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-1');
      File(
        '${root.path}/$nativeLlamaCppTagPath',
      ).writeAsStringSync('// nothing here\n');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          '$nativeLlamaCppTagPath: found 0 _llamaCppTag constants, expected '
          'exactly 1; the gate cannot identify the active native pin',
        ),
      );
    });

    test('duplicate native pin constants fail closed', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-1');
      File('${root.path}/$nativeLlamaCppTagPath').writeAsStringSync(
        "const _llamaCppTag = 'v0.2.0-1';\n"
        "const _llamaCppTag = 'v0.3.0-1';\n",
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          contains('found 2 _llamaCppTag constants, expected exactly 1'),
        ),
      );
    });

    test('an unreadable native pin is reported without throwing', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-1');
      final file = File('${root.path}/$nativeLlamaCppTagPath');
      expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
      addTearDown(() => Process.runSync('chmod', ['600', file.path]));

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(contains('$nativeLlamaCppTagPath: could not be read:')),
      );
    }, skip: Platform.isWindows ? 'requires POSIX file permissions' : false);

    test(
      'a recorded anchor outside the recorded upstream family is reported',
      () {
        // bridgeNativeReleaseTag is a constant, so drive the mismatch from the
        // other side: a tree whose bridge and native pins agree on a family the
        // checked-in anchor does not belong to.
        final root = _fakeRuntimeRepo(bridgeTag: 'v0.4.0', nativeTag: 'v0.4.0');

        expect(
          findBridgeRuntimeDrift(root, 'v0.4.0'),
          contains(
            contains(
              'bridgeNativeReleaseTag $bridgeNativeReleaseTag does not belong to '
              'the recorded upstream llama.cpp release v0.4.0',
            ),
          ),
        );
      },
    );
  });

  group('Pinned release provenance', () {
    test('the checked-in docs restate the pinned provenance', () {
      expect(findBridgeProvenanceDrift(Directory.current), isEmpty);
    });

    test('immutable release identity stays pinned to the approved release', () {
      expect(bridgeAssetsReleaseId, '381873266');
      expect(bridgeAssetsTagCommit, 'dca41da58a689697f3b532f09da5aa1672e24e93');
    });

    test('accepts equivalent CRLF documentation passages', () {
      final root = Directory.systemTemp.createTempSync(
        'bridge_provenance_crlf',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      for (final pin in bridgeProvenancePins) {
        final source = File(pin.path).readAsStringSync();
        final crlfSource = source
            .replaceAll('\r\n', '\n')
            .replaceAll('\n', '\r\n');
        File('${root.path}/${pin.path}')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(crlfSource);
      }

      expect(findBridgeProvenanceDrift(root), isEmpty);
    });

    test('a doc restating a stale provenance value is reported', () {
      final root = Directory.systemTemp.createTempSync('bridge_provenance');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final pin in bridgeProvenancePins) {
        final source = File(pin.path).readAsStringSync();
        final passage = pin.pattern.firstMatch(source)!.group(0)!;
        File('${root.path}/${pin.path}')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${passage.replaceFirst(bridgeManifestSha256, 'a' * 64)}\n',
          );
      }

      expect(
        findBridgeProvenanceDrift(root),
        everyElement(
          contains(
            'states manifestSha256 ${'a' * 64}, expected '
            '$bridgeManifestSha256',
          ),
        ),
      );
    });

    test('a reworded provenance passage is reported rather than skipped', () {
      final root = Directory.systemTemp.createTempSync('bridge_provenance');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final pin in bridgeProvenancePins) {
        File('${root.path}/${pin.path}')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('Built from some release, trust us.\n');
      }

      expect(
        findBridgeProvenanceDrift(root),
        everyElement(contains('matches 0 lines, expected 1')),
      );
    });

    test('a missing provenance doc fails instead of passing vacuously', () {
      final root = Directory.systemTemp.createTempSync('bridge_provenance');
      addTearDown(() => root.deleteSync(recursive: true));

      expect(
        findBridgeProvenanceDrift(root),
        everyElement(contains('file is missing')),
      );
    });
  });

  group('Remote manifest machine verification', () {
    test('verifies success for the exact approved manifest', () async {
      // Deliberately the production constants, not literals: the fixture is
      // the only offline proof that they describe the approved bytes, and
      // repeating them here would let a half-finished bump still pass.
      final bytes = utf8.encode(_approvedManifestJson);
      final errors = await verifyManifest(
        expectedTag: readPinnedBridgeTag(Directory.current),
        expectedLlamaCppTag: bridgeLlamaCppTag,
        expectedLlamaCppCommit: bridgeLlamaCppCommit,
        expectedBridgeCommit: bridgeSourceCommit,
        expectedNativeReleaseTag: bridgeNativeReleaseTag,
        expectedManifestSha256: bridgeManifestSha256,
        fetcher: (_) async => ManifestResponse(HttpStatus.ok, bytes),
      );

      expect(errors, isEmpty);
    });

    test(
      'an alias-only manifest no longer satisfies the required fields',
      () async {
        // The published manifest carries a legacy alias for each of these four
        // fields; dropping the canonical names must fail rather than fall back.
        final aliasOnly =
            jsonDecode(_approvedManifestJson) as Map<String, dynamic>;
        aliasOnly.remove('release_tag');
        aliasOnly.remove('upstream_tag');
        aliasOnly.remove('upstream_commit');
        aliasOnly.remove('bridge_commit');
        final manifestJson = jsonEncode(aliasOnly);
        final errors = await _verifyManifestJson(manifestJson);

        expect(
          errors,
          allOf(
            contains(contains('release_tag is missing or empty')),
            contains(contains('upstream_tag is missing or empty')),
            contains(contains('upstream_commit is missing or empty')),
            contains(contains('bridge_commit is missing or empty')),
          ),
        );
      },
    );

    test('conflicting legacy provenance aliases fail closed', () async {
      for (final alias in const <String>[
        'bridge_assets_tag',
        'source_repository',
        'source_commit',
        'llama_cpp_tag',
        'llama_cpp_commit',
      ]) {
        final manifestJson = jsonEncode(<String, dynamic>{
          ...jsonDecode(_approvedManifestJson) as Map<String, dynamic>,
          alias: 'conflict',
        });
        final errors = await _verifyManifestJson(manifestJson);

        expect(
          errors,
          contains(contains('conflicting provenance aliases')),
          reason: '$alias conflict was accepted',
        );
      }
    });

    test('reports mismatching manifest SHA-256 hash', () async {
      final errors = await _verifyManifestJson(
        _approvedManifestJson,
        expectedManifestSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );

      expect(errors, hasLength(greaterThanOrEqualTo(1)));
      expect(errors.first, contains('manifest SHA-256 is'));
    });

    test('rejects drift in every canonical provenance field', () async {
      for (final mutation in <String, Object>{
        'schema_version': 1,
        'release_tag': 'v0.1.38',
        'assets_repository': 'fork/llama-web-bridge-assets',
        'bridge_repository': 'fork/llama-web-bridge',
        'bridge_commit': '2' * 40,
        'upstream_repository': 'fork/llama.cpp',
        'upstream_tag': 'v0.1.9',
        'upstream_commit': '1' * 40,
        'native_repository': 'fork/llamadart-native',
        'native_release_tag': 'v0.1.0-1',
      }.entries) {
        final manifestJson = jsonEncode(<String, dynamic>{
          ...jsonDecode(_approvedManifestJson) as Map<String, dynamic>,
          mutation.key: mutation.value,
        });
        final errors = await _verifyManifestJson(manifestJson);

        expect(
          errors,
          contains(contains('reports ${mutation.key} ${mutation.value}')),
          reason: '${mutation.key} drift was accepted',
        );
      }
    });

    test('HTTP error response is reported without throwing', () async {
      final errors = await verifyManifest(
        expectedTag: 'v0.1.39',
        expectedLlamaCppTag: 'v0.2.0',
        expectedLlamaCppCommit: 'bb4caa7540188872173c44d161602d9271386413',
        expectedBridgeCommit: '79b6ef31e394dd2de92a456b7c249f9da377c720',
        expectedNativeReleaseTag: 'v0.2.0-1',
        expectedManifestSha256: bridgeManifestSha256,
        fetcher: (_) async =>
            const ManifestResponse(HttpStatus.notFound, <int>[]),
      );

      expect(errors, hasLength(1));
      expect(errors.single, contains('returned HTTP 404'));
    });

    test(
      'malformed remote manifest JSON is reported without throwing',
      () async {
        final errors = await _verifyManifestJson(
          '{not-json',
          expectedManifestSha256: bridgeManifestSha256,
        );

        expect(errors, hasLength(greaterThanOrEqualTo(1)));
        expect(errors.join('\n'), contains('returned invalid manifest JSON'));
      },
    );

    test('a stalled remote manifest request times out', () async {
      final pending = Completer<ManifestResponse>();

      final errors = await verifyManifest(
        expectedTag: 'v0.1.39',
        expectedLlamaCppTag: 'v0.2.0',
        expectedLlamaCppCommit: 'bb4caa7540188872173c44d161602d9271386413',
        expectedBridgeCommit: '79b6ef31e394dd2de92a456b7c249f9da377c720',
        expectedNativeReleaseTag: 'v0.2.0-1',
        expectedManifestSha256: bridgeManifestSha256,
        fetcher: (_) => pending.future,
        timeout: const Duration(milliseconds: 50),
      );

      expect(errors, hasLength(1));
      expect(errors.single, contains('timed out reading'));
    });

    test('an oversized manifest response fails before validation', () async {
      final errors = await verifyManifest(
        expectedTag: 'v0.1.39',
        expectedLlamaCppTag: 'v0.2.0',
        expectedLlamaCppCommit: 'bb4caa7540188872173c44d161602d9271386413',
        expectedBridgeCommit: '79b6ef31e394dd2de92a456b7c249f9da377c720',
        expectedNativeReleaseTag: 'v0.2.0-1',
        expectedManifestSha256: bridgeManifestSha256,
        maximumBytes: 16,
        fetcher: (_) async =>
            ManifestResponse(HttpStatus.ok, List<int>.filled(17, 0)),
      );

      expect(errors.single, contains('exceeds the 16-byte limit'));
    });
  });
}
