@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_runtime_coexistence.dart';
import '../../../hook/build.dart' as build_hook;

void main() {
  late Directory scratch;
  late File pubspec;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('runtime-owner-test-');
    pubspec = File.fromUri(scratch.uri.resolve('pubspec.yaml'));
  });
  tearDown(() async => scratch.delete(recursive: true));

  void check(List<String> runtimes, {void Function(Uri)? dependency}) =>
      validateRuntimeCoexistence(
        consumerRoot: scratch,
        selectedRuntimes: runtimes,
        dependency: dependency ?? (_) {},
      );

  test(
    'direct owner requires llama.cpp-only selection, defaults otherwise unchanged',
    () {
      pubspec.writeAsStringSync(
        'name: app\ndependencies:\n  flutter_edge_ai_litertlm: any\n',
      );
      expect(
        () => check(['llama_cpp', 'litert_lm']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'fix',
            contains('[llama_cpp]'),
          ),
        ),
      );
      check(['llama_cpp']);
      pubspec.writeAsStringSync('name: app\ndependencies:\n  llamadart: any\n');
      check(['llama_cpp', 'litert_lm']);
    },
  );

  test('malformed metadata errors do not print source credentials', () {
    pubspec.writeAsStringSync(
      'name: app\ndependencies: [ secret-token: broken',
    );
    try {
      check(['litert_lm']);
      fail('Malformed graph must fail');
    } on StateError catch (error) {
      expect(error.message, contains('rerun pub get'));
      expect(error.message, isNot(contains('secret-token')));
    }
  });

  test(
    'transitive owner is detected but unused workspace packages are ignored',
    () async {
      final indirect = Directory.fromUri(scratch.uri.resolve('indirect/'));
      await indirect.create();
      final child = File.fromUri(indirect.uri.resolve('pubspec.yaml'));
      await child.writeAsString(
        'name: indirect\ndependencies:\n  flutter_edge_ai_litertlm: any\n',
      );
      final config = File.fromUri(
        scratch.uri.resolve('.dart_tool/package_config.json'),
      );
      await config.parent.create();
      await config.writeAsString(
        jsonEncode({
          'packages': [
            {'name': 'indirect', 'rootUri': '../indirect'},
            {
              'name': 'flutter_edge_ai_litertlm',
              'rootUri': scratch.uri.resolve('unused/').toString(),
            },
          ],
        }),
      );
      await pubspec.writeAsString(
        'name: app\ndependencies:\n  indirect: any\n',
      );
      final dependencies = <Uri>{};
      expect(
        () => check(['litert_lm'], dependency: dependencies.add),
        throwsStateError,
      );
      expect(dependencies, containsAll([pubspec.uri, child.uri, config.uri]));
      await pubspec.writeAsString(
        'name: app\ndependencies:\n  unrelated: any\n',
      );
      check(['litert_lm']);
    },
  );

  for (final target in [
    (OS.linux, Architecture.x64),
    (OS.windows, Architecture.x64),
    (OS.android, Architecture.arm64),
    (OS.iOS, Architecture.arm64),
  ]) {
    test(
      'production hook rejects duplicate owner before emitting assets on ${target.$1}',
      () async {
        await pubspec.writeAsString(
          'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  flutter_edge_ai_litertlm: any\n',
        );
        var emitted = false;
        await expectLater(
          testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: target.$1,
            targetArchitecture: target.$2,
            targetIOSSdk: target.$1 == OS.iOS ? IOSSdk.iPhoneOS : null,
            userDefines: PackageUserDefines(
              workspacePubspec: PackageUserDefinesSource(
                defines: {},
                basePath: pubspec.uri,
              ),
            ),
            check: (_, _) => emitted = true,
          ),
          throwsA(
            predicate(
              (e) => e.toString().contains('Conflicting LiteRT-LM runtimes'),
            ),
          ),
        );
        expect(emitted, isFalse);
      },
    );
  }
}
