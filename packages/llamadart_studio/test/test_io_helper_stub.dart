import 'dart:typed_data';

Future<String?> createTempDir(String prefix) async => null;

Future<void> deleteDirIfExists(String? path) async {}

Future<void> writeTextFile(String path, String content) async {}

Uint8List readBytesSync(String path) => Uint8List(0);

bool fileExistsSync(String path) => false;
