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
      "sha256": "bab791021bb7a2654127b7e3eced01f408e7960d75699596f5fe6f7ad6af56a6",
      "size_bytes": 28814
    },
    "llama_webgpu_bridge.js": {
      "sha256": "c72d480fba9feef0405562bebd7a70b7e44fc63562ad1d7da8018753856d4018",
      "size_bytes": 424423
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "4c708c879eeaad19dc55c7f01fdd3ab901b8f83e69f63e0669a36024f32d3ef7",
      "size_bytes": 423465
    },
    "llama_webgpu_core.js": {
      "sha256": "63decaee039c8f91b5923494a44bff7b7f3d83e3eafefff40cef274868069b82",
      "size_bytes": 134847
    },
    "llama_webgpu_core.wasm": {
      "sha256": "6e816f27ca86afca37425b56388f16b777da59016d3609b3d3683f0b3316b4a4",
      "size_bytes": 11105672
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "78f2fc465f8280b63371422954e6146bb5f5cbe386dd203973abcd4844bd3e3d",
      "size_bytes": 157733
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "0e5557e452f39be574c0d9304e14a5c9808ff67c5641dc4b0e347ad9506b3fbf",
      "size_bytes": 11431602
    },
    "llama_webgpu_core_mem64_st.js": {
      "sha256": "6eb83f4f322027b3de864ed61f64d4b5df57cc4e1317de39d344f7e720ba7430",
      "size_bytes": 136514
    },
    "llama_webgpu_core_mem64_st.wasm": {
      "sha256": "b976d7b8b2804d6780a7146736973700adc7b4fbdef5dd52841fd741d8f34174",
      "size_bytes": 10764413
    },
    "llama_webgpu_core_st.js": {
      "sha256": "f2bc8115ed9f397919a81630e15a55cd68a8ea40e0b1fd6ad4c3c2b6228b04de",
      "size_bytes": 115126
    },
    "llama_webgpu_core_st.wasm": {
      "sha256": "ae92804f607c2bdbd07178dba2fc73d0dc8de3a4e473f38fc0a9221a6455a343",
      "size_bytes": 10476055
    }
  },
  "assets_repository": "leehack/llama-web-bridge-assets",
  "bridge_assets_tag": "v0.1.92",
  "bridge_commit": "d7236223d2393d51dab541df6caf3ef88f06d49b",
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
      "sha256": "bab791021bb7a2654127b7e3eced01f408e7960d75699596f5fe6f7ad6af56a6",
      "size_bytes": 28814
    },
    "llama_webgpu_bridge.js": {
      "sha256": "c72d480fba9feef0405562bebd7a70b7e44fc63562ad1d7da8018753856d4018",
      "size_bytes": 424423
    },
    "llama_webgpu_bridge_worker.js": {
      "sha256": "4c708c879eeaad19dc55c7f01fdd3ab901b8f83e69f63e0669a36024f32d3ef7",
      "size_bytes": 423465
    },
    "llama_webgpu_core.js": {
      "sha256": "63decaee039c8f91b5923494a44bff7b7f3d83e3eafefff40cef274868069b82",
      "size_bytes": 134847
    },
    "llama_webgpu_core.wasm": {
      "sha256": "6e816f27ca86afca37425b56388f16b777da59016d3609b3d3683f0b3316b4a4",
      "size_bytes": 11105672
    },
    "llama_webgpu_core_mem64.js": {
      "sha256": "78f2fc465f8280b63371422954e6146bb5f5cbe386dd203973abcd4844bd3e3d",
      "size_bytes": 157733
    },
    "llama_webgpu_core_mem64.wasm": {
      "sha256": "0e5557e452f39be574c0d9304e14a5c9808ff67c5641dc4b0e347ad9506b3fbf",
      "size_bytes": 11431602
    },
    "llama_webgpu_core_mem64_st.js": {
      "sha256": "6eb83f4f322027b3de864ed61f64d4b5df57cc4e1317de39d344f7e720ba7430",
      "size_bytes": 136514
    },
    "llama_webgpu_core_mem64_st.wasm": {
      "sha256": "b976d7b8b2804d6780a7146736973700adc7b4fbdef5dd52841fd741d8f34174",
      "size_bytes": 10764413
    },
    "llama_webgpu_core_st.js": {
      "sha256": "f2bc8115ed9f397919a81630e15a55cd68a8ea40e0b1fd6ad4c3c2b6228b04de",
      "size_bytes": 115126
    },
    "llama_webgpu_core_st.wasm": {
      "sha256": "ae92804f607c2bdbd07178dba2fc73d0dc8de3a4e473f38fc0a9221a6455a343",
      "size_bytes": 10476055
    }
  },
  "github_run_id": "45031773094",
  "github_run_url": "https://github.com/leehack/llama-web-bridge/actions/runs/45031773094",
  "llama_cpp_commit": "b1b770d90d94cad9e9ea5b993bdbc383a522fb28",
  "llama_cpp_tag": "v1.0.0",
  "native_commit": "4b480fbf303d69c1f67416a25986bd0913728ede",
  "native_manifest_sha256": "7d8e69971e2e3bd73d258005c86d5f47d0cd96e1d7f08a23fdf44dd244ea1316",
  "native_release_tag": "v1.0.0-4",
  "native_repository": "leehack/llamadart-native",
  "orchestrator_correlation_id": "manual-v0.1.92-d723622",
  "qualification_gates": {
    "multimodal": "passed",
    "speech_to_text": "required-automated-qualification",
    "state_persistence": "passed",
    "text_to_speech": "required-automated-qualification"
  },
  "release_channel": "stable",
  "release_rebuild": 0,
  "release_tag": "v0.1.92",
  "schema_version": 2,
  "source_commit": "d7236223d2393d51dab541df6caf3ef88f06d49b",
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
    expectedTag: 'v0.1.92',
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
        valid.replaceFirst('native LiteRT-LM uses', 'native LiteRT-LM stays'),
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

  test('prep CLI reads prior native pins from the requested tag', () async {
    final root = _preparedReleaseRepo();
    final candidatePubspec = File('${root.path}/$rootPubspecPath');
    final candidatePins = File('${root.path}/$nativeLlamaCppTagPath');
    final pubspec = candidatePubspec.readAsStringSync();
    final pins = candidatePins.readAsStringSync();
    final coreChangelog = File('${root.path}/CHANGELOG.md');
    final notes = coreChangelog.readAsStringSync();
    final script = File('tool/testing/check_webgpu_bridge_tag.dart').absolute;
    final packages = File('.dart_tool/package_config.json').absolute.path;
    void git(List<String> args) {
      final result = Process.runSync(
        'git',
        args,
        workingDirectory: root.path,
        environment: {
          'GIT_AUTHOR_NAME': 'Release fixture',
          'GIT_AUTHOR_EMAIL': 'release-fixture@example.invalid',
          'GIT_COMMITTER_NAME': 'Release fixture',
          'GIT_COMMITTER_EMAIL': 'release-fixture@example.invalid',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    git(['init', '--quiet']);
    candidatePubspec.writeAsStringSync(pubspec.replaceFirst('1.2.3', '1.2.2'));
    candidatePins.writeAsStringSync(pins.replaceFirst('v1.0.0-3', 'v1.0.0-2'));
    git(['add', rootPubspecPath, nativeLlamaCppTagPath, bridgeTagSourcePath]);
    git(['commit', '--quiet', '-m', 'Last release']);
    git(['tag', 'v1.2.2']);
    candidatePubspec.writeAsStringSync(pubspec);
    candidatePins.writeAsStringSync(pins);
    coreChangelog.writeAsStringSync(
      notes.replaceFirst('`v1.0.0-3`', '`v1.0.0-3` (unchanged from 1.2.2)'),
    );

    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=$packages',
      script.path,
      '--release-prep',
      'v1.2.2',
    ], workingDirectory: root.path);
    expect(result.exitCode, 1, reason: '${result.stdout}');
    expect(
      result.stderr,
      contains('CHANGELOG.md must contain one complete Runtime baseline'),
    );
  });

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
    test(
      'strict prep ignores retention examples in comments and code in $path',
      () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        final valid = changelog.readAsStringSync();
        const badClaim = '(unchanged from 1.2.1)';
        changelog.writeAsStringSync(
          '$valid\n<!-- Another runtime $badClaim. -->\n'
          '```markdown\n- Example $badClaim.\n```\n'
          '- Pass the prompt unchanged from the caller.\n',
        );
        expect(_verifyPreparedRelease(root), isEmpty);
      },
    );

    for (final (shape, example) in [
      ('quoted backticks', '> ```html\n> <!--\n> ```'),
      ('nested quoted tildes', '> > ~~~~html\n>> ~~~\n> > <!--\n> > ~~~~'),
      (
        'literal quote marker in a fence',
        '> ```html\n> > Literal code (unchanged from 1.2.1).\n> > ```\n> <!--\n> ````',
      ),
      ('unclosed nested fence', '> > ```html\n>> <!--'),
      ('unclosed quoted comment', '> <!--\n> Hidden (unchanged from 1.2.1).'),
    ]) {
      test('strict prep keeps the baseline after $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        final valid = changelog.readAsStringSync();
        changelog.writeAsStringSync(
          valid.replaceFirst(
            _preparedBaseline,
            '$example\n\n$_preparedBaseline',
          ),
        );
        expect(_verifyPreparedRelease(root), isEmpty);
      });

      test('strict prep checks visible claims after $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        final valid = changelog.readAsStringSync();
        changelog.writeAsStringSync(
          '$valid\n$example\n\n'
          '- Native audio remains pinned to v9.9.8 (unchanged from 1.2.1).\n',
        );
        expect(
          _verifyPreparedRelease(root),
          contains(
            allOf(
              startsWith(path),
              contains('does not match the previous release'),
            ),
          ),
        );
      });
    }

    test('strict prep ignores retention text in quoted code in $path', () {
      final root = _preparedReleaseRepo();
      final changelog = File('${root.path}/$path');
      final valid = changelog.readAsStringSync();
      changelog.writeAsStringSync(
        '$valid\n> ```text\n> Literal marker (unchanged from 1.2.1).\n> ```\n',
      );
      expect(_verifyPreparedRelease(root), isEmpty);
    });

    for (final (shape, markup, ending) in [
      ('inline emphasis', '<em><!-- previous release -->', '</em>'),
      ('wrap hint', '<wbr><!-- editorial -->', ''),
      ('line break', '<br> <!-- wrap -->', ''),
    ]) {
      test('strict prep rejects a wrapped claim with $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        final valid = changelog.readAsStringSync();
        changelog.writeAsStringSync(
          '$valid\nNative audio remains pinned to v9.9.8 (unchanged\n'
          '$markup\nfrom 1.2.1$ending).\n',
        );
        expect(
          _verifyPreparedRelease(root),
          contains(
            allOf(
              startsWith(path),
              contains('does not match the previous release'),
            ),
          ),
        );
      });
    }

    for (final (shape, example) in [
      ('quoted indented code', '>     Literal example (unchanged from 1.2.1).'),
      (
        'quoted HTML code',
        '> <pre><code>Literal example (unchanged from 1.2.1).</code></pre>',
      ),
      (
        'quoted list-item fence',
        '> - ```text\n>   Literal example (unchanged from 1.2.1).\n>   ```',
      ),
      (
        'separate paragraphs',
        'The public API is unchanged\n\n> From 1.2.1 onward, use the new CLI.',
      ),
    ]) {
      test('strict prep accepts valid notes with $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        final valid = changelog.readAsStringSync();
        changelog.writeAsStringSync('$valid\n$example\n');
        expect(_verifyPreparedRelease(root), isEmpty);
      });
    }
  }

  for (final path in _preparedChangelogs) {
    const badClaim = 'Native audio (unchanged from 1.2.1).';
    const footnoteClaim = 'Native audio unchanged since 1.2.1.';
    for (final (shape, notes, rejected, rendered) in [
      (
        'a blockquote closing an outer HTML pre',
        '<div><pre>\n\n> Sample. </pre></div>\n\n'
            'Ordinary paragraph.\n\n- $badClaim',
        true,
        'GitHub renders the final list after </pre>.',
      ),
      (
        'a list item closing an outer HTML pre',
        '<div><pre>\n\n- Sample ends here. </pre></div>\n\n$badClaim',
        true,
        'GitHub renders the final paragraph after </pre>.',
      ),
      (
        'an HTML pre ending with its list item',
        '- <pre>\n  Sample.\n- $badClaim',
        true,
        'GitHub closes the pre inside the first item and renders the claim in the second.',
      ),
      (
        'an HTML pre ending with its blockquote',
        '> <div><pre>\n>\n> Sample.\n\n$badClaim',
        true,
        'GitHub closes the pre inside the blockquote and renders the claim outside.',
      ),
      (
        'a blockquote inside an open HTML pre',
        '<div><pre>\n\n> Sample $badClaim\n\n</pre></div>',
        false,
        'GitHub renders the blockquote inside the still-open pre.',
      ),
      (
        'an HTML pre with a closing tag inside a table cell',
        '<div><pre>\n\n| Sample |\n| --- |\n| End. </pre></div> |\n\n$badClaim',
        false,
        'GitHub keeps the table and the final paragraph inside the pre.',
      ),
      (
        'a Markdown link title',
        '- [Reference](notes.md "$badClaim")',
        true,
        'GitHub retains the claim as the link title.',
      ),
      (
        'a Markdown image title',
        '- ![Diagram](image.png "$badClaim")',
        true,
        'GitHub retains the claim as the image title and Diagram as its alt text.',
      ),
      (
        'a link title without a retention claim',
        '- [Reference](notes.md "Native audio notes.")',
        false,
        'GitHub retains the ordinary title on the link.',
      ),
      (
        'a raw HTML link title',
        '<a href="notes.md" title="$badClaim">Reference</a>',
        true,
        'GitHub retains the claim as the raw HTML link title.',
      ),
      (
        'an unreferenced list footnote',
        '- [^a]: Changelog search is unchanged since 1.2.1.',
        false,
        'GitHub renders an empty list item and omits the definition.',
      ),
      (
        'a second definition of a referenced footnote',
        'See the note[^a].\n\n[^a]: Ordinary.\n\n[^a]: $footnoteClaim',
        false,
        'GitHub renders only the first definition, Ordinary.',
      ),
      (
        'the only definition of a referenced footnote',
        'See the note[^a].\n\n[^a]: $footnoteClaim',
        true,
        'GitHub renders the claim in the footnotes section.',
      ),
      (
        'a footnote marker in inline code',
        'See `[^a]`.\n\n[^a]: $badClaim',
        false,
        'GitHub renders the marker as code and emits no footnote.',
      ),
      (
        'a duplicate footnote label with different case',
        'See note[^a].\n\n[^A]: First note.\n\n[^a]: $badClaim',
        false,
        'GitHub resolves both spellings to the first definition.',
      ),
      (
        'a footnote referenced from an omitted definition',
        '[^a]: Read this[^b].\n\n[^b]: $badClaim',
        true,
        'GitHub omits a but emits b in the footnotes section.',
      ),
      (
        'a footnote referenced from a superseded definition',
        'See note[^a].\n\n[^a]: First note.\n\n'
            '[^a]: Read this[^b].\n\n[^b]: $badClaim',
        true,
        'GitHub emits the first a and also emits b.',
      ),
      (
        'a footnote with its reference and a duplicate in an older release',
        '[^a]: $badClaim\n\n## 1.2.2\n\nSee note[^a].\n\n[^a]: Later note.',
        true,
        'GitHub renders the first definition, which belongs to the current release.',
      ),
      (
        'a Setext heading spelling an older release',
        '1.2.2\n-----\n\n$badClaim\n\n## 1.2.2\n\nPrevious notes.',
        true,
        'GitHub renders the claim after the Setext heading and before the actual release boundary.',
      ),
    ]) {
      test('strict prep checks rendered Markdown for $shape in $path', () {
        final root = _preparedReleaseRepo();
        File(
          '${root.path}/$path',
        ).writeAsStringSync('\n$notes\n', mode: FileMode.append);
        expect(_verifyPreparedRelease(root), [
          if (rejected)
            startsWith('$path contains an (unchanged from ...) claim'),
        ], reason: rendered);
      });
    }

    for (final (shape, notes) in [
      (
        'prose after an opening textarea',
        '- Support <textarea> controls. $badClaim',
      ),
      (
        'formatted prose after an opening textarea',
        '- Support <textarea> controls. Native audio (unchanged <em>from</em> 1.2.1).',
      ),
      for (final tag in [
        'textarea',
        'script',
        'style',
        'title',
        'xmp',
        'iframe',
        'noembed',
        'noframes',
        'plaintext',
      ])
        ('prose within filtered HTML tag $tag', '- <$tag>$badClaim</$tag>'),
      ('image alt text', '- Add a status graphic: ![$badClaim](missing.png)'),
      (
        'a footnote referenced from an older release',
        '[^rt]: $badClaim\n\n## 1.2.2\n\nSee details[^rt].',
      ),
      (
        'prose after a multiblock HTML pre',
        '> <div><pre>\n>\n> Literal example.\n>\n'
            '> </pre></div>\n>\n> $badClaim',
      ),
      (
        'ordinary bullet continuation',
        '- Native audio\n  (unchanged from 1.2.1).',
      ),
      ('nested sub-bullet', '- Runtime notes\n  - $badClaim'),
      ('blockquote', '> $badClaim'),
      ('wrapped quote', '> Native audio unchanged from\n> 1.2.1.'),
      ('lazy quote continuation', '> Runtime notes:\n$badClaim'),
      ('trailing inline comment', '- $badClaim <!-- editorial -->'),
      (
        'split inline comment',
        '- Native audio (unchanged <!-- x --> from 1.2.1).',
      ),
      (
        'double hyphen in a comment',
        '- Native audio (unchanged <!-- a -- b --> from 1.2.1).',
      ),
      (
        'empty inline comment',
        '- Native audio (unchanged <!----> from 1.2.1).',
      ),
      ('bare claim with a code span', '- Native audio unchanged from `1.2.1`.'),
      ('bare since claim', '- Native audio unchanged since 1.2.1.'),
      ('parenthesized since claim', '- Native audio (unchanged since 1.2.1).'),
      ('HTML div', '<div>\n$badClaim\n</div>'),
      (
        'HTML attribute with a comment opener',
        '<span title="<!--">$badClaim</span>',
      ),
      ('HTML entity', '- Native audio &#40;unchanged from 1.2.1).'),
      (
        'GFM table cell',
        '| Runtime | Notes |\n| --- | --- |\n| Audio | $badClaim |',
      ),
      ('indented code before prose', '    <!--\n\n$badClaim'),
      (
        'quoted indented code before quoted prose',
        '>     <!--\n>\n> $badClaim',
      ),
      ('quoted indented code before outside prose', '>     <!--\n\n$badClaim'),
      ('list item fence before prose', '- ```html\n  <!--\n  ```\n\n$badClaim'),
      (
        'fence on a list continuation',
        '- Example\n\n  ```html\n  <!--\n  ```\n\n$badClaim',
      ),
      (
        'list fence ending at an outdent',
        '- Example\n\n  ```html\n  <!--\n\n$badClaim',
      ),
      (
        'quoted list fence before quoted prose',
        '> - ```html\n>   <!--\n>   ```\n>\n> $badClaim',
      ),
      (
        'inline code with a comment opener',
        'Use `<!--` in the sample.\n\n$badClaim',
      ),
      (
        'quoted inline code with a comment opener',
        '> Use `<!--` in the sample.\n>\n> $badClaim',
      ),
      (
        'multiline code span',
        'Use `the literal\nmarker <!--` in the sample.\n\n$badClaim',
      ),
      (
        'shorter closing fence',
        '> ````text\n> ```\n> <!--\n> ````\n\n$badClaim',
      ),
      (
        'wrong closing fence marker',
        '> ~~~~text\n> ````\n> <!--\n> ~~~~\n>\n> $badClaim',
      ),
      ('comment around a fence marker', '<!--\n```text\n-->\n\n$badClaim'),
      (
        'quoted comment around a fence marker',
        '> <!--\n> ```text\n> -->\n>\n> $badClaim',
      ),
      (
        'quoted HTML pre with a fence marker',
        '> <pre>\n> ```\n> </pre>\n>\n> $badClaim',
      ),
      (
        'quoted list fence ending at an outdent',
        '> - Sample\n>\n>   ```html\n>   <!--\n> - $badClaim',
      ),
      (
        'outer quote after a nested unclosed comment',
        '> > <!--\n>\n> $badClaim',
      ),
    ]) {
      test('strict prep rejects retention in $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync('\n$notes\n', mode: FileMode.append);
        expect(_verifyPreparedRelease(root), [
          startsWith('$path contains an (unchanged from ...) claim'),
        ]);
      });
    }

    for (final (shape, notes) in [
      (
        'an inline-code search query',
        '- Document the literal search query `unchanged since 1.2.1`.',
      ),
      (
        'a quoted inline-code example',
        '> The old checker matched the literal string `(unchanged from 1.2.1)`.',
      ),
      (
        'a multiblock HTML pre inside a quote',
        '> <div><pre>\n>\n> Literal sample (unchanged from 1.2.1).\n>\n'
            '> </pre></div>',
      ),
      ('top-level indented code', '    $badClaim'),
      ('list-item fenced code', '- ```text\n  $badClaim\n  ```'),
      ('indented code in a list', '- Example\n\n      $badClaim'),
      ('HTML preformatted code', '<pre><code>$badClaim</code></pre>'),
      ('HTML preformatted text', '<pre>$badClaim</pre>'),
      (
        'a footnote defined in an older release',
        'See details[^rt].\n\n## 1.2.2\n\n[^rt]: $badClaim',
      ),
      (
        'shorter marker inside fenced code',
        '> ````text\n> ```\n> $badClaim\n> ````',
      ),
      (
        'separate list item and quote',
        '- Native audio (unchanged\n> from 1.2.1).',
      ),
      ('separate list items', '- Native audio is unchanged\n- from 1.2.1.'),
      (
        'separate HTML paragraphs',
        '<p>Native audio is unchanged</p>\n<p>from 1.2.1.</p>',
      ),
      (
        'separate GFM table cells',
        '| State | Version |\n| --- | --- |\n| unchanged | from 1.2.1 |',
      ),
      (
        'line-start comment interrupting a code span',
        'Use `the token\n<!--` in the sample.\n\n$badClaim',
      ),
    ]) {
      test('strict prep accepts notes with $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync('\n$notes\n', mode: FileMode.append);
        expect(_verifyPreparedRelease(root), isEmpty);
      });
    }

    test(
      'strict prep accepts a loose bridge item before a list fence in $path',
      () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync(
          changelog.readAsStringSync().replaceFirst(
            _preparedBaseline,
            '- ```html\n  <!--\n  ```\n\n$_preparedBaseline',
          ),
        );
        expect(_verifyPreparedRelease(root), isEmpty);
      },
    );

    for (final (shape, child) in [
      ('nested bullet', '  - The download instructions now include checksums.'),
      ('fenced example', '\n  ```text\n  $badClaim\n  ```'),
    ]) {
      test('strict prep accepts a Keep claim with a $shape in $path', () {
        final root = _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync(
          changelog.readAsStringSync().replaceFirst(
            '.\n\nRuntime',
            '.\n$child\n\nRuntime',
          ),
        );
        expect(_verifyPreparedRelease(root), isEmpty);
      });
    }

    for (final (shape, bridgeChanged, extra) in [
      ('changed bridge continuation', true, '  $badClaim\n'),
      ('Keep continuation', false, '  $badClaim\n'),
      ('Keep sub-bullet', false, '  - $badClaim\n'),
    ]) {
      test('strict prep scans $shape in $path', () {
        final root = bridgeChanged
            ? _preparedReleaseRepo(
                '- Aligned the default WebGPU bridge assets to `v9.9.9`.',
              )
            : _preparedReleaseRepo();
        final changelog = File('${root.path}/$path');
        changelog.writeAsStringSync(
          changelog.readAsStringSync().replaceFirst(
            '.\n\nRuntime',
            '.\n$extra\nRuntime',
          ),
        );
        expect(
          _verifyPreparedRelease(
            root,
            previousBridge: bridgeChanged ? 'v9.9.8' : 'v9.9.9',
          ),
          contains(startsWith('$path contains an (unchanged from ...) claim')),
        );
      });
    }

    test('strict prep rejects duplicate bridge claims in $path', () {
      const claim = '- Aligned the default WebGPU bridge assets to `v9.9.9`.';
      final root = _preparedReleaseRepo(claim);
      final changelog = File('${root.path}/$path');
      changelog.writeAsStringSync(
        changelog.readAsStringSync().replaceFirstMapped(
          RegExp(r'^- Aligned.*$', multiLine: true),
          (match) => '${match[0]}\n${match[0]}',
        ),
      );
      expect(_verifyPreparedRelease(root, previousBridge: 'v9.9.8'), [
        startsWith(
          '$path must contain exactly one matching WebGPU bridge claim',
        ),
      ]);
    });

    test('strict prep rejects duplicate baselines in $path', () {
      final root = _preparedReleaseRepo();
      File(
        '${root.path}/$path',
      ).writeAsStringSync('\n$_preparedBaseline\n', mode: FileMode.append);
      expect(_verifyPreparedRelease(root), [
        startsWith('$path must contain one complete Runtime baseline'),
      ]);
    });
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
    expect(readPinnedBridgeTag(Directory.current), 'v0.1.92');
    expect(bridgeNativeReleaseTag, 'v1.0.0-4');
    expect(bridgeApprovedNativePin, 'v1.0.0-4');
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

  test('Genkit DartPad pins the bridge with single-thread core preflight', () {
    const path =
        'packages/genkit_llamadart/example/dartpad/lib/bridge_bootstrap_web.dart';
    expect(
      File(path).readAsStringSync(),
      contains("const String defaultBridgeAssetsTag = 'v0.1.93';"),
      reason: path,
    );
  });

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
    }) =>
        'Runtime baseline: native llama.cpp `$llama` and Web use upstream '
        '`$upstream`; native LiteRT-LM uses `$liteRt` and '
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
      final root = baselineRepo(changelog: paragraph(), docs: paragraph());
      expect(findRuntimeBaselineDrift(root), isEmpty);
    });

    for (final runtime in ['native LiteRT-LM', 'stable-diffusion']) {
      for (final (index, path) in _preparedChangelogs.indexed) {
        test('rejects stays for $runtime in $path', () {
          final valid = paragraph();
          final invalid = valid.replaceFirst('$runtime uses', '$runtime stays');
          final root = baselineRepo(
            changelog: index == 0 ? invalid : valid,
            docs: index == 0 ? valid : invalid,
          );
          expect(findRuntimeBaselineDrift(root), [
            startsWith(
              '$path: the Runtime baseline paragraph no longer states the $runtime tag',
            ),
          ]);
        });
      }
    }

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
      expect(bridgeAssetsReleaseId, '454541989');
      expect(bridgeAssetsTagCommit, '056f474f389feaa4e02a62a3125549cb9154fabf');
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
