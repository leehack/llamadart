import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Download URL that replaces the Tetris-tuned head, from
/// `--dart-define=LAYA_TUNED_HEAD_URL=<url>`.
const String tunedHeadUrlDefine = String.fromEnvironment('LAYA_TUNED_HEAD_URL');

/// The app's model folder: downloads are cached here, and a Tetris-tuned head
/// saved here replaces the published one.
class ModelStore {
  /// Creates a store rooted at [directory].
  ModelStore(this.directory, {this.tunedHeadUrl = tunedHeadUrlDefine})
    : downloads = DefaultModelDownloadManager.appPrivate(
        cacheDirectory: directory,
      );

  /// Opens `laya/` in the app's cache directory, which iOS leaves out of
  /// backups, or on Android in its external files directory, where
  /// `adb push` can reach it.
  static Future<ModelStore> open() async {
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final base = external ?? await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/laya');
    await dir.create(recursive: true);
    return ModelStore(dir.path);
  }

  /// Absolute path of the folder.
  final String directory;

  /// Download manager caching into [directory].
  final ModelDownloadManager downloads;

  /// Download URL for the tuned head, or empty for the file at
  /// [tunedHeadPath] or the published head.
  final String tunedHeadUrl;

  /// A Tetris-tuned head saved here replaces the published one, unless
  /// [tunedHeadUrl] is set.
  String get tunedHeadPath =>
      '$directory${Platform.pathSeparator}$tunedHeadFile';

  /// The tuned head: [tunedHeadUrl] when set, else the file at
  /// [tunedHeadPath] when present, else [publishedTunedHead].
  ModelSource tunedHead() {
    if (tunedHeadUrl.isNotEmpty) {
      return ModelSource.url(Uri.parse(tunedHeadUrl), fileName: tunedHeadFile);
    }
    return File(tunedHeadPath).existsSync()
        ? ModelSource.path(tunedHeadPath)
        : publishedTunedHead;
  }

  /// How to recover when the tuned head from [source] fails to load. On iOS,
  /// where [directory] is inside the app sandbox, it does not suggest saving
  /// a file there.
  String tunedHeadHelp(ModelSource source) => switch (source.kind) {
    ModelSourceKind.path =>
      'Replace $tunedHeadPath, or delete it to use the published head, then '
          'tap Reload models.',
    ModelSourceKind.http =>
      'Tap Reload models to try again, or rebuild with a different '
          'LAYA_TUNED_HEAD_URL.',
    ModelSourceKind.huggingFace =>
      'Tap Reload models to try again'
          '${Platform.isIOS ? '' : ', or save a tuned head as $tunedHeadPath'}.',
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
