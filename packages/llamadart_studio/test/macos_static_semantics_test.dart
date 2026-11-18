@TestOn('vm && mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native static output updates remain readable with semantics enabled',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'studio_semantics_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final config = File('.dart_tool/package_config.json');
      final packages =
          (jsonDecode(await config.readAsString())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      final flutter = packages.cast<Map<String, dynamic>>().singleWhere(
        (package) => package['name'] == 'flutter',
      );
      final sdk = Directory.fromUri(
        config.absolute.uri.resolve(flutter['rootUri'] as String),
      ).parent.parent;
      // Studio uses SwiftPM. The legacy adjacent .framework may contain a
      // different engine, so it cannot qualify this accessibility regression.
      final frameworks =
          '${sdk.path}/bin/cache/artifacts/engine/darwin-x64/'
          'FlutterMacOS.xcframework/macos-arm64_x86_64';
      final executable = '${temporary.path}/semantics_test';
      final compile = await Process.run('xcrun', [
        'clang++',
        '-std=c++17',
        '-fobjc-arc',
        '-I',
        '${sdk.path}/engine/src/flutter/shell/platform/embedder',
        '-F',
        frameworks,
        '-framework',
        'Cocoa',
        '-framework',
        'FlutterMacOS',
        '-Wl,-rpath,$frameworks',
        'test/support/macos_static_semantics.mm',
        '-o',
        executable,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final result = await Process.run(executable, []);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('STATIC_SEMANTICS_UPDATE_OK'));
    },
  );
}
