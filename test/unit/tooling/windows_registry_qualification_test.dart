@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../fixtures/windows_ggml_registry_qualification/payload/passive_modules.dart';

void main() {
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
