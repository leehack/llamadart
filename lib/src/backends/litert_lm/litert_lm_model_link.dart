import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/exceptions.dart';
import '../../core/models/model_format.dart';

/// The path to hand the LiteRT-LM runtime for the bundle at [path].
///
/// The runtime picks a bundle's format from a path's extension and rejects a
/// path without a known one, so a bundle named without `.litertlm`, such as a
/// cached `download?id=42`, gets a `.litertlm` symbolic link under
/// [linkDirectory] (default: a `llamadart_litert_lm_links` system temp
/// directory). The link name is derived from the bundle's absolute path, so
/// reloading the same file reuses it.
///
/// Throws [LlamaUnsupportedException] when the platform cannot create the
/// link.
Future<String> liteRtLmRuntimeModelPath(
  String path, {
  String? linkDirectory,
}) async {
  if (ModelFormat.fromPath(path) == ModelFormat.liteRtLm) return path;

  final target = File(path).absolute.path;
  final directory = Directory(
    linkDirectory ?? '${Directory.systemTemp.path}/llamadart_litert_lm_links',
  );
  final digest = sha256.convert(utf8.encode(target)).toString();
  final link = Link(
    '${directory.path}${Platform.pathSeparator}'
    '${digest.substring(0, 32)}${ModelFormat.liteRtLm.extension}',
  );
  try {
    await directory.create(recursive: true);
    if (await link.exists()) {
      if (await link.target() == target) return link.path;
      await link.delete();
    }
    await link.create(target);
  } on FileSystemException catch (error) {
    if (await _linksTo(link, target)) return link.path;
    throw LlamaUnsupportedException(
      'LiteRT-LM needs a .litertlm file name, and this platform could not '
      'link one to a model file named without it (${error.osError?.message ?? error.message}). '
      'Rename the file to end in .litertlm, or pass a ModelSource fileName '
      'that does.',
    );
  }
  return link.path;
}

Future<bool> _linksTo(Link link, String target) async {
  try {
    return await link.target() == target;
  } on FileSystemException {
    return false;
  }
}
