@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory root;
  late DefaultModelDownloadManager manager;
  final source = ModelSource.url(
    Uri.parse('https://example.com/m/tiny.gguf?token=SECRET'),
    fileName: 'tiny.gguf',
  );
  final payload = utf8.encode('downloaded-by-a-platform-executor');
  final digest = sha256.convert(payload).toString();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('llamadart_import_');
    addTearDown(() {
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['-R', 'u+w', temp.path]);
      }
      temp.deleteSync(recursive: true);
    });
    root = Directory(path.join(temp.path, 'cache'));
    manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
  });

  File download([List<int>? bytes, String dir = 'incoming']) {
    return File(path.join(temp.path, dir, 'CFNetworkDownload_x.tmp'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes ?? payload);
  }

  List<String> entryFiles(ModelCacheEntry entry) => Directory(
    path.dirname(entry.filePath),
  ).listSync().map((entity) => path.basename(entity.path)).toList()..sort();

  test('moves a verified file into place as a cacheOnly hit', () async {
    final file = download();

    final entry = await manager.importDownloadedFile(
      source,
      file.path,
      options: ModelLoadOptions(sha256: digest, bearerToken: 'hf_SECRET'),
      expectedBytes: payload.length,
      etag: '"abc"',
      lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
    );

    expect(file.existsSync(), isFalse);
    expect(File(entry.filePath).readAsBytesSync(), payload);
    expect(entry.sha256, digest);
    expect(entry.etag, '"abc"');
    final hit = await manager.ensureModel(
      source,
      options: ModelLoadOptions(
        cachePolicy: ModelCachePolicy.cacheOnly,
        sha256: digest,
      ),
    );
    expect(hit.filePath, entry.filePath);
    expect(hit.etag, '"abc"');
    expect(hit.lastModified, 'Wed, 21 Oct 2026 07:28:00 GMT');
    final metadata = File(
      path.join(path.dirname(entry.filePath), 'metadata.json'),
    ).readAsStringSync();
    expect(metadata, isNot(contains('SECRET')));
    expect((await manager.list()).single.cacheKey, source.cacheKey);
  });

  test('a checksum mismatch leaves the cache and the file untouched', () async {
    final bytes = utf8.encode('an HTML error page');
    final file = download(bytes);

    await expectLater(
      manager.importDownloadedFile(
        source,
        file.path,
        options: ModelLoadOptions(sha256: digest),
      ),
      throwsA(isA<LlamaModelException>()),
    );

    expect(file.readAsBytesSync(), bytes);
    expect(await manager.list(), isEmpty);
    expect(root.existsSync(), isFalse);
  });

  test('a size mismatch and an empty file are rejected', () async {
    final file = download();
    await expectLater(
      manager.importDownloadedFile(
        source,
        file.path,
        expectedBytes: payload.length + 1,
      ),
      throwsA(isA<LlamaModelException>()),
    );
    final empty = download(<int>[], 'empty');
    await expectLater(
      manager.importDownloadedFile(source, empty.path),
      throwsA(isA<LlamaModelException>()),
    );

    expect(file.existsSync(), isTrue);
    expect(await manager.list(), isEmpty);
  });

  test('a missing path and a directory are rejected', () async {
    final directory = Directory(path.join(temp.path, 'incoming'))..createSync();

    for (final target in [
      path.join(temp.path, 'missing.tmp'),
      directory.path,
    ]) {
      await expectLater(
        manager.importDownloadedFile(source, target),
        throwsA(isA<LlamaModelException>()),
      );
    }
    expect(await manager.list(), isEmpty);
  });

  test('a symbolic link is rejected', () async {
    final file = download();
    final link = Link(path.join(temp.path, 'link.tmp'))..createSync(file.path);

    await expectLater(
      manager.importDownloadedFile(source, link.path),
      throwsA(isA<LlamaModelException>()),
    );

    expect(file.existsSync(), isTrue);
    expect(await manager.list(), isEmpty);
  }, testOn: '!windows');

  test('rejects local sources, noCache and cacheOnly', () async {
    final file = download();
    await expectLater(
      manager.importDownloadedFile(ModelSource.path(file.path), file.path),
      throwsA(
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'source',
        ),
      ),
    );
    for (final policy in [
      ModelCachePolicy.noCache,
      ModelCachePolicy.cacheOnly,
    ]) {
      await expectLater(
        manager.importDownloadedFile(
          source,
          file.path,
          options: ModelLoadOptions(cachePolicy: policy),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    }

    expect(file.existsSync(), isTrue);
    expect(root.existsSync(), isFalse);
  });

  test('replaces a completed entry and drops the part file', () async {
    final first = await manager.importDownloadedFile(
      source,
      download(utf8.encode('old')).path,
    );
    final part = File('${first.filePath}.part')..writeAsStringSync('partial');
    File('${part.path}.json').writeAsStringSync('{}');

    final entry = await manager.importDownloadedFile(
      source,
      download().path,
      options: ModelLoadOptions(sha256: digest),
    );

    expect(File(entry.filePath).readAsBytesSync(), payload);
    expect(entryFiles(entry), ['metadata.json', 'tiny.gguf']);
    expect((await manager.get(source.cacheKey))?.sha256, digest);
  });

  test('removes orphaned import copies and attempt parts', () async {
    final first = await manager.importDownloadedFile(source, download().path);
    final orphans = [
      '${first.filePath}.0123456789abcdef.import',
      '${first.filePath}.0123456789abcdef.part',
    ];
    for (final orphan in orphans) {
      File(orphan).writeAsStringSync('orphan');
    }

    final entry = await manager.importDownloadedFile(source, download().path);

    expect(entryFiles(entry), ['metadata.json', 'tiny.gguf']);
  });

  test('copies when the file cannot be renamed out of its directory', () async {
    final file = download();
    expect(Process.runSync('chmod', ['a-w', file.parent.path]).exitCode, 0);

    final entry = await manager.importDownloadedFile(
      source,
      file.path,
      options: ModelLoadOptions(sha256: digest),
    );

    expect(File(entry.filePath).readAsBytesSync(), payload);
    expect(entryFiles(entry), ['metadata.json', 'tiny.gguf']);
    expect((await manager.get(source.cacheKey))?.bytes, payload.length);
  }, testOn: '!windows');

  test('a cache entry path that is not a directory is rejected', () async {
    final file = download();
    Directory(root.path).createSync(recursive: true);
    File(path.join(root.path, source.cacheDirectoryName)).writeAsStringSync('');

    await expectLater(
      manager.importDownloadedFile(source, file.path),
      throwsA(isA<LlamaStateException>()),
    );

    expect(file.existsSync(), isTrue);
  });

  test(
    'reports a failed move and leaves the file in place',
    () async {
      final file = download();
      final entry = Directory(path.join(root.path, source.cacheDirectoryName))
        ..createSync(recursive: true);
      expect(Process.runSync('chmod', ['a-w', entry.path]).exitCode, 0);

      await expectLater(
        manager.importDownloadedFile(source, file.path),
        throwsA(isA<LlamaModelException>()),
      );

      expect(file.readAsBytesSync(), payload);
      expect(entry.listSync(), isEmpty);
    },
    testOn: '!windows',
    skip: Platform.isWindows || _isRoot()
        ? 'Directory permissions do not bind this user.'
        : false,
  );

  test('honors cancellation before touching the file', () async {
    final file = download();
    final token = ModelDownloadCancelToken()..cancel();

    await expectLater(
      manager.importDownloadedFile(
        source,
        file.path,
        options: ModelLoadOptions(cancelToken: token),
      ),
      throwsA(isA<LlamaStateException>()),
    );

    expect(file.existsSync(), isTrue);
    expect(root.existsSync(), isFalse);
  });
}

bool _isRoot() =>
    !Platform.isWindows &&
    Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
