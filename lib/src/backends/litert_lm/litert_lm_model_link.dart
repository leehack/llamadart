import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import '../../core/models/model_format.dart';

/// Creates [link] pointing at [target].
typedef LiteRtLmLinkCreator = Future<Link> Function(Link link, String target);

/// A `.litertlm` symbolic link that hands the LiteRT-LM runtime a bundle named
/// without that extension.
///
/// The runtime picks a bundle's format from a path's extension, matched case
/// sensitively, and opens the path lazily at engine creation. The link lives
/// in its own new directory, so no other user can plant, swap, list or block
/// it before the runtime opens it. On POSIX the directory comes from
/// `mkdtemp(3)`, which creates it atomically with mode 0700 whatever the
/// process umask, and the link is created only after `stat` confirms no group
/// or other permission bit is set. On Windows it comes from
/// [Directory.createTemp] and inherits the access control list of the
/// per-user temp directory. [dispose] deletes that directory.
///
/// The runtime names weight and program caches after the path's base name and
/// deletes same-named caches it finds stale, so the link name keeps the
/// bundle's own name plus a digest of its absolute path: two files with the
/// same name do not evict each other's caches. Without a configured cache
/// directory the runtime would write those caches next to the link, so the
/// caller passes [cacheDirectory] instead, which keeps them next to the
/// bundle where reloading the same file reuses them.
class LiteRtLmModelLink {
  LiteRtLmModelLink._(this._directory, this.path, this.cacheDirectory);

  final Directory _directory;

  /// The `.litertlm` path to hand the runtime.
  final String path;

  /// The directory of the linked bundle, where the runtime should keep its
  /// caches when none is configured.
  final String cacheDirectory;

  /// Links the bundle at [modelPath] under a new private directory in
  /// [parent] (default: the system temp directory), or returns null when
  /// [modelPath] already ends in `.litertlm`.
  ///
  /// Throws [LlamaModelException] when [parent] does not allow creating the
  /// private directory, and [LlamaUnsupportedException] when the platform
  /// cannot create the link. [createLink] replaces [Link.create] in tests.
  static Future<LiteRtLmModelLink?> create(
    String modelPath, {
    Directory? parent,
    LiteRtLmLinkCreator? createLink,
  }) async {
    if (modelPath.endsWith(ModelFormat.liteRtLm.extension)) return null;

    final Directory directory;
    try {
      directory = await _createPrivateDirectory(parent ?? Directory.systemTemp);
    } on FileSystemException catch (error) {
      throw LlamaModelException(
        'Could not create a private directory for the .litertlm link that '
        'LiteRT-LM needs for a model file named without that extension '
        '(${error.osError?.message ?? error.message}). Check that the '
        'temporary directory is writable, or rename the file to end in '
        '.litertlm.',
      );
    }

    final target = File(modelPath).absolute;
    try {
      final link = await (createLink ?? _createLink)(
        Link(
          '${directory.path}${Platform.pathSeparator}'
          '${_linkName(target.path)}',
        ),
        target.path,
      );
      return LiteRtLmModelLink._(directory, link.path, target.parent.path);
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

  static const String _directoryPrefix = 'llamadart_litert_lm_link_';

  static Future<Directory> _createPrivateDirectory(Directory parent) async {
    if (Platform.isWindows) return parent.createTemp(_directoryPrefix);

    final mkdtemp = _mkdtemp;
    if (mkdtemp == null) {
      throw LlamaUnsupportedException(
        'LiteRT-LM needs a .litertlm file name, and this platform has no '
        'mkdtemp to create a private directory for a link to a model file '
        'named without it. Rename the file to end in .litertlm.',
      );
    }
    final template = '${parent.path}/${_directoryPrefix}XXXXXX'.toNativeUtf8();
    final Directory directory;
    try {
      final created = mkdtemp(template);
      if (created == nullptr) {
        throw FileSystemException(
          'Cannot create a private directory',
          parent.path,
          _lastOsError(),
        );
      }
      directory = Directory(created.toDartString());
    } finally {
      malloc.free(template);
    }

    final mode = (await directory.stat()).mode;
    if (mode & 0x3f != 0 || mode & 0x1c0 != 0x1c0) {
      _deleteQuietly(directory);
      throw LlamaModelException(
        'The private directory for the .litertlm link that LiteRT-LM needs '
        'was created with mode ${(mode & 0x1ff).toRadixString(8)} instead of '
        '700, so other users could reach it. Rename the model file to end in '
        '.litertlm.',
      );
    }
    return directory;
  }

  static Future<Link> _createLink(Link link, String target) =>
      link.create(target);

  static String _linkName(String target) {
    var name = target
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // Keeps the name under the 255-byte file name limit.
    if (name.length > 100) name = name.substring(0, 100);
    final digest = sha256.convert(utf8.encode(target)).toString();
    return '$name-${digest.substring(0, 12)}${ModelFormat.liteRtLm.extension}';
  }

  /// Deletes the link and its directory, never the linked bundle.
  void dispose() => _deleteQuietly(_directory);

  static void _deleteQuietly(Directory directory) {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // The private directory holds only the link; the runtime keeps its
      // caches in [cacheDirectory].
    }
  }
}

final Pointer<Utf8> Function(Pointer<Utf8>)? _mkdtemp = () {
  final libc = DynamicLibrary.process();
  if (!libc.providesSymbol('mkdtemp')) return null;
  return libc.lookupFunction<
    Pointer<Utf8> Function(Pointer<Utf8>),
    Pointer<Utf8> Function(Pointer<Utf8>)
  >('mkdtemp');
}();

OSError? _lastOsError() {
  final libc = DynamicLibrary.process();
  for (final symbol in ['__errno_location', '__error', '__errno']) {
    if (!libc.providesSymbol(symbol)) continue;
    final code = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          symbol,
        )()
        .value;
    final message = libc
        .lookupFunction<
          Pointer<Utf8> Function(Int32),
          Pointer<Utf8> Function(int)
        >('strerror')(code)
        .toDartString();
    return OSError(message, code);
  }
  return null;
}
