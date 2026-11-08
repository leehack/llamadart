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
      expect(opened.companions, hasLength(inventory.length));
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
    expect(calls, [
      ...liteRtLmCompanionLibrariesForAbi(Abi.windowsX64),
      'LiteRtLm.dll',
    ]);

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

  test('smoke inventory selection admits only reviewed release tags', () {
    expect(liteRtLmSmokeUsesCApiV1('v0.19.0'), isTrue);
    expect(liteRtLmSmokeUsesCApiV1('v0.19.1'), isTrue);
    expect(liteRtLmSmokeUsesCApiV1('v0.18.1-4'), isFalse);
    for (final tag in ['v0.19.0-1', 'v0.19.2', 'v0.20.0', 'g0123456789ab']) {
      expect(
        () => liteRtLmSmokeUsesCApiV1(tag),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('no reviewed C API inventory for $tag'),
          ),
        ),
      );
    }
  });

  for (final (tag, abi) in [
    ('v0.19.1', Abi.linuxX64),
    ('v0.19.1', Abi.windowsX64),
    ('v0.18.1-4', Abi.linuxX64),
    ('v0.18.1-4', Abi.windowsX64),
  ]) {
    final cApiV1 = liteRtLmSmokeUsesCApiV1(tag);
    final required = liteRtLmRequiredLibrariesForAbi(abi, cApiV1: cApiV1);
    test('$tag $abi smoke opens its complete reviewed inventory', () {
      final runtimeDir = Directory(path.join(directory.path, 'runtime'))
        ..createSync();
      for (final name in required) {
        File(path.join(runtimeDir.path, name)).writeAsStringSync('fixture');
      }
      final calls = <String>[];
      final opened = openLiteRtLmSmokeLibrary(
        directory: runtimeDir.path,
        abi: abi,
        cApiV1: cApiV1,
        openLibrary: (library) {
          calls.add(path.basename(library));
          return DynamicLibrary.process();
        },
      );
      final primary = liteRtLmPrimaryLibraryForAbi(abi)!;
      final nonPreloaded = liteRtLmNonPreloadedLibrariesForAbi(abi);
      expect(
        calls,
        unorderedEquals(required.where((name) => !nonPreloaded.contains(name))),
      );
      expect(calls.last, primary);
      expect(opened.companions, hasLength(calls.length - 1));
      expect(calls, isNot(anyElement(isIn(nonPreloaded))));
      if (cApiV1) {
        expect(calls, isNot(anyElement(contains('TopK'))));
      } else {
        expect(calls, anyElement(contains('TopKWebGpuSampler')));
      }
    });

    for (final missing in required) {
      test('$tag $abi refuses missing $missing before any library opens', () {
        final runtimeDir = Directory(path.join(directory.path, 'runtime'))
          ..createSync();
        for (final name in required.where((name) => name != missing)) {
          File(path.join(runtimeDir.path, name)).writeAsStringSync('fixture');
        }
        expect(
          () => openLiteRtLmSmokeLibrary(
            directory: runtimeDir.path,
            abi: abi,
            cApiV1: cApiV1,
            openLibrary: (_) =>
                fail('must validate every required member first'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains(
                'Required LiteRT-LM smoke library is missing: '
                '${runtimeDir.path}/$missing',
              ),
            ),
          ),
        );
      });
    }
  }

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
