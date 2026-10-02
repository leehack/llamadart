@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_model_link.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String links;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart_link_');
    links = '${tempDir.path}/links';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('passes a .litertlm path through unchanged', () async {
    final path = '${tempDir.path}/Model.LITERTLM';

    expect(await liteRtLmRuntimeModelPath(path, linkDirectory: links), path);
    expect(Directory(links).existsSync(), isFalse);
  });

  test('links a bundle named without .litertlm and reuses the link', () async {
    final model = File('${tempDir.path}/download');
    await model.writeAsString('LITERTLM');

    final first = await liteRtLmRuntimeModelPath(
      model.path,
      linkDirectory: links,
    );
    final second = await liteRtLmRuntimeModelPath(
      model.path,
      linkDirectory: links,
    );

    expect(first, endsWith('.litertlm'));
    expect(first, startsWith(links));
    expect(second, first);
    expect(await Link(first).target(), model.absolute.path);
    expect(await File(first).readAsString(), 'LITERTLM');
  }, testOn: '!windows');

  test('repoints a stale link', () async {
    final model = File('${tempDir.path}/download');
    await model.writeAsString('LITERTLM');
    final path = await liteRtLmRuntimeModelPath(
      model.path,
      linkDirectory: links,
    );
    await Link(path).update('${tempDir.path}/other');

    expect(
      await liteRtLmRuntimeModelPath(model.path, linkDirectory: links),
      path,
    );
    expect(await Link(path).target(), model.absolute.path);
  }, testOn: '!windows');

  test('reports a link it cannot create as unsupported', () async {
    final model = File('${tempDir.path}/download');
    await model.writeAsString('LITERTLM');
    final blocker = File(links);
    await blocker.writeAsString('not a directory');

    await expectLater(
      liteRtLmRuntimeModelPath(model.path, linkDirectory: links),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('.litertlm'), isNot(contains(tempDir.path))),
        ),
      ),
    );
  });
}
