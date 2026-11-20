@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/hook/native_release_tag.dart';
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
    nativeLlamaCppTagPath: "const llamaCppTag = '$nativeTag';\n",
    'example/chat_app/web/index.html':
        "    const defaultBridgeLlamaCppTag = '$bridgeTag';\n",
    'packages/llamadart_studio/web/index.html':
        "    const defaultBridgeLlamaCppTag = '$bridgeTag';\n",
    'doc/webgpu_bridge.md': parityWording
        ? 'That release embeds llama.cpp `$bridgeTag`, matching the '
              '`hook/build.dart` native pin\n'
        : 'That release embeds llama.cpp `$bridgeTag`, which now trails the '
              '`hook/build.dart`\n',
    'website/docs/platforms/webgpu-bridge.md': parityWording
        ? '- The pinned `v1.2.3` bridge assets embed llama.cpp `$bridgeTag`, matching '
              'the native runtime `$nativeTag`.\n'
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
      "sha256": "84730f301d6973d9948d84fb20f71e0832082771f1673ef84e5ecf68ffa6e98b",
      "size_bytes": 25422
    },
    "llama_webgpu_bridge.js": {
      "sha256": "92b1a085bb4eb4eff4fc38243326fab5e56e941d7b0e462b3d2fe6a33f9a6042",
      "size_bytes": 360701
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
      "size_bytes": 257
    },
    "llama_webgpu_core.js": {
      "sha256": "50e522cb6f007c257e67310a26ffa62913df7f38a9dde9656857791199f93880",
      "size_bytes": 133222
    },
    "llama_webgpu_core.wasm": {
      "sha256": "3848c51103a434e0b51a722320a6e0ff7e9057855cd7dfb80e932eb97e0d0813",
      "size_bytes": 11107296
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "95a0f9586eafd379e837b5a421ae48e0abe1c96ddc07ac3f16ffe0ff3ecdfbb8",
      "size_bytes": 156444
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "e86990e6296414c1bbeee560402a7548f39f39b0865e9105df1d78f57ef8da1e",
      "size_bytes": 11434866
    },
    "llama_webgpu_core_mem64_st.js": {
      "sha256": "2411c1ec42395b87ff15661b57f8e957a14e3860e81b73eb20d2624787bd75fc",
      "size_bytes": 134332
    },
    "llama_webgpu_core_mem64_st.wasm": {
      "sha256": "9e4898e26deccdf75d5438b11718bfb4d77e6414d57cefdf531fbc50a21e449d",
      "size_bytes": 10754409
    },
    "llama_webgpu_core_st.js": {
      "sha256": "8e5dad3d998260409a7cc175bfa12bf3706554f6925001689717c7b5efb35659",
      "size_bytes": 112971
    },
    "llama_webgpu_core_st.wasm": {
      "sha256": "33ab5bf22e96077be415082d6d698624d0f2b4930b93413c6847e8b32420dcbd",
      "size_bytes": 10465506
    }
  },
  "assets_repository": "leehack/llama-web-bridge-assets",
  "bridge_assets_tag": "v0.1.87",
  "bridge_commit": "3cf2aaed32acefade1ea603748d3dedb760125bd",
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
      "sha256": "84730f301d6973d9948d84fb20f71e0832082771f1673ef84e5ecf68ffa6e98b",
      "size_bytes": 25422
    },
    "llama_webgpu_bridge.js": {
      "sha256": "92b1a085bb4eb4eff4fc38243326fab5e56e941d7b0e462b3d2fe6a33f9a6042",
      "size_bytes": 360701
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
      "size_bytes": 257
    },
    "llama_webgpu_core.js": {
      "sha256": "50e522cb6f007c257e67310a26ffa62913df7f38a9dde9656857791199f93880",
      "size_bytes": 133222
    },
    "llama_webgpu_core.wasm": {
      "sha256": "3848c51103a434e0b51a722320a6e0ff7e9057855cd7dfb80e932eb97e0d0813",
      "size_bytes": 11107296
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "95a0f9586eafd379e837b5a421ae48e0abe1c96ddc07ac3f16ffe0ff3ecdfbb8",
      "size_bytes": 156444
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "e86990e6296414c1bbeee560402a7548f39f39b0865e9105df1d78f57ef8da1e",
      "size_bytes": 11434866
    },
    "llama_webgpu_core_mem64_st.js": {
      "sha256": "2411c1ec42395b87ff15661b57f8e957a14e3860e81b73eb20d2624787bd75fc",
      "size_bytes": 134332
    },
    "llama_webgpu_core_mem64_st.wasm": {
      "sha256": "9e4898e26deccdf75d5438b11718bfb4d77e6414d57cefdf531fbc50a21e449d",
      "size_bytes": 10754409
    },
    "llama_webgpu_core_st.js": {
      "sha256": "8e5dad3d998260409a7cc175bfa12bf3706554f6925001689717c7b5efb35659",
      "size_bytes": 112971
    },
    "llama_webgpu_core_st.wasm": {
      "sha256": "33ab5bf22e96077be415082d6d698624d0f2b4930b93413c6847e8b32420dcbd",
      "size_bytes": 10465506
    }
  },
  "github_run_id": "44803716338",
  "github_run_url": "https://github.com/leehack/llama-web-bridge/actions/runs/44803716338",
  "llama_cpp_commit": "b1b770d90d94cad9e9ea5b993bdbc383a522fb28",
  "llama_cpp_tag": "v1.0.0",
  "native_commit": "962c7ae5a46ffb1f6bbd39d3b1141901e0248da5",
  "native_manifest_sha256": "ba923f1a3838e237397e8c24fd319ea3637ed96a304639bce3f7b9f655b205e5",
  "native_release_tag": "v1.0.0-3",
  "native_repository": "leehack/llamadart-native",
  "orchestrator_correlation_id": "w1949b-v0.1.87-3cf2aae",
  "qualification_gates": {
    "multimodal": "passed",
    "speech_to_text": "required-automated-qualification",
    "state_persistence": "passed",
    "text_to_speech": "required-automated-qualification"
  },
  "release_channel": "stable",
  "release_rebuild": 0,
  "release_tag": "v0.1.87",
  "schema_version": 2,
  "source_commit": "3cf2aaed32acefade1ea603748d3dedb760125bd",
  "source_repository": "leehack/llama-web-bridge",
  "unproven_capabilities": {
    "hardware_gpu_acceleration": "unavailable-on-hosted-runners",
    "real_device_intelligibility": "unproven",
    "real_device_playback": "unproven",
    "speaker_reference_fidelity": "unproven",
    "wasm32_text_to_speech": "unsupported"
  },
  "upstream_commit": "b1b770d90d94cad9e9ea5b993bdbc383a522fb28",
  "upstream_repository": "ggml-org/llama.cpp",
  "upstream_tag": "v1.0.0"
}
''';

Future<List<String>> _verifyManifestJson(
  String manifestJson, {
  String? expectedManifestSha256,
}) {
  final bytes = utf8.encode(manifestJson);
  return verifyManifest(
    expectedTag: 'v0.1.87',
    expectedLlamaCppTag: bridgeLlamaCppTag,
    expectedLlamaCppCommit: bridgeLlamaCppCommit,
    expectedBridgeCommit: bridgeSourceCommit,
    expectedNativeReleaseTag: bridgeNativeReleaseTag,
    expectedManifestSha256:
        expectedManifestSha256 ?? sha256.convert(bytes).toString(),
    fetcher: (_) async => ManifestResponse(HttpStatus.ok, bytes),
  );
}

String _publishedReleaseNotes(String path) {
  final section = currentReleaseNotesSection(
    File(path).readAsStringSync(),
    '0.20.2',
  );
  expect(
    section,
    isNotNull,
    reason: '$path has no current release-notes section',
  );
  return section!;
}

const _preparedNativePins =
    "const llamaCppTag = 'v1.0.0-3';\n"
    "const liteRtLmReleaseTag = 'v0.19.1-5';\n"
    "const stableDiffusionReleaseTag = 'v0.4.0';\n";

const _keptBridgeClaim =
    '- Keep the default WebGPU bridge assets at `v9.9.9` (unchanged from 1.2.2).';
const _preparedBaseline =
    'Runtime baseline: native llama.cpp `v1.0.0-3` and Web use '
    'upstream `$bridgeLlamaCppTag@$bridgeLlamaCppCommit`; native LiteRT-LM uses '
    '`v0.19.1-5` and stable-diffusion uses `v0.4.0`. '
    'Web LiteRT-LM uses `@litert-lm/core@0.19.0`. Manifest SHA-256: `$bridgeManifestSha256`.';

const _preparedChangelogs = [
  'CHANGELOG.md',
  'website/docs/changelog/recent-releases.md',
];

Directory _preparedReleaseRepo([String claim = _keptBridgeClaim]) => _fakeRepo(
  'v9.9.9',
  files: {
    'example/chat_app/web/index.html':
        'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.19.0/+esm',
    nativeLlamaCppTagPath: _preparedNativePins,
    for (final (index, path) in _preparedChangelogs.indexed)
      path:
          '## 1.2.3\n\n'
          '${index == 0 ? claim : claim.replaceFirst('the default', 'default')}\n\n'
          '$_preparedBaseline\n',
  },
);

List<String> _verifyPreparedRelease(
  Directory root, {
  String previousBridge = 'v9.9.9',
  String previousNativePins = _preparedNativePins,
}) => findPreparedReleaseNotesDrift(
  root,
  'v9.9.9',
  '1.2.2',
  previousBridge,
  previousNativePins: previousNativePins,
);

void main() {
  test(
    'strict prep requires the exact prior version and full runtime baseline',
    () {
      final root = _preparedReleaseRepo();
      expect(_verifyPreparedRelease(root), isEmpty);
      expect(
        _verifyPreparedRelease(root, previousBridge: 'v9.9.8'),
        isNotEmpty,
      );
      final changelog = File('${root.path}/CHANGELOG.md');
      final valid = changelog.readAsStringSync();
      for (final wrong in [
        valid.replaceFirst('1.2.2', '1.2.1'),
        '${valid.replaceFirst('## 1.2.3', '## 1.2.1')}\n'
            '## 1.2.3\n\n- Candidate without bridge evidence.\n',
        valid.replaceFirst(
          _keptBridgeClaim,
          '$_keptBridgeClaim\n$_keptBridgeClaim',
        ),
        valid.replaceFirst(_preparedBaseline, ''),
        '$valid$_preparedBaseline\n',
        valid.replaceFirst('@litert-lm/core@0.19.0', '@litert-lm/core@0.18.0'),
        valid.replaceFirst(
          bridgeManifestSha256,
          '0000000000000000000000000000000000000000000000000000000000000000',
        ),
        valid.replaceFirst(
          bridgeLlamaCppCommit,
          '2222222222222222222222222222222222222222',
        ),
      ]) {
        changelog.writeAsStringSync(wrong);
        expect(_verifyPreparedRelease(root), isNotEmpty, reason: wrong);
      }
    },
  );

  for (final path in _preparedChangelogs) {
    test(
      'strict prep rejects an unchanged suffix on a changed bridge in $path',
      () {
        final root = _preparedReleaseRepo(
          '- Aligned the default WebGPU bridge assets to `v9.9.9`.',
        );
        List<String> verify() =>
            _verifyPreparedRelease(root, previousBridge: 'v9.9.8');
        expect(verify(), isEmpty);

        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync(
          changelog.readAsStringSync().replaceFirst(
            '`v9.9.9`.',
            '`v9.9.9` (unchanged from 1.2.2).',
          ),
        );
        expect(verify(), contains(startsWith('$path ')));
      },
    );
  }

  for (final path in _preparedChangelogs) {
    for (final (runtime, pin, previousPin) in [
      ('native llama.cpp', 'v1.0.0-3', 'v1.0.0-2'),
      ('LiteRT-LM', 'v0.19.1-5', 'v0.19.1-4'),
      ('stable-diffusion', 'v0.4.0', 'v0.3.0'),
    ]) {
      test(
        'strict prep verifies $runtime retention against the previous pins in $path',
        () {
          final root = _preparedReleaseRepo();
          final changelog = File('${root.path}/$path');
          final original = changelog.readAsStringSync();
          final previousPins = _preparedNativePins.replaceFirst(
            pin,
            previousPin,
          );
          List<String> verify(String prior) =>
              _verifyPreparedRelease(root, previousNativePins: prior);
          expect(verify(previousPins), isEmpty);

          changelog.writeAsStringSync(
            original.replaceFirst('`$pin`', '`$pin` (unchanged from 1.2.2)'),
          );
          expect(verify(_preparedNativePins), isEmpty);
          expect(verify(previousPins), contains(startsWith('$path ')));

          changelog.writeAsStringSync(
            original.replaceFirst('`$pin`', '`$pin` (unchanged from 1.2.1)'),
          );
          expect(verify(_preparedNativePins), contains(startsWith('$path ')));
        },
      );
    }
  }

  test('default assets include the qualified media embedding API', () {
    expect(readPinnedBridgeTag(Directory.current), 'v0.1.87');
    expect(bridgeNativeReleaseTag, 'v1.0.0-3');
    expect(bridgeApprovedNativePin, 'v1.0.0-3');
    expect(
      normalizeNativeLlamaCppTag(bridgeApprovedNativePin),
      bridgeLlamaCppTag,
    );
  });

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
          releaseFetcher: _FakeGitHub.pinned().fetch,
        ),
        isEmpty,
      );
    },
  );

  test('tracked Studio bootstrap pins are registered and cannot drift', () {
    const path = 'packages/llamadart_studio/web/index.html';
    final root = _fakeRepo(
      'v9.9.9',
      files: {path: "const defaultBridgeAssetsTag = 'v9.9.9';\n"},
    );
    Process.runSync('git', ['init', '--quiet'], workingDirectory: root.path);
    Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
    expect(findUnregisteredTagSites(root, 'v9.9.9'), isEmpty);
    File(
      '${root.path}/$path',
    ).writeAsStringSync("const defaultBridgeAssetsTag = 'v9.9.8';\n");
    expect(findBridgeTagDrift(root, 'v9.9.9'), contains(contains('$path:')));
  });

  test('the checked-in pins all quote the source of truth', () {
    final repoRoot = Directory.current;
    expect(
      findBridgeTagDrift(repoRoot, readPinnedBridgeTag(repoRoot)),
      isEmpty,
    );
  });

  test('LiteRtLmBackend names the LiteRT-LM module the chat app loads', () {
    final chatAppDefault = RegExp(
      r"'(https://cdn\.jsdelivr\.net/npm/(@litert-lm/core@[^/']+)/\+esm)'",
    ).firstMatch(File('example/chat_app/web/index.html').readAsStringSync())!;
    final backend = File(
      'lib/src/backends/litert_lm/litert_lm_backend_web.dart',
    ).readAsStringSync();

    expect(backend, contains('/// `${chatAppDefault[1]}`.'));
    expect(
      RegExp(
        r'@litert-lm/core@\d+\.\d+\.\d+',
      ).allMatches(backend).map((m) => m[0]).toSet(),
      {chatAppDefault[2]},
    );
  });

  test(
    'v0.20.2 release notes keep exact Web provenance and LiteRT separation',
    () {
      const path =
          'website/versioned_docs/version-0.20.2/changelog/recent-releases.md';
      final shipped = _publishedReleaseNotes(path);
      expect(shipped, contains('`v0.1.86`'));
      expect(
        shipped,
        contains('v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28'),
      );
      expect(shipped, contains('native llama.cpp `v1.0.0-3`'));
      expect(shipped, contains('@litert-lm/core@0.19.0'));
      expect(
        shipped,
        contains(
          'd589fbe3c334e4fcb0ccbac3efc4500209358a010b6662ee8523e598a433a0f2',
        ),
      );
    },
  );

  test('Playwright helpers wrap the LiteRT-LM module the chat app loads', () {
    List<String> moduleUrls(String path) => RegExp(
      r"'(https://cdn\.jsdelivr\.net/npm/@litert-lm/core@[^']+)'",
    ).allMatches(File(path).readAsStringSync()).map((m) => m[1]!).toList();

    final chatAppDefault = moduleUrls('example/chat_app/web/index.html');
    expect(chatAppDefault, hasLength(1));
    // The helpers install their wrapper before index.html runs, so their own
    // default is the module a smoke or benchmark loads.
    for (final helper in const <String>[
      'tool/testing/playwright_chat_app_real_model_smoke.py',
      'tool/testing/playwright_chat_app_benchmark.py',
    ]) {
      expect(moduleUrls(helper), chatAppDefault, reason: helper);
    }
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

    test('accepts a `-` bullet in the changelog claim', () {
      final root = releaseNotesRepo('Unreleased');
      final changelog = File('${root.path}/CHANGELOG.md');
      changelog.writeAsStringSync(
        changelog.readAsStringSync().replaceFirst('* Aligned', '- Aligned'),
      );
      expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), isEmpty);
    });

    test('accepts the promoted `## <pubspec version>` heading', () {
      expect(
        findCurrentReleaseNotesDrift(releaseNotesRepo('1.2.3'), 'v9.9.9'),
        isEmpty,
      );
    });

    test(
      'unrelated Unreleased notes retain the exact current released pin',
      () {
        final root = releaseNotesRepo('1.2.3');
        for (final pin in releaseNotesPins) {
          final file = File('${root.path}/${pin.path}');
          file.writeAsStringSync(
            '## Unreleased\n\n* Fix Apple dependency scanning.\n\n'
            'WebGPU bridge assets are unchanged.\n\n${file.readAsStringSync()}',
          );
        }
        expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), isEmpty);
        expect(findCurrentReleaseNotesDrift(root, 'v8.8.8'), isNotEmpty);
      },
    );

    test('pin-free Unreleased cannot borrow another historical version', () {
      final root = releaseNotesRepo('1.0.0');
      for (final pin in releaseNotesPins) {
        final file = File('${root.path}/${pin.path}');
        file.writeAsStringSync(
          '## Unreleased\n\n* Apple fix.\n${file.readAsStringSync()}',
        );
      }
      expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
      for (final pin in releaseNotesPins) {
        File(
          '${root.path}/${pin.path}',
        ).writeAsStringSync('## Unreleased\n\n* Apple fix.\n');
      }
      expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
    });

    for (final claim in [
      'Aligned default WebGPU bridge assets to `v0.0.1`.',
      'Moved WebGPU bridge assets to an invalid tag.',
      'Aligned default WebGPU bridge assets to `v9.9.9`.\n- Moved WebGPU bridge assets to malformed.',
      'Aligned default WebGPU bridge assets to `v9.9.9`.\n- Aligned default WebGPU bridge assets to `v9.9.9`.',
    ]) {
      test('Unreleased claim cannot hide behind released history: $claim', () {
        final root = releaseNotesRepo('1.2.3');
        for (final pin in releaseNotesPins) {
          final file = File('${root.path}/${pin.path}');
          final currentClaim = pin.path == 'CHANGELOG.md'
              ? claim
                    .replaceAll(
                      'Aligned default WebGPU',
                      'Aligned the default WebGPU',
                    )
                    .replaceAll('\n- ', '\n* ')
              : claim;
          final bullet = pin.path == 'CHANGELOG.md' ? '*' : '-';
          file.writeAsStringSync(
            '## Unreleased\n\n$bullet $currentClaim\n\n'
            '${file.readAsStringSync()}',
          );
        }
        expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
      });
    }

    Directory baselineRepo(String heading, {String tag = 'v9.9.9'}) {
      final root = releaseNotesRepo(heading);
      for (final pin in releaseNotesPins) {
        final file = File('${root.path}/${pin.path}');
        final claim = pin.path == 'CHANGELOG.md'
            ? '* Keep the default WebGPU bridge assets at'
            : '- Keep default WebGPU bridge assets at';
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            RegExp(r'^[*-] Aligned[^\n]*', multiLine: true),
            '$claim `$tag` (unchanged from 1.2.2).',
          ),
        );
      }
      return root;
    }

    for (final heading in ['Unreleased', '1.2.3']) {
      test('accepts an explicit unchanged bridge baseline in $heading', () {
        expect(
          findCurrentReleaseNotesDrift(baselineRepo(heading), 'v9.9.9'),
          isEmpty,
        );
      });

      test('a stale unchanged baseline in $heading fails', () {
        expect(
          findCurrentReleaseNotesDrift(
            baselineRepo(heading, tag: 'v0.0.1'),
            'v9.9.9',
          ),
          [
            for (final pin in releaseNotesPins)
              '${pin.path}: pins v0.0.1, expected v9.9.9',
          ],
        );
      });

      for (final extra in [
        'Keep default WebGPU bridge assets at `v9.9.9` (unchanged from 1.2.2).',
        'Aligned default WebGPU bridge assets to `v9.9.9`.',
        'Moved WebGPU bridge assets to malformed.',
      ]) {
        test('$heading baseline cannot hide an additional claim: $extra', () {
          final root = baselineRepo(heading);
          for (final pin in releaseNotesPins) {
            final file = File('${root.path}/${pin.path}');
            final bullet = pin.path == 'CHANGELOG.md' ? '*' : '-';
            final claim = pin.path == 'CHANGELOG.md'
                ? extra.replaceFirst('default WebGPU', 'the default WebGPU')
                : extra;
            file.writeAsStringSync(
              file.readAsStringSync().replaceFirst(
                '\n\n',
                '\n\n$bullet $claim\n',
              ),
            );
          }
          expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
        });
      }

      for (final malformed in [
        ' (unchanged from 1.2.2)',
        ' (unchanged from older releases).',
        ' (unchanged from 1.2.2). Extra claim.',
        '.',
      ]) {
        test('$heading baseline requires its complete wording: $malformed', () {
          final root = baselineRepo(heading);
          for (final pin in releaseNotesPins) {
            final file = File('${root.path}/${pin.path}');
            file.writeAsStringSync(
              file.readAsStringSync().replaceFirst(
                ' (unchanged from 1.2.2).',
                malformed,
              ),
            );
          }
          expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
        });
      }
    }

    test('live pin checks ignore a frozen release baseline', () {
      final root = baselineRepo('1.2.3', tag: 'v0.0.1');
      expect(
        findBridgeTagDrift(root, 'v9.9.9'),
        isNot(contains(contains('CHANGELOG.md'))),
      );
    });

    test('a promoted pin-free section cannot borrow a frozen baseline', () {
      final root = baselineRepo('1.2.3');
      for (final pin in releaseNotesPins) {
        final file = File('${root.path}/${pin.path}');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            RegExp(r'^[*-] Keep[^\n]*\n', multiLine: true),
            '',
          ),
        );
      }
      expect(findCurrentReleaseNotesDrift(root, 'v9.9.9'), hasLength(2));
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

  test('frozen validation journals do not exempt adjacent live tag sites', () {
    const historyPaths = <String>[
      'packages/llamadart_validation/test/fixtures/windows_native_log/chat.events.jsonl',
      'packages/llamadart_validation/test/fixtures/windows_native_log/tiny.events.jsonl',
      'packages/llamadart_validation/test/fixtures/android_logcat/galaxys24-gemma4-litert-gpu.events.jsonl',
      'packages/llamadart_validation/test/fixtures/android_logcat/pixel9pro-gemma4-litert-gpu.events.jsonl',
    ];
    const livePath =
        'packages/llamadart_validation/test/fixtures/windows_native_log/current.json';
    final root = _fakeRepo(
      'v0.1.63',
      files: <String, String>{
        for (final path in historyPaths)
          path: '{"bridge_assets_tag":"v0.1.63"}\r\n',
        livePath: '{"bridge_assets_tag":"v0.1.63"}\n',
      },
    );
    Process.runSync('git', <String>[
      'init',
      '--quiet',
    ], workingDirectory: root.path);
    Process.runSync('git', <String>['add', '-A'], workingDirectory: root.path);

    final unregistered = findUnregisteredTagSites(root, 'v0.1.63');
    expect(unregistered, hasLength(1));
    expect(unregistered.single, startsWith('$livePath:1:'));
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

  group('runtime baseline paragraph', () {
    const commit = bridgeLlamaCppCommit;
    String paragraph({
      String llama = 'v0.9.0',
      String liteRt = 'v0.19.1-5',
      String sd = 'v0.3.0-3',
      String upstream = '$bridgeLlamaCppTag@$commit',
      String liteRtVerb = 'uses',
    }) =>
        'Runtime baseline: native llama.cpp `$llama` and Web use upstream '
        '`$upstream`; native LiteRT-LM $liteRtVerb `$liteRt` and '
        'stable-diffusion uses `$sd`. Web LiteRT-LM uses '
        '`@litert-lm/core@0.19.0`.\n';

    Directory baselineRepo({
      String changelog = '',
      String docs = '',
      String heading = '1.2.3',
    }) => _fakeRepo(
      'v9.9.9',
      files: <String, String>{
        nativeLlamaCppTagPath:
            "const llamaCppTag = 'v0.9.0';\n"
            "const liteRtLmReleaseTag = 'v0.19.1-5';\n"
            "const stableDiffusionReleaseTag = 'v0.3.0-3';\n",
        'CHANGELOG.md': '## $heading\n\n- Fix.\n\n$changelog',
        'website/docs/changelog/recent-releases.md':
            '## $heading\n\n- Fix.\n\n$docs',
      },
    );

    test('accepts a paragraph that matches the pins', () {
      final root = baselineRepo(
        changelog: paragraph(),
        docs: paragraph(liteRtVerb: 'stays'),
      );
      expect(findRuntimeBaselineDrift(root), isEmpty);
    });

    test('a section without the paragraph is skipped', () {
      expect(findRuntimeBaselineDrift(baselineRepo()), isEmpty);
    });

    for (final (name, mutated, label) in <(String, String, String)>[
      ('llama.cpp', paragraph(llama: 'v0.9.1'), 'native llama.cpp v0.9.1'),
      (
        'LiteRT-LM',
        paragraph(liteRt: 'v0.19.1-3'),
        'native LiteRT-LM v0.19.1-3',
      ),
      (
        'stable-diffusion',
        paragraph(sd: 'v0.3.0-2'),
        'stable-diffusion v0.3.0-2',
      ),
      (
        'Web upstream',
        paragraph(upstream: 'v0.9.1@$commit'),
        'Web upstream llama.cpp v0.9.1@$commit',
      ),
    ]) {
      test('a mutated $name tag fails', () {
        final root = baselineRepo(changelog: mutated, docs: paragraph());
        expect(
          findRuntimeBaselineDrift(root),
          [
            contains('CHANGELOG.md'),
          ].map((m) => allOf(m, contains(label))).toList(),
        );
      });
    }

    test('a mutated paragraph in the docs changelog fails', () {
      final root = baselineRepo(
        changelog: paragraph(),
        docs: paragraph(sd: 'v0.3.0-2'),
      );
      expect(findRuntimeBaselineDrift(root), [
        allOf(
          contains('website/docs/changelog/recent-releases.md'),
          contains('stable-diffusion v0.3.0-2'),
        ),
      ]);
    });

    test('a mutated Web upstream commit fails', () {
      final other = 'a' * 40;
      final root = baselineRepo(
        changelog: paragraph(upstream: '$bridgeLlamaCppTag@$other'),
        docs: paragraph(),
      );
      expect(findRuntimeBaselineDrift(root), [
        contains('$bridgeLlamaCppTag@$other'),
      ]);
    });

    test('a duplicated paragraph fails', () {
      final root = baselineRepo(
        changelog: paragraph() + paragraph(),
        docs: paragraph(),
      );
      expect(findRuntimeBaselineDrift(root), [
        allOf(contains('CHANGELOG.md'), contains('2 Runtime baseline')),
      ]);
    });

    test('normal live checks ignore the shipped baseline', () async {
      final root = baselineRepo(
        changelog: paragraph(sd: 'v0.3.0-2'),
        docs: paragraph(),
      );
      expect(
        await findBridgeProblems(root, 'v9.9.9'),
        isNot(contains(contains('Runtime baseline names stable-diffusion'))),
      );
    });
    group('with a released section below Unreleased', () {
      Directory cycleRepo({
        String unreleased = '',
        String liteRtPin = 'v0.19.1-6',
        String released = '',
      }) {
        final changelog =
            '## Unreleased\n\n$unreleased\n## 1.2.3\n\n- Fix.\n\n$released';
        return _fakeRepo(
          'v9.9.9',
          files: <String, String>{
            nativeLlamaCppTagPath:
                "const llamaCppTag = 'v0.9.0';\n"
                "const liteRtLmReleaseTag = '$liteRtPin';\n"
                "const stableDiffusionReleaseTag = 'v0.3.0-3';\n",
            'CHANGELOG.md': changelog,
            'website/docs/changelog/recent-releases.md': changelog,
          },
        );
      }

      test('a mid-cycle pin bump does not fail the frozen baseline', () {
        final root = cycleRepo(
          unreleased: '- Adopt native LiteRT-LM `v0.19.1-6`.\n',
          released: paragraph(),
        );
        expect(findRuntimeBaselineDrift(root), isEmpty);
      });

      test('after the docs cut the frozen baseline is not checked', () {
        final root = cycleRepo(released: paragraph());
        expect(findRuntimeBaselineDrift(root), isEmpty);
      });

      test('an Unreleased baseline paragraph is checked', () {
        final root = cycleRepo(
          unreleased:
              '- Keep the default WebGPU bridge assets at `v9.9.9`.\n'
              '\n${paragraph()}',
          released: paragraph(liteRt: 'v0.19.1-6'),
        );
        expect(findRuntimeBaselineDrift(root), [
          allOf(contains('CHANGELOG.md'), contains('v0.19.1-5')),
          allOf(contains('recent-releases.md'), contains('v0.19.1-5')),
        ]);
      });
    });

    test('a reworded paragraph fails instead of passing silently', () {
      final root = baselineRepo(
        changelog: 'Runtime baseline: everything is current.\n',
        docs: paragraph(),
      );
      expect(findRuntimeBaselineDrift(root), hasLength(4));
    });

    test('a frozen top section keeps the tags it shipped with', () {
      final released = paragraph(liteRt: 'v0.18.0', sd: 'v0.2.0');
      final root = baselineRepo(
        heading: '1.0.0',
        changelog: released,
        docs: released,
      );
      expect(findRuntimeBaselineDrift(root), isEmpty);
    });

    test('a missing native pin file fails', () {
      final root = baselineRepo(changelog: paragraph(), docs: paragraph());
      File('${root.path}/$nativeLlamaCppTagPath').deleteSync();
      expect(findRuntimeBaselineDrift(root), hasLength(1));
    });
  });

  group('Web/native llama.cpp relationship', () {
    test('the checked-in repo agrees on the Web/native relationship', () {
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

    test('the native pin must share the Web upstream release', () {
      expect(
        findBridgeRuntimeDrift(
          _fakeRuntimeRepo(
            bridgeTag: bridgeLlamaCppTag,
            nativeTag: bridgeApprovedNativePin,
          ),
          bridgeLlamaCppTag,
        ),
        isEmpty,
      );
      expect(
        findBridgeRuntimeDrift(
          _fakeRuntimeRepo(bridgeTag: bridgeLlamaCppTag, nativeTag: 'v0.10.0'),
          bridgeLlamaCppTag,
        ),
        contains(contains('Web and native must share')),
      );
    });

    test('an upstream-family mismatch is reported', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.3.0-1');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          'bridge assets embed llama.cpp v0.2.0 but $nativeLlamaCppTagPath '
          'pins v0.3.0-1 (upstream family v0.3.0) — Web and native must share '
          'an upstream llama.cpp release',
        ),
      );
    });

    test('a different wrapper in the same family is not the approved pin', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-2');

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(
          '$nativeLlamaCppTagPath pins v0.2.0-2, expected the bridge-approved '
          'native pin $bridgeApprovedNativePin',
        ),
      );
    });

    test('another tag in the upstream family is not accepted in place of the '
        'approved pin', () {
      // Either the bare upstream tag or a wrapper rebuild of it, whichever is
      // not the approved pin.
      final otherFamilyTag = bridgeApprovedNativePin == bridgeLlamaCppTag
          ? '$bridgeLlamaCppTag-1'
          : bridgeLlamaCppTag;
      final root = _fakeRuntimeRepo(
        bridgeTag: bridgeLlamaCppTag,
        nativeTag: otherFamilyTag,
      );

      expect(findBridgeRuntimeDrift(root, bridgeLlamaCppTag), [
        '$nativeLlamaCppTagPath pins $otherFamilyTag, expected the '
            'bridge-approved native pin $bridgeApprovedNativePin',
      ]);
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

    test('relationship prose is accepted for the approved pin', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: bridgeLlamaCppTag,
        nativeTag: bridgeApprovedNativePin,
        parityWording: true,
      );

      expect(findBridgeRuntimeDrift(root, bridgeLlamaCppTag), isEmpty);
    });

    for (final (name, from, to) in [
      ('behind', ', matching the', ', behind the'),
      ('ahead', ', matching the', ', ahead of the'),
    ]) {
      for (final path in [
        'doc/webgpu_bridge.md',
        'website/docs/platforms/webgpu-bridge.md',
      ]) {
        test('$path cannot state a $name relationship at parity', () {
          final root = _fakeRuntimeRepo(
            bridgeTag: bridgeLlamaCppTag,
            nativeTag: bridgeApprovedNativePin,
          );
          final doc = File('${root.path}/$path');
          final source = doc.readAsStringSync();
          expect(source, contains(from));
          doc.writeAsStringSync(source.replaceFirst(from, to));

          expect(
            findBridgeRuntimeDrift(root, bridgeLlamaCppTag).join('\n'),
            contains('$path: '),
          );
          expect(
            findBridgeRuntimeDrift(root, bridgeLlamaCppTag).join('\n'),
            contains('matches 0 lines, expected 1'),
          );
        });
      }
    }

    test('a native pin ahead of Web is reported even with parity prose', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: bridgeLlamaCppTag,
        nativeTag: 'v1.1.0',
      );

      expect(
        findBridgeRuntimeDrift(root, bridgeLlamaCppTag),
        contains(contains('Web and native must share')),
      );
    });

    test('the website must name the exact native runtime pin', () {
      final root = _fakeRuntimeRepo(
        bridgeTag: bridgeLlamaCppTag,
        nativeTag: bridgeApprovedNativePin,
      );
      final path = 'website/docs/platforms/webgpu-bridge.md';
      final doc = File('${root.path}/$path');
      doc.writeAsStringSync(
        doc.readAsStringSync().replaceFirst(
          'runtime `$bridgeApprovedNativePin`',
          'runtime `v0.0.0`',
        ),
      );

      expect(findBridgeRuntimeDrift(root, bridgeLlamaCppTag), [
        '$path: states native pin v0.0.0, '
            'expected $bridgeApprovedNativePin',
      ]);
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
          '$nativeLlamaCppTagPath: found 0 llamaCppTag constants, expected '
          'exactly 1; the gate cannot identify the active native pin',
        ),
      );
    });

    test('duplicate native pin constants fail closed', () {
      final root = _fakeRuntimeRepo(bridgeTag: 'v0.2.0', nativeTag: 'v0.2.0-1');
      File('${root.path}/$nativeLlamaCppTagPath').writeAsStringSync(
        "const llamaCppTag = 'v0.2.0-1';\n"
        "const llamaCppTag = 'v0.3.0-1';\n",
      );

      expect(
        findBridgeRuntimeDrift(root, 'v0.2.0'),
        contains(contains('found 2 llamaCppTag constants, expected exactly 1')),
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
        final root = _fakeRuntimeRepo(
          bridgeTag: 'v0.10.0',
          nativeTag: 'v0.10.0',
        );

        expect(
          findBridgeRuntimeDrift(root, 'v0.10.0'),
          contains(
            contains(
              'bridgeNativeReleaseTag $bridgeNativeReleaseTag does not belong to '
              'the recorded upstream llama.cpp release v0.10.0',
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
      expect(bridgeAssetsReleaseId, '453141343');
      expect(bridgeAssetsTagCommit, '42be158f58427b7b9a168e1c2121f74c3c4cc413');
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

    for (final (name, lineEnding) in [('LF', '\n'), ('CRLF', '\r\n')]) {
      test('the provenance doc cannot state a skewed upstream ($name)', () {
        const path = 'doc/webgpu_bridge.md';
        const parity = ', both built from';
        final source = File(path)
            .readAsStringSync()
            .replaceAll('\r\n', '\n')
            .replaceAll('\n', lineEnding);
        expect(source, contains(parity));
        final root = _fakeRepo(
          readPinnedBridgeTag(Directory.current),
          files: {
            path: source.replaceFirst(parity, '; the bridge is built from'),
          },
        );

        expect(findBridgeProvenanceDrift(root), [
          contains('$path: the pinned release provenance passage matches 0'),
        ]);
      });
    }

    for (final (name, lineEnding) in [('LF', '\n'), ('CRLF', '\r\n')]) {
      test(
        'the repeated native runtime tag must match the exact pin ($name)',
        () {
          const path = 'doc/webgpu_bridge.md';
          const staleNativeTag = 'v0.0.0';
          const provenanceStart =
              '. Provenance for this immutable consumer artifact:';
          const target = '`$bridgeApprovedNativePin`$provenanceStart';
          final source = File(path)
              .readAsStringSync()
              .replaceAll('\r\n', '\n')
              .replaceAll('\n', lineEnding);
          expect(
            target.allMatches(source),
            hasLength(1),
            reason:
                'The fixture must have one repeated native runtime tag to replace',
          );
          final root = _fakeRepo(
            readPinnedBridgeTag(Directory.current),
            files: {
              path: source.replaceFirst(
                target,
                '`$staleNativeTag`$provenanceStart',
              ),
            },
          );

          expect(findBridgeProvenanceDrift(root), [
            '$path: states nativeRuntimeTag $staleNativeTag, '
                'expected $bridgeApprovedNativePin',
          ]);
        },
      );
    }

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

  group('Published release verification', () {
    test('accepts the pinned immutable release and its tag commit', () async {
      final github = _FakeGitHub.pinned();

      expect(await _verifyRelease(github), isEmpty);
      expect(github.requested.map((url) => url.path), <String>[
        '/repos/$bridgeAssetsRepository/releases/tags/${github.tag}',
        '/repos/$bridgeAssetsRepository/git/ref/tags/${github.tag}',
      ]);
      expect(github.requested.map((url) => url.host).toSet(), <String>{
        'api.github.com',
      });
    });

    test('peels annotated tags to the pinned commit', () async {
      for (final chain in <List<String>>[
        <String>['a' * 40],
        <String>['a' * 40, 'b' * 40, 'c' * 40],
      ]) {
        final github = _FakeGitHub.pinned()
          ..annotatedTag(chain, bridgeAssetsTagCommit);

        expect(
          await _verifyRelease(github),
          isEmpty,
          reason: '${chain.length} annotated tag(s)',
        );
        expect(
          github.requested.last.path,
          '/repos/$bridgeAssetsRepository/git/tags/${chain.last}',
        );
      }
    });

    test('an annotated tag object is not mistaken for its commit', () async {
      final github = _FakeGitHub.pinned()
        ..annotatedTag(<String>[bridgeAssetsTagCommit], 'd' * 40);

      expect(await _verifyRelease(github), <String>[
        'tag ${github.tag} points at commit ${'d' * 40}, expected '
            'bridgeAssetsTagCommit $bridgeAssetsTagCommit',
      ]);
    });

    test('a different release id fails', () async {
      final github = _FakeGitHub.pinned()..release(<String, Object?>{'id': 1});

      expect(await _verifyRelease(github), <String>[
        'release ${github.tag} has id 1, expected bridgeAssetsReleaseId '
            '$bridgeAssetsReleaseId',
      ]);
    });

    test('a different tag commit fails', () async {
      final github = _FakeGitHub.pinned()..lightweightTag('e' * 40);

      expect(await _verifyRelease(github), <String>[
        'tag ${github.tag} points at commit ${'e' * 40}, expected '
            'bridgeAssetsTagCommit $bridgeAssetsTagCommit',
      ]);
    });

    test('a mutable or draft release fails closed', () async {
      for (final fields in <Map<String, Object?>>[
        <String, Object?>{'immutable': false},
        <String, Object?>{'immutable': null},
        <String, Object?>{'immutable': 'true'},
        <String, Object?>{'draft': true},
        <String, Object?>{'draft': null},
      ]) {
        final github = _FakeGitHub.pinned()..release(fields);
        final key = fields.keys.single;

        expect(await _verifyRelease(github), <Matcher>[
          contains('reports $key: ${fields[key]}'),
        ], reason: '$fields was accepted');
      }
    });

    test('missing or malformed release data fails closed', () async {
      for (final entry in <Map<String, Object?>, String>{
        <String, Object?>{'id': null}: 'reports no numeric release id',
        <String, Object?>{'id': bridgeAssetsReleaseId}:
            'reports no numeric release id',
        <String, Object?>{'tag_name': 'v0.0.1'}: 'reports tag_name v0.0.1',
      }.entries) {
        final github = _FakeGitHub.pinned()..release(entry.key);

        expect(await _verifyRelease(github), <Matcher>[
          contains(entry.value),
        ], reason: '${entry.key} was accepted');
      }

      final notAnObject = _FakeGitHub.pinned();
      notAnObject.respond('releases/tags/${notAnObject.tag}', <Object?>[
        <String, Object?>{'id': int.parse(bridgeAssetsReleaseId)},
      ]);
      expect(await _verifyRelease(notAnObject), <Matcher>[
        contains('returned invalid JSON: expected an object'),
      ]);
    });

    test('missing or malformed tag data fails closed', () async {
      final tag = readPinnedBridgeTag(Directory.current);
      for (final entry in <Object, String>{
        <String, Object?>{
          'ref': 'refs/tags/v0.0.1',
          'object': <String, Object?>{
            'type': 'commit',
            'sha': bridgeAssetsTagCommit,
          },
        }: 'does not describe refs/tags/$tag',
        <String, Object?>{'ref': 'refs/tags/$tag'}:
            'reports no valid object sha',
        <String, Object?>{
          'ref': 'refs/tags/$tag',
          'object': <String, Object?>{'type': 'commit', 'sha': 'abc123'},
        }: 'reports no valid object sha',
        <String, Object?>{
          'ref': 'refs/tags/$tag',
          'object': <String, Object?>{'type': 'tree', 'sha': 'f' * 40},
        }: 'at a tree object, expected a commit or an annotated tag',
        <Object?>[
          <String, Object?>{'ref': 'refs/tags/$tag'},
        ]: 'returned invalid JSON: expected an object',
      }.entries) {
        final github = _FakeGitHub.pinned()
          ..respond('git/ref/tags/$tag', entry.key);

        expect(await _verifyRelease(github), <Matcher>[
          contains(entry.value),
        ], reason: '${entry.key} was accepted');
      }

      final missingTagObject = _FakeGitHub.pinned()
        ..annotatedTag(<String>['a' * 40], bridgeAssetsTagCommit);
      missingTagObject.responses.remove(
        '/repos/$bridgeAssetsRepository/git/tags/${'a' * 40}',
      );
      expect(await _verifyRelease(missingTagObject), <Matcher>[
        endsWith('/git/tags/${'a' * 40} returned HTTP 404'),
      ]);

      final endless = _FakeGitHub.pinned()
        ..annotatedTag(<String>[
          for (var i = 0; i <= maxTagPeelDepth; i++)
            i.toRadixString(16).padLeft(40, '0'),
        ], bridgeAssetsTagCommit);
      expect(await _verifyRelease(endless), <Matcher>[
        contains('does not reach a commit within $maxTagPeelDepth'),
      ]);
    });

    test('API failures are reported without throwing', () async {
      final tag = readPinnedBridgeTag(Directory.current);

      final missing = _FakeGitHub.pinned();
      missing.responses.remove(
        '/repos/$bridgeAssetsRepository/releases/tags/$tag',
      );
      expect(await _verifyRelease(missing), <Matcher>[
        endsWith('/releases/tags/$tag returned HTTP 404'),
      ]);

      final limited = _FakeGitHub.pinned()
        ..respond('git/ref/tags/$tag', null, status: HttpStatus.forbidden);
      expect(await _verifyRelease(limited), <Matcher>[
        allOf(
          contains('returned HTTP 403'),
          contains('set GH_TOKEN or GITHUB_TOKEN'),
        ),
      ]);

      final invalid = _FakeGitHub.pinned();
      invalid.responses['/repos/$bridgeAssetsRepository/releases/tags/$tag'] =
          ManifestResponse(HttpStatus.ok, utf8.encode('{not-json'));
      expect(await _verifyRelease(invalid), <Matcher>[
        contains('returned invalid JSON'),
      ]);

      expect(
        await verifyPublishedRelease(
          expectedTag: tag,
          expectedReleaseId: bridgeAssetsReleaseId,
          expectedTagCommit: bridgeAssetsTagCommit,
          fetcher: (_) async =>
              throw const SocketException('connection refused'),
        ),
        <Matcher>[contains('could not read'), contains('could not read')],
      );

      final pending = Completer<ManifestResponse>();
      expect(
        await verifyPublishedRelease(
          expectedTag: tag,
          expectedReleaseId: bridgeAssetsReleaseId,
          expectedTagCommit: bridgeAssetsTagCommit,
          fetcher: (_) => pending.future,
          timeout: const Duration(milliseconds: 20),
        ),
        <Matcher>[contains('timed out reading'), contains('timed out reading')],
      );

      expect(
        await verifyPublishedRelease(
          expectedTag: tag,
          expectedReleaseId: bridgeAssetsReleaseId,
          expectedTagCommit: bridgeAssetsTagCommit,
          maximumBytes: 16,
          fetcher: _FakeGitHub.pinned().fetch,
        ),
        <Matcher>[
          contains('exceeds the 16-byte limit'),
          contains('exceeds the 16-byte limit'),
        ],
      );
    });

    test('the aggregate gate reports release drift', () async {
      final repoRoot = Directory.current;
      final bytes = utf8.encode(_approvedManifestJson);
      final github = _FakeGitHub.pinned()
        ..release(<String, Object?>{'immutable': false});

      expect(
        await findBridgeProblems(
          repoRoot,
          readPinnedBridgeTag(repoRoot),
          verifyPublishedManifest: true,
          manifestFetcher: (_) async => ManifestResponse(HttpStatus.ok, bytes),
          releaseFetcher: github.fetch,
        ),
        <Matcher>[contains('reports immutable: false')],
      );
    });

    test(
      'the token is sent only as a header and redirects are not followed',
      () async {
        const token = 'test-token-not-a-secret';
        final tag = readPinnedBridgeTag(Directory.current);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <String, String?>{};
        server.listen((request) async {
          seen[request.uri.path] = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          final response = request.response;
          if (request.uri.path.endsWith('/releases/tags/$tag')) {
            response
              ..statusCode = HttpStatus.found
              ..headers.set(HttpHeaders.locationHeader, '/redirected');
          } else if (request.uri.path.endsWith('/ref/tags/$tag')) {
            response.write(
              jsonEncode(<String, Object?>{
                'ref': 'refs/tags/$tag',
                'object': <String, Object?>{
                  'type': 'commit',
                  'sha': bridgeAssetsTagCommit,
                },
              }),
            );
          } else {
            response.statusCode = HttpStatus.notFound;
          }
          await response.close();
        });

        Future<List<String>> run(Map<String, String> environment) =>
            verifyPublishedRelease(
              expectedTag: tag,
              expectedReleaseId: bridgeAssetsReleaseId,
              expectedTagCommit: bridgeAssetsTagCommit,
              apiBase: Uri.parse('http://127.0.0.1:${server.port}'),
              environment: environment,
            );

        final errors = await run(<String, String>{'GH_TOKEN': token});
        expect(errors, <Matcher>[endsWith('returned HTTP 302')]);
        expect(errors.join('\n'), isNot(contains(token)));
        expect(seen.keys, isNot(contains('/redirected')));
        expect(seen, hasLength(2));
        expect(seen.values.toSet(), <String?>{'Bearer $token'});

        // gh's precedence: GH_TOKEN wins, and a blank one is unset.
        seen.clear();
        await run(<String, String>{
          'GH_TOKEN': token,
          'GITHUB_TOKEN': 'other-token',
        });
        expect(seen.values.toSet(), <String?>{'Bearer $token'});

        seen.clear();
        await run(<String, String>{'GH_TOKEN': ' ', 'GITHUB_TOKEN': token});
        expect(seen.values.toSet(), <String?>{'Bearer $token'});

        seen.clear();
        await run(const <String, String>{});
        expect(seen, hasLength(2));
        expect(seen.values.toSet(), <String?>{null});

        // An invalid GH_TOKEN fails closed rather than falling back.
        seen.clear();
        expect(
          await run(<String, String>{
            'GH_TOKEN': 'bad\ntoken',
            'GITHUB_TOKEN': token,
          }),
          <Matcher>[startsWith('GH_TOKEN is not a valid bearer token')],
        );
        expect(seen, isEmpty);
      },
    );

    test('an invalid token fails closed without being printed', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      });
      final repoRoot = Directory.current;
      final manifest = utf8.encode(_approvedManifestJson);

      const secrets = <String>[
        'bogus-audit\nsecretpart',
        'bogus-audit\r\nX-Injected: secretpart',
        'bogus-audit\u0000secretpart',
        'bogus-audit secretpart',
        'bogus-auditésecretpart',
      ];
      for (final secret in secrets) {
        for (final name in const <String>['GH_TOKEN', 'GITHUB_TOKEN']) {
          final environment = <String, String>{name: secret};
          final direct = await verifyPublishedRelease(
            expectedTag: readPinnedBridgeTag(repoRoot),
            expectedReleaseId: bridgeAssetsReleaseId,
            expectedTagCommit: bridgeAssetsTagCommit,
            apiBase: Uri.parse('http://127.0.0.1:${server.port}'),
            environment: environment,
          );
          // The aggregate scans the whole repository first, so it checks one
          // secret per name; `direct` covers every malformed value.
          final aggregate = secret == secrets.first
              ? await findBridgeProblems(
                  repoRoot,
                  readPinnedBridgeTag(repoRoot),
                  verifyPublishedManifest: true,
                  manifestFetcher: (_) async =>
                      ManifestResponse(HttpStatus.ok, manifest),
                  environment: environment,
                )
              : null;

          for (final problems in <List<String>>[direct, ?aggregate]) {
            expect(problems, <String>[
              '$name is not a valid bearer token, so no GitHub API request '
                  'was sent; its value is not shown',
            ], reason: '${jsonEncode(secret)} in $name');
            expect(problems.join('\n'), isNot(contains('secretpart')));
          }
        }
      }
      expect(requests, 0);
    });
  });
}

Future<List<String>> _verifyRelease(_FakeGitHub github) =>
    verifyPublishedRelease(
      expectedTag: github.tag,
      expectedReleaseId: bridgeAssetsReleaseId,
      expectedTagCommit: bridgeAssetsTagCommit,
      fetcher: github.fetch,
    );

/// Serves GitHub REST responses by path; anything unregistered is a 404.
class _FakeGitHub {
  final String tag;
  final Map<String, ManifestResponse> responses = <String, ManifestResponse>{};
  final List<Uri> requested = <Uri>[];

  _FakeGitHub(this.tag);

  /// The published state the production pins describe.
  factory _FakeGitHub.pinned() =>
      _FakeGitHub(readPinnedBridgeTag(Directory.current))
        ..release(const <String, Object?>{})
        ..lightweightTag(bridgeAssetsTagCommit);

  void respond(String path, Object? json, {int status = HttpStatus.ok}) {
    responses['/repos/$bridgeAssetsRepository/$path'] = ManifestResponse(
      status,
      utf8.encode(jsonEncode(json)),
    );
  }

  /// Publishes the pinned release with [overrides]; a null value drops the
  /// field.
  void release(Map<String, Object?> overrides) {
    final fields = <String, Object?>{
      'id': int.parse(bridgeAssetsReleaseId),
      'tag_name': tag,
      'immutable': true,
      'draft': false,
      'prerelease': false,
      ...overrides,
    }..removeWhere((_, value) => value == null);
    respond('releases/tags/$tag', fields);
  }

  void lightweightTag(String commit) {
    respond('git/ref/tags/$tag', <String, Object?>{
      'ref': 'refs/tags/$tag',
      'object': <String, Object?>{'type': 'commit', 'sha': commit},
    });
  }

  /// Points the tag at [tagObjects] in turn, the last of which tags [commit].
  void annotatedTag(List<String> tagObjects, String commit) {
    respond('git/ref/tags/$tag', <String, Object?>{
      'ref': 'refs/tags/$tag',
      'object': <String, Object?>{'type': 'tag', 'sha': tagObjects.first},
    });
    for (var i = 0; i < tagObjects.length; i++) {
      respond('git/tags/${tagObjects[i]}', <String, Object?>{
        'sha': tagObjects[i],
        'object': i + 1 < tagObjects.length
            ? <String, Object?>{'type': 'tag', 'sha': tagObjects[i + 1]}
            : <String, Object?>{'type': 'commit', 'sha': commit},
      });
    }
  }

  Future<ManifestResponse> fetch(Uri url) async {
    requested.add(url);
    return responses[url.path] ??
        const ManifestResponse(HttpStatus.notFound, <int>[]);
  }
}
