@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_cache.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'llamadart_litert_cache_test_',
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['-R', 'u+rwx', tempDir.path]);
      }
      await tempDir.delete(recursive: true);
    }
  });

  File write(String name, int bytes, {Directory? dir}) {
    final file = File('${(dir ?? tempDir).path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  test('deletes only program caches above the cap', () {
    final over = write('model_1_10_mldrift_program_cache.bin', 11);
    final atCap = write('model_2_10_mldrift_program_cache.bin', 10);
    final under = write('model_3_10_mldrift_program_cache.bin', 1);
    final weights = write('model_1_10_mldrift_weight_cache.bin', 100);
    final xnnpack = write('model.litertlm.xnnpack_cache', 100);
    final other = write('mldrift_program_cache.bin.bak', 100);
    final deleted = <String, int>{};
    final errors = <Object>[];

    pruneLiteRtLmProgramCaches(
      tempDir.path,
      10,
      onDeleted: (path, bytes) => deleted[path] = bytes,
      onError: (path, error) => errors.add(error),
    );

    expect(over.existsSync(), isFalse);
    expect(atCap.existsSync(), isTrue);
    expect(under.existsSync(), isTrue);
    expect(weights.existsSync(), isTrue);
    expect(xnnpack.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
    expect(deleted, {over.path: 11});
    expect(errors, isEmpty);
  });

  test('zero cap deletes non-empty program caches and keeps empty ones', () {
    final nonEmpty = write('a_mldrift_program_cache.bin', 1);
    final empty = write('b_mldrift_program_cache.bin', 0);

    pruneLiteRtLmProgramCaches(tempDir.path, 0);

    expect(nonEmpty.existsSync(), isFalse);
    expect(empty.existsSync(), isTrue);
  });

  test('does not descend into subdirectories', () {
    final nested = Directory('${tempDir.path}/nested')..createSync();
    final file = write('a_mldrift_program_cache.bin', 50, dir: nested);

    pruneLiteRtLmProgramCaches(tempDir.path, 10);

    expect(file.existsSync(), isTrue);
  });

  test('skips links and keeps their targets', () {
    final outside = Directory('${tempDir.path}/outside')..createSync();
    final cache = Directory('${tempDir.path}/cache')..createSync();
    final target = write('real_mldrift_program_cache.bin', 50, dir: outside);
    final fileLink = Link('${cache.path}/link_mldrift_program_cache.bin')
      ..createSync(target.path);
    Link('${cache.path}/dir_link').createSync(outside.path);
    final deleted = <String>[];

    pruneLiteRtLmProgramCaches(
      cache.path,
      10,
      onDeleted: (path, bytes) => deleted.add(path),
    );

    expect(target.existsSync(), isTrue);
    expect(fileLink.existsSync(), isTrue);
    expect(deleted, isEmpty);
  }, testOn: '!windows');

  test('missing directory is a no-op', () {
    final errors = <Object>[];

    pruneLiteRtLmProgramCaches(
      '${tempDir.path}/missing',
      10,
      onError: (path, error) => errors.add(error),
    );

    expect(errors, isEmpty);
    expect(Directory('${tempDir.path}/missing').existsSync(), isFalse);
  });

  test('a failed delete is reported and does not stop the scan', () {
    final locked = Directory('${tempDir.path}/locked')..createSync();
    final first = write('a_mldrift_program_cache.bin', 50, dir: locked);
    final second = write('b_mldrift_program_cache.bin', 50, dir: locked);
    Process.runSync('chmod', ['a-w', locked.path]);
    final deleted = <String>[];
    final errorPaths = <String>[];

    expect(
      () => pruneLiteRtLmProgramCaches(
        locked.path,
        10,
        onDeleted: (path, bytes) => deleted.add(path),
        onError: (path, error) => errorPaths.add(path),
      ),
      returnsNormally,
    );

    final survivors = [
      for (final file in [first, second])
        if (file.existsSync()) file.path,
    ];
    expect(errorPaths, unorderedEquals(survivors));
    expect([...deleted, ...survivors], hasLength(2));
  }, testOn: '!windows');

  test('an unreadable directory is reported and tolerated', () {
    final locked = Directory('${tempDir.path}/unreadable')..createSync();
    final file = write('a_mldrift_program_cache.bin', 50, dir: locked);
    Process.runSync('chmod', ['a-rwx', locked.path]);
    final errorPaths = <String>[];

    expect(
      () => pruneLiteRtLmProgramCaches(
        locked.path,
        10,
        onError: (path, error) => errorPaths.add(path),
      ),
      returnsNormally,
    );

    Process.runSync('chmod', ['u+rwx', locked.path]);
    if (file.existsSync()) {
      expect(errorPaths, [locked.path]);
    }
  }, testOn: '!windows');
}
