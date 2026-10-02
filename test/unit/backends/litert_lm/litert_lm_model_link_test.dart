@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:llamadart/src/backends/litert_lm/litert_lm_model_link.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory links;
  late File model;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart_link_');
    links = await Directory('${tempDir.path}/links').create();
    model = File('${tempDir.path}/download');
    await model.writeAsString('LITERTLM');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String nameOf(String path) => path.split(Platform.pathSeparator).last;

  test('does not link a path ending in lowercase .litertlm', () async {
    expect(
      await LiteRtLmModelLink.create(
        '${tempDir.path}/model.litertlm',
        parent: links,
      ),
      isNull,
    );
    expect(links.listSync(), isEmpty);
  });

  for (final name in ['download', 'MODEL.LITERTLM', 'model.gguf']) {
    test('links $name in a new private directory', () async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsString('LITERTLM');

      final link = (await LiteRtLmModelLink.create(file.path, parent: links))!;
      addTearDown(link.dispose);

      expect(nameOf(link.path), startsWith('$name-'));
      expect(link.path, endsWith('.litertlm'));
      expect(await Link(link.path).target(), file.absolute.path);
      expect(await File(link.path).readAsString(), 'LITERTLM');
      final directory = Directory(File(link.path).parent.path);
      expect(directory.parent.path, links.path);
      expect(directory.statSync().modeString(), 'rwx------');
    }, testOn: '!windows');
  }

  for (final mask in [0x0, 0x12]) {
    test(
      'creates a 0700 directory under umask ${mask.toRadixString(8)}',
      () async {
        final previous = _umask(mask) & 0x1ff;
        try {
          final link = (await LiteRtLmModelLink.create(
            model.path,
            parent: links,
          ))!;
          addTearDown(link.dispose);

          final directory = File(link.path).parent;
          expect(directory.statSync().modeString(), 'rwx------');
          expect(directory.listSync(), hasLength(1));
        } finally {
          _umask(previous);
        }
      },
      testOn: '!windows',
    );
  }

  test(
    'gives every load its own directory and disposes only the link',
    () async {
      final first = (await LiteRtLmModelLink.create(
        model.path,
        parent: links,
      ))!;
      final second = (await LiteRtLmModelLink.create(
        model.path,
        parent: links,
      ))!;

      expect(
        File(first.path).parent.path,
        isNot(File(second.path).parent.path),
      );
      expect(nameOf(first.path), nameOf(second.path));

      first.dispose();
      expect(Directory(File(first.path).parent.path).existsSync(), isFalse);
      expect(Link(second.path).existsSync(), isTrue);
      second.dispose();
      first.dispose();
      expect(links.listSync(), isEmpty);
      expect(model.readAsStringSync(), 'LITERTLM');
    },
    testOn: '!windows',
  );

  test('names links of same-named files apart', () async {
    final other = File('${tempDir.path}/other/download');
    await other.create(recursive: true);

    final a = (await LiteRtLmModelLink.create(model.path, parent: links))!;
    final b = (await LiteRtLmModelLink.create(other.path, parent: links))!;
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    expect(nameOf(a.path), startsWith('download-'));
    expect(nameOf(a.path), isNot(nameOf(b.path)));
  }, testOn: '!windows');

  test('never reuses a directory planted under the parent', () async {
    final planted = File('${tempDir.path}/attacker.gguf');
    await planted.writeAsString('GGUF');
    final first = (await LiteRtLmModelLink.create(model.path, parent: links))!;
    final plantedName = nameOf(first.path);
    first.dispose();
    for (var i = 0; i < 8; i++) {
      final dir = await Directory(
        '${links.path}/llamadart_litert_lm_link_planted$i',
      ).create();
      await Link('${dir.path}/$plantedName').create(planted.path);
    }

    final link = (await LiteRtLmModelLink.create(model.path, parent: links))!;
    addTearDown(link.dispose);

    expect(File(link.path).parent.path, isNot(contains('planted')));
    expect(await File(link.path).readAsString(), 'LITERTLM');
  }, testOn: '!windows');

  test('reports a parent it cannot write as a model error', () async {
    final blocker = File('${tempDir.path}/blocker');
    await blocker.writeAsString('not a directory');

    await expectLater(
      LiteRtLmModelLink.create(model.path, parent: Directory(blocker.path)),
      throwsA(
        isA<LlamaModelException>().having(
          (e) => e.message,
          'message',
          allOf(contains('writable'), isNot(contains(tempDir.path))),
        ),
      ),
    );
  });

  test('removes its directory when the link cannot be created', () async {
    await expectLater(
      LiteRtLmModelLink.create(
        model.path,
        parent: links,
        createLink: (link, target) =>
            throw FileSystemException('no links', link.path),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('could not link'), isNot(contains(tempDir.path))),
        ),
      ),
    );
    expect(links.listSync(), isEmpty);
  });

  test('links a relative path to its absolute target', () async {
    final relative = p.relative(model.path);
    expect(p.isAbsolute(relative), isFalse);

    final link = (await LiteRtLmModelLink.create(relative, parent: links))!;
    addTearDown(link.dispose);

    final target = await Link(link.path).target();
    expect(p.isAbsolute(target), isTrue);
    expect(p.equals(target, model.absolute.path), isTrue);
    expect(p.equals(link.cacheDirectory, tempDir.absolute.path), isTrue);
  }, testOn: '!windows');

  test('names the link from a sanitized bundle name', () async {
    final file = File('${tempDir.path}/my model \u00fc?.bin');
    await file.writeAsString('LITERTLM');

    final link = (await LiteRtLmModelLink.create(file.path, parent: links))!;
    addTearDown(link.dispose);

    expect(
      nameOf(link.path),
      matches(r'^my_model___\.bin-[0-9a-f]{12}\.litertlm$'),
    );
  }, testOn: '!windows');

  test('truncates a long bundle name under the file name limit', () async {
    final name = 'm' * 240;
    final file = File('${tempDir.path}/$name');
    await file.writeAsString('LITERTLM');

    final link = (await LiteRtLmModelLink.create(file.path, parent: links))!;
    addTearDown(link.dispose);

    expect(
      nameOf(link.path),
      '${'m' * 100}-${nameOf(link.path).substring(101)}',
    );
    expect(nameOf(link.path).length, 100 + 1 + 12 + '.litertlm'.length);
    expect(await File(link.path).readAsString(), 'LITERTLM');
  }, testOn: '!windows');
}

final int Function(int) _umask = DynamicLibrary.process()
    .lookupFunction<Uint32 Function(Uint32), int Function(int)>('umask');
