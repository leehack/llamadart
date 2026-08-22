@TestOn('vm')
library;

import 'dart:async';
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
const _llamaCppTag = 'b9998';
const _litertLmVersion = '1.0.0';

const _litertLmBundleSpecs = <_LiteRtLmBundleSpec>[
  _LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '${_hex('0')}',
    requiredLibraries: {'libLiteRtLm.so'},
  ),
];
''');
    final litertRuntimeDart = File(
      path.join(
        root.path,
        'lib',
        'src',
        'backends',
        'litert_lm',
        'litert_lm_runtime.dart',
      ),
    );
    await litertRuntimeDart.parent.create(recursive: true);
    await litertRuntimeDart.writeAsString('''
const _litertLmVersion = '1.0.0';
''');
    final macosPrepareScript = File(
      path.join(root.path, 'tool', 'macos_litert_lm_prepare_app.sh'),
    );
    await macosPrepareScript.parent.create(recursive: true);
    await macosPrepareScript.writeAsString('''
paths=(
  ".dart_tool/llamadart/litert_lm/1.0.0/macos_arm64"
  ".dart_tool/llamadart/litert_lm/1.0.0/macos/arm64"
)
''');
    await _writePackageSwift(
      root,
      'packages/llamadart_llama_cpp_flutter/darwin/'
          'llamadart_llama_cpp_flutter/Package.swift',
      'llamaCppTag',
      const ['llama'],
      const {'llama': 'llamadart-native-apple-xcframework-\\(llamaCppTag).zip'},
    );
    await _writePackageSwift(
      root,
      'packages/llamadart_litert_lm_flutter/darwin/'
          'llamadart_litert_lm_flutter/Package.swift',
      'liteRtLmTag',
      _litertAppleTargets.keys,
      {
        for (final entry in _litertAppleTargets.entries)
          entry.key: entry.value.$1.replaceAll('{tag}', '\\(liteRtLmTag)'),
      },
    );
    await _writeCompanionDocs(
      root,
      'packages/llamadart_llama_cpp_flutter',
      'leehack/llamadart-native',
    );
    await _writeCompanionDocs(
      root,
      'packages/llamadart_litert_lm_flutter',
      'leehack/litert-lm-native',
    );
    await _writeProjectDocs(root);

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

    final result = await _runPython([
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
    final litertRuntimeDartText = await litertRuntimeDart.readAsString();
    expect(
      litertRuntimeDartText,
      contains("const _litertLmVersion = '9.9.9';"),
    );
    final macosPrepareText = await macosPrepareScript.readAsString();
    expect(macosPrepareText, contains('litert_lm/9.9.9/macos_arm64'));
    expect(macosPrepareText, contains('litert_lm/9.9.9/macos/arm64'));
    expect(macosPrepareText, isNot(contains('litert_lm/1.0.0/')));

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
    expect(llamaReadme, contains('llamadart_llama_cpp_flutter: ^0.0.1'));
    final llamaPubspec = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/pubspec.yaml'),
    ).readAsString();
    expect(llamaPubspec, contains('version: 0.0.1'));
    final llamaChangelog = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(llamaChangelog, startsWith('## Unreleased'));
    expect(
      llamaChangelog,
      contains(
        '* Updated Apple SwiftPM native pin to '
        '`leehack/llamadart-native@$llamaTag`.',
      ),
    );
    expect(llamaChangelog, isNot(contains('llamadart-native@old')));
    expect(llamaChangelog, contains('## 0.0.1'));

    final rootReadme = await File(
      path.join(root.path, 'README.md'),
    ).readAsString();
    expect(rootReadme, contains('llamadart_native_tag: $llamaTag'));
    expect(
      rootReadme,
      contains('default `leehack/llamadart-native@$llamaTag` runtime'),
    );
    expect(
      rootReadme,
      contains('llamadart-native-windows-x64-$llamaTag.tar.gz'),
    );
    expect(rootReadme, contains('default native tag `$llamaTag`'));
    expect(rootReadme, contains('llamadart_llama_cpp_flutter: ^0.0.1'));
    expect(rootReadme, contains('llamadart_litert_lm_flutter: ^0.0.1'));
    expect(
      rootReadme,
      contains('`leehack/llamadart-native@$llamaTag` Apple XCFramework'),
    );
    expect(rootReadme, isNot(contains('b0001')));

    final installDoc = await File(
      path.join(root.path, 'website/docs/getting-started/installation.md'),
    ).readAsString();
    expect(installDoc, contains('llamadart_native_tag: $llamaTag'));
    expect(
      installDoc,
      contains('default `leehack/llamadart-native@$llamaTag` runtime'),
    );
    expect(
      installDoc,
      contains('llamadart-native-windows-x64-$llamaTag.tar.gz'),
    );
    expect(installDoc, contains('llamadart_llama_cpp_flutter: ^0.0.1'));
    expect(installDoc, contains('llamadart_litert_lm_flutter: ^0.0.1'));
    expect(installDoc, isNot(contains('b0001')));

    final supportMatrix = await File(
      path.join(root.path, 'website/docs/platforms/support-matrix.md'),
    ).readAsString();
    expect(
      supportMatrix,
      matches(
        RegExp(
          r'pins `llamadart-native` tag\s+`' + RegExp.escape(llamaTag) + r'`',
        ),
      ),
    );
    expect(
      supportMatrix,
      contains('module availability by bundle (`$llamaTag`)'),
    );
    expect(supportMatrix, contains('llamadart_native_tag: $llamaTag'));
    expect(supportMatrix, isNot(contains('b0001')));

    final coreChangelogFile = File(path.join(root.path, 'CHANGELOG.md'));
    final coreChangelog = await coreChangelogFile.readAsString();
    expect(coreChangelog, startsWith('## Unreleased'));
    expect(coreChangelog, contains('`leehack/llamadart-native@$llamaTag`'));
    expect(coreChangelog, contains('* Existing unreleased note.'));
    expect(coreChangelog, isNot(contains('b0001')));

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
    expect(litertReadme, contains('llamadart_litert_lm_flutter: ^0.0.1'));
    final litertPubspec = await File(
      path.join(root.path, 'packages/llamadart_litert_lm_flutter/pubspec.yaml'),
    ).readAsString();
    expect(litertPubspec, contains('version: 0.0.1'));
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
    expect(litertChangelog, contains('## 0.0.1'));

    final curatedCoreChangelog = coreChangelog.replaceFirst(
      '  aligned current README/website native override docs.',
      '  aligned current README/website native override docs. '
          'Curated compatibility evidence remains attached to this pin.',
    );
    expect(curatedCoreChangelog, isNot(coreChangelog));
    await coreChangelogFile.writeAsString(curatedCoreChangelog);

    final sameTagRerunResult = await _runPython([
      'tool/native/sync_native_release_pins.py',
      '--repo-root',
      root.path,
      '--release-json-dir',
      releaseDir.path,
      '--llama-cpp-tag',
      llamaTag,
      '--litert-lm-tag',
      litertTag,
    ]);
    expect(
      sameTagRerunResult.exitCode,
      0,
      reason: '${sameTagRerunResult.stdout}\n${sameTagRerunResult.stderr}',
    );
    expect(await coreChangelogFile.readAsString(), curatedCoreChangelog);
    expect(
      await File(
        path.join(
          root.path,
          'packages/llamadart_llama_cpp_flutter/CHANGELOG.md',
        ),
      ).readAsString(),
      llamaChangelog,
    );

    const nextLlamaTag = 'b10000';
    const nextLitertTag = 'v9.9.10';
    final nextLitertRuntimeChecksum = _hex('6');
    final nextLlamaAppleChecksum = _hex('7');
    final nextLitertAppleChecksums = {
      for (final entry in _litertAppleTargets.entries)
        entry.key: _hex(entry.value.$2.toUpperCase()),
    };
    await _writeReleaseFixture(
      releaseDir,
      'leehack/llamadart-native',
      nextLlamaTag,
      {
        'llamadart-native-apple-xcframework-$nextLlamaTag.zip':
            nextLlamaAppleChecksum,
      },
    );
    await _writeReleaseFixture(
      releaseDir,
      'leehack/litert-lm-native',
      nextLitertTag,
      {
        'litert-lm-native-runtime-linux-x64-$nextLitertTag.tar.gz':
            nextLitertRuntimeChecksum,
        for (final entry in _litertAppleTargets.entries)
          entry.value.$1.replaceAll('{tag}', nextLitertTag):
              nextLitertAppleChecksums[entry.key]!,
      },
    );

    final rerunResult = await _runPython([
      'tool/native/sync_native_release_pins.py',
      '--repo-root',
      root.path,
      '--release-json-dir',
      releaseDir.path,
      '--llama-cpp-tag',
      nextLlamaTag,
      '--litert-lm-tag',
      nextLitertTag,
    ]);

    expect(
      rerunResult.exitCode,
      0,
      reason: '${rerunResult.stdout}\n${rerunResult.stderr}',
    );

    final rerunCoreChangelog = await File(
      path.join(root.path, 'CHANGELOG.md'),
    ).readAsString();
    expect(
      rerunCoreChangelog,
      contains('`leehack/llamadart-native@$nextLlamaTag`'),
    );
    expect(
      rerunCoreChangelog,
      isNot(contains('`leehack/llamadart-native@$llamaTag`')),
    );
    expect(
      _occurrences(
        rerunCoreChangelog,
        '* Updated the default llama.cpp native runtime pin to',
      ),
      1,
    );

    final rerunLlamaChangelog = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(
      rerunLlamaChangelog,
      contains('`leehack/llamadart-native@$nextLlamaTag`.'),
    );
    expect(
      rerunLlamaChangelog,
      isNot(contains('`leehack/llamadart-native@$llamaTag`.')),
    );
    expect(
      _occurrences(
        rerunLlamaChangelog,
        '* Updated Apple SwiftPM native pin to',
      ),
      1,
    );

    final rerunLitertChangelog = await File(
      path.join(root.path, 'packages/llamadart_litert_lm_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(
      rerunLitertChangelog,
      contains('`leehack/litert-lm-native@$nextLitertTag`.'),
    );
    expect(
      rerunLitertChangelog,
      isNot(contains('`leehack/litert-lm-native@$litertTag`.')),
    );
    expect(
      _occurrences(
        rerunLitertChangelog,
        '* Updated Apple SwiftPM native pin to',
      ),
      1,
    );

    const releasePrepLlamaTag = 'b10001';
    await _writeReleaseFixture(
      releaseDir,
      'leehack/llamadart-native',
      releasePrepLlamaTag,
      {
        'llamadart-native-apple-xcframework-$releasePrepLlamaTag.zip': _hex(
          '9',
        ),
      },
    );
    final releasePrepResult = await _runPython([
      'tool/native/sync_native_release_pins.py',
      '--repo-root',
      root.path,
      '--release-json-dir',
      releaseDir.path,
      '--llama-cpp-tag',
      releasePrepLlamaTag,
      '--litert-lm-tag',
      'keep',
      '--bump-companion-versions',
    ]);
    expect(
      releasePrepResult.exitCode,
      0,
      reason: '${releasePrepResult.stdout}\n${releasePrepResult.stderr}',
    );

    final releasePrepPubspec = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/pubspec.yaml'),
    ).readAsString();
    expect(releasePrepPubspec, contains('version: 0.0.2'));
    final releasePrepReadme = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/README.md'),
    ).readAsString();
    expect(releasePrepReadme, contains('llamadart_llama_cpp_flutter: ^0.0.2'));
    final releasePrepChangelog = await File(
      path.join(root.path, 'packages/llamadart_llama_cpp_flutter/CHANGELOG.md'),
    ).readAsString();
    expect(releasePrepChangelog, startsWith('## 0.0.2'));
    expect(releasePrepChangelog, isNot(contains('## Unreleased')));
    expect(
      releasePrepChangelog,
      contains('`leehack/llamadart-native@$releasePrepLlamaTag`.'),
    );
    expect(
      releasePrepChangelog,
      isNot(contains('`leehack/llamadart-native@$nextLlamaTag`.')),
    );
    expect(
      releasePrepChangelog,
      contains('* Existing unreleased companion note.'),
    );
    expect(
      _occurrences(
        releasePrepChangelog,
        '* Updated Apple SwiftPM native pin to',
      ),
      1,
    );
    final releasePrepRootReadme = await File(
      path.join(root.path, 'README.md'),
    ).readAsString();
    expect(
      releasePrepRootReadme,
      contains('llamadart_llama_cpp_flutter: ^0.0.2'),
    );
  });

  test(
    'transitions b10514 to stable tags and upgrades semantic versions',
    () async {
      final setup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => setup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        setup.releaseDir,
        'v0.2.0',
        includeNativeReleaseTag: false,
      );

      final transition = await _runLlamaSync(setup, 'v0.2.0');
      expect(
        transition.exitCode,
        0,
        reason: '${transition.stdout}\n${transition.stderr}',
      );
      expect(
        await File(
          path.join(setup.root.path, 'hook', 'build.dart'),
        ).readAsString(),
        contains("const _llamaCppTag = 'v0.2.0';"),
      );
      expect(
        await File(path.join(setup.root.path, 'README.md')).readAsString(),
        contains('leehack/llamadart-native@v0.2.0'),
      );

      await _writeStableNativeReleaseFixture(setup.releaseDir, 'v0.2.1');
      final upgrade = await _runLlamaSync(setup, 'v0.2.1');
      expect(
        upgrade.exitCode,
        0,
        reason: '${upgrade.stdout}\n${upgrade.stderr}',
      );
      expect(
        await File(
          path.join(setup.root.path, 'hook', 'build.dart'),
        ).readAsString(),
        contains("const _llamaCppTag = 'v0.2.1';"),
      );

      final latestSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => latestSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        latestSetup.releaseDir,
        'latest',
        resolvedTag: 'v0.2.0',
      );
      final latest = await _runLlamaSync(latestSetup, 'latest');
      expect(latest.exitCode, 0, reason: '${latest.stdout}\n${latest.stderr}');
    },
  );

  test('requires explicit opt-in for stable to historical channel', () async {
    final setup = await _writeLlamaOnlyRepo('v0.2.0');
    addTearDown(() => setup.root.delete(recursive: true));
    await _writeReleaseFixture(
      setup.releaseDir,
      'leehack/llamadart-native',
      'b10514',
      {'llamadart-native-apple-xcframework-b10514.zip': _hex('a')},
    );

    final rejected = await _runLlamaSync(setup, 'b10514');
    expect(rejected.exitCode, 1);
    expect(
      rejected.stderr,
      contains('stable-to-historical/nightly native channel'),
    );
    expect(rejected.stderr, contains('--allow-legacy-tag'));

    final accepted = await _runLlamaSync(
      setup,
      'b10514',
      extraArguments: const ['--allow-legacy-tag'],
    );
    expect(
      accepted.exitCode,
      0,
      reason: '${accepted.stdout}\n${accepted.stderr}',
    );
  });

  test(
    'accepts nightly rebuild progression and legacy wrapper artifacts',
    () async {
      final setup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => setup.root.delete(recursive: true));
      for (final tag in const ['b10514-1', 'b10514-2']) {
        await _writeNightlyNativeReleaseFixture(setup.releaseDir, tag);
        final result = await _runLlamaSync(setup, tag);
        expect(
          result.exitCode,
          0,
          reason: '$tag\n${result.stdout}\n${result.stderr}',
        );
      }

      final legacySetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => legacySetup.root.delete(recursive: true));
      const legacyTag = 'b10514-llamadart.1';
      await _writeReleaseFixture(
        legacySetup.releaseDir,
        'leehack/llamadart-native',
        legacyTag,
        {'llamadart-native-apple-xcframework-$legacyTag.zip': _hex('b')},
      );
      final legacy = await _runLlamaSync(legacySetup, legacyTag);
      expect(legacy.exitCode, 0, reason: '${legacy.stdout}\n${legacy.stderr}');
    },
  );

  test('requires provenance manifests for new wrapper release forms', () async {
    final missingManifestSetup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => missingManifestSetup.root.delete(recursive: true));
    await _writeNightlyNativeReleaseFixture(
      missingManifestSetup.releaseDir,
      'b10514-1',
      includeManifest: false,
    );
    final missingManifest = await _runLlamaSync(
      missingManifestSetup,
      'b10514-1',
    );
    expect(missingManifest.exitCode, 1);
    expect(missingManifest.stderr, contains('missing required assets.json'));

    final missingNativeTagSetup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => missingNativeTagSetup.root.delete(recursive: true));
    await _writeNightlyNativeReleaseFixture(
      missingNativeTagSetup.releaseDir,
      'b10514-1',
      includeNativeReleaseTag: false,
    );
    final missingNativeTag = await _runLlamaSync(
      missingNativeTagSetup,
      'b10514-1',
    );
    expect(missingNativeTag.exitCode, 1);
    expect(missingNativeTag.stderr, contains('native_release_tag'));

    final missingLegacyAliasSetup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => missingLegacyAliasSetup.root.delete(recursive: true));
    await _writeNightlyNativeReleaseFixture(
      missingLegacyAliasSetup.releaseDir,
      'b10514-1',
      includeLegacyTag: false,
    );
    final missingLegacyAlias = await _runLlamaSync(
      missingLegacyAliasSetup,
      'b10514-1',
    );
    expect(missingLegacyAlias.exitCode, 1);
    expect(missingLegacyAlias.stderr, contains('tag field(s): tag'));

    final stableWrapperSetup = await _writeLlamaOnlyRepo('v0.2.0');
    addTearDown(() => stableWrapperSetup.root.delete(recursive: true));
    await _writeStableNativeReleaseFixture(
      stableWrapperSetup.releaseDir,
      'v0.2.0-1',
      includeNativeReleaseTag: false,
    );
    final stableWrapper = await _runLlamaSync(stableWrapperSetup, 'v0.2.0-1');
    expect(stableWrapper.exitCode, 1);
    expect(stableWrapper.stderr, contains('native_release_tag'));
  });

  test('reports non-UTF-8 release manifests without a traceback', () async {
    final setup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => setup.root.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(const [0xff]);
      await request.response.close();
    });

    const tag = 'v0.2.0';
    await _writeStableNativeReleaseFixture(setup.releaseDir, tag);
    final fixture = File(
      path.join(setup.releaseDir.path, 'leehack__llamadart-native__$tag.json'),
    );
    final release = jsonDecode(await fixture.readAsString()) as Map;
    final assets = release['assets'] as List;
    final manifestAsset = assets.cast<Map>().singleWhere(
      (asset) => asset['name'] == 'assets.json',
    );
    manifestAsset.remove('fixture_json');
    manifestAsset['browser_download_url'] =
        'http://${server.address.address}:${server.port}/assets.json';
    await fixture.writeAsString(jsonEncode(release));

    final result = await _runLlamaSync(setup, tag);

    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains('Failed to read release manifest assets.json'),
    );
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test(
    'workflow passes dispatch inputs through quoted environment variables',
    () async {
      final workflow = await File(
        path.join(
          Directory.current.path,
          '.github',
          'workflows',
          'sync_native_bindings.yml',
        ),
      ).readAsString();

      expect(workflow, contains('allow_nightly_channel:'));
      expect(
        _occurrences(workflow, 'transition_args+=(--allow-legacy-tag)'),
        2,
      );
      expect(_occurrences(workflow, r'"${transition_args[@]}"'), 2);
      expect(workflow, contains(r'NATIVE_TAG: ${{ inputs.native_tag }}'));
      expect(
        _occurrences(workflow, r'LITERT_LM_TAG: ${{ inputs.litert_lm_tag }}'),
        2,
      );
      expect(
        workflow,
        contains(
          r'RESOLVED_NATIVE_TAG: ${{ steps.sync_headers.outputs.resolved_tag }}',
        ),
      );
      expect(_occurrences(workflow, r'--llama-cpp-tag "${NATIVE_TAG}"'), 1);
      expect(_occurrences(workflow, r'--tag "${NATIVE_TAG}"'), 1);
      expect(
        _occurrences(workflow, r'--llama-cpp-tag "${RESOLVED_NATIVE_TAG}"'),
        1,
      );
      expect(_occurrences(workflow, r'--litert-lm-tag "${LITERT_LM_TAG}"'), 2);
      expect(
        workflow,
        isNot(contains(r'${{ github.event.inputs.native_tag }}')),
      );
      expect(
        workflow,
        isNot(contains(r'${{ github.event.inputs.litert_lm_tag }}')),
      );
      expect(
        workflow,
        isNot(contains(r'--llama-cpp-tag "${{ inputs.native_tag }}"')),
      );
      expect(
        workflow,
        isNot(contains(r'--litert-lm-tag "${{ inputs.litert_lm_tag }}"')),
      );
    },
  );

  test('native tag consumers use canonical nightly core grammar', () async {
    final sources = <String, String>{
      'Python synchronizer': await File(
        'tool/native/sync_native_release_pins.py',
      ).readAsString(),
      'Bash header sync': await File(
        'tool/native/sync_native_headers_and_bindings.sh',
      ).readAsString(),
      'Dart build hook': await File('hook/build.dart').readAsString(),
      'release-doc verifier': await File(
        'tool/testing/verify_release_docs_versions.dart',
      ).readAsString(),
    };

    expect(sources['Python synchronizer'], contains(r'r"^b(0|[1-9][0-9]*)$"'));
    expect(
      sources['Bash header sync'],
      contains("nightly_tag_pattern='^b(0|[1-9][0-9]*)\$'"),
    );
    for (final entry in sources.entries.where(
      (entry) =>
          entry.key.startsWith('Dart') || entry.key.startsWith('release'),
    )) {
      expect(entry.value, contains(r'b(?:0|[1-9][0-9]*)'), reason: entry.key);
      expect(entry.value, isNot(contains(r'b[0-9]+')), reason: entry.key);
    }
  });

  test('orders stable wrapper rebuilds between upstream stable tags', () async {
    final setup = await _writeLlamaOnlyRepo('v0.2.0');
    addTearDown(() => setup.root.delete(recursive: true));
    for (final tag in const ['v0.2.0-1', 'v0.2.0-2', 'v0.2.1']) {
      await _writeStableNativeReleaseFixture(setup.releaseDir, tag);
      final result = await _runLlamaSync(setup, tag);
      expect(
        result.exitCode,
        0,
        reason: '$tag\n${result.stdout}\n${result.stderr}',
      );
    }
  });

  test('rejects invalid native release tags before release lookup', () async {
    final setup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => setup.root.delete(recursive: true));

    for (final tag in const [
      'v1.2',
      'v01.2.3',
      'b00',
      'b0000',
      'b0001',
      'b0001-1',
      'b0001-llamadart.1',
      'b1-01',
      'b1-llamadart.01',
      'b10514-custom',
      'b10514-0',
      'v0.2.0-0',
      'v0.2.0-llamadart.1',
      'v0.2.0-custom.1',
      '../v0.2.0',
      r'b1; touch "$RUNNER_TEMP/llamadart-pwned"',
      r'b1$(touch "$RUNNER_TEMP/llamadart-pwned")',
    ]) {
      final result = await _runLlamaSync(setup, tag);
      expect(result.exitCode, 1, reason: tag);
      expect(
        result.stderr,
        contains('Invalid llamadart-native release tag'),
        reason: tag,
      );
    }
  });

  test(
    'header sync rejects invalid native tags before network lookup',
    () async {
      for (final tag in const [
        'v1.2',
        'b0000',
        'b0001-1',
        'b0001-llamadart.1',
        'b1-01',
        'b1-llamadart.01',
        'b10514-0',
        'v0.2.0-llamadart.1',
        r'b1; touch "$RUNNER_TEMP/llamadart-pwned"',
      ]) {
        final result = await Process.run('bash', [
          'tool/native/sync_native_headers_and_bindings.sh',
          '--tag',
          tag,
          '--skip-ffigen',
        ]);
        expect(result.exitCode, 1, reason: tag);
        expect(
          result.stderr,
          contains('Invalid llamadart-native tag'),
          reason: tag,
        );
        expect(
          result.stderr,
          contains('stable vMAJOR.MINOR.PATCH'),
          reason: tag,
        );
      }
    },
    skip: Platform.isWindows ? 'requires a POSIX Bash runtime' : false,
  );

  test(
    'header sync rejects wrapper prereleases resolved through latest',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'native_latest_wrapper_',
      );
      addTearDown(() => root.delete(recursive: true));
      final fakeBin = Directory(path.join(root.path, 'bin'))
        ..createSync(recursive: true);
      final curl = File(path.join(fakeBin.path, 'curl'));
      await curl.writeAsString('''#!/usr/bin/env bash
printf '%s\\n' '{"tag_name":"v0.2.0-1","assets":[]}'
''');
      await Process.run('chmod', ['+x', curl.path]);

      final result = await Process.run(
        'bash',
        [
          'tool/native/sync_native_headers_and_bindings.sh',
          '--tag',
          'latest',
          '--skip-ffigen',
        ],
        environment: {
          ...Platform.environment,
          'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
        },
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('latest resolved to v0.2.0-1'));
      expect(result.stderr, contains('only unsuffixed vMAJOR.MINOR.PATCH'));
    },
    skip: Platform.isWindows ? 'requires a POSIX Bash runtime' : false,
  );

  test('rejects semantic, nightly, and legacy wrapper rollbacks', () async {
    final semanticSetup = await _writeLlamaOnlyRepo('v0.2.1');
    addTearDown(() => semanticSetup.root.delete(recursive: true));
    await _writeStableNativeReleaseFixture(semanticSetup.releaseDir, 'v0.2.0');
    final semanticRollback = await _runLlamaSync(semanticSetup, 'v0.2.0');
    expect(semanticRollback.exitCode, 1);
    expect(semanticRollback.stderr, contains('native release rollback'));

    final wrapperSetup = await _writeLlamaOnlyRepo('b10514-2');
    addTearDown(() => wrapperSetup.root.delete(recursive: true));
    await _writeReleaseFixture(
      wrapperSetup.releaseDir,
      'leehack/llamadart-native',
      'b10514-1',
      {'llamadart-native-apple-xcframework-b10514-1.zip': _hex('c')},
    );
    final wrapperRollback = await _runLlamaSync(wrapperSetup, 'b10514-1');
    expect(wrapperRollback.exitCode, 1);
    expect(wrapperRollback.stderr, contains('native release rollback'));

    final legacyWrapperSetup = await _writeLlamaOnlyRepo('b10514-llamadart.2');
    addTearDown(() => legacyWrapperSetup.root.delete(recursive: true));
    await _writeReleaseFixture(
      legacyWrapperSetup.releaseDir,
      'leehack/llamadart-native',
      'b10514-llamadart.1',
      {'llamadart-native-apple-xcframework-b10514-llamadart.1.zip': _hex('c')},
    );
    final legacyWrapperRollback = await _runLlamaSync(
      legacyWrapperSetup,
      'b10514-llamadart.1',
    );
    expect(legacyWrapperRollback.exitCode, 1);
    expect(legacyWrapperRollback.stderr, contains('native release rollback'));

    final aliasSetup = await _writeLlamaOnlyRepo('b10514-llamadart.1');
    addTearDown(() => aliasSetup.root.delete(recursive: true));
    await _writeReleaseFixture(
      aliasSetup.releaseDir,
      'leehack/llamadart-native',
      'b10514-1',
      {'llamadart-native-apple-xcframework-b10514-1.zip': _hex('c')},
    );
    final aliasCollision = await _runLlamaSync(aliasSetup, 'b10514-1');
    expect(aliasCollision.exitCode, 1);
    expect(
      aliasCollision.stderr,
      contains('equivalent native release sequence aliases'),
    );

    final stableWrapperSetup = await _writeLlamaOnlyRepo('v0.2.0-2');
    addTearDown(() => stableWrapperSetup.root.delete(recursive: true));
    await _writeStableNativeReleaseFixture(
      stableWrapperSetup.releaseDir,
      'v0.2.0-1',
    );
    final stableWrapperRollback = await _runLlamaSync(
      stableWrapperSetup,
      'v0.2.0-1',
    );
    expect(stableWrapperRollback.exitCode, 1);
    expect(stableWrapperRollback.stderr, contains('native release rollback'));

    final alignedSetup = await _writeLlamaOnlyRepo('v0.2.1');
    addTearDown(() => alignedSetup.root.delete(recursive: true));
    await _writeStableNativeReleaseFixture(alignedSetup.releaseDir, 'v0.2.0-3');
    final alignedRollback = await _runLlamaSync(alignedSetup, 'v0.2.0-3');
    expect(alignedRollback.exitCode, 1);
    expect(alignedRollback.stderr, contains('native release rollback'));
  });

  test(
    'latest accepts only unsuffixed stable tags and rejects release skew',
    () async {
      final latestSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => latestSetup.root.delete(recursive: true));
      await _writeReleaseFixture(
        latestSetup.releaseDir,
        'leehack/llamadart-native',
        'latest',
        {'llamadart-native-apple-xcframework-b10515-1.zip': _hex('d')},
        resolvedTag: 'b10515-1',
      );
      final latest = await _runLlamaSync(latestSetup, 'latest');
      expect(latest.exitCode, 1);
      expect(latest.stderr, contains('latest resolved to b10515-1'));
      expect(latest.stderr, contains('only unsuffixed vMAJOR.MINOR.PATCH'));

      final latestWrapperSetup = await _writeLlamaOnlyRepo('v0.2.0');
      addTearDown(() => latestWrapperSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        latestWrapperSetup.releaseDir,
        'latest',
        resolvedTag: 'v0.2.0-1',
      );
      final latestWrapper = await _runLlamaSync(latestWrapperSetup, 'latest');
      expect(latestWrapper.exitCode, 1);
      expect(latestWrapper.stderr, contains('latest resolved to v0.2.0-1'));
      expect(
        latestWrapper.stderr,
        contains('select GitHub-prerelease wrapper rebuilds'),
      );

      final releaseSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => releaseSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        releaseSetup.releaseDir,
        'v0.2.0',
        resolvedTag: 'v0.2.1',
      );
      final releaseSkew = await _runLlamaSync(releaseSetup, 'v0.2.0');
      expect(releaseSkew.exitCode, 1);
      expect(releaseSkew.stderr, contains('metadata resolved v0.2.1'));

      final manifestSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => manifestSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        manifestSetup.releaseDir,
        'v0.2.0',
        manifestTag: 'v0.2.1',
      );
      final manifestSkew = await _runLlamaSync(manifestSetup, 'v0.2.0');
      expect(manifestSkew.exitCode, 1);
      expect(
        manifestSkew.stderr,
        contains('Refusing version-skewed native assets'),
      );

      final abiSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => abiSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        abiSetup.releaseDir,
        'v0.2.0',
        llamaCppTag: 'v0.1.9',
      );
      final abiSkew = await _runLlamaSync(abiSetup, 'v0.2.0');
      expect(abiSkew.exitCode, 1);
      expect(abiSkew.stderr, contains('version-skewed native ABI metadata'));

      final aliasSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => aliasSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        aliasSetup.releaseDir,
        'v0.2.0',
        legacyManifestTag: 'v0.2.1',
      );
      final aliasSkew = await _runLlamaSync(aliasSetup, 'v0.2.0');
      expect(aliasSkew.exitCode, 1);
      expect(aliasSkew.stderr, contains('disagrees with legacy tag alias'));

      final wrapperRefSetup = await _writeLlamaOnlyRepo('v0.2.0');
      addTearDown(() => wrapperRefSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        wrapperRefSetup.releaseDir,
        'v0.2.0-1',
        llamaCppTag: 'v0.2.0-1',
      );
      final wrapperRefSkew = await _runLlamaSync(wrapperRefSetup, 'v0.2.0-1');
      expect(wrapperRefSkew.exitCode, 1);
      expect(
        wrapperRefSkew.stderr,
        contains('version-skewed native ABI metadata'),
      );

      final nightlyWrapperRefSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => nightlyWrapperRefSetup.root.delete(recursive: true));
      await _writeNightlyNativeReleaseFixture(
        nightlyWrapperRefSetup.releaseDir,
        'b10514-1',
        llamaCppTag: 'b10514-1',
      );
      final nightlyWrapperRefSkew = await _runLlamaSync(
        nightlyWrapperRefSetup,
        'b10514-1',
      );
      expect(nightlyWrapperRefSkew.exitCode, 1);
      expect(
        nightlyWrapperRefSkew.stderr,
        contains('version-skewed native ABI metadata'),
      );
    },
  );

  test(
    'rejects unsupported contracts, unavailable bundles, and checksum skew',
    () async {
      final contractSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => contractSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        contractSetup.releaseDir,
        'v0.2.0',
        hookContractVersion: 2,
      );
      final contract = await _runLlamaSync(contractSetup, 'v0.2.0');
      expect(contract.exitCode, 1);
      expect(contract.stderr, contains('requires native hook contract 2'));

      final bundleSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => bundleSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        bundleSetup.releaseDir,
        'v0.2.0',
        omittedBundle: 'windows-arm64',
      );
      final bundle = await _runLlamaSync(bundleSetup, 'v0.2.0');
      expect(bundle.exitCode, 1);
      expect(bundle.stderr, contains('missing required bundle(s)'));
      expect(bundle.stderr, contains('windows-arm64'));

      final digestSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => digestSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        digestSetup.releaseDir,
        'v0.2.0',
        missingDigestFile: 'llamadart-native-linux-x64-v0.2.0.tar.gz',
      );
      final digest = await _runLlamaSync(digestSetup, 'v0.2.0');
      expect(digest.exitCode, 1);
      expect(digest.stderr, contains('does not publish a GitHub SHA-256'));

      for (final metadataFile in const ['assets.json', 'SHA256SUMS']) {
        final metadataDigestSetup = await _writeLlamaOnlyRepo('b10514');
        addTearDown(() => metadataDigestSetup.root.delete(recursive: true));
        await _writeStableNativeReleaseFixture(
          metadataDigestSetup.releaseDir,
          'v0.2.0',
          missingDigestFile: metadataFile,
        );
        final metadataDigest = await _runLlamaSync(
          metadataDigestSetup,
          'v0.2.0',
        );
        expect(metadataDigest.exitCode, 1, reason: metadataFile);
        expect(
          metadataDigest.stderr,
          contains(
            'does not publish a GitHub SHA-256 digest for $metadataFile',
          ),
          reason: metadataFile,
        );
      }

      final sumsSetup = await _writeLlamaOnlyRepo('b10514');
      addTearDown(() => sumsSetup.root.delete(recursive: true));
      await _writeStableNativeReleaseFixture(
        sumsSetup.releaseDir,
        'v0.2.0',
        checksumSumsMismatchFile: 'llamadart-native-headers-v0.2.0.tar.gz',
      );
      final sums = await _runLlamaSync(sumsSetup, 'v0.2.0');
      expect(sums.exitCode, 1);
      expect(sums.stderr, contains('SHA256SUMS checksum'));
    },
  );

  test('rejects non-object release assets without a traceback', () async {
    final setup = await _writeLlamaOnlyRepo('b10514');
    addTearDown(() => setup.root.delete(recursive: true));
    await _writeStableNativeReleaseFixture(setup.releaseDir, 'v0.2.0');
    final fixture = File(
      path.join(
        setup.releaseDir.path,
        'leehack__llamadart-native__v0.2.0.json',
      ),
    );
    final payload =
        jsonDecode(await fixture.readAsString()) as Map<String, Object?>;
    (payload['assets'] as List<Object?>).add('not-an-object');
    await fixture.writeAsString(jsonEncode(payload));

    final result = await _runLlamaSync(setup, 'v0.2.0');
    expect(result.exitCode, 1);
    expect(result.stderr, contains('asset list contains a non-object entry'));
    expect(result.stderr, isNot(contains('Traceback')));
    expect(result.stderr, isNot(contains('AttributeError')));
  });
}

Future<_LlamaSyncSetup> _writeLlamaOnlyRepo(String currentTag) async {
  final root = await Directory.systemTemp.createTemp('native_semver_sync_');
  await Directory(path.join(root.path, 'hook')).create(recursive: true);
  await File(path.join(root.path, 'hook', 'build.dart')).writeAsString('''
const _llamaCppTag = '$currentTag';
''');
  final releaseDir = Directory(path.join(root.path, 'releases'))
    ..createSync(recursive: true);
  await _writePackageSwift(
    root,
    'packages/llamadart_llama_cpp_flutter/darwin/'
        'llamadart_llama_cpp_flutter/Package.swift',
    'llamaCppTag',
    const ['llama'],
    const {'llama': 'llamadart-native-apple-xcframework-\\(llamaCppTag).zip'},
  );
  await _writeCompanionDocs(
    root,
    'packages/llamadart_llama_cpp_flutter',
    'leehack/llamadart-native',
  );
  await _writeProjectDocs(root);
  return _LlamaSyncSetup(root, releaseDir);
}

Future<ProcessResult> _runLlamaSync(
  _LlamaSyncSetup setup,
  String tag, {
  List<String> extraArguments = const [],
}) {
  return _runPython([
    'tool/native/sync_native_release_pins.py',
    '--repo-root',
    setup.root.path,
    '--release-json-dir',
    setup.releaseDir.path,
    '--llama-cpp-tag',
    tag,
    '--litert-lm-tag',
    'keep',
    ...extraArguments,
  ]);
}

Future<void> _writeStableNativeReleaseFixture(
  Directory dir,
  String fixtureTag, {
  String? resolvedTag,
  String? manifestTag,
  String? legacyManifestTag,
  String? llamaCppTag,
  bool includeNativeReleaseTag = true,
  int hookContractVersion = 1,
  String? omittedBundle,
  String? missingDigestFile,
  String? checksumSumsMismatchFile,
}) {
  final releaseTag = resolvedTag ?? fixtureTag;
  final bundleNames = _stableNativeBundles
      .where((bundle) => bundle != omittedBundle)
      .toList(growable: false);
  final artifactFiles = <String>[
    for (final bundle in bundleNames)
      'llamadart-native-$bundle-$releaseTag.tar.gz',
    'llamadart-native-apple-xcframework-$releaseTag.zip',
    'llamadart-native-headers-$releaseTag.tar.gz',
  ];
  final artifacts = [
    for (var index = 0; index < artifactFiles.length; index++)
      {
        'file': artifactFiles[index],
        'sha256': _hex(_fixtureHexCharacters[index]),
      },
  ];
  final manifest = {
    if (includeNativeReleaseTag)
      'native_release_tag': manifestTag ?? releaseTag,
    'tag': legacyManifestTag ?? manifestTag ?? releaseTag,
    'llama_cpp_tag': llamaCppTag ?? _upstreamTagForNativeTag(releaseTag),
    'llama_cpp_commit': _hex('a').substring(0, 40),
    'native_commit': _hex('b').substring(0, 40),
    'hook_contract_version': hookContractVersion,
    'artifacts': artifacts,
  };
  final payload = {
    'tag_name': releaseTag,
    'assets': [
      for (final artifact in artifacts)
        {
          'name': artifact['file'],
          if (artifact['file'] != missingDigestFile)
            'digest': 'sha256:${artifact['sha256']}',
        },
      {
        'name': 'assets.json',
        if (missingDigestFile != 'assets.json') 'digest': 'sha256:${_hex('c')}',
        'fixture_json': manifest,
      },
      {
        'name': 'SHA256SUMS',
        if (missingDigestFile != 'SHA256SUMS') 'digest': 'sha256:${_hex('d')}',
        'fixture_text': [
          for (final artifact in artifacts)
            '${artifact['file'] == checksumSumsMismatchFile ? _hex('f') : artifact['sha256']}  ${artifact['file']}',
        ].join('\n'),
      },
    ],
  };
  final file = File(
    path.join(dir.path, 'leehack__llamadart-native__$fixtureTag.json'),
  );
  return file.writeAsString(jsonEncode(payload));
}

Future<void> _writeNightlyNativeReleaseFixture(
  Directory dir,
  String tag, {
  bool includeManifest = true,
  bool includeNativeReleaseTag = true,
  bool includeLegacyTag = true,
  String? llamaCppTag,
}) {
  final artifactFile = 'llamadart-native-apple-xcframework-$tag.zip';
  final artifactChecksum = _hex('b');
  final manifest = {
    if (includeNativeReleaseTag) 'native_release_tag': tag,
    if (includeLegacyTag) 'tag': tag,
    'llama_cpp_tag':
        llamaCppTag ?? tag.replaceFirst(RegExp(r'-[1-9][0-9]*$'), ''),
    'llama_cpp_commit': _hex('a').substring(0, 40),
    'native_commit': _hex('b').substring(0, 40),
    'hook_contract_version': 1,
    'artifacts': [
      {'file': artifactFile, 'sha256': artifactChecksum},
    ],
  };
  final payload = {
    'tag_name': tag,
    'assets': [
      {'name': artifactFile, 'digest': 'sha256:$artifactChecksum'},
      if (includeManifest)
        {
          'name': 'assets.json',
          'digest': 'sha256:${_hex('c')}',
          'fixture_json': manifest,
        },
    ],
  };
  final file = File(
    path.join(dir.path, 'leehack__llamadart-native__$tag.json'),
  );
  return file.writeAsString(jsonEncode(payload));
}

String _upstreamTagForNativeTag(String tag) {
  if (tag.startsWith('v')) {
    return tag.replaceFirst(RegExp(r'-[1-9][0-9]*$'), '');
  }
  return tag.split('-llamadart.').first;
}

int _occurrences(String text, String needle) => needle.allMatches(text).length;

Future<ProcessResult> _runPython(List<String> arguments) async {
  final executable = Platform.isWindows ? 'python' : 'python3';
  final process = await Process.start(executable, arguments);
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .forEach(stdout.write);
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .forEach(stderr.write);

  late final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    fail(
      '$executable ${arguments.join(' ')} timed out.\n'
      'stdout:\n$stdout\nstderr:\n$stderr',
    );
  }

  await Future.wait([stdoutDone, stderrDone]);
  return ProcessResult(
    process.pid,
    exitCode,
    stdout.toString(),
    stderr.toString(),
  );
}

Future<void> _writePackageSwift(
  Directory root,
  String relativePath,
  String tagVariable,
  Iterable<String> targetNames,
  Map<String, String> artifactNames,
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
            artifactName: "${artifactNames[target]}",
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
  String repo,
) async {
  final packageDir = Directory(path.join(root.path, relativePackagePath));
  await packageDir.create(recursive: true);
  final packageName = path.basename(relativePackagePath);
  await File(path.join(packageDir.path, 'pubspec.yaml')).writeAsString('''
name: $packageName
version: 0.0.1
''');
  await File(path.join(packageDir.path, 'README.md')).writeAsString('''
# Test package

dependencies:
  $packageName: ^0.0.1

The Apple SwiftPM manifest pins
`$repo@old`.
''');
  await File(path.join(packageDir.path, 'CHANGELOG.md')).writeAsString('''
## Unreleased

* Updated Apple SwiftPM native pin to
  `$repo@old`.

* Existing unreleased companion note.

## 0.0.1

* Initial package.
''');
}

Future<void> _writeProjectDocs(Directory root) async {
  await File(path.join(root.path, 'README.md')).writeAsString('''
llamadart_native_tag: b1-llamadart.1

ABI-compatible with the default `leehack/llamadart-native@b1-llamadart.1` runtime.

dependencies:
  llamadart: ^0.1.0
  llamadart_llama_cpp_flutter: ^0.0.1
  llamadart_litert_lm_flutter: ^0.0.1

`llamadart-native-windows-x64-b1-llamadart.1.tar.gz`

Available llama.cpp module matrix from the default native tag `b1-llamadart.1`:

| Native llama.cpp / GGUF | `leehack/llamadart-native@b1-llamadart.1` |
| Apple SPM llama.cpp / GGUF | `llamadart_llama_cpp_flutter` pins `leehack/llamadart-native@b1-llamadart.1` Apple XCFramework |
''');

  final installDoc = File(
    path.join(root.path, 'website/docs/getting-started/installation.md'),
  );
  await installDoc.parent.create(recursive: true);
  await installDoc.writeAsString('''
llamadart_native_tag: b1-llamadart.1

ABI-compatible with the default `leehack/llamadart-native@b1-llamadart.1` runtime.

dependencies:
  llamadart: ^0.1.0
  llamadart_llama_cpp_flutter: ^0.0.1
  llamadart_litert_lm_flutter: ^0.0.1

`llamadart-native-windows-x64-b1-llamadart.1.tar.gz`
''');

  final supportMatrix = File(
    path.join(root.path, 'website/docs/platforms/support-matrix.md'),
  );
  await supportMatrix.parent.create(recursive: true);
  await supportMatrix.writeAsString('''
The native-assets hook currently pins `llamadart-native` tag
`b1-llamadart.1` and
`litert-lm-native` release `v0.13.1-native.1`.

## Current llama.cpp module availability by bundle (`b1-llamadart.1`)

llamadart_native_tag: b1-llamadart.1
''');

  await File(path.join(root.path, 'CHANGELOG.md')).writeAsString('''
## Unreleased

* Updated the default llama.cpp native runtime pin to
  `leehack/llamadart-native@b1`, regenerated matching Dart FFI bindings,
  refreshed the `llamadart_llama_cpp_flutter` Apple SwiftPM checksum, and
  aligned current README/website native override docs.

* Existing unreleased note.

## 0.1.0

* Previous release.
''');
}

Future<void> _writeReleaseFixture(
  Directory dir,
  String repo,
  String tag,
  Map<String, String> assets, {
  String? resolvedTag,
}) {
  final file = File(
    path.join(dir.path, '${repo.replaceAll('/', '__')}__$tag.json'),
  );
  final payload = {
    'tag_name': resolvedTag ?? tag,
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
  'CLiteRTLMMac': (
    'litert-lm-native-apple-CLiteRTLMMac-xcframework-{tag}.zip',
    '8',
  ),
};

const _stableNativeBundles = <String>[
  'android-arm64',
  'android-x64',
  'ios-arm64',
  'ios-arm64-sim',
  'ios-x86_64-sim',
  'linux-arm64',
  'linux-x64',
  'macos-arm64',
  'macos-x86_64',
  'windows-arm64',
  'windows-x64',
];

const _fixtureHexCharacters = <String>[
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  'a',
  'b',
  'c',
];

final class _LlamaSyncSetup {
  const _LlamaSyncSetup(this.root, this.releaseDir);

  final Directory root;
  final Directory releaseDir;
}
