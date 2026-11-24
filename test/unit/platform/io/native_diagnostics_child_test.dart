@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:test/test.dart';

import '../../../support/dart_script_snapshot.dart';

void main() {
  late final String child;
  setUpAll(() async {
    // Source launches recompile the diagnostic and its imports on every run.
    child = await compileDartScript(
      'lib/src/platform/io/native_diagnostics_child.dart',
    );
  });

  for (final (label, nonce, expectedExit) in [
    ('accepts a valid', '0' * 48, 0),
    ('rejects an invalid', 'PRIVATE_DIAGNOSTIC_TOKEN', 1),
  ]) {
    test('child $label request nonce', () async {
      final directory = await _diagnosticDirectory();
      final output = File('${directory.path}/result.json');
      final phase = File('${directory.path}/phase');
      final manifest = File('${directory.path}/native_assets.yaml');
      await _writeManifest(manifest, {
        'package:llamadart/llamadart': [
          'absolute',
          File('${directory.path}/missing').absolute.path,
        ],
      });

      await _runChild(
        child,
        _request('llama_cpp', nonce, output, phase, manifest),
        expectedExit: expectedExit,
        phase: phase,
      );
      expect(await output.exists(), expectedExit == 0);
      if (expectedExit == 0) {
        expect(
          (jsonDecode(await output.readAsString()) as Map)['code'],
          'ARTIFACT_MISSING',
        );
      }
    });
  }

  group('child probes the macOS LiteRT-LM hook cache only when undeclared', () {
    late Directory directory;
    late Directory cache;
    late File manifest;
    setUp(() async {
      directory = await _diagnosticDirectory();
      final root = Directory('${directory.path}/llamadart');
      cache = Directory(
        '${root.path}/.dart_tool/llamadart/litert_lm/$liteRtLmVersion/'
        'macos/arm64',
      );
      manifest = File('${directory.path}/native_assets.yaml');
      await _writeManifest(manifest, {});
      await File('${directory.path}/package_config.json').writeAsString(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'llamadart',
              'rootUri': root.uri.toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );
    });

    Future<void> populateCache() async {
      await cache.create(recursive: true);
      // Empty files reach the loader without running native constructors.
      for (final library in [
        'libCLiteRTLM_mac.dylib',
        'libGemmaModelConstraintProvider.dylib',
        'libLiteRtLm.dylib',
        'libwebgpu_dawn.dylib',
      ]) {
        await File('${cache.path}/$library').writeAsString('');
      }
    }

    Future<Map<Object?, Object?>> check(
      String runtime, {
      Map<String, String>? environment,
    }) async {
      final output = File('${directory.path}/result.json');
      final phase = File('${directory.path}/phase');
      await _runChild(
        child,
        _request(runtime, '0' * 48, output, phase, manifest),
        expectedExit: 0,
        phase: phase,
        environment: environment,
      );
      final result = jsonDecode(await output.readAsString()) as Map;
      expect(result['runtime'], runtime);
      expect(result['phase'], await phase.readAsString());
      return result;
    }

    test('reports an undeclared asset when the cache is absent', () async {
      final missing = await check('litert_lm');
      expect(missing['code'], 'ASSET_NOT_DECLARED');
      expect(missing['source'], 'local_manifest_declaration');
    });

    test('selects the populated cache for undeclared LiteRT-LM', () async {
      await populateCache();
      final cached = await check('litert_lm');
      expect(cached['source'], 'build_hook_cache');
      expect(cached['phase'], 'open');
      expect(cached['code'], isNot('ASSET_NOT_DECLARED'));
    });

    test('ignores the incomplete directory override', () async {
      await populateCache();
      final overridden = await check(
        'litert_lm',
        environment: {'LLAMADART_LITERT_LM_LIB_DIR': directory.path},
      );
      expect(overridden['source'], 'build_hook_cache');
      expect(overridden['phase'], 'open');
    });

    test(
      'reports a missing declared asset even with a populated cache',
      () async {
        await populateCache();
        await _writeManifest(manifest, {
          'package:llamadart/litert_lm_libLiteRtLm': [
            'absolute',
            File('${directory.path}/missing').absolute.path,
          ],
        });
        final declared = await check('litert_lm');
        expect(declared['source'], 'local_manifest_declaration');
        expect(declared['phase'], 'open');
        expect(declared['code'], 'ARTIFACT_MISSING');
      },
    );

    test('ignores the LiteRT-LM cache for other runtimes', () async {
      await populateCache();
      final otherRuntime = await check('llama_cpp');
      expect(otherRuntime['code'], 'ASSET_NOT_DECLARED');
      expect(otherRuntime['source'], 'local_manifest_declaration');
    });
  });

  for (final (label, input) in [
    ('invalid JSON', 'PRIVATE_DIAGNOSTIC_TOKEN'),
    ('overlong input', 'x' * 33000),
    ('empty request', '{}'),
  ]) {
    test('packaged child rejects $label without raw output', () async {
      await _runChild(child, input, expectedExit: 1);
    });
  }
}

Future<Directory> _diagnosticDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'llamadart_native_diagnostic_',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

Future<void> _writeManifest(File manifest, Map<String, Object> assets) async {
  await manifest.writeAsString(
    jsonEncode({
      'format-version': [1, 0, 0],
      'native-assets': {'macos_arm64': assets},
    }),
  );
}

String _request(
  String runtime,
  String nonce,
  File output,
  File phase,
  File manifest,
) => jsonEncode({
  'runtime': runtime,
  'nonce': nonce,
  'output': output.path,
  'phase': phase.path,
  'manifest': manifest.path,
  'abi': 'macos_arm64',
});

Future<void> _runChild(
  String script,
  String input, {
  required int expectedExit,
  File? phase,
  Map<String, String>? environment,
}) async {
  final elapsed = Stopwatch()..start();
  final config = (await Isolate.packageConfig)!;
  final process = await Process.start(Platform.resolvedExecutable, [
    '--disable-dart-dev',
    '--packages=${config.toFilePath()}',
    script,
  ], environment: environment);
  // Kill and drain the child before test teardown can remove its IPC files.
  var timedOut = false;
  final deadline = Timer(const Duration(seconds: 15), () {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
  });

  Future<void> sendInput() async {
    process.stdin.write(input);
    await process.stdin.close();
  }

  try {
    final (code, stdoutEmpty, stderrEmpty, _) = await (
      process.exitCode,
      process.stdout.fold(true, (_, _) => false),
      process.stderr.fold(true, (_, _) => false),
      sendInput(),
    ).wait;
    deadline.cancel();
    elapsed.stop();
    final recordedPhase = phase != null && await phase.exists()
        ? await phase.readAsString()
        : null;
    final lastPhase = switch (recordedPhase) {
      'declaration' ||
      'open' ||
      'symbols' ||
      'abi' ||
      'complete' => recordedPhase,
      null => 'not written',
      _ => 'invalid',
    };
    final details =
        'Child phase: $lastPhase, exit: $code, '
        'elapsed: ${elapsed.elapsedMilliseconds} ms, '
        'stdout empty: $stdoutEmpty, stderr empty: $stderrEmpty';
    expect(timedOut, isFalse, reason: 'Child deadline exceeded. $details');
    expect(code, expectedExit, reason: details);
    expect(stdoutEmpty && stderrEmpty, isTrue, reason: details);
  } on ParallelWaitError {
    final failure = timedOut ? 'Child deadline exceeded' : 'Child I/O failed';
    fail('$failure after ${elapsed.elapsedMilliseconds} ms.');
  } finally {
    deadline.cancel();
  }
}
