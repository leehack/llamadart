@TestOn('vm')
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_extraction_marker.dart';

void main() {
  late Directory cacheDir;
  late Directory extractedDir;
  late File archive;
  const archiveBytes = [1, 2, 3, 4];
  final archiveSha256 = sha256.convert(archiveBytes).toString();

  Future<bool> matches() => nativeExtractionMatchesArchive(
    extractedDir: extractedDir,
    archive: archive,
  );

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('extraction_marker_');
    extractedDir = Directory(path.join(cacheDir.path, 'extracted'));
    File(path.join(extractedDir.path, 'libllamadart.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync('library');
    File(path.join(extractedDir.path, 'lib', 'libggml.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ggml');
    archive = File(path.join(cacheDir.path, 'bundle.tar.gz'))
      ..writeAsBytesSync(archiveBytes);
    await writeNativeExtractionMarker(
      extractedDir: extractedDir,
      archive: archive,
      archiveSha256: archiveSha256,
    );
  });

  tearDown(() => cacheDir.delete(recursive: true));

  test('the marker sits beside extracted/', () {
    expect(
      nativeExtractionMarkerFile(extractedDir).path,
      path.join(cacheDir.path, 'extracted.json'),
    );
    expect(nativeExtractionMarkerFile(extractedDir).existsSync(), isTrue);
  });

  test('an untouched extraction matches its archive', () async {
    expect(await matches(), isTrue);
  });

  test('a library replaced by a stub of another size does not match', () async {
    File(
      path.join(extractedDir.path, 'libllamadart.so'),
    ).writeAsStringSync('fake-libllamadart.so');
    expect(await matches(), isFalse);
  });

  test('an added or removed file does not match', () async {
    final extra = File(path.join(extractedDir.path, 'libggml-cuda.so'))
      ..writeAsStringSync('stub');
    expect(await matches(), isFalse);
    extra.deleteSync();
    expect(await matches(), isTrue);
    File(path.join(extractedDir.path, 'lib', 'libggml.so')).deleteSync();
    expect(await matches(), isFalse);
  });

  test('an added link does not match', () async {
    Link(
      path.join(extractedDir.path, 'libggml-cuda.so'),
    ).createSync(path.join(extractedDir.path, 'libllamadart.so'));
    expect(await matches(), isFalse);
  }, testOn: '!windows');

  test('another archive does not match', () async {
    archive.writeAsBytesSync([4, 3, 2, 1]);
    archive.setLastModifiedSync(DateTime(2001));
    expect(await matches(), isFalse);
  });

  test(
    'a resized archive does not match at the same modification time',
    () async {
      final modified = archive.lastModifiedSync();
      archive.writeAsBytesSync([...archiveBytes, 5]);
      archive.setLastModifiedSync(modified);
      expect(await matches(), isFalse);
    },
  );

  test('the same archive with a new modification time matches', () async {
    archive.setLastModifiedSync(DateTime(2001));
    expect(await matches(), isTrue);
  });

  test('a missing archive, marker or extraction does not match', () async {
    archive.renameSync('${archive.path}.moved');
    expect(await matches(), isFalse);
    File('${archive.path}.moved').renameSync(archive.path);
    expect(await matches(), isTrue);

    nativeExtractionMarkerFile(extractedDir).deleteSync();
    expect(await matches(), isFalse);
  });

  test('a malformed marker does not match', () async {
    for (final body in [
      '',
      '{"archive":',
      '[]',
      '{"archive":{"sha256":"$archiveSha256"},"files":{}}',
      '{"files":{}}',
    ]) {
      nativeExtractionMarkerFile(extractedDir).writeAsStringSync(body);
      expect(await matches(), isFalse, reason: body);
    }
  });

  test('an empty extraction matches only an empty record', () async {
    extractedDir.deleteSync(recursive: true);
    expect(await matches(), isFalse);
    extractedDir.createSync();
    await writeNativeExtractionMarker(
      extractedDir: extractedDir,
      archive: archive,
      archiveSha256: archiveSha256,
    );
    expect(await matches(), isTrue);
  });
}
