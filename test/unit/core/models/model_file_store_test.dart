import 'package:test/test.dart';

import 'package:llamadart/llamadart.dart';

void main() {
  test('a store defaults to the default resolver and download manager', () {
    final store = ModelFileStore();

    expect(store.resolver, isA<DefaultModelResolver>());
    expect(store.downloadManager, isA<DefaultModelDownloadManager>());
  });

  test('a store keeps the parts it is given', () {
    final resolver = _Resolver();
    final downloads = DefaultModelDownloadManager();

    final store = ModelFileStore(
      resolver: resolver,
      downloadManager: downloads,
    );

    expect(store.resolver, same(resolver));
    expect(store.downloadManager, same(downloads));
  });
}

final class _Resolver implements ModelResolver {
  @override
  Future<ModelLoadTarget> resolve(
    ModelSource source,
    ModelResolveRequest request,
  ) async => const LocalModelFile('/models/model.gguf');
}
