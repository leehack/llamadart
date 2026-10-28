@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_model_store/llamadart_model_store.dart';
import 'package:path/path.dart' as p;

import 'support/model_server.dart';

void main() {
  late Directory root;
  late ModelServer server;
  late LlamaModel pair;

  final modelBytes = List<int>.generate(4096, (i) => i % 251);
  final projectorBytes = List<int>.generate(1024, (i) => i % 13);
  final otherBytes = List<int>.generate(2048, (i) => i % 7);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('model_store_test_');
    server = await ModelServer.start(<String, List<int>>{
      '/model.gguf': modelBytes,
      '/mmproj.gguf': projectorBytes,
      '/other.gguf': otherBytes,
    });
    pair = LlamaModel(
      ModelSource.url(server.url('/model.gguf')),
      projector: ModelSource.url(server.url('/mmproj.gguf')),
    );
  });

  tearDown(() async {
    await server.close();
    await root.delete(recursive: true);
  });

  Future<ModelStore> open(String appId) =>
      ModelStore.open(directory: root.path, appId: appId);

  LlamaModel single(String path) =>
      LlamaModel(ModelSource.url(server.url(path)));

  /// Marks [file] as last used two days ago in its cache metadata.
  Future<void> age(ModelCacheEntry file) async {
    final metadata = File(p.join(p.dirname(file.filePath), 'metadata.json'));
    final json = jsonDecode(await metadata.readAsString()) as Map;
    json['updated_at'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 2))
        .toIso8601String();
    await metadata.writeAsString(jsonEncode(json));
  }

  Future<List<String>> storeFileNames() async =>
      [for (final file in await (await open('inspector')).list()) file.fileName]
        ..sort();

  group('ensure', () {
    test('keeps a model and its projector as one referenced entry', () async {
      final store = await open('app.a');

      final entry = await store.ensure(pair);

      expect(entry.id, ModelStore.entryIdFor(pair));
      expect(await File(entry.model.filePath).readAsBytes(), modelBytes);
      expect(
        await File(entry.projector!.filePath).readAsBytes(),
        projectorBytes,
      );
      expect(entry.references.map((r) => r.appId), ['app.a']);
      final loadable = entry.toLlamaModel();
      expect(loadable.source.path, entry.model.filePath);
      expect(loadable.projector!.path, entry.projector!.filePath);

      final listed = await store.entries();
      expect(listed.map((e) => e.id), [entry.id]);
      expect(listed.single.projector!.cacheKey, entry.projector!.cacheKey);
    });

    test('reuses files another app downloaded and records both apps', () async {
      await (await open('app.a')).ensure(pair);
      final entry = await (await open('app.b')).ensure(pair);

      expect(server.requests['/model.gguf'], 1);
      expect(server.requests['/mmproj.gguf'], 1);
      expect(entry.references.map((r) => r.appId).toSet(), {'app.a', 'app.b'});
    });

    test('drops its reference when a download fails', () async {
      final store = await open('app.a');
      final broken = LlamaModel(
        ModelSource.url(server.url('/model.gguf')),
        projector: ModelSource.url(server.url('/missing.gguf')),
      );

      await expectLater(
        store.ensure(broken, options: ModelLoadOptions(maxRetries: 0)),
        throwsA(isA<LlamaException>()),
      );

      expect(await store.entries(), isEmpty);
      // The downloaded model stays for a retry, but nothing protects it.
      expect(await storeFileNames(), ['model.gguf']);
      await store.prune(maxBytes: 0);
      expect(await storeFileNames(), isEmpty);
    });

    test('drops its reference on a cacheOnly miss', () async {
      final store = await open('app.a');

      await expectLater(
        store.ensure(
          pair,
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
        ),
        throwsA(isA<LlamaException>()),
      );

      final refs = Directory(
        p.join(root.path, 'entries', ModelStore.entryIdFor(pair), 'refs'),
      );
      expect(refs.listSync(), isEmpty);
    });

    test(
      'keeps a reference a concurrent call of the same app rewrote',
      () async {
        final store = await open('app.a');

        final miss = store.ensure(
          pair,
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.cacheOnly),
        );
        final download = store.ensure(pair);

        await expectLater(miss, throwsA(isA<LlamaException>()));
        await download;
        expect((await store.entries()).single.references.map((r) => r.appId), [
          'app.a',
        ]);
      },
    );

    test('rejects what the store cannot hold', () async {
      final store = await open('app.a');
      final local = File(p.join(root.path, 'local.gguf'))
        ..writeAsBytesSync(modelBytes);

      await expectLater(
        store.ensure(LlamaModel(ModelSource.path(local.path))),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        store.ensure(
          pair,
          options: ModelLoadOptions(cachePolicy: ModelCachePolicy.noCache),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        store.ensure(
          pair,
          options: ModelLoadOptions(cacheDirectory: root.path),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        store.ensure(pair, options: ModelLoadOptions(sha256: 'a' * 64)),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(server.requests, isEmpty);
      expect(Directory(p.join(root.path, 'entries')).listSync(), isEmpty);
    });

    test('never sends credentials to a second host', () async {
      final store = await open('app.a');
      final crossHost = LlamaModel(
        ModelSource.url(server.url('/model.gguf')),
        projector: ModelSource.url(
          server.url('/mmproj.gguf').replace(host: 'localhost'),
        ),
      );

      await expectLater(
        store.ensure(
          crossHost,
          options: ModelLoadOptions(bearerToken: 'secret-token'),
        ),
        throwsA(
          isA<LlamaArgumentException>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret-token')),
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('writes no source secrets to store metadata', () async {
      final signed = LlamaModel(
        ModelSource.url(
          server.url('/model.gguf', query: {'X-Amz-Signature': 'url-secret'}),
        ),
      );
      final store = await open('app.a');

      await store.ensure(
        signed,
        options: ModelLoadOptions(
          bearerToken: 'bearer-secret',
          headers: {'X-Api-Key': 'header-secret'},
        ),
      );

      expect(server.requestHeaders.single.value('x-api-key'), 'header-secret');
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (p.extension(file.path) == '.gguf') {
          continue;
        }
        final text = latin1.decode(file.readAsBytesSync());
        for (final secret in ['url-secret', 'bearer-secret', 'header-secret']) {
          expect(text, isNot(contains(secret)), reason: file.path);
        }
      }
    });
  });

  group('release', () {
    test('keeps files while another app references them', () async {
      final a = await open('app.a');
      final b = await open('app.b');
      final entry = await a.ensure(pair);
      await b.ensure(pair);

      await a.release(entry.id);

      expect(File(entry.model.filePath).existsSync(), isTrue);
      expect((await b.entries()).single.references.map((r) => r.appId), [
        'app.b',
      ]);

      await b.release(entry.id);

      expect(File(entry.model.filePath).existsSync(), isFalse);
      expect(File(entry.projector!.filePath).existsSync(), isFalse);
      expect(await b.entries(), isEmpty);
    });

    test('keeps a projector another referenced entry shares', () async {
      final a = await open('app.a');
      final b = await open('app.b');
      final first = await a.ensure(pair);
      final second = await b.ensure(
        LlamaModel(
          ModelSource.url(server.url('/other.gguf')),
          projector: pair.projector,
        ),
      );

      await a.release(first.id);

      expect(File(first.model.filePath).existsSync(), isFalse);
      expect(File(second.projector!.filePath).existsSync(), isTrue);
      expect((await b.entries()).map((e) => e.id), [second.id]);
    });

    test('waits for a store lock another process holds', () async {
      final a = await open('app.a');
      final entry = await a.ensure(pair);
      final child = await Process.start(_dartExecutable(), [
        'test/support/hold_store_lock.dart',
        p.join(root.path, 'store.lock'),
      ]);
      addTearDown(child.kill);
      final output = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      await output.firstWhere((line) => line == 'locked');

      var released = false;
      final release = a.release(entry.id).then((_) => released = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(released, isFalse);
      expect(File(entry.model.filePath).existsSync(), isTrue);

      child.stdin.writeln('done');
      await child.stdin.flush();
      await release;
      expect(await child.exitCode, 0);
      expect(File(entry.model.filePath).existsSync(), isFalse);
    });
  });

  group('download manager contract', () {
    test('ensureModel records a single-file entry', () async {
      final store = await open('app.a');
      final model = single('/model.gguf');

      final file = await store.ensureModel(model.source);

      expect(await File(file.filePath).readAsBytes(), modelBytes);
      expect((await store.entries()).single.id, ModelStore.entryIdFor(model));
      expect(await store.get(model.source.cacheKey), isNotNull);
      expect((await store.list()).single.cacheKey, model.source.cacheKey);
    });

    test(
      'ensureModel passes local files through without a reference',
      () async {
        final store = await open('app.a');
        final local = File(p.join(root.path, 'local.gguf'))
          ..writeAsBytesSync(modelBytes);

        final file = await store.ensureModel(ModelSource.path(local.path));

        expect(file.filePath, local.path);
        expect(await store.entries(), isEmpty);
      },
    );

    test('rejects another cache directory', () async {
      final store = await open('app.a');

      expect(
        () => store.list(cacheDirectory: root.path),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(
        () => store.prune(cacheDirectory: root.path),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('remove keeps a file another app references', () async {
      final a = await open('app.a');
      final b = await open('app.b');
      final model = single('/model.gguf');
      final file = await a.ensureModel(model.source);
      await b.ensureModel(model.source);

      await expectLater(
        a.remove(model.source.cacheKey),
        throwsA(
          isA<ModelCacheEntryInUseException>().having(
            (e) => e.entryDirectories,
            'entryDirectories',
            [p.dirname(file.filePath)],
          ),
        ),
      );
      expect(File(file.filePath).existsSync(), isTrue);
      expect((await a.entries()).single.references.map((r) => r.appId), [
        'app.b',
      ]);

      await b.remove(model.source.cacheKey);
      expect(File(file.filePath).existsSync(), isFalse);
    });

    test('clear removes only what no other app references', () async {
      final a = await open('app.a');
      final b = await open('app.b');
      await a.ensure(pair);
      final shared = await a.ensure(single('/other.gguf'));
      await b.ensure(single('/other.gguf'));

      await expectLater(
        a.clear(),
        throwsA(
          isA<ModelCacheEntryInUseException>().having(
            (e) => e.entryDirectories,
            'entryDirectories',
            [p.dirname(shared.model.filePath)],
          ),
        ),
      );

      expect(await storeFileNames(), ['other.gguf']);
      expect((await b.entries()).single.id, shared.id);
    });

    test('prune deletes only unreferenced files, oldest first', () async {
      final a = await open('app.a');
      final referenced = await a.ensure(single('/model.gguf'));
      final unreferenced = DefaultModelDownloadManager(
        defaultCacheDirectory: p.join(root.path, 'files'),
      );
      await unreferenced.ensureModel(single('/other.gguf').source);
      await unreferenced.ensureModel(single('/mmproj.gguf').source);
      await age(referenced.model);
      await age((await a.get(single('/other.gguf').source.cacheKey))!);

      final byAge = await a.prune(maxAge: const Duration(days: 1));

      expect(byAge.map((e) => e.fileName), ['other.gguf']);
      expect(await storeFileNames(), ['mmproj.gguf', 'model.gguf']);

      final bySize = await a.prune(maxBytes: 0);

      expect(bySize.map((e) => e.fileName), ['mmproj.gguf']);
      expect(await storeFileNames(), ['model.gguf']);
    });

    test('prune deletes leftover entries without references', () async {
      final a = await open('app.a');
      final entry = await a.ensure(pair);
      File(p.join(root.path, 'entries', entry.id, 'refs')).parent
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.dirname(file.path).endsWith('refs'))
          .forEach((file) => file.deleteSync());

      await a.prune();

      expect(
        Directory(p.join(root.path, 'entries', entry.id)).existsSync(),
        isFalse,
      );
      expect(await storeFileNames(), ['mmproj.gguf', 'model.gguf']);
    });

    test('an unreadable referenced entry protects every file', () async {
      final a = await open('app.a');
      await a.ensure(single('/other.gguf'));
      final entry = await a.ensure(single('/model.gguf'));
      final foreign = Directory(p.join(root.path, 'entries', 'foreign'));
      File(p.join(foreign.path, 'refs', 'x.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      File(p.join(foreign.path, 'entry.json')).writeAsStringSync('{"v":9}');

      expect(await a.prune(maxBytes: 0), isEmpty);
      await a.release(entry.id);
      expect(await storeFileNames(), ['model.gguf', 'other.gguf']);
      await expectLater(
        a.clear(),
        throwsA(isA<ModelCacheEntryInUseException>()),
      );
      expect(await storeFileNames(), ['model.gguf', 'other.gguf']);
    });
  });

  test('entry ids stay stable across store versions', () {
    // Every app sharing a store derives the same id; changing it orphans
    // existing entries.
    final model = LlamaModel(
      ModelSource.parse('hf://owner/repo/model.gguf'),
      projector: ModelSource.parse('hf://owner/repo/mmproj.gguf'),
    );

    expect(
      ModelStore.entryIdFor(model),
      '292ebbecf6ab9efd5fa017606e35fd223d39fdce0fa1c489c9613884f8944820',
    );
  });

  group('open', () {
    test('rejects a blank app id', () async {
      await expectLater(
        ModelStore.open(directory: root.path, appId: ' '),
        throwsA(isA<LlamaArgumentException>()),
      );
    });

    test('rejects a directory it cannot write', () async {
      final file = File(p.join(root.path, 'not-a-directory'))
        ..writeAsStringSync('');

      await expectLater(
        ModelStore.open(directory: p.join(file.path, 'store'), appId: 'a'),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });
  });
}

/// The `dart` executable of the SDK running these tests.
String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    return p.join(flutterRoot, 'bin', Platform.isWindows ? 'dart.bat' : 'dart');
  }
  return 'dart';
}
