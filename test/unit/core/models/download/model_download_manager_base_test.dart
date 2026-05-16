import 'package:llamadart/src/core/models/download/model_download_manager_base.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:test/test.dart';

void main() {
  group('ThrowingModelDownloadManager', () {
    test('base placeholder throws for all operations', () async {
      const manager = _TestDownloadManager();
      final source = ModelSource.path('/models/model.gguf');

      await expectLater(manager.ensureModel(source), throwsUnsupportedError);
      await expectLater(manager.list(), throwsUnsupportedError);
      await expectLater(manager.get('abc123'), throwsUnsupportedError);
      await expectLater(manager.remove('abc123'), throwsUnsupportedError);
      await expectLater(manager.clear(), throwsUnsupportedError);
      await expectLater(manager.prune(), throwsUnsupportedError);
    });
  });
}

class _TestDownloadManager extends ThrowingModelDownloadManager {
  const _TestDownloadManager();

  @override
  Object unsupported(String operation) => UnsupportedError(operation);
}
