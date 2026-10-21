@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/platform/io/projector_file_reader_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llamadart_projector_');
    path = p.join(directory.path, 'mmproj.gguf');
    await File(path).writeAsBytes(<int>[0, 1, 2, 3, 4, 5]);
  });

  tearDown(() => directory.delete(recursive: true));

  test('reads the requested range', () async {
    expect(await readProjectorFileRange(path, 2, 3), <int>[2, 3, 4]);
  });

  test('returns fewer bytes at the end of the file', () async {
    expect(await readProjectorFileRange(path, 4, 10), <int>[4, 5]);
  });

  test('fails for a missing file', () async {
    await expectLater(
      readProjectorFileRange(p.join(directory.path, 'missing.gguf'), 0, 4),
      throwsA(isA<FileSystemException>()),
    );
  });
}
