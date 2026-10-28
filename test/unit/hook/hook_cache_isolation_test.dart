@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../support/native_library_headers.dart';

/// Every hook test builds in a `HookProjectRoot`. One that built in this
/// checkout would leave its fake bundles in `.dart_tool/llamadart`, which the
/// next build in the checkout reuses (#1558).
void main() {
  test('hook tests build in a throwaway package root', () {
    final bare = RegExp(r'(?<![\w.])testCodeBuildHook\(');
    final inCoreVersionRoot = RegExp(
      r'withHookCoreVersion\(\s*\w+,\s*\(\) => testCodeBuildHook\(',
    );
    final ownRoot = {'build_hook_backend_sidecar_test.dart'};
    final offenders = [
      for (final file in Directory('test/unit/hook').listSync())
        if (file is File &&
            file.path.endsWith('_test.dart') &&
            !ownRoot.contains(path.basename(file.path)))
          if (bare.hasMatch(
            file.readAsStringSync().replaceAll(inCoreVersionRoot, ''),
          ))
            path.basename(file.path),
    ];

    expect(offenders, isEmpty);
  });

  test("the checkout's hook caches hold no stub libraries", () {
    final dartTool = Directory('.dart_tool');
    final stubs = [
      for (final cache in ['llamadart', 'lib'])
        ...findNonNativeLibraries(Directory(path.join(dartTool.path, cache))),
    ];

    expect(
      stubs,
      isEmpty,
      reason:
          'Delete .dart_tool/llamadart/native_bundles/*/*/extracted, '
          '.dart_tool/lib and .dart_tool/hooks_runner/shared/llamadart.',
    );
  });

  group('findNonNativeLibraries', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('native_headers_'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String name, List<int> bytes) {
      File(path.join(root.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }

    test('accepts ELF, Mach-O and PE headers', () {
      write('a/libx.so.1', [0x7f, 0x45, 0x4c, 0x46, 2, 1]);
      write('a/libx.dylib', [0xcf, 0xfa, 0xed, 0xfe, 7]);
      write('a/fat.dylib', [0xca, 0xfe, 0xba, 0xbe, 0]);
      write('a/x.dll', [0x4d, 0x5a, 0x90, 0]);

      expect(findNonNativeLibraries(root), isEmpty);
    });

    test('reports text stubs and empty libraries, not other files', () {
      write('libllamadart.dylib', 'fake-libllamadart.dylib'.codeUnits);
      write('b/libggml.so', const []);
      write('b/x.dll', [0x4d]);
      write('b/archive.tar.gz', [0x1f, 0x8b]);
      write('b/LiteRtLm', 'text'.codeUnits);

      expect(
        findNonNativeLibraries(root).map(path.basename),
        unorderedEquals(['libllamadart.dylib', 'libggml.so', 'x.dll']),
      );
    });

    test('ignores a missing directory', () {
      expect(findNonNativeLibraries(Directory(path.join(root.path, 'no'))), []);
    });
  });
}
