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

  List<String> check(
    List<String> runtimes, {
    bool explicit = false,
    void Function(Uri)? dependency,
  }) => selectConsumerNativeRuntimes(
    consumerRoot: scratch,
    selectedRuntimes: runtimes,
    explicitLiteRtLm: explicit,
    dependency: dependency ?? (_) {},
  );

  test(
    'direct owner defaults to llama.cpp and rejects explicit duplicate selection',
    () {
      pubspec.writeAsStringSync(
        'name: app\ndependencies:\n  flutter_edge_ai_litertlm: any\n',
      );
      expect(
        () => check(['llama_cpp', 'litert_lm'], explicit: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'fix',
            contains('[llama_cpp]'),
          ),
        ),
      );
      expect(check(['llama_cpp', 'litert_lm']), ['llama_cpp']);
      expect(check(['llama_cpp']), ['llama_cpp']);
      pubspec.writeAsStringSync('name: app\ndependencies:\n  llamadart: any\n');
      expect(check(['llama_cpp', 'litert_lm']), ['llama_cpp', 'litert_lm']);
    },
  );

  test(
    'connector defaults omit only implicit LiteRT and preserve other runtimes',
    () {
      pubspec.writeAsStringSync(
        'name: app\ndependencies:\n  flutter_edge_ai_llama: any\n',
      );
      final runtimes = ['llama_cpp', 'litert_lm', 'stable_diffusion'];
      expect(check(runtimes), ['llama_cpp', 'stable_diffusion']);
      expect(check(runtimes, explicit: true), runtimes);
      expect(runtimes, ['llama_cpp', 'litert_lm', 'stable_diffusion']);
    },
  );

  test('engine package itself receives the conditional default', () {
    pubspec.writeAsStringSync('name: flutter_edge_ai_llama\n');
    expect(check(['llama_cpp', 'litert_lm']), ['llama_cpp']);
  });

  test('malformed metadata errors do not print source credentials', () {
    pubspec.writeAsStringSync(
      'name: app\ndependencies: [ secret-token: broken',
    );
    try {
      expect(check(['litert_lm']), ['litert_lm']);
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
      expect(check(['llama_cpp', 'litert_lm']), ['llama_cpp']);
      final dependencies = <Uri>{};
      expect(
        () =>
            check(['litert_lm'], explicit: true, dependency: dependencies.add),
        throwsStateError,
      );
      expect(dependencies, containsAll([pubspec.uri, child.uri, config.uri]));
      await pubspec.writeAsString(
        'name: app\ndependencies:\n  unrelated: any\n',
      );
      expect(check(['litert_lm']), ['litert_lm']);
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
                defines: {
                  'llamadart_native_runtimes': ['llama_cpp', 'litert_lm'],
                },
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
