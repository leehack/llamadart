@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;
import '../../support/hooks_runner_layout.dart';

void main() {
  final nativeTag = _readHookNativeTag();
  final litertVersion = _readHookLiteRtLmVersion();
  final cacheRelativeDir =
      '.dart_tool/llamadart/native_bundles/$nativeTag/linux-x64';
  final bundleRelativePath = '$cacheRelativeDir/extracted';
  final bundleDir = Directory(bundleRelativePath);
  final backupDir = Directory('$bundleRelativePath.__hook_test_backup');
  const historicalNativeTag = 'b10545';
  final historicalBundleRelativePath =
      '.dart_tool/llamadart/native_bundles/$historicalNativeTag/'
      'linux-x64/extracted';
  final historicalBundleDir = Directory(historicalBundleRelativePath);
  final historicalBackupDir = Directory(
    '$historicalBundleRelativePath.__hook_test_backup',
  );
  final litertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/linux/x64',
  );
  final litertBackupDir = Directory(
    '${litertBundleDir.path}.__hook_test_backup',
  );
  final archiveFile = File(
    '$cacheRelativeDir/llamadart-native-linux-x64-$nativeTag.tar.gz',
  );
  final archiveBackupFile = File('${archiveFile.path}.__hook_test_backup');

  setUpAll(() async {
    if (backupDir.existsSync()) {
      await backupDir.delete(recursive: true);
    }
    if (historicalBackupDir.existsSync()) {
      await historicalBackupDir.delete(recursive: true);
    }
    if (litertBackupDir.existsSync()) {
      await litertBackupDir.delete(recursive: true);
    }
    if (archiveBackupFile.existsSync()) {
      await archiveBackupFile.delete();
    }

    if (bundleDir.existsSync()) {
      await bundleDir.rename(backupDir.path);
    }
    if (archiveFile.existsSync()) {
      await archiveFile.rename(archiveBackupFile.path);
    }
    if (historicalBundleDir.existsSync()) {
      await historicalBundleDir.rename(historicalBackupDir.path);
    }
    if (litertBundleDir.existsSync()) {
      await litertBundleDir.rename(litertBackupDir.path);
    }
  });

  setUp(() async {
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    await _writeBundleLibraries(bundleDir, const [
      'libllamadart.so',
      'libmtmd.so',
      'libllama.so',
      'libllama-common.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
      'libggml-vulkan.so',
    ]);
    await _writeBundleLibraries(historicalBundleDir, const [
      'libllamadart.so',
      'libmtmd.so',
      'libllama.so',
      'libllama-common.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
      'libggml-vulkan.so',
    ]);
    await _writeBundleLibraries(litertBundleDir, _linuxLiteRtLibraries);

    if (archiveFile.existsSync()) {
      await archiveFile.delete();
    }
  });

  tearDownAll(() async {
    if (archiveFile.existsSync()) {
      await archiveFile.delete();
    }
    if (archiveBackupFile.existsSync()) {
      await archiveBackupFile.rename(archiveFile.path);
    }
    if (bundleDir.existsSync()) {
      await bundleDir.delete(recursive: true);
    }
    if (backupDir.existsSync()) {
      await backupDir.rename(bundleDir.path);
    }
    if (historicalBundleDir.existsSync()) {
      await historicalBundleDir.delete(recursive: true);
    }
    if (historicalBackupDir.existsSync()) {
      await historicalBackupDir.rename(historicalBundleDir.path);
    }
    if (litertBundleDir.existsSync()) {
      await litertBundleDir.delete(recursive: true);
    }
    if (litertBackupDir.existsSync()) {
      await litertBackupDir.rename(litertBundleDir.path);
    }
  });

  test(
    'build hook emits linux SONAME aliases and all runtimes by default',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        check: (input, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
          expect(codeAssetIds, contains('package:llamadart/llamadart'));

          final emittedNames = codeAssets
              .map((asset) => path.basename(asset.file!.toFilePath()))
              .toSet();

          expect(emittedNames, contains('libllamadart.so'));
          expect(emittedNames, contains('libmtmd.so'));
          expect(emittedNames, contains('libmtmd.so.0'));
          expect(emittedNames, isNot(contains('libmtmd.so.SOVERSION')));
          expect(emittedNames, contains('libllama.so'));
          expect(emittedNames, contains('libllama.so.0'));
          expect(emittedNames, contains('libllama-common.so'));
          expect(emittedNames, contains('libllama-common.so.0'));
          expect(emittedNames, contains('libggml.so'));
          expect(emittedNames, contains('libggml.so.0'));
          expect(emittedNames, contains('libggml-base.so'));
          expect(emittedNames, contains('libggml-base.so.0'));
          for (final library in _linuxLiteRtLibraries) {
            expect(emittedNames, contains(library));
          }
          for (final assetName in _linuxLiteRtAssetNames) {
            expect(codeAssetIds, contains('package:llamadart/$assetName'));
          }
        },
      );
    },
  );

  group('Flutter Edge AI coexistence', () {
    const workspacePubspec = 'name: workspace\nworkspace: [app, other]\n';
    final cases =
        <
          ({
            String name,
            List<String> roots,
            Map<String, List<String>> dependencies,
            Map<String, List<String>> devDependencies,
            String pubspec,
            Object? runtimes,
            bool bundlesLiteRtLm,
            List<String> warns,
          })
        >[
          for (final runtimes in [null, 'both'])
            (
              name: 'standalone app reaching $_edgeAiLlama, runtimes $runtimes',
              roots: ['app'],
              dependencies: {
                'app': [_edgeAiLlama],
                _edgeAiLlama: ['llamadart'],
                'llamadart': [],
              },
              devDependencies: {},
              pubspec: 'name: app\n',
              runtimes: runtimes,
              bundlesLiteRtLm: false,
              warns: [_edgeAiLlama, 'name litert_lm'],
            ),
          (
            name: 'standalone app with $_edgeAiLiteRtLm',
            roots: ['app'],
            dependencies: {
              'app': ['llamadart', _edgeAiLiteRtLm],
              _edgeAiLiteRtLm: [],
              'llamadart': [],
            },
            devDependencies: {},
            pubspec: 'name: app\n',
            runtimes: null,
            bundlesLiteRtLm: false,
            warns: [_edgeAiLiteRtLm, 'owns the same native libraries'],
          ),
          (
            name: 'standalone app naming litert_lm beside $_edgeAiLlama',
            roots: ['app'],
            dependencies: {
              'app': [_edgeAiLlama],
              _edgeAiLlama: ['llamadart'],
              'llamadart': [],
            },
            devDependencies: {},
            pubspec: 'name: app\n',
            runtimes: ['llama_cpp', 'litert_lm'],
            bundlesLiteRtLm: true,
            warns: [],
          ),
          (
            name: 'standalone app with $_edgeAiLlama as a dev dependency',
            roots: ['app'],
            dependencies: {
              'app': ['llamadart'],
              _edgeAiLlama: ['llamadart'],
              'llamadart': [],
            },
            devDependencies: {
              'app': [_edgeAiLlama],
            },
            pubspec: 'name: app\n',
            runtimes: null,
            bundlesLiteRtLm: false,
            warns: [_edgeAiLlama],
          ),
          (
            name: 'non-Apple app also resolving the Apple LiteRT-LM companion',
            roots: ['app'],
            dependencies: {
              'app': [
                'llamadart',
                _edgeAiLiteRtLm,
                'llamadart_litert_lm_flutter',
              ],
              _edgeAiLiteRtLm: [],
              'llamadart_litert_lm_flutter': ['llamadart'],
              'llamadart': [],
            },
            devDependencies: {},
            pubspec: 'name: app\n',
            runtimes: null,
            bundlesLiteRtLm: false,
            warns: [_edgeAiLiteRtLm],
          ),
          (
            name: 'workspace member with both engines, none in the root',
            roots: ['workspace', 'app', _edgeAiLlama, _edgeAiLiteRtLm],
            dependencies: {
              'workspace': [],
              'app': [_edgeAiLlama, _edgeAiLiteRtLm],
              _edgeAiLlama: ['llamadart'],
              _edgeAiLiteRtLm: [],
              'llamadart': [],
              'melos': [],
            },
            devDependencies: {
              'workspace': ['melos'],
            },
            pubspec:
                'name: workspace\n'
                'workspace: [app, $_edgeAiLlama, $_edgeAiLiteRtLm]\n'
                'dev_dependencies:\n'
                '  melos: any\n',
            runtimes: null,
            bundlesLiteRtLm: false,
            warns: [_edgeAiLlama, _edgeAiLiteRtLm],
          ),
          (
            name: 'workspace whose other member bundles $_edgeAiLlama',
            roots: ['workspace', 'app', 'other'],
            dependencies: {
              'workspace': [],
              'app': ['llamadart'],
              'other': [_edgeAiLlama],
              _edgeAiLlama: ['llamadart'],
              'llamadart': [],
            },
            devDependencies: {},
            pubspec: workspacePubspec,
            runtimes: null,
            bundlesLiteRtLm: false,
            warns: [_edgeAiLlama],
          ),
          (
            name:
                'workspace whose $_edgeAiLiteRtLm member never builds llamadart',
            roots: ['workspace', 'app', 'other'],
            dependencies: {
              'workspace': [],
              'app': ['llamadart'],
              'other': [_edgeAiLiteRtLm],
              _edgeAiLiteRtLm: [],
              'llamadart': [],
            },
            devDependencies: {},
            pubspec: workspacePubspec,
            runtimes: null,
            bundlesLiteRtLm: true,
            warns: [],
          ),
          (
            name: 'workspace member depending on a member with a dev engine',
            roots: ['workspace', 'app', 'other'],
            dependencies: {
              'workspace': [],
              'app': ['llamadart', 'other'],
              'other': [],
              _edgeAiLiteRtLm: [],
              'llamadart': [],
            },
            devDependencies: {
              'other': [_edgeAiLiteRtLm],
            },
            pubspec: workspacePubspec,
            runtimes: null,
            bundlesLiteRtLm: true,
            warns: [],
          ),
        ];

    for (final scenario in cases) {
      test(scenario.name, () async {
        final layout = await HooksRunnerLayout.create(
          roots: scenario.roots,
          dependencies: scenario.dependencies,
          devDependencies: scenario.devDependencies,
          pubspec: scenario.pubspec,
        );
        addTearDown(layout.delete);
        final run = await _runLinuxHook(
          layout: layout,
          defines: scenario.runtimes == null
              ? null
              : {'llamadart_native_runtimes': scenario.runtimes},
        );
        expect(run.assets.values, contains('libllamadart.so'));
        expect(
          run.assets.values.toSet().intersection(_linuxLiteRtLibraries.toSet()),
          scenario.bundlesLiteRtLm ? _linuxLiteRtLibraries.toSet() : isEmpty,
        );
        expect(
          run.assets.keys.where((id) => id.contains('litert_lm')),
          scenario.bundlesLiteRtLm ? isNotEmpty : isEmpty,
        );
        expect(run.dependencies, contains(layout.packageGraph.uri));
        final warning = run.warnings.where(
          (message) => message.contains('LiteRT-LM'),
        );
        if (scenario.warns.isEmpty) {
          expect(warning, isEmpty);
        } else {
          expect(warning.single, stringContainsInOrder(scenario.warns));
        }
      });
    }

    test(
      'only LiteRT-LM assets follow the resolved graph',
      () => expectOnlyLiteRtLmFollowsResolvedGraph(
        hookMain: build_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        liteRtLmLibraries: _linuxLiteRtLibraries,
      ),
    );

    test('an unreadable graph keeps the selection and warns', () async {
      final layout = await HooksRunnerLayout.create(
        roots: ['app'],
        dependencies: {
          'app': [_edgeAiLlama],
        },
      );
      addTearDown(layout.delete);
      await layout.packageGraph.writeAsString('{"roots": ["app"]}');
      final run = await _runLinuxHook(layout: layout);
      expect(run.assets.values, containsAll(_linuxLiteRtLibraries));
      expect(
        run.warnings.single,
        stringContainsInOrder([
          layout.packageGraph.path,
          'llamadart_native_runtimes: [llama_cpp]',
        ]),
      );
    });
  });

  test('build hook preserves historical linux mtmd SONAME alias', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: const {'llamadart_native_tag': historicalNativeTag},
          basePath: Directory.current.uri,
        ),
      ),
      check: (input, output) {
        final emittedNames = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .map((asset) => path.basename(asset.file!.toFilePath()))
            .toSet();

        expect(emittedNames, contains('libmtmd.so'));
        expect(emittedNames, contains('libmtmd.so.0'));
        expect(emittedNames, contains('libmtmd.so.SOVERSION'));
      },
    );
  });

  test('build hook emits archive symlink aliases with target bytes', () async {
    await bundleDir.delete(recursive: true);
    await _writeSymlinkedBundleArchive(archiveFile);

    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      check: (input, output) {
        final assetFilesByName = <String, File>{};
        for (final asset
            in output.assets.encodedAssets
                .where((asset) => asset.isCodeAsset)
                .map((asset) => asset.asCodeAsset)) {
          final assetFile = File(asset.file!.toFilePath());
          assetFilesByName[path.basename(assetFile.path)] = assetFile;
        }

        for (final fileName in const ['libmtmd.so', 'libmtmd.so.0']) {
          final assetFile = assetFilesByName[fileName];
          expect(assetFile, isNotNull, reason: fileName);
          expect(assetFile!.readAsStringSync(), _mtmdPayload, reason: fileName);
        }

        expect(
          assetFilesByName['libllamadart.so']?.readAsStringSync(),
          'archive-libllamadart.so',
        );
      },
    );
  });

  test('build hook fails when runtimes config selects none', () async {
    for (final rawUserConfig in const <Object>['none', false]) {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: {'llamadart_native_runtimes': rawUserConfig},
              basePath: Directory.current.uri,
            ),
          ),
          check: (_, _) {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('No native runtimes selected for linux-x64'),
          ),
        ),
      );
    }
  });
}

String _readHookNativeTag() {
  final source = File(
    'lib/src/hook/native_release_pins.dart',
  ).readAsStringSync();
  final match = RegExp(r"const llamaCppTag = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError(
      'Could not locate llamaCppTag in lib/src/hook/native_release_pins.dart',
    );
  }
  return match.group(1)!;
}

String _readHookLiteRtLmVersion() {
  final source = File(
    'lib/src/hook/native_release_pins.dart',
  ).readAsStringSync();
  final match = RegExp(
    r"const liteRtLmVersion = '([^']+)';",
  ).firstMatch(source);
  if (match == null) {
    throw StateError(
      'Could not locate liteRtLmVersion in lib/src/hook/native_release_pins.dart',
    );
  }
  return match.group(1)!;
}

const List<String> _linuxLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRt.so',
  'libLiteRtLm.so',
  'libwebgpu_dawn.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
];

const List<String> _linuxLiteRtAssetNames = [
  'litert_lm_GemmaModelConstraintProvider',
  'litert_lm_LiteRt',
  'litert_lm_LiteRtLm',
  'litert_lm_webgpu_dawn',
  'litert_lm_LiteRtTopKWebGpuSampler',
  'litert_lm_LiteRtWebGpuAccelerator',
];

const String _edgeAiLlama = 'flutter_edge_ai_llama';
const String _edgeAiLiteRtLm = 'flutter_edge_ai_litertlm';

Future<HookRun> _runLinuxHook({
  HooksRunnerLayout? layout,
  Map<String, Object?>? defines,
}) => runCodeBuildHook(
  hookMain: build_hook.main,
  targetOS: OS.linux,
  targetArchitecture: Architecture.x64,
  layout: layout,
  userDefines: layout?.userDefines(defines),
);

const String _mtmdPayload = 'archive-libmtmd.so.0.2.0';

Future<void> _writeSymlinkedBundleArchive(File archiveFile) async {
  final archive = Archive();

  void addRegularFile(String name, String content) {
    archive.addFile(ArchiveFile(name, content.length, content.codeUnits));
  }

  addRegularFile('libllamadart.so', 'archive-libllamadart.so');
  addRegularFile('libmtmd.so.0.2.0', _mtmdPayload);
  archive.addFile(ArchiveFile.symlink('libmtmd.so.0', 'libmtmd.so.0.2.0'));
  archive.addFile(ArchiveFile.symlink('libmtmd.so', 'libmtmd.so.0'));
  for (final name in const [
    'libllama.so',
    'libllama-common.so',
    'libggml.so',
    'libggml-base.so',
    'libggml-cpu.so',
    'libggml-vulkan.so',
  ]) {
    addRegularFile(name, 'archive-$name');
  }

  await archiveFile.parent.create(recursive: true);
  await archiveFile.writeAsBytes(
    GZipEncoder().encode(TarEncoder().encode(archive)),
  );
}

Future<void> _writeBundleLibraries(
  Directory bundleDir,
  List<String> fileNames,
) async {
  if (bundleDir.existsSync()) {
    await bundleDir.delete(recursive: true);
  }
  await bundleDir.create(recursive: true);
  for (final name in fileNames) {
    await File(path.join(bundleDir.path, name)).writeAsString('fake-$name');
  }
}
