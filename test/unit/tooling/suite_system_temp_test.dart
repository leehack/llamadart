@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../support/suite_system_temp.dart';

void main() {
  late Directory root;
  late List<Directory> scheduled;

  setUp(() {
    root = Directory.systemTemp.createTempSync('suite_system_temp_test_');
    File(path.join(root.path, 'a.bin')).writeAsStringSync('a');
    File(path.join(root.path, 'model', 'b.xnnpack_cache'))
      ..createSync(recursive: true)
      ..writeAsStringSync('b');
    File(path.join(root.path, 'model', 'c.bin')).writeAsStringSync('c');
    scheduled = [];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> deleteAfterExit(Directory directory) async =>
      scheduled.add(directory);

  /// Deletes like the host, except that [locked] files and every directory
  /// holding one cannot be deleted, as on Windows while a file is open.
  void Function(FileSystemEntity) lockedDelete(Set<String> locked) => (entity) {
    final blocked = locked.any(
      (file) => file == entity.path || path.isWithin(entity.path, file),
    );
    if (blocked) {
      throw FileSystemException('locked', entity.path);
    }
    entity.deleteSync(recursive: true);
  };

  String file(String relative) => path.join(root.path, relative);

  test('an unlocked root is deleted without scheduling anything', () async {
    await deleteSuiteRoot(root, deleteAfterExit: deleteAfterExit);
    expect(root.existsSync(), isFalse);
    expect(scheduled, isEmpty);
  });

  test('Windows deletes all but the open XNNPack caches and schedules the '
      'root for deletion after exit', () async {
    final cache = file(path.join('model', 'b.xnnpack_cache'));
    await deleteSuiteRoot(
      root,
      isWindows: true,
      delete: lockedDelete({cache}),
      deleteAfterExit: deleteAfterExit,
    );
    expect(File(file('a.bin')).existsSync(), isFalse);
    expect(File(file(path.join('model', 'c.bin'))).existsSync(), isFalse);
    expect(File(cache).existsSync(), isTrue);
    expect(scheduled.map((directory) => directory.path), [root.path]);
  });

  test('Windows still fails on any other undeletable file', () async {
    await expectLater(
      deleteSuiteRoot(
        root,
        isWindows: true,
        delete: lockedDelete({
          file(path.join('model', 'b.xnnpack_cache')),
          file(path.join('model', 'c.bin')),
        }),
        deleteAfterExit: deleteAfterExit,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(scheduled, isEmpty);
  });

  test('other hosts fail on an undeletable XNNPack cache', () async {
    await expectLater(
      deleteSuiteRoot(
        root,
        isWindows: false,
        delete: lockedDelete({file(path.join('model', 'b.xnnpack_cache'))}),
        deleteAfterExit: deleteAfterExit,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(file('a.bin')).existsSync(), isTrue);
    expect(scheduled, isEmpty);
  });

  test('the reaper waits for the process, then deletes the literal path', () {
    final arguments = suiteRootReaperArguments(r"C:\Temp\it's $HOME", 42);
    expect(arguments.take(3), ['-NoProfile', '-NonInteractive', '-Command']);
    expect(
      arguments.last,
      'Wait-Process -Id 42 -ErrorAction SilentlyContinue; '
      r"Remove-Item -LiteralPath 'C:\Temp\it''s $HOME' -Recurse -Force",
    );
  });

  test(
    'Windows removes a root whose XNNPack cache stays open until exit',
    () async {
      final cache = file(path.join('model', 'b.xnnpack_cache'));
      final scriptDir = Directory.systemTemp.createTempSync('holder_');
      addTearDown(() => scriptDir.deleteSync(recursive: true));
      final script = File(path.join(scriptDir.path, 'holder.dart'));
      final support = path.absolute(
        'test',
        'support',
        'suite_system_temp.dart',
      );
      script.writeAsStringSync("""
import 'dart:io';

import '${Uri.file(support)}';

Future<void> main(List<String> args) async {
  final [rootPath, cachePath] = args;
  final cache = File(cachePath).openSync(mode: FileMode.append);
  await deleteSuiteRoot(Directory(rootPath));
  stdout.write(Directory(rootPath).listSync(recursive: true)
      .whereType<File>().map((file) => file.path).join('|'));
  cache.closeSync();
}
""");
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${path.absolute('.dart_tool', 'package_config.json')}',
        script.path,
        root.path,
        cache,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, cache, reason: 'only the open cache survives');
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (root.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(root.existsSync(), isFalse, reason: 'the reaper removes the root');
    },
    // The child compiles the support file, then the reaper outlives it.
    timeout: const Timeout(Duration(minutes: 3)),
    skip: Platform.isWindows ? false : 'needs Windows file locking',
  );
}
