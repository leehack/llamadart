@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../fixtures/windows_ggml_registry_qualification/payload/passive_modules.dart';

void main() {
  test('observer flushes complete before the next piped snapshot', () async {
    for (final mode in ['unawaited-flush', 'success', 'exception']) {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/windows_ggml_registry_qualification/observer_stdout_probe.dart',
        mode,
      ]);
      addTearDown(() => process.kill());
      final ready = Completer<void>();
      final errors = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) {
            if (line == 'OBSERVER_STDOUT_READY' && !ready.isCompleted) {
              ready.complete();
            }
            return line;
          })
          .join('\n');
      unawaited(
        errors.then((_) {
          if (!ready.isCompleted) ready.complete();
        }),
      );
      // Keep the pipe full while the first snapshot starts its flush.
      await ready.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final output = process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode;
      final text = await output;
      final errorText = await errors;
      if (mode == 'unawaited-flush') {
        expect(code, isNot(0));
        expect(errorText, contains('StreamSink is bound to a stream'));
        continue;
      }
      expect(code, mode == 'exception' ? 7 : 0, reason: errorText);
      expect(errorText, contains('NATIVE_STDERR emitter-only cadence'));
      expect(errorText, isNot(contains('StreamSink is bound to a stream')));
      final lines = const LineSplitter().convert(text);
      expect(lines.first, startsWith('MODEL_OUTCOME $mode'));
      final identity = lines.indexWhere(
        (line) => line.startsWith('REGISTRY_IDENTITY '),
      );
      expect(identity, 65);
      expect(lines, hasLength(130));
      for (var index = 0; index < lines.length; index++) {
        if (index == 0 || index == identity) continue;
        expect(lines[index], startsWith('PASSIVE_MODULE '));
        final row = jsonDecode(lines[index].substring(15)) as Map;
        final second = index > identity;
        expect(
          row['checkpoint'],
          second ? 'after-registry-observation' : 'after-stock-model-$mode',
        );
        expect(row['registryGettersCalled'], second);
        expect(row['index'], second ? index - identity - 1 : index - 1);
        expect(row['emitterOnlyPadding'], 'x' * 16384);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'primary observer accepts real Windows separators and exact DLL leaf',
    () {
      for (final value in [
        r'C:\runtime\llama.dll',
        r'C:\RUNTIME\LLAMA.DLL',
        r'\\host\share\llama.dll',
      ]) {
        expect(isPrimaryLlamaModule(value), isTrue, reason: value);
      }
      for (final value in [
        r'C:\runtime\notllama.dll',
        r'C:\runtime\llama.dll.bak',
        r'C:\llama.dll\other.dll',
        'llama.dll',
      ]) {
        expect(isPrimaryLlamaModule(value), isFalse, reason: value);
      }
    },
  );

  test(
    'download verifier refuses omitted and false-success evidence',
    () async {
      final result =
          await Process.run(Platform.isWindows ? 'python' : 'python3', [
            'test/unit/tooling/support/windows_registry/check_evidence.py',
            Directory(
              'test/fixtures/windows_ggml_registry_qualification',
            ).absolute.path,
          ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  final shell = Platform.environment['LLAMADART_TEST_PWSH'] ?? 'pwsh';
  for (final name in [
    'protocol',
    'path',
    'registry_mutation',
    'aot_distribution',
    'matrix_workflow',
  ]) {
    test('real qualification $name controls', () async {
      final scratch = await Directory.systemTemp.createTemp(
        'registry-controls-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final result = await Process.run(shell, [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        'test/unit/tooling/support/windows_registry/check_$name.ps1',
        '-BundleRoot',
        Directory(
          'test/fixtures/windows_ggml_registry_qualification',
        ).absolute.path,
        '-OutputPath',
        '${scratch.resolveSymbolicLinksSync()}/receipt.json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        File('${scratch.resolveSymbolicLinksSync()}/receipt.json').existsSync(),
        isTrue,
      );
      if (name == 'protocol') {
        final verifier = [
          'test/fixtures/windows_ggml_registry_qualification/verify_evidence.py',
          '${scratch.resolveSymbolicLinksSync()}/protocol/evidence.zip',
          '--head',
          List.filled(40, 'a').join(),
          '--run-id',
          '12',
          '--run-attempt',
          '1',
        ];
        final integrity = await Process.run(
          Platform.isWindows ? 'python' : 'python3',
          [...verifier, '--inventory-only'],
        );
        expect(
          integrity.exitCode,
          0,
          reason: '${integrity.stdout}\n${integrity.stderr}',
        );
        expect(
          '${integrity.stdout}',
          contains('"qualificationVerified": false'),
        );
        final qualification = await Process.run(
          Platform.isWindows ? 'python' : 'python3',
          verifier,
        );
        expect(
          qualification.exitCode,
          isNot(0),
          reason: 'Complete failed-run evidence cannot become a pass.',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
