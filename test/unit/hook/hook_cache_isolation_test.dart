@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../support/hook_project_root.dart';
import '../../support/native_library_headers.dart';

/// Whether [source] calls `testCodeBuildHook` other than through a
/// `HookProjectRoot` receiver, or imports `code_assets` under a prefix that
/// would hide the call from this check.
bool escapesHookRoot(String source) {
  final calls = RegExp(r'testCodeBuildHook\(').allMatches(source).length;
  final onRoot = RegExp(
    r'(?<![\w.])(?!code_assets\b)\w+\.testCodeBuildHook\(',
  ).allMatches(source).length;
  final prefixed = RegExp(
    r"import 'package:code_assets/[^;]*\bas\b",
  ).hasMatch(source);
  return calls != onRoot || prefixed;
}

/// Every hook test builds in a `HookProjectRoot`. One that built in this
/// checkout would leave its fake bundles in `.dart_tool/llamadart`, which the
/// next build in the checkout reuses (#1558).
void main() {
  test('hook tests build in a throwaway package root', () {
    final ownRoot = {
      'build_hook_backend_sidecar_test.dart',
      'hook_cache_isolation_test.dart',
    };
    final offenders = [
      for (final file in Directory('test/unit/hook').listSync())
        if (file is File &&
            file.path.endsWith('_test.dart') &&
            !ownRoot.contains(path.basename(file.path)) &&
            escapesHookRoot(file.readAsStringSync()))
          path.basename(file.path),
    ];

    expect(offenders, isEmpty);
  });

  group('escapesHookRoot', () {
    test('accepts calls on a root', () {
      expect(escapesHookRoot('await project.testCodeBuildHook(a);'), isFalse);
      expect(escapesHookRoot('() => coreRoot.testCodeBuildHook(a)'), isFalse);
    });

    test('flags bare, prefixed and aliased calls', () {
      expect(escapesHookRoot('await testCodeBuildHook(a);'), isTrue);
      expect(escapesHookRoot('code_assets.testCodeBuildHook(a);'), isTrue);
      expect(escapesHookRoot('a.b.testCodeBuildHook(a);'), isTrue);
      expect(
        escapesHookRoot("import 'package:code_assets/code_assets.dart' as ca;"),
        isTrue,
      );
    });

    test('flags a bare call in a file that also uses a root', () {
      expect(
        escapesHookRoot(
          'project.testCodeBuildHook(a); withCore(v, () => testCodeBuildHook(b));',
        ),
        isTrue,
      );
    });
  });

  group('HookProjectRoot', () {
    test('creates nothing until the directory is used', () {
      final temp = Directory.systemTemp.createTempSync('hook_root_probe_');
      addTearDown(() => temp.deleteSync(recursive: true));

      IOOverrides.runZoned(() {
        final root = HookProjectRoot.create();
        root.resolve('.dart_tool/llamadart');
        expect(temp.listSync(), isEmpty);
        root.delete();

        final created = root.directory;
        expect(created.existsSync(), isTrue);
        root.delete();
        expect(created.existsSync(), isFalse);
      }, getSystemTempDirectory: () => temp);
    });

    test('declares the requested core version', () {
      final root = HookProjectRoot.create(coreVersion: '0.16.1');
      addTearDown(root.delete);

      expect(
        File(path.join(root.directory.path, 'pubspec.yaml')).readAsStringSync(),
        'name: llamadart\nversion: 0.16.1\n',
      );
    });
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
