import 'dart:io';
import 'dart:typed_data';

Future<String?> createTempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  return dir.path;
}

Future<void> deleteDirIfExists(String? path) async {
  if (path == null) {
    return;
  }
  final dir = Directory(path);
  if (dir.existsSync()) {
    await dir.delete(recursive: true);
  }
}

Future<void> writeTextFile(String path, String content) async {
  final file = File(path);
  await file.create(recursive: true);
  await file.writeAsString(content);
}

Uint8List readBytesSync(String path) => File(path).readAsBytesSync();

bool fileExistsSync(String path) => File(path).existsSync();
