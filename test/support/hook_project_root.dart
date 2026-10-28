import 'dart:async';
import 'dart:io';

import 'package:code_assets/code_assets.dart' as code_assets;
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;

import 'hook_core_version.dart';

/// A throwaway package root for the build hook.
///
/// The hook caches bundles under `<package root>/.dart_tool/llamadart`, and
/// `testCodeBuildHook` takes the package root from [Directory.current]. Hook
/// tests that built in this checkout would leave their fake bundles in the
/// cache that real builds reuse, so they build here instead.
class HookProjectRoot {
  HookProjectRoot._(this.directory);

  /// Creates a root holding only the `pubspec.yaml` the hook reads.
  factory HookProjectRoot.create() {
    final directory = Directory.systemTemp.createTempSync('hook_project_');
    File(path.join(directory.path, 'pubspec.yaml')).writeAsStringSync(
      'name: llamadart\nversion: ${readCheckoutCoreVersion()}\n',
    );
    return HookProjectRoot._(Directory(directory.resolveSymbolicLinksSync()));
  }

  /// The package root, and the working directory the hook sees.
  final Directory directory;

  /// The absolute path of [relative] below the package root.
  String resolve(String relative) => path.join(directory.path, relative);

  /// Runs [body] with [Directory.current] at the package root.
  Future<T> run<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(body, getCurrentDirectory: () => directory);

  void delete() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  /// [code_assets.testCodeBuildHook] with its package root at [directory].
  Future<void> testCodeBuildHook({
    required FutureOr<void> Function(List<String> arguments) mainMethod,
    required FutureOr<void> Function(BuildInput, BuildOutput) check,
    code_assets.Architecture? targetArchitecture,
    code_assets.OS? targetOS,
    code_assets.IOSSdk? targetIOSSdk = code_assets.IOSSdk.iPhoneOS,
    int? targetAndroidNdkApi = 30,
    PackageUserDefines? userDefines,
  }) => run(
    () => code_assets.testCodeBuildHook(
      mainMethod: mainMethod,
      check: check,
      targetArchitecture: targetArchitecture,
      targetOS: targetOS,
      targetIOSSdk: targetIOSSdk,
      targetAndroidNdkApi: targetAndroidNdkApi,
      userDefines: userDefines,
    ),
  );
}
