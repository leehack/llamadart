import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

/// The `version` this checkout's core `pubspec.yaml` declares.
String readCheckoutCoreVersion() => RegExp(
  r'^version:\s*(\S+)\s*$',
  multiLine: true,
).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;

/// Runs [body] with the build hook's package root at a core declaring
/// [coreVersion], or at this checkout when it is `null`.
///
/// `testCodeBuildHook` takes the package root from [Directory.current], so
/// this overrides it for [body] alone.
Future<void> withHookCoreVersion(
  String? coreVersion,
  Future<void> Function() body,
) async {
  if (coreVersion == null) return body();
  final root = await Directory.systemTemp.createTemp('llamadart_core_');
  addTearDown(() => root.deleteSync(recursive: true));
  File(
    path.join(root.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: llamadart\nversion: $coreVersion\n');
  return IOOverrides.runZoned(body, getCurrentDirectory: () => root);
}
