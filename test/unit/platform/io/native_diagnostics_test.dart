@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/src/platform/io/native_diagnostics.dart';
import 'package:test/test.dart';

String manifest(Map<String, Object> entries, {String abi = 'macos_arm64'}) =>
    jsonEncode({
      'format-version': [1, 0, 0],
      'native-assets': {abi: entries},
    });

void main() {
  const id = 'package:llamadart/llamadart';
  test(
    'only the CLI source and its package snapshot are eligible helper hosts',
    () {
      final root = Directory('fake_package').absolute.uri;
      final helper = root.resolve(
        'lib/src/platform/io/native_diagnostics_child.dart',
      );
      final config = root.resolve('.dart_tool/package_config.json');
      expect(
        isNativeDiagnosticCliInvocation(
          root.resolve('bin/doctor_native.dart'),
          config,
          helper,
        ),
        isTrue,
      );
      expect(
        isNativeDiagnosticCliInvocation(
          config.resolve(
            'pub/bin/llamadart/doctor_native.dart-3.13.1.snapshot',
          ),
          config,
          helper,
        ),
        isTrue,
      );
      for (final name in [
        'main.dart',
        'doctor_native.exe',
        'doctor_native.dart-3.13.1.snapshot',
      ]) {
        expect(
          isNativeDiagnosticCliInvocation(root.resolve(name), config, helper),
          isFalse,
        );
      }
      expect(
        isNativeDiagnosticCliInvocation(
          Uri.parse('https://invalid.test/main.dart'),
          config,
          helper,
        ),
        isFalse,
      );
    },
  );
  test(
    'native CLI help and invalid arguments retain narrow imports and fixed output',
    () async {
      final config = (await Isolate.packageConfig)!;
      Future<ProcessResult> cli(List<String> arguments) =>
          Process.run(Platform.resolvedExecutable, [
            '--disable-dart-dev',
            '--packages=${config.toFilePath()}',
            'bin/doctor_native.dart',
            ...arguments,
          ]);
      final help = await cli(['--help']);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('The child runs no hooks/network'));
      expect(help.stderr, isEmpty);
      for (final arguments in [
        <String>[],
        ['--runtime', 'PRIVATE_DIAGNOSTIC_TOKEN'],
        ['--runtime', 'llama_cpp', '--json', '--json'],
        ['--help', 'PRIVATE_DIAGNOSTIC_TOKEN'],
      ]) {
        final invalid = await cli(arguments);
        expect(invalid.exitCode, 64);
        expect(invalid.stdout, isEmpty);
        expect(
          invalid.stderr,
          'doctor_native: invalid arguments. Use --help.\n',
        );
      }
      for (final file in [
        'bin/doctor_native.dart',
        'lib/src/platform/io/native_diagnostics.dart',
      ]) {
        final imports = File(file)
            .readAsLinesSync()
            .where((line) => line.startsWith('import '))
            .join('\n');
        expect(imports, isNot(contains('llamadart/llamadart.dart')));
        expect(imports, isNot(contains('/backends/')));
        expect(imports, isNot(contains('native_diagnostics_probe')));
      }
    },
  );
  test(
    'manifest selects exact ABI, fixed IDs and absolute declarations only',
    () {
      final source = manifest({
        id: ['absolute', File('DECLARED-v999.0.0/lib.dylib').absolute.path],
        'package:other/secret': ['absolute', File('OTHER').absolute.path],
      });
      final target = parseNativeDiagnosticManifest(
        source,
        'macos_arm64',
        'llama_cpp',
      )!;
      expect(target.primary, File('DECLARED-v999.0.0/lib.dylib').absolute.path);
      expect(target.companions, isEmpty);
      expect(
        parseNativeDiagnosticManifest(source, 'linux_x64', 'llama_cpp'),
        isNull,
      );
      expect(
        parseNativeDiagnosticManifest(
          source,
          'macos_arm64',
          'stable_diffusion',
        ),
        isNull,
      );
      expect(
        nativeDiagnosticObservation(
          'llama_cpp',
          'SURFACE_OBSERVED',
        )['loaded_release'],
        'unknown',
      );
      for (final entry in [
        ['relative', 'secret'],
        ['process'],
        ['absolute', 'relative/path'],
        ['absolute', '/a', 'extra'],
      ]) {
        expect(
          () => parseNativeDiagnosticManifest(
            manifest({id: entry}),
            'macos_arm64',
            'llama_cpp',
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'manifest rejects duplicates, future versions, malformed and oversized data',
    () {
      for (final source in [
        '{}',
        '{"format-version":[2,0,0],"native-assets":{}}',
        '{"format-version":[9,0,0],"format-version":[1,0,0],"native-assets":{}}',
        'PRIVATE_DIAGNOSTIC_TOKEN',
        'x' * (256 * 1024 + 1),
      ]) {
        expect(
          () =>
              parseNativeDiagnosticManifest(source, 'macos_arm64', 'llama_cpp'),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'LiteRT uses actual platform asset IDs and only fixed companion IDs',
    () {
      final target = parseNativeDiagnosticManifest(
        manifest({
          'package:llamadart/litert_lm_libLiteRtLm': [
            'absolute',
            File('primary').absolute.path,
          ],
          'package:llamadart/litert_lm_libLiteRt': [
            'absolute',
            File('companion').absolute.path,
          ],
          'package:llamadart/litert_lm_PRIVATE': ['absolute', '/never-open'],
        }),
        'macos_arm64',
        'litert_lm',
      )!;
      expect(target.primary, File('primary').absolute.path);
      expect(target.companions, [File('companion').absolute.path]);
      expect(
        () => parseNativeDiagnosticManifest(
          manifest({
            id: ['absolute', File('core').absolute.path],
          }, abi: 'windows_x64'),
          'windows_x64',
          'llama_cpp',
        ),
        throwsFormatException,
      );
    },
  );
  test('private target and bounded reads reject arbitrary IPC input', () async {
    expect(
      () => NativeDiagnosticTarget.fromJson({'primary': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => NativeDiagnosticTarget.fromJson({
        'primary': 'relative',
        'wrapper': '/b',
        'companions': [],
      }),
      throwsFormatException,
    );
    expect(
      () => decodeNativeDiagnosticJson('{"a":1,"a":1}'),
      throwsFormatException,
    );
    final dir = await Directory.systemTemp.createTemp('diagnostic_read_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/bounded');
    await file.writeAsString('abc');
    expect(await readNativeDiagnosticFile(file, 3), 'abc');
    expect(() => readNativeDiagnosticFile(file, 2), throwsFormatException);
  });
  group('isolated child owner', () {
    late Directory dir;
    late Uri config;
    late Uri childScript;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('diagnostic_owner_');
      config = File('${dir.path}/package_config.json').uri;
      await File.fromUri(config).writeAsString('{}');
      await File('${dir.path}/native_assets.yaml').writeAsString(
        manifest({
          id: ['absolute', File('DECLARED').absolute.path],
        }),
      );
      childScript = File(
        'test/fixtures/native_diagnostics_fake_child.dart',
      ).absolute.uri;
    });
    tearDown(() => dir.delete(recursive: true));
    Future<Map<String, Object>> run(
      String mode, {
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final activeConfig = (await Isolate.packageConfig)!;
      return runNativeDiagnostic(
        'llama_cpp',
        packageConfig: config,
        childScript: childScript,
        abi: 'macos_arm64',
        timeout: timeout,
        start: (executable, arguments) => Process.start(executable, [
          '--disable-dart-dev',
          '--packages=${activeConfig.toFilePath()}',
          childScript.toFilePath(),
          mode,
        ]),
      );
    }

    test(
      'success accepts only bounded surface observations and discards native output',
      () async {
        for (final mode in ['success', 'flood']) {
          final result = await run(mode);
          expect(result['code'], 'SURFACE_OBSERVED');
          expect(result['loaded_release'], 'unknown');
          expect(result['production_loader'], 'not_checked');
          expect(result['gpu_usability'], 'not_checked');
          expect(jsonEncode(result), isNot(contains('PRIVATE')));
        }
      },
    );
    for (final mode in [
      'stdout-only',
      'malformed',
      'oversized',
      'duplicate',
      'extra',
      'wrong-nonce',
      'wrong-runtime',
      'inconsistent',
    ]) {
      test('rejects $mode without exposing child-controlled strings', () async {
        final result = await run(mode);
        expect(result['code'], 'CHILD_PROTOCOL_INVALID');
        expect(jsonEncode(result), isNot(contains('PRIVATE')));
        expect(jsonEncode(result), isNot(contains('private-user')));
      });
    }
    test('reports child failure with only the last fixed phase', () async {
      expect((await run('fail'))['phase'], 'not_started');
      final result = await run('phase-fail');
      expect(result['code'], 'CHILD_FAILED');
      expect(result['phase'], 'open');
    });
    test('kills, reaps and cleans up a child that never answers', () async {
      final before = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('llamadart_native_diagnostic_'))
          .map((d) => d.path)
          .toSet();
      final result = await run(
        'hang',
        timeout: const Duration(milliseconds: 350),
      );
      expect(result['code'], 'PROBE_TIMEOUT');
      final after = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('llamadart_native_diagnostic_'))
          .map((d) => d.path)
          .toSet();
      expect(after.difference(before), isEmpty);
    });
    test(
      'absent/invalid declarations never start a child or choose another ABI/cache',
      () async {
        var starts = 0;
        Future<Map<String, Object>> check() => runNativeDiagnostic(
          'llama_cpp',
          packageConfig: config,
          childScript: childScript,
          abi: 'macos_arm64',
          start: (_, _) {
            starts++;
            throw StateError('PRIVATE');
          },
        );
        await File('${dir.path}/native_assets.yaml').delete();
        expect((await check())['code'], 'ASSET_DECLARATION_UNAVAILABLE');
        await File('${dir.path}/native_assets.yaml').writeAsString('{}');
        expect((await check())['code'], 'ASSET_DECLARATION_INVALID');
        await File('${dir.path}/native_assets.yaml').writeAsString(
          manifest({
            id: ['absolute', '/OTHER'],
          }, abi: 'linux_x64'),
        );
        expect((await check())['code'], 'ASSET_NOT_DECLARED');
        expect(starts, 0);
      },
    );
    test(
      'bounded startup failure exposes no command or environment values',
      () async {
        final result = await runNativeDiagnostic(
          'llama_cpp',
          packageConfig: config,
          childScript: childScript,
          abi: 'macos_arm64',
          start: (_, _) =>
              throw StateError('/Users/private-user/PRIVATE_DIAGNOSTIC_TOKEN'),
        );
        expect(result['code'], 'PROBE_HOST_UNAVAILABLE');
        expect(jsonEncode(result), isNot(contains('PRIVATE')));
        final timedOut = await runNativeDiagnostic(
          'llama_cpp',
          packageConfig: config,
          childScript: childScript,
          abi: 'macos_arm64',
          timeout: const Duration(milliseconds: 20),
          start: (_, _) => Completer<Process>().future,
        );
        expect(timedOut['code'], 'PROBE_TIMEOUT');
      },
    );
  });
}
