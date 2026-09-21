@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../tool/litert_lm_library_smoke.dart';

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('litert_library_smoke_');
    for (final name in liteRtLmRequiredLibrariesForAbi(Abi.windowsX64)) {
      File(path.join(directory.path, name)).writeAsStringSync('fixture');
    }
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'Windows smoke retries an earlier DLL after a later dependency loads',
    () {
      final calls = <String>[];
      final inventory = liteRtLmCompanionLibrariesForAbi(Abi.windowsX64);
      final dependent = inventory.first;
      final dependency = inventory.last;
      var dependencyLoaded = false;
      final opened = openLiteRtLmSmokeLibrary(
        directory: directory.path,
        abi: Abi.windowsX64,
        openLibrary: (library) {
          final name = path.basename(library);
          calls.add(name);
          if (name == dependent && !dependencyLoaded) {
            throw ArgumentError('missing dependency: $dependency');
          }
          if (name == dependency) dependencyLoaded = true;
          return DynamicLibrary.process();
        },
      );
      expect(calls.last, 'LiteRtLm.dll');
      expect(calls.where((name) => name == dependent), hasLength(2));
      expect(opened.companions, hasLength(5));
    },
  );

  test('Windows smoke requires the DXC pair without opening it', () {
    final calls = <String>[];
    openLiteRtLmSmokeLibrary(
      directory: directory.path,
      abi: Abi.windowsX64,
      openLibrary: (library) {
        calls.add(path.basename(library));
        return DynamicLibrary.process();
      },
    );
    expect(calls, isNot(anyElement(isIn(['dxcompiler.dll', 'dxil.dll']))));
    expect(calls, hasLength(6));

    File(path.join(directory.path, 'dxil.dll')).deleteSync();
    expect(
      () => openLiteRtLmSmokeLibrary(
        directory: directory.path,
        abi: Abi.windowsX64,
        openLibrary: (_) => fail('must validate inventory first'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('dxil.dll'),
        ),
      ),
    );
  });

  test('missing required DLL fails before opening any libraries', () {
    File(path.join(directory.path, 'libwebgpu_dawn.dll')).deleteSync();
    expect(
      () => openLiteRtLmSmokeLibrary(
        directory: directory.path,
        abi: Abi.windowsX64,
        openLibrary: (_) => fail('must validate inventory first'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('libwebgpu_dawn.dll'),
        ),
      ),
    );
  });

  test('an unresolved DLL dependency still fails the smoke', () {
    final failure = ArgumentError('missing external dependency');
    expect(
      () => openLiteRtLmSmokeLibrary(
        directory: directory.path,
        abi: Abi.windowsX64,
        openLibrary: (_) => throw failure,
      ),
      throwsA(same(failure)),
    );
  });
}
