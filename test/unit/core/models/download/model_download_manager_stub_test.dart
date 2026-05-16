@TestOn('browser')
library;

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/download/model_download_manager_stub.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:test/test.dart';

void main() {
  group('DefaultModelDownloadManager stub placeholder', () {
    test('throws unsupported exception for ensureModel', () async {
      const manager = DefaultModelDownloadManager();

      await expectLater(
        manager.ensureModel(ModelSource.path('/models/model.gguf')),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });
  });
}
