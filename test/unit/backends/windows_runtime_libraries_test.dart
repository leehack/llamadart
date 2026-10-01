@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/windows_runtime_libraries.dart';

void main() {
  group('findMissingWindowsLibraries', () {
    test('keeps only the names that fail to load, in order', () {
      final loadable = switch (Platform.operatingSystem) {
        'windows' => 'kernel32.dll',
        'macos' => '/usr/lib/libSystem.B.dylib',
        _ => 'libc.so.6',
      };

      expect(
        findMissingWindowsLibraries([
          'llamadart_missing_a.dll',
          loadable,
          'llamadart_missing_b.dll',
        ]),
        ['llamadart_missing_a.dll', 'llamadart_missing_b.dll'],
      );
    });
  });

  group('isWindowsModuleNotFoundError', () {
    test('matches both Dart VM spellings of error 126', () {
      expect(
        isWindowsModuleNotFoundError(
          "Failed to load dynamic library 'a.dll': The specified module could "
          'not be found.\r\n (error code: 126)',
        ),
        isTrue,
      );
      expect(
        isWindowsModuleNotFoundError(
          "Failed to load dynamic library 'a.dll': error code 126",
        ),
        isTrue,
      );
    });

    test('rejects other error codes that start with 126', () {
      expect(
        isWindowsModuleNotFoundError(
          "Failed to load dynamic library 'a.dll': (error code: 1260)",
        ),
        isFalse,
      );
      expect(
        isWindowsModuleNotFoundError(
          "Failed to load dynamic library 'a.dll': error code 1260",
        ),
        isFalse,
      );
    });
  });

  group('visualCppRuntimeAdvice', () {
    test('names the redistributable, its installer and the DLLs', () {
      expect(
        visualCppRuntimeAdvice(
          architecture: 'ARM64',
          missing: const ['msvcp140.dll', 'vcruntime140.dll'],
          library: 'llamadart.dll',
        ),
        'It requires the Microsoft Visual C++ 2015-2022 Redistributable '
        '(ARM64), and msvcp140.dll, vcruntime140.dll could not be loaded; '
        'install vc_redist.arm64.exe or ship those DLLs next to llamadart.dll.',
      );
    });
  });
}
