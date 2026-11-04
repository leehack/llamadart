@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/download/model_download_manager_base.dart';
import 'package:llamadart/src/core/models/model_load_options.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:llamadart/src/platform/io/model_cache_entry_lock.dart';
import 'package:llamadart/src/platform/io/model_download_manager_io.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late DefaultModelDownloadManager manager;
  late ModelSource source;
  late File modelFile;
  late File metadataFile;
  late ModelCacheEntry original;
  final payload = utf8.encode('retained cache fixture');
  final timestamp = DateTime.utc(2020);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('llamadart_relocation_');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    addTearDown(() => sandbox.delete(recursive: true));
    root = Directory(path.join(sandbox.path, 'before'))..createSync();
    source = ModelSource.url(Uri.parse('https://fixture.invalid/tiny.gguf'));
    final entry = Directory(path.join(root.path, source.cacheDirectoryName))
      ..createSync();
    modelFile = File(path.join(entry.path, source.fileName))
      ..writeAsBytesSync(payload);
    metadataFile = File(path.join(entry.path, 'metadata.json'));
    original = ModelCacheEntry(
      sourceCanonicalKey: source.metadataSourceKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: modelFile.path,
      bytes: payload.length,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    metadataFile.writeAsStringSync(
      jsonEncode({'schema_version': 1, ...original.toJson()}),
    );
    manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
  });

  void editMetadata(Map<String, Object?> fields) {
    final metadata = jsonDecode(metadataFile.readAsStringSync()) as Map;
    metadata.addAll(fields);
    metadataFile.writeAsStringSync(jsonEncode(metadata));
  }

  Future<void> moveRoot() async {
    root = await root.rename(path.join(sandbox.path, 'after'));
    modelFile = File(
      path.join(root.path, source.cacheDirectoryName, source.fileName),
    );
    metadataFile = File(path.join(modelFile.parent.path, 'metadata.json'));
    manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
  }

  test(
    'inventory before loading rebases paths without changing metadata',
    () async {
      editMetadata({'sha256': sha256.convert(payload).toString()});
      await moveRoot();
      final metadata = metadataFile.readAsBytesSync();
      final modified = metadataFile.lastModifiedSync();

      final listed = (await manager.list()).single;
      final found = (await manager.get(source.cacheKey))!;

      for (final entry in [listed, found]) {
        expect(entry.filePath, modelFile.path);
        expect(entry.createdAt, timestamp);
        expect(entry.updatedAt, timestamp);
        expect(entry.sha256, sha256.convert(payload).toString());
      }
      expect(metadataFile.readAsBytesSync(), metadata);
      expect(metadataFile.lastModifiedSync(), modified);
      final cached = await manager.ensureModel(
        source,
        options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
      );
      expect(cached.filePath, modelFile.path);
      expect(modelFile.readAsBytesSync(), payload);
    },
  );

  test(
    'inspection works in a read-only cache without changing last use',
    () async {
      await moveRoot();
      final metadata = metadataFile.readAsBytesSync();
      final modified = metadataFile.lastModifiedSync();
      final entryDirectory = modelFile.parent.path;
      addTearDown(() async {
        await Process.run('chmod', ['755', root.path, entryDirectory]);
      });
      final permissions = await Process.run('chmod', [
        '555',
        root.path,
        entryDirectory,
      ]);
      expect(permissions.exitCode, 0);
      expect((await manager.list()).single.updatedAt, timestamp);
      expect((await manager.get(source.cacheKey))?.filePath, modelFile.path);
      expect(metadataFile.readAsBytesSync(), metadata);
      expect(metadataFile.lastModifiedSync(), modified);
      expect(Directory(path.join(root.path, '.locks')).existsSync(), isFalse);
    },
    skip: Platform.isWindows ? 'POSIX permissions' : false,
  );

  test('explicit cache root is used before loading', () async {
    await moveRoot();
    final other = DefaultModelDownloadManager(
      defaultCacheDirectory: path.join(sandbox.path, 'unrelated'),
    );
    expect(await other.list(), isEmpty);
    expect(
      (await other.list(cacheDirectory: root.path)).single.filePath,
      modelFile.path,
    );
    expect(
      (await other.get(source.cacheKey, cacheDirectory: root.path))?.filePath,
      modelFile.path,
    );
    await other.remove(source.cacheKey, cacheDirectory: root.path);
    expect(modelFile.parent.existsSync(), isFalse);
  });

  for (final operation in ['remove', 'age', 'bytes', 'missing']) {
    test('$operation cleans relocated entries before loading', () async {
      await moveRoot();
      final currentPath = modelFile.path;
      if (operation == 'missing') {
        modelFile.deleteSync();
        expect(await manager.list(), isEmpty);
        expect(await manager.get(source.cacheKey), isNull);
      }
      if (operation == 'remove') {
        await manager.remove(source.cacheKey);
      } else {
        final removed = await manager.prune(
          maxAge: operation == 'age' ? Duration.zero : null,
          maxBytes: operation == 'bytes' ? 0 : null,
        );
        expect(removed.single.filePath, currentPath);
        expect(removed.single.updatedAt, timestamp);
      }
      expect(modelFile.parent.existsSync(), isFalse);
    });
  }

  test('relocated noCache entries remain discoverable and removable', () async {
    final transient = await modelFile.parent.rename(
      '${modelFile.parent.path}-nocache-12345',
    );
    modelFile = File(path.join(transient.path, source.fileName));
    metadataFile = File(path.join(transient.path, 'metadata.json'));
    editMetadata({'file_path': modelFile.path});
    root = await root.rename(path.join(sandbox.path, 'after'));
    manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
    final listed = (await manager.list()).single;
    expect(await manager.get(source.cacheKey), isNotNull);
    expect(listed.filePath, contains('-nocache-12345'));
    await manager.remove(source.cacheKey);
    expect(File(listed.filePath).parent.existsSync(), isFalse);
  });

  for (final corruption in ['length', 'hash']) {
    test(
      'inventory preserves $corruption checks on the next cacheOnly load',
      () async {
        editMetadata({'sha256': sha256.convert(payload).toString()});
        await moveRoot();
        modelFile.writeAsBytesSync(
          corruption == 'length' ? [0] : List<int>.filled(payload.length, 0),
        );
        final before = metadataFile.readAsBytesSync();
        expect(await manager.list(), hasLength(1));
        expect(await manager.get(source.cacheKey), isNotNull);
        expect(metadataFile.readAsBytesSync(), before);
        expect(modelFile.existsSync(), isTrue);
        await expectLater(
          manager.ensureModel(
            source,
            options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
          ),
          throwsA(isA<LlamaStateException>()),
        );
        expect(modelFile.existsSync(), isFalse);
      },
    );
  }

  for (final operation in ['load', 'remove', 'prune', 'missing']) {
    test(
      '$operation never follows a saved outside path with the same basename',
      () async {
        final outside = File(path.join(sandbox.path, source.fileName))
          ..writeAsStringSync('outside sentinel');
        editMetadata({'file_path': outside.path});
        if (operation == 'missing') {
          modelFile.deleteSync();
          expect(await manager.list(), isEmpty);
          expect(await manager.get(source.cacheKey), isNull);
          await manager.prune();
        } else {
          expect((await manager.list()).single.filePath, modelFile.path);
          expect(
            (await manager.get(source.cacheKey))?.filePath,
            modelFile.path,
          );
          if (operation == 'load') {
            final entry = await manager.ensureModel(
              source,
              options: ModelLoadOptions(
                cachePolicy: ModelCachePolicy.cacheOnly,
              ),
            );
            expect(File(entry.filePath).readAsBytesSync(), payload);
          } else if (operation == 'remove') {
            await manager.remove(source.cacheKey);
          } else {
            expect(await manager.prune(maxBytes: 0), hasLength(1));
          }
        }
        expect(outside.readAsStringSync(), 'outside sentinel');
      },
    );
  }

  for (final fileName in [
    '../tiny.gguf',
    '/tiny.gguf',
    r'C:\tiny.gguf',
    '%2e%2e',
    'sub%2ftiny.gguf',
    r'sub\tiny.gguf',
  ]) {
    test('unsafe metadata basename $fileName is ignored', () async {
      editMetadata({'file_name': fileName});
      expect(await manager.list(), isEmpty);
      expect(await manager.get(source.cacheKey), isNull);
      await manager.remove(source.cacheKey);
      expect(await manager.prune(maxBytes: 0), isEmpty);
      expect(modelFile.readAsBytesSync(), payload);
    });
  }

  test('wrong entry directory identity is ignored', () async {
    await modelFile.parent.rename(path.join(root.path, 'other-000000000000'));
    expect(await manager.list(), isEmpty);
    expect(await manager.get(source.cacheKey), isNull);
    await manager.remove(source.cacheKey);
    expect(await manager.prune(maxBytes: 0), isEmpty);
    expect(root.listSync(), hasLength(1));
  });

  test('metadata for a different cache-key prefix is ignored', () async {
    editMetadata({'cache_key': '0' * 64});
    expect(await manager.list(), isEmpty);
    expect(await manager.get(source.cacheKey), isNull);
    await manager.remove(source.cacheKey);
    expect(await manager.prune(maxBytes: 0), isEmpty);
    expect(modelFile.readAsBytesSync(), payload);
  });

  test('full cache key must match for keyed lookup and removal', () async {
    final otherKey = '${source.cacheKey.substring(0, 12)}${'0' * 52}';
    editMetadata({'cache_key': otherKey});
    expect(await manager.get(source.cacheKey), isNull);
    await manager.remove(source.cacheKey);
    expect(modelFile.readAsBytesSync(), payload);
    expect((await manager.get(otherKey))?.cacheKey, otherKey);
  });

  for (final target in ['model', 'metadata', 'entry']) {
    test('does not follow a symbolic link for $target', () async {
      final outside = Directory(path.join(sandbox.path, 'outside'))
        ..createSync();
      final outsideModel = File(path.join(outside.path, source.fileName))
        ..writeAsBytesSync(payload);
      final outsideMetadata = File(path.join(outside.path, 'metadata.json'))
        ..writeAsBytesSync(metadataFile.readAsBytesSync());
      final metadataBytes = outsideMetadata.readAsBytesSync();
      if (target == 'entry') {
        modelFile.parent.deleteSync(recursive: true);
        Link(modelFile.parent.path).createSync(outside.path);
      } else {
        final file = target == 'model' ? modelFile : metadataFile;
        file.deleteSync();
        Link(file.path).createSync(
          target == 'model' ? outsideModel.path : outsideMetadata.path,
        );
      }
      expect(await manager.list(), isEmpty);
      expect(await manager.get(source.cacheKey), isNull);
      await manager.remove(source.cacheKey);
      expect(await manager.prune(maxBytes: 0), isEmpty);
      await expectLater(
        manager.ensureModel(
          source,
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(outsideModel.readAsBytesSync(), payload);
      expect(outsideMetadata.readAsBytesSync(), metadataBytes);
    }, skip: Platform.isWindows ? 'Symbolic links need privileges' : false);
  }

  test(
    'a caller-selected root symlink can be relinked between operations',
    () async {
      final link = Link(path.join(sandbox.path, 'selected'))
        ..createSync(root.path);
      manager = DefaultModelDownloadManager(defaultCacheDirectory: link.path);
      final selectedPath = path.join(
        link.path,
        source.cacheDirectoryName,
        source.fileName,
      );
      expect((await manager.list()).single.filePath, selectedPath);
      expect(
        (await manager.ensureModel(
          source,
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
        )).filePath,
        selectedPath,
      );
      final empty = Directory(path.join(sandbox.path, 'empty'))..createSync();
      link.deleteSync();
      link.createSync(empty.path);
      expect(await manager.list(), isEmpty);
      await manager.remove(source.cacheKey);
      expect(await manager.prune(maxBytes: 0), isEmpty);
      expect(modelFile.readAsBytesSync(), payload);
    },
    skip: Platform.isWindows ? 'Symbolic links need privileges' : false,
  );

  test(
    'prune through a selected root preserves its returned path spelling',
    () async {
      final link = Link(path.join(sandbox.path, 'selected'))
        ..createSync(root.path);
      manager = DefaultModelDownloadManager(defaultCacheDirectory: link.path);
      final selectedPath = path.join(
        link.path,
        source.cacheDirectoryName,
        source.fileName,
      );
      expect(
        (await manager.prune(maxAge: Duration.zero)).single.filePath,
        selectedPath,
      );
      expect(modelFile.existsSync(), isFalse);
    },
    skip: Platform.isWindows ? 'Symbolic links need privileges' : false,
  );

  test(
    'prune revalidates relocated metadata after acquiring its entry lock',
    () async {
      await moveRoot();
      final previousLocker = modelCacheEntryLocker;
      addTearDown(() => modelCacheEntryLocker = previousLocker);
      var refreshed = false;
      modelCacheEntryLocker = (lockPath, {required throwIfCancelled}) async {
        if (!refreshed &&
            path.basename(lockPath) == '${source.cacheDirectoryName}.lock') {
          refreshed = true;
          editMetadata({
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
        return previousLocker(lockPath, throwIfCancelled: throwIfCancelled);
      };
      expect(await manager.prune(maxAge: Duration.zero), isEmpty);
      expect(refreshed, isTrue);
      expect(modelFile.readAsBytesSync(), payload);
    },
  );
}
