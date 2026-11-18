import 'local_model_scanner.dart';

/// Web stub returning an empty scan result because browser storage is origin
/// scoped rather than directory backed.
LocalModelScanner createLocalModelScanner({
  List<String> defaultRoots = const <String>[],
}) => _StubLocalModelScanner(defaultRoots);

/// Returns no filesystem roots on Web.
List<String> defaultDesktopModelRoots() => const <String>[];

class _StubLocalModelScanner implements LocalModelScanner {
  const _StubLocalModelScanner(this.defaultRoots);

  @override
  final List<String> defaultRoots;

  @override
  Future<LocalModelScanResult> scan({
    List<String> extraDirectories = const <String>[],
  }) async => const LocalModelScanResult();
}
