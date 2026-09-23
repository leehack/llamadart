import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Download URL for the Tetris-tuned head, from
/// `--dart-define=LAYA_TUNED_HEAD_URL=<url>`.
const String tunedHeadUrlDefine = String.fromEnvironment('LAYA_TUNED_HEAD_URL');

/// The app's model folder: downloads are cached here, and the Tetris-tuned
/// head is read from here.
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

  /// Download URL for the tuned head, or empty to look in [directory].
  final String tunedHeadUrl;

  /// Where the app looks for the Tetris-tuned head.
  String get tunedHeadPath =>
      '$directory${Platform.pathSeparator}$tunedHeadFile';

  /// The tuned head: [tunedHeadUrl] when set, else the file at
  /// [tunedHeadPath] when present, else null.
  ModelSource? tunedHead() {
    if (tunedHeadUrl.isNotEmpty) {
      return ModelSource.url(Uri.parse(tunedHeadUrl), fileName: tunedHeadFile);
    }
    return File(tunedHeadPath).existsSync()
        ? ModelSource.path(tunedHeadPath)
        : null;
  }

  /// Explains how to provide a missing tuned head. An iOS app's folder is
  /// in its sandbox, so there it has to be downloaded.
  String get tunedHeadHelp =>
      'Tetris-tuned head not found. Fine-tune the base head on the data from '
      'bin/make_dataset.dart, then '
      '${Platform.isIOS ? '' : 'save it as $tunedHeadPath and reload the models, or '}'
      'build with --dart-define=LAYA_TUNED_HEAD_URL=<url>.';

  /// The published [backbone] and base head, the tuned head when available,
  /// and the runtime settings.
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
