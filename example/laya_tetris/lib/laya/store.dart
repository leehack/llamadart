import 'package:llamadart/llamadart.dart';

import '../host.dart';
import 'models.dart';

/// Download URL that replaces the Tetris-tuned head, from
/// `--dart-define=LAYA_TUNED_HEAD_URL=<url>`.
const String tunedHeadUrlDefine = String.fromEnvironment('LAYA_TUNED_HEAD_URL');

/// The app's model folder: downloads are cached here, and a Tetris-tuned head
/// saved here replaces the published one.
class ModelStore {
  /// Creates a store rooted at [directory], or without a folder when it is
  /// null.
  ModelStore(this.directory, {this.tunedHeadUrl = tunedHeadUrlDefine})
    : downloads = directory == null
          ? null
          : DefaultModelDownloadManager.appPrivate(cacheDirectory: directory);

  /// Opens the folder from [openModelDirectory]; in a browser, a store
  /// without one.
  static Future<ModelStore> open() async =>
      ModelStore(await openModelDirectory());

  /// Absolute path of the folder, or null in a browser.
  final String? directory;

  /// Download manager caching into [directory], or null without one.
  final ModelDownloadManager? downloads;

  /// Download URL for the tuned head, or empty for the file at
  /// [tunedHeadPath] or the published head.
  final String tunedHeadUrl;

  /// A Tetris-tuned head saved here replaces the published one, unless
  /// [tunedHeadUrl] is set. Null without a [directory].
  String? get tunedHeadPath {
    final dir = directory;
    return dir == null ? null : joinPath(dir, tunedHeadFile);
  }

  /// The tuned head: [tunedHeadUrl] when set, else the file at
  /// [tunedHeadPath] when present, else [publishedTunedHead].
  ModelSource tunedHead() {
    if (tunedHeadUrl.isNotEmpty) {
      return ModelSource.url(Uri.parse(tunedHeadUrl), fileName: tunedHeadFile);
    }
    final path = tunedHeadPath;
    return path != null && fileExists(path)
        ? ModelSource.path(path)
        : publishedTunedHead;
  }

  /// How to recover when the tuned head from [source] fails to load. On iOS,
  /// where [directory] is inside the app sandbox, and in a browser, it does
  /// not suggest saving a file there.
  String tunedHeadHelp(ModelSource source) => switch (source.kind) {
    ModelSourceKind.path =>
      'Replace $tunedHeadPath, or delete it to use the published head, then '
          'tap Reload models.',
    ModelSourceKind.http =>
      'Tap Reload models to try again, or rebuild with a different '
          'LAYA_TUNED_HEAD_URL.',
    ModelSourceKind.huggingFace =>
      'Tap Reload models to try again'
          '${isIOS || tunedHeadPath == null ? '' : ', or save a tuned head as $tunedHeadPath'}.',
  };

  /// The published [backbone] and base head, the tuned head from
  /// [tunedHead], and the runtime settings.
  LayaSetup setup(
    LayaBackbone backbone, {
    required GpuBackend backend,
    required int threads,
  }) => LayaSetup(
    backbone: layaSource(backbone.fileName),
    head: layaSource(baseHeadFile),
    tunedHead: tunedHead(),
    backend: backend,
    threads: threads,
  );
}
