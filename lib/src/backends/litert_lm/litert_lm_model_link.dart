import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/exceptions.dart';
import '../../core/models/model_format.dart';

/// A `.litertlm` symbolic link that hands the LiteRT-LM runtime a bundle named
/// without that extension.
///
/// The runtime picks a bundle's format from a path's extension, matched case
/// sensitively, and opens the path lazily at engine creation. The link lives
/// in its own directory made by [Directory.createTemp], which is private to the
/// current user (mode 0700 on POSIX), so no other user can plant, swap or
/// block it before the runtime opens it. [dispose] deletes that directory.
///
/// The runtime names weight and program caches after the path's base name and
/// deletes same-named caches it finds stale, so the link name keeps the
/// bundle's own name plus a digest of its absolute path: reloading one file
/// reuses its caches, and two files with the same name do not evict each
/// other's.
class LiteRtLmModelLink {
  LiteRtLmModelLink._(this._directory, this.path);

  final Directory _directory;

  /// The `.litertlm` path to hand the runtime.
  final String path;

  /// Links the bundle at [modelPath] under a new private directory in
  /// [parent] (default: the system temp directory), or returns null when
  /// [modelPath] already ends in `.litertlm`.
  ///
  /// Throws [LlamaUnsupportedException] when the platform cannot create the
  /// link.
  static Future<LiteRtLmModelLink?> create(
    String modelPath, {
    Directory? parent,
  }) async {
    if (modelPath.endsWith(ModelFormat.liteRtLm.extension)) return null;

    Directory? directory;
    try {
      directory = await (parent ?? Directory.systemTemp).createTemp(
        'llamadart_litert_lm_link_',
      );
      final target = File(modelPath).absolute.path;
      final link = await Link(
        '${directory.path}${Platform.pathSeparator}${_linkName(target)}',
      ).create(target);
      return LiteRtLmModelLink._(directory, link.path);
    } on FileSystemException catch (error) {
      _deleteQuietly(directory);
      throw LlamaUnsupportedException(
        'LiteRT-LM needs a .litertlm file name, and this platform could not '
        'link one to a model file named without it '
        '(${error.osError?.message ?? error.message}). Rename the file to end '
        'in .litertlm, or pass a ModelSource fileName that does.',
      );
    }
  }

  static String _linkName(String target) {
    var name = target
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.length > 100) name = name.substring(0, 100);
    final digest = sha256.convert(utf8.encode(target)).toString();
    return '$name-${digest.substring(0, 12)}${ModelFormat.liteRtLm.extension}';
  }

  /// Deletes the link and its directory, never the linked bundle.
  void dispose() => _deleteQuietly(_directory);

  static void _deleteQuietly(Directory? directory) {
    try {
      directory?.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover private temp directory holds only a symbolic link.
    }
  }
}
