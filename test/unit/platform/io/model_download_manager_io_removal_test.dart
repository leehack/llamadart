@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/core/models/model_source.dart';
import 'package:llamadart/src/platform/io/model_download_manager_io.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../support/dart_script_snapshot.dart';

void main() {
  late String childSnapshot;
  late Directory root;
  late HttpServer server;
  late DefaultModelDownloadManager manager;

  setUpAll(() async {
    childSnapshot = await compileDartScript(
      'test/support/model_cache_clear_child.dart',
    );
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('llamadart_cache_removal_');
    addTearDown(() => root.delete(recursive: true));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentLength = 1024;
      request.response.add(List<int>.filled(1024, 7));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
  });

  Future<void> populate(int count) async {
    for (var i = 0; i < count; i += 1) {
      await manager.ensureModel(
        ModelSource.url(
          Uri.parse('http://127.0.0.1:${server.port}/model$i.gguf'),
          fileName: 'model$i.gguf',
        ),
      );
    }
  }

  test('clears in several processes and this one report no entry in use, '
      'since each takes the removal lock until it finishes deleting', () async {
    for (var round = 0; round < 3; round += 1) {
      await populate(60);
      final goDirectory = await Directory.systemTemp.createTemp(
        'llamadart_cache_removal_go_',
      );
      addTearDown(() => goDirectory.delete(recursive: true));
      final go = path.join(goDirectory.path, 'go');
      final children = <Process>[];
      final lines = <StreamIterator<String>>[];
      for (var i = 0; i < 3; i += 1) {
        final child = await Process.start(Platform.resolvedExecutable, <String>[
          childSnapshot,
          root.path,
          go,
        ]);
        addTearDown(child.kill);
        children.add(child);
        lines.add(
          StreamIterator(
            child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          ),
        );
      }
      Future<Map<String, Object?>> nextEvent(
        StreamIterator<String> lines,
      ) async {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 60)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, Object?>;
      }

      for (final childLines in lines) {
        expect((await nextEvent(childLines))['event'], 'ready');
      }
      File(go).writeAsStringSync('go');

      await manager.clear();
      for (final childLines in lines) {
        final done = await nextEvent(childLines);
        expect(done['errors'], isEmpty);
        expect(done['inUse'], 0);
      }
      for (final child in children) {
        await child.exitCode;
      }
      expect(await manager.list(), isEmpty);
    }
  });

  test('clear removes a stray .removal directory instead of reporting it in '
      'use', () async {
    await populate(1);
    Directory(path.join(root.path, '.removal')).createSync();

    await manager.clear().timeout(const Duration(seconds: 10));

    expect(
      root.listSync().map((entity) => path.basename(entity.path)),
      <String>['.locks'],
    );
  });
}
