@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../support/fake_mtmd.dart';

void main() {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  Symbol private(String name) => MirrorSystem.getSymbol(name, owner);
  final fileName = Platform.isWindows
      ? 'mtmd.dll'
      : Platform.isMacOS || Platform.isIOS
      ? 'libmtmd.dylib'
      : 'libmtmd.so';

  for (final (platform, directory) in [
    ('Windows', r'C:\bundle\lib'),
    ('Linux', '/opt/bundle/lib'),
    ('macOS', '/Applications/bundle/lib'),
  ]) {
    test(
      '$platform mtmd retry policy preserves misses and successful APIs',
      () {
        bool retry({
          required bool attempted,
          required bool hasApi,
          required String? searched,
          required String? current,
        }) =>
            reflectClass(
                  LlamaCppService,
                ).invoke(private('_shouldRetryMtmdFallbackLookup'), [], {
                  #attempted: attempted,
                  #hasApi: hasApi,
                  #searchedDirectory: searched,
                  #moduleDirectory: current,
                }).reflectee
                as bool;

        expect(
          retry(attempted: false, hasApi: false, searched: null, current: null),
          isTrue,
        );
        expect(
          retry(
            attempted: true,
            hasApi: false,
            searched: null,
            current: directory,
          ),
          isTrue,
        );
        expect(
          retry(
            attempted: true,
            hasApi: false,
            searched: directory,
            current: directory,
          ),
          isFalse,
        );
        expect(
          retry(
            attempted: true,
            hasApi: true,
            searched: null,
            current: directory,
          ),
          isFalse,
        );
      },
    );
  }

  late LlamaCppService service;
  late List<String> opened;
  late String moduleDirectory;

  void setDirectory(String? directory) =>
      reflect(service).setField(private('_backendModuleDirectory'), directory);

  Object? resolve({DynamicLibrary Function(String)? open}) =>
      reflect(service).invoke(private('_resolveMtmdFallbackApi'), [], {
        #open:
            open ??
            (String candidate) {
              opened.add(candidate);
              throw ArgumentError('Library unavailable');
            },
      }).reflectee;

  setUp(() {
    service = LlamaCppService();
    opened = [];
    final temp = Directory.systemTemp.createTempSync('mtmd_fallback_');
    addTearDown(() => temp.deleteSync(recursive: true));
    moduleDirectory = path.join(temp.path, 'lib');
    Directory(moduleDirectory).createSync();
  });

  test(
    'failed pre-init mtmd lookup retries after module directory resolves',
    () {
      expect(resolve(), isNull);
      expect(opened, [fileName]);
      opened.clear();

      setDirectory(moduleDirectory);
      expect(resolve(), isNull);
      expect(opened, [path.join(moduleDirectory, fileName), fileName]);
    },
  );

  test(
    'failed mtmd lookup is cached for the same directory, including null',
    () {
      for (final directory in [null, moduleDirectory]) {
        service = LlamaCppService();
        setDirectory(directory);
        expect(resolve(), isNull);
        opened.clear();
        expect(resolve(), isNull);
        expect(opened, isEmpty);
      }
    },
  );

  test('failed mtmd lookup retries when a known module directory changes', () {
    setDirectory(moduleDirectory);
    expect(resolve(), isNull);
    opened.clear();
    final other = path.join(moduleDirectory, 'other');
    setDirectory(other);
    expect(resolve(), isNull);
    expect(opened, [path.join(other, fileName), fileName]);
  });

  test('successful mtmd lookup remains cached when the directory changes', () {
    final fake = FakeMtmd.install(service, tokens: const []);
    addTearDown(fake.dispose);
    final api = reflect(
      service,
    ).getField(private('_mtmdFallbackApi')).reflectee;
    expect(resolve(), same(api));
    setDirectory(moduleDirectory);
    expect(resolve(), same(api));
    expect(opened, isEmpty);
  });

  test(
    'module mtmd library is opened before a bare name on the search path',
    () {
      setDirectory(moduleDirectory);
      expect(
        resolve(
          open: (candidate) {
            opened.add(candidate);
            return DynamicLibrary.open(
              Platform.isWindows
                  ? 'kernel32.dll'
                  : Platform.isMacOS || Platform.isIOS
                  ? '/usr/lib/libSystem.B.dylib'
                  : 'libc.so.6',
            );
          },
        ),
        isNull,
      );
      expect(opened, [path.join(moduleDirectory, fileName)]);
    },
  );

  test('an incomplete mtmd library is retried after directory resolution', () {
    DynamicLibrary incomplete(String candidate) {
      opened.add(candidate);
      return DynamicLibrary.open(
        Platform.isWindows
            ? 'kernel32.dll'
            : Platform.isMacOS || Platform.isIOS
            ? '/usr/lib/libSystem.B.dylib'
            : 'libc.so.6',
      );
    }

    expect(resolve(open: incomplete), isNull);
    expect(opened, [fileName]);
    opened.clear();
    expect(resolve(open: incomplete), isNull);
    expect(opened, isEmpty);
    setDirectory(moduleDirectory);
    expect(resolve(open: incomplete), isNull);
    expect(opened, [path.join(moduleDirectory, fileName)]);
  });
}
