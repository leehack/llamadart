import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

// The root orchestrator shares policy with the private, unpublished harness;
// adding a root package dependency would create a dependency cycle.
// ignore: avoid_relative_lib_imports
import '../../../packages/llamadart_validation/lib/src/runtime_environment.dart';

import 'process.dart';
import 'npu.dart';
import 'runtime_bundle.dart';

/// Reads committed source and runtime identities for local runs and bundles.
Future<Map<String, dynamic>> readValidationProvenance(
  String root, {
  CommandExecutor execute = executeCommand,
}) async {
  requireValidationRuntimeEnvironment();
  for (final directory in [
    '',
    'packages/llamadart_validation',
    'example/chat_app',
  ]) {
    if (File(p.join(root, directory, 'pubspec_overrides.yaml')).existsSync()) {
      throw StateError(
        'Validation builds require manifests without local pub overrides',
      );
    }
  }
  final revision = await execute('git', ['rev-parse', 'HEAD'], directory: root);
  final source = revision.output.trim();
  final status = await execute('git', [
    'status',
    '--porcelain',
  ], directory: root);
  if (revision.code != 0 ||
      status.code != 0 ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(source)) {
    throw StateError('Cannot establish source revision and working-tree state');
  }
  final hook = File(p.join(root, 'hook', 'build.dart')).readAsStringSync();
  final pins = File(
    p.join(root, 'lib/src/hook/native_release_pins.dart'),
  ).readAsStringSync();
  String? pin(String key) =>
      RegExp("const $key = '([^']+)'").firstMatch(pins)?.group(1);
  final bridgeScript = File(
    p.join(root, 'scripts', 'fetch_webgpu_bridge_assets.sh'),
  ).readAsStringSync();
  final bridgeTag = RegExp(
    r'WEBGPU_BRIDGE_ASSETS_TAG:-([^}]+)',
  ).firstMatch(bridgeScript)?.group(1);
  if (pin('llamaCppTag') == null ||
      pin('liteRtLmVersion') == null ||
      bridgeTag == null) {
    throw StateError('Cannot establish runtime pins');
  }
  return {
    'source_commit': source,
    'source_dirty': status.output.isNotEmpty,
    'native_tag': pin('llamaCppTag'),
    'litert_tag': pin('liteRtLmVersion'),
    'bridge_tag': bridgeTag,
    'hook_sha256': sha256.convert(utf8.encode(hook)).toString(),
  };
}

/// Creates a portable bundle and an exhaustive checksum inventory.
Future<Directory> buildValidationBundle(
  String root,
  String target,
  String output, {
  String profile = 'tiny-gguf-cpu',
  String mode = 'debug',
  String? team,
  String? npuKit,
  String? model,
  String executionPath = 'public_api',
  CommandExecutor execute = executeCommand,
}) async {
  final destination = Directory(output).absolute;
  if (destination.existsSync()) {
    throw StateError('Bundle destination already exists');
  }
  if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(profile)) {
    throw const FormatException('Invalid profile');
  }
  final package = p.join(root, 'packages', 'llamadart_validation');
  final selectedProfile =
      jsonDecode(
            File(
              p.join(package, 'assets', 'profiles', '$profile.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final npu = selectedProfile['backend'] == 'npu';
  requireExecutableValidationProfile(
    selectedProfile,
    supportsLocalModelPath: target == 'desktop',
    verifiedAndroidKit:
        npu && target == 'android' && npuKit != null && model != null,
  );
  if (!['public_api', 'native_c_api'].contains(executionPath) ||
      (executionPath == 'native_c_api' && !npu)) {
    throw const FormatException('native_c_api requires an Android NPU kit');
  }
  if (npu && Platform.isWindows) {
    throw UnsupportedError(
      'NPU APK builder currently uses a macOS/Linux build host',
    );
  }
  final app = p.join(root, 'example', 'chat_app');
  final sourceIdentity = await readValidationProvenance(root, execute: execute);
  final source = sourceIdentity['source_commit'] as String;
  final sdk = jsonObject(
    await execute('flutter', ['--version', '--machine'], directory: root),
  );
  final expectedFlutter = File(
    p.join(root, '.flutter-version'),
  ).readAsStringSync().trim();
  if (sdk['frameworkVersion'] != expectedFlutter ||
      !(sdk['dartSdkVersion'] as String? ?? '').startsWith(
        Platform.version.split(' ').first,
      )) {
    throw StateError(
      'Build requires the repository-pinned Flutter and matching Dart SDK',
    );
  }
  final provenance = <String, dynamic>{
    ...sourceIdentity,
    'build_os': Platform.operatingSystem,
    'build_abi': Abi.current().toString(),
    'dart_sdk': Platform.version,
    'flutter_sdk': sdk['frameworkVersion'],
    'target': target,
    'profile': profile,
    'execution_path': executionPath,
    'mode': ['desktop', 'web', 'ios'].contains(target) ? 'release' : mode,
  };
  final defines = [
    'VALIDATION_PROFILE=$profile',
    'VALIDATION_EXECUTION_PATH=$executionPath',
    'VALIDATION_COMMIT=$source',
    'VALIDATION_SOURCE_DIRTY=${provenance['source_dirty']}',
    'VALIDATION_NATIVE_TAG=${provenance['native_tag']}',
    'VALIDATION_LITERT_TAG=${provenance['litert_tag']}',
    'VALIDATION_BRIDGE_TAG=${provenance['bridge_tag']}',
    'VALIDATION_HOOK_SHA256=${provenance['hook_sha256']}',
  ];
  String? npuStage;
  Future<void> command(String binary, List<String> args, String cwd) async {
    final result = await execute(
      npuStage == null ? binary : 'env',
      npuStage == null
          ? args
          : ['LLAMADART_VALIDATION_NPU_STAGE=$npuStage', binary, ...args],
      directory: cwd,
      timeout: const Duration(minutes: 30),
    );
    if (result.code != 0) {
      stdout.write(result.output);
      stderr.write(result.error);
      throw StateError('Bundle build failed: $binary (${result.code})');
    }
  }

  final scratch = Directory(
    p.join(
      root,
      '.dart_tool',
      'validation',
      'build-${DateTime.now().microsecondsSinceEpoch}',
    ),
  )..createSync(recursive: true);
  try {
    if (npu) {
      final stage = Directory(p.join(scratch.path, 'npu'));
      provenance['npu'] = await stageNpuAndroid(
        root,
        profile,
        model,
        npuKit,
        stage,
      );
      npuStage = stage.path;
    }
    if (target == 'desktop') {
      await command(Platform.resolvedExecutable, ['pub', 'get'], package);
      await command(Platform.resolvedExecutable, [
        'build',
        'cli',
        '-t',
        'bin/run.dart',
        '-o',
        scratch.path,
      ], package);
      copyDirectory(Directory(p.join(scratch.path, 'bundle')), destination);
      final executable = File(
        p.join(destination.path, 'bin', Platform.isWindows ? 'run.exe' : 'run'),
      );
      executable.renameSync(
        p.join(
          executable.parent.path,
          Platform.isWindows ? 'llamadart-validate.exe' : 'llamadart-validate',
        ),
      );
      final reportBuild = p.join(scratch.path, 'report');
      await command(Platform.resolvedExecutable, [
        'build',
        'cli',
        '-t',
        'bin/report.dart',
        '-o',
        reportBuild,
      ], package);
      File(
        p.join(
          reportBuild,
          'bundle',
          'bin',
          Platform.isWindows ? 'report.exe' : 'report',
        ),
      ).copySync(
        p.join(
          destination.path,
          'bin',
          Platform.isWindows ? 'llamadart-report.exe' : 'llamadart-report',
        ),
      );
      final reportLibraries = Directory(p.join(reportBuild, 'bundle', 'lib'));
      if (reportLibraries.existsSync()) {
        for (final file in reportLibraries.listSync().whereType<File>()) {
          final existing = File(
            p.join(destination.path, 'lib', p.basename(file.path)),
          );
          if (existing.existsSync() &&
              (await sha256.bind(existing.openRead()).first) !=
                  (await sha256.bind(file.openRead()).first)) {
            throw StateError('Runner and reporter native code assets disagree');
          }
          existing.parent.createSync(recursive: true);
          file.copySync(existing.path);
        }
      }
      requireDesktopBackendModules(destination);
      copyDirectory(
        Directory(p.join(package, 'assets')),
        Directory(p.join(destination.path, 'assets')),
      );
      await bundleLiteRtRuntime(
        root,
        destination,
        scratch,
        provenance,
        execute: execute,
      );
      for (final name in ['run-remote.sh', 'run-remote.ps1']) {
        File(
          p.join(root, 'tool', 'testing', 'validation', name),
        ).copySync(p.join(destination.path, name));
      }
    } else if (target == 'android') {
      if (mode != 'debug') {
        throw const FormatException(
          'Android instrumentation currently uses debug; performance is labelled separately',
        );
      }
      await command('flutter', ['pub', 'get'], app);
      destination.createSync(recursive: true);
      await command('flutter', [
        'build',
        'apk',
        '--debug',
        '--target',
        'lib/validation_main.dart',
        '--target-platform',
        'android-arm64',
        ...defines.map((value) => '--dart-define=$value'),
      ], app);
      File(
        p.join(app, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk'),
      ).copySync(p.join(destination.path, 'qa-app.apk'));
      await command('flutter', [
        'build',
        'apk',
        '--debug',
        '--target',
        'integration_test/validation_test.dart',
        '--target-platform',
        'android-arm64',
        ...defines.map((value) => '--dart-define=$value'),
      ], app);
      await command(Platform.isWindows ? 'gradlew.bat' : './gradlew', [
        'app:assembleAndroidTest',
        '-Ptarget=integration_test/validation_test.dart',
        '-Ptarget-platform=android-arm64',
        '-Pdart-defines=${defines.map((value) => base64Encode(utf8.encode(value))).join(',')}',
      ], p.join(app, 'android'));
      destination.createSync(recursive: true);
      File(
        p.join(app, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk'),
      ).copySync(p.join(destination.path, 'app.apk'));
      File(
        p.join(
          app,
          'build',
          'app',
          'outputs',
          'apk',
          'androidTest',
          'debug',
          'app-debug-androidTest.apk',
        ),
      ).copySync(p.join(destination.path, 'test.apk'));
    } else if (target == 'web') {
      // The maintained builder owns bridge staging and header/base-href checks.
      await command('bash', [
        p.join(root, 'scripts', 'build_chat_app_web.sh'),
        '--validation',
        ...defines.map((value) => '--dart-define=$value'),
      ], root);
      copyDirectory(Directory(p.join(app, 'build', 'web')), destination);
    } else if (target == 'ios') {
      final configuredTeams = RegExp(r'DEVELOPMENT_TEAM = ([A-Z0-9]{10});')
          .allMatches(
            File(
              p.join(app, 'ios/Runner.xcodeproj/project.pbxproj'),
            ).readAsStringSync(),
          )
          .map((m) => m[1]!)
          .toSet();
      final signingTeam =
          team ?? (configuredTeams.length == 1 ? configuredTeams.single : null);
      if (signingTeam == null ||
          !RegExp(r'^[A-Z0-9]{10}$').hasMatch(signingTeam)) {
        throw StateError(
          'Set --team to an existing configured Apple development team',
        );
      }
      if (!Platform.isMacOS) {
        throw StateError('Signing XCTest requires macOS/Xcode');
      }
      await command('flutter', ['pub', 'get'], app);
      await command('flutter', [
        'build',
        'ios',
        '--config-only',
        '--release',
        '--target',
        'integration_test/validation_test.dart',
        ...defines.map((value) => '--dart-define=$value'),
      ], app);
      await command('xcodebuild', [
        '-workspace',
        'Runner.xcworkspace',
        '-scheme',
        'Runner',
        '-configuration',
        'Release',
        '-sdk',
        'iphoneos',
        '-destination',
        'generic/platform=iOS',
        '-derivedDataPath',
        scratch.path,
        'build-for-testing',
        'DEVELOPMENT_TEAM=$signingTeam',
      ], p.join(app, 'ios'));
      destination.createSync(recursive: true);
      await command('zip', [
        '-r',
        p.join(destination.path, 'tests.zip'),
        '.',
      ], p.join(scratch.path, 'Build', 'Products'));
    } else if (target == 'ios-inputs') {
      destination.createSync(recursive: true);
      // Source inputs have no signing keys and are reproducible from the commit.
      await command('git', [
        'archive',
        '--format=tar',
        '-o',
        p.join(destination.path, 'source.tar'),
        'HEAD',
      ], root);
      if (provenance['source_dirty'] == true) {
        throw StateError(
          'iOS source input bundles require a committed source revision',
        );
      }
    } else {
      throw const FormatException(
        'Target must be desktop, android, web, ios or ios-inputs',
      );
    }
    final finalRevision = await execute('git', [
      'rev-parse',
      'HEAD',
    ], directory: root);
    final finalStatus = await execute('git', [
      'status',
      '--porcelain',
    ], directory: root);
    if (finalRevision.code != 0 ||
        finalStatus.code != 0 ||
        finalRevision.output.trim() != source ||
        (provenance['source_dirty'] == false &&
            finalStatus.output.isNotEmpty)) {
      throw StateError('Source revision changed during the build');
    }
    provenance['source_dirty'] =
        provenance['source_dirty'] == true || finalStatus.output.isNotEmpty;
    selectedProfile['execution_path'] = executionPath;
    File(
      p.join(destination.path, 'profile.json'),
    ).writeAsStringSync(jsonEncode(selectedProfile));
    if (npu) {
      File(
        p.join(npuKit!, 'npu-kit.json'),
      ).copySync(p.join(destination.path, 'npu-kit.json'));
      await verifyNpuApks(root, destination, execute: execute);
    }
    File(
      p.join(package, 'pubspec.lock'),
    ).copySync(p.join(destination.path, 'validation-pubspec.lock'));
    if (target != 'desktop') {
      File(
        p.join(app, 'pubspec.lock'),
      ).copySync(p.join(destination.path, 'app-pubspec.lock'));
    }
    File(
      p.join(destination.path, 'environment.json'),
    ).writeAsStringSync(jsonEncode(provenance));
    File(p.join(destination.path, 'RUN.txt')).writeAsStringSync(
      'llamadart validation bundle\nTarget: $target\nSource: $source\n'
      'Desktop: bin/llamadart-validate --profile $profile --environment-file environment.json --out results\n'
      '${npu ? 'NPU model and licensed vendor libraries are embedded and SHA256-verified.' : 'Models are downloaded and SHA256-verified; weights are not in this bundle.'}\n'
      'Android: install qa-app.apk for interactive use; app.apk plus test.apk are a matched instrumentation pair.\n'
      'iOS: build/sign XCTest on a Mac. Web: serve with required isolation headers.\n',
    );
    await writeBundleManifest(destination, provenance);
    return destination;
  } catch (_) {
    // Incomplete outputs must never be confused with a usable bundle.
    if (destination.existsSync()) destination.deleteSync(recursive: true);
    rethrow;
  } finally {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

/// Copies regular files only; symlinks are not portable artifact inputs.
void copyDirectory(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is File) {
      entity.copySync(target);
    } else if (entity is Directory) {
      copyDirectory(entity, Directory(target));
    } else {
      throw StateError('Symlink in bundle inputs: ${entity.path}');
    }
  }
}

/// Records every shipped file, including native code assets.
Future<void> writeBundleManifest(
  Directory directory,
  Map<String, dynamic> provenance,
) async {
  final inventory = <String, dynamic>{};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) throw StateError('Symlink in bundle');
    if (entity is! File || p.basename(entity.path) == 'bundle-manifest.json') {
      continue;
    }
    inventory[p
        .relative(entity.path, from: directory.path)
        .replaceAll('\\', '/')] = {
      'sha256': (await sha256.bind(entity.openRead()).first).toString(),
      'bytes': await entity.length(),
    };
  }
  File(p.join(directory.path, 'bundle-manifest.json')).writeAsStringSync(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'schema_version': 1, ...provenance, 'files': inventory}),
    flush: true,
  );
}

/// Rejects missing, altered, unexpected or escaping bundle members before upload.
Future<Map<String, dynamic>> verifyBundle(Directory directory) async {
  final manifest =
      jsonDecode(
            File(
              p.join(directory.path, 'bundle-manifest.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  if (manifest['schema_version'] != 1) {
    throw const FormatException('Unsupported bundle schema');
  }
  final files = manifest['files'] as Map<String, dynamic>;
  if (files.isEmpty) throw const FormatException('Empty bundle');
  final actual = <String>{};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) throw StateError('Symlink in bundle');
    if (entity is File) {
      actual.add(
        p.relative(entity.path, from: directory.path).replaceAll('\\', '/'),
      );
    }
  }
  actual.remove('bundle-manifest.json');
  if (actual.length != files.length || !actual.containsAll(files.keys)) {
    throw const FormatException('Bundle file inventory mismatch');
  }
  for (final entry in files.entries) {
    if (p.posix.isAbsolute(entry.key) ||
        entry.key.split('/').any((s) => s == '..' || s.isEmpty) ||
        entry.key.contains('\\')) {
      throw const FormatException('Invalid bundle member path');
    }
    final file = File(p.join(directory.path, entry.key));
    final expected = entry.value as Map;
    if (await file.length() != expected['bytes'] ||
        (await sha256.bind(file.openRead()).first).toString() !=
            expected['sha256']) {
      throw FormatException('Bundle checksum mismatch: ${entry.key}');
    }
  }
  return manifest;
}
