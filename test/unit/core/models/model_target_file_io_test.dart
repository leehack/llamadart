@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/models/model_target_file.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llamadart_files_');
    file = File('${directory.path}/model.gguf')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => directory.delete(recursive: true));

  Future<List<String>> resolve(String sha256) => resolveModelSourceFiles(
    [ModelSource.path(file.path)],
    store: ModelFileStore(
      downloadManager: DefaultModelDownloadManager.appPrivate(
        cacheDirectory: '${directory.path}/cache',
      ),
    ),
    download: ModelLoadOptions(sha256: sha256),
    operation: 'Test loading',
  );

  test('a single local file is verified against the checksum', () async {
    await expectLater(
      resolve('0' * 64),
      throwsA(
        isA<LlamaModelException>().having(
          (error) => error.message,
          'message',
          contains('Checksum mismatch for local model file'),
        ),
      ),
    );
    expect(
      await resolve(
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
      ),
      [file.path],
    );
  });
}
