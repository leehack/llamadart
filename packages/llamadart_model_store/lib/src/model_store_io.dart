import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'entry_id.dart';
import 'model_store_entry.dart';
import 'store_lock.dart';

const int _schemaVersion = 1;
const String _entryFileName = 'entry.json';
const String _referencesDirectoryName = 'refs';

/// A model library that every app able to open the same directory shares.
///
/// Files are downloaded, resumed, verified and locked per file by a
/// [DefaultModelDownloadManager] rooted at `<directory>/files`. On top of
/// that, the store keeps each [LlamaModel], model and projector together, as
/// one [ModelStoreEntry], and records which apps reference it under
/// `<directory>/entries`. An entry's files are deleted only when no app
/// references them, so one app cannot delete a model another app still uses.
///
/// Store metadata holds cache keys, app ids and timestamps only. Source
/// URLs, tokens and headers are never written to it; the file metadata
/// [DefaultModelDownloadManager] writes redacts URL secrets.
///
/// Use a store from one isolate per process: its lock excludes other
/// processes, and on POSIX not other isolates of the same process.
///
/// Downloads run in the foreground, as with [DefaultModelDownloadManager].
final class ModelStore implements ModelDownloadManager {
  ModelStore._(this.directory, this.appId)
    : _files = DefaultModelDownloadManager(
        defaultCacheDirectory: p.join(directory, 'files'),
      ),
      _entriesDirectory = p.join(directory, 'entries'),
      _lock = StoreLock(p.join(directory, 'store.lock'));

  /// Opens the store in [directory] for the app named [appId], creating the
  /// directory when needed.
  ///
  /// [directory] decides who shares the store: on desktop, a per-user
  /// directory such as one under
  /// [DefaultModelDownloadManager.defaultSharedCacheDirectory]; on Android, a
  /// directory the user granted every participating app; on iOS and macOS, a
  /// directory in an App Group container. [appId] names the app in the
  /// store's references, for example its bundle or application id. Every app
  /// can read the ids of the others.
  ///
  /// Throws [LlamaArgumentException] when [appId] is blank or contains a
  /// control character, and [LlamaUnsupportedException] when [directory]
  /// cannot be created, written or locked.
  static Future<ModelStore> open({
    required String directory,
    required String appId,
  }) async {
    if (appId.trim().isEmpty || appId.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw LlamaArgumentException(
        'ModelStore appId must be non-blank and free of control characters.',
        name: 'appId',
      );
    }
    final store = ModelStore._(p.normalize(p.absolute(directory)), appId);
    try {
      await Directory(store._entriesDirectory).create(recursive: true);
      await Directory(store._files.defaultCacheDirectory).create();
      await store._lock.run(() async {});
    } on FileSystemException catch (error) {
      throw LlamaUnsupportedException(
        'ModelStore needs a writable directory that supports file locks; '
        '${store.directory} is not one (${error.osError?.message ?? error.message}).',
      );
    }
    return store;
  }

  /// The store's root directory.
  final String directory;

  /// The app this store handle records references for.
  final String appId;

  final DefaultModelDownloadManager _files;
  final String _entriesDirectory;
  final StoreLock _lock;

  /// The identifier of the entry that holds [model]'s files.
  ///
  /// Derived from the files' [ModelSource.cacheKey]s, so it is the same in
  /// every app and reveals nothing about the sources.
  static String entryIdFor(LlamaModel model) => modelStoreEntryId(model);

  /// Ensures [model]'s files are in the store and records that this app
  /// references them.
  ///
  /// The reference is recorded before downloading, so no other app deletes
  /// the files while they download or after they are returned. When the call
  /// fails, the reference it recorded is dropped again; files and partial
  /// downloads stay for a later call to resume, or for [prune].
  ///
  /// [options] apply to every file, as in `LlamaEngine.load`: credentials are
  /// never sent to more than one origin, and [ModelLoadOptions.sha256] needs
  /// a model without a projector. [onProgress] reports the model's download,
  /// then the projector's.
  ///
  /// Throws [LlamaUnsupportedException] for a local [ModelSource.path] file,
  /// [ModelCachePolicy.noCache] or a [ModelLoadOptions.cacheDirectory]: the
  /// store holds remote files in its own directory.
  Future<ModelStoreEntry> ensure(
    LlamaModel model, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final sources = <ModelSource>[model.source, ?model.projector];
    _checkEnsureArguments(sources, options);
    final id = entryIdFor(model);
    final token = await _lock.run(
      () => _addReference(id, [for (final source in sources) source.cacheKey]),
    );
    try {
      final files = <ModelCacheEntry>[
        for (final source in sources)
          await _files.ensureModel(
            source,
            options: options,
            onProgress: onProgress,
          ),
      ];
      return ModelStoreEntry(
        id: id,
        model: files.first,
        projector: files.length > 1 ? files[1] : null,
        references: await _readReferences(id),
      );
    } catch (_) {
      await _lock.run(() => _dropReference(id, token: token));
      rethrow;
    }
  }

  /// The entries whose files are all in the store, most recently used first.
  Future<List<ModelStoreEntry>> entries() async {
    final result = <ModelStoreEntry>[];
    for (final record in await _readEntries()) {
      final cacheKeys = record.cacheKeys;
      if (cacheKeys == null) {
        continue;
      }
      final files = <ModelCacheEntry>[];
      for (final cacheKey in cacheKeys) {
        final file = await _files.get(cacheKey);
        if (file == null) {
          break;
        }
        files.add(file);
      }
      if (files.length != cacheKeys.length) {
        continue;
      }
      result.add(
        ModelStoreEntry(
          id: record.id,
          model: files.first,
          projector: files.length > 1 ? files[1] : null,
          references: record.references,
        ),
      );
    }
    result.sort((a, b) => _lastUsed(b).compareTo(_lastUsed(a)));
    return result;
  }

  /// Drops this app's reference to the entry [entryId] and, when no app
  /// references it any more, deletes the entry and every file of it that no
  /// other referenced entry holds.
  ///
  /// Throws [ModelCacheEntryInUseException] when a file could not be deleted
  /// because it is downloading elsewhere; the reference is dropped anyway and
  /// a later [prune] deletes the file.
  Future<void> release(String entryId) {
    return _lock.run(() async {
      await _dropReference(entryId);
      await _collect(<String>{entryId});
    });
  }

  /// Ensures [source] is in the store, recording this app's reference to it
  /// as an entry of its own, so the store works as an engine's download
  /// manager through `ModelFileStore(downloadManager: store)`.
  ///
  /// A local [ModelSource.path] file and a [ModelCachePolicy.noCache]
  /// download are passed to the store's file manager without a reference.
  /// Throws [LlamaUnsupportedException] for a
  /// [ModelLoadOptions.cacheDirectory].
  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    _rejectCacheDirectory(options.cacheDirectory);
    if (source.isLocal || options.cachePolicy == ModelCachePolicy.noCache) {
      return _files.ensureModel(
        source,
        options: options,
        onProgress: onProgress,
      );
    }
    final entry = await ensure(
      LlamaModel(source),
      options: options,
      onProgress: onProgress,
    );
    return entry.model;
  }

  /// Lists the store's files. Throws [LlamaUnsupportedException] for a
  /// [cacheDirectory].
  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) {
    _rejectCacheDirectory(cacheDirectory);
    return _files.list();
  }

  /// Gets the store's file for [cacheKey]. Throws
  /// [LlamaUnsupportedException] for a [cacheDirectory].
  @override
  Future<ModelCacheEntry?> get(String cacheKey, {String? cacheDirectory}) {
    _rejectCacheDirectory(cacheDirectory);
    return _files.get(cacheKey);
  }

  /// Drops this app's references to every entry holding the file for
  /// [cacheKey], then deletes the file unless another app still references
  /// it.
  ///
  /// Throws [ModelCacheEntryInUseException] naming the file's directory when
  /// it is kept because another app references it or because it is
  /// downloading elsewhere. Throws [LlamaUnsupportedException] for a
  /// [cacheDirectory].
  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) {
    _rejectCacheDirectory(cacheDirectory);
    return _lock.run(() async {
      final holders = <String>{
        for (final record in await _readEntries())
          if (record.cacheKeys?.contains(cacheKey) ?? false) record.id,
      };
      for (final id in holders) {
        await _dropReference(id);
      }
      await _collect(holders, orphans: <String>{cacheKey});
    });
  }

  /// Drops every reference this app holds, then deletes every file no app
  /// references.
  ///
  /// Throws [ModelCacheEntryInUseException] naming the directories of the
  /// files kept because other apps reference them or because they are
  /// downloading elsewhere. Throws [LlamaUnsupportedException] for a
  /// [cacheDirectory].
  @override
  Future<void> clear({String? cacheDirectory}) {
    _rejectCacheDirectory(cacheDirectory);
    return _lock.run(() async {
      final records = await _readEntries();
      for (final record in records) {
        await _dropReference(record.id);
      }
      await _collect(
        <String>{for (final record in records) record.id},
        orphans: <String>{
          for (final file in await _files.list()) file.cacheKey,
        },
      );
    });
  }

  /// Deletes files no app references: those last used more than [maxAge]
  /// ago, then the least recently used until the store holds at most
  /// [maxBytes]. Returns the deleted files.
  ///
  /// Never deletes a file an app references, so the store can stay above
  /// [maxBytes]; [release] references first. Also deletes leftover entries
  /// without references, and skips files downloading elsewhere. Throws
  /// [LlamaUnsupportedException] for a [cacheDirectory].
  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) {
    _rejectCacheDirectory(cacheDirectory);
    return _lock.run(() async {
      final records = await _readEntries();
      for (final record in records) {
        if (record.references.isEmpty) {
          await _deleteEntryDirectory(record.id);
        }
      }
      if (records.any((record) => record.protectsUnknownFiles)) {
        return const <ModelCacheEntry>[];
      }
      final referenced = <String>{
        for (final record in records)
          if (record.references.isNotEmpty) ...?record.cacheKeys,
      };
      final files = (await _files.list())
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      var total = 0;
      for (final file in files) {
        total += await _fileLength(file);
      }
      final now = DateTime.now().toUtc();
      final removed = <ModelCacheEntry>[];
      for (final file in files) {
        if (referenced.contains(file.cacheKey)) {
          continue;
        }
        final expired =
            maxAge != null && now.difference(file.updatedAt.toUtc()) > maxAge;
        final overBudget = maxBytes != null && total > maxBytes;
        if (!expired && !overBudget) {
          continue;
        }
        final length = await _fileLength(file);
        try {
          await _files.remove(file.cacheKey);
        } on ModelCacheEntryInUseException {
          continue;
        }
        removed.add(file);
        total -= length;
      }
      return removed;
    });
  }

  void _checkEnsureArguments(
    List<ModelSource> sources,
    ModelLoadOptions options,
  ) {
    _rejectCacheDirectory(options.cacheDirectory);
    if (options.cachePolicy == ModelCachePolicy.noCache) {
      throw LlamaUnsupportedException(
        'ModelStore keeps every file it downloads, so it does not support '
        'ModelCachePolicy.noCache. Use DefaultModelDownloadManager for '
        'transient downloads.',
      );
    }
    if (sources.any((source) => source.isLocal)) {
      throw LlamaUnsupportedException(
        'ModelStore holds downloaded files only; load a local ModelSource.path '
        'file directly.',
      );
    }
    if (sources.length > 1 && options.sha256 != null) {
      throw LlamaUnsupportedException(
        'ModelStore entry with a projector uses ${sources.length} files, so '
        'ModelLoadOptions.sha256 cannot apply to them. Leave it unset.',
      );
    }
    if (options.bearerToken != null || options.headers.isNotEmpty) {
      final origins = <String>{
        for (final source in sources)
          if (source.resolvedUri case final url?)
            '${url.scheme}://${url.host}:${url.port}',
      };
      if (origins.length > 1) {
        throw LlamaArgumentException(
          'ModelStore entry would send ModelLoadOptions.bearerToken or headers '
          'to more than one host (${origins.join(', ')}). Credentials are '
          'never forwarded across hosts: load these files from one host, or '
          'leave bearerToken and headers unset.',
          name: 'options',
        );
      }
    }
  }

  void _rejectCacheDirectory(String? cacheDirectory) {
    if (cacheDirectory != null) {
      throw LlamaUnsupportedException(
        'ModelStore keeps its files in its own directory, so it does not take '
        'a cacheDirectory.',
      );
    }
  }

  /// Records this app's reference to [id] and returns the token that lets
  /// the same call drop it again.
  Future<String> _addReference(String id, List<String> cacheKeys) async {
    final entryDirectory = p.join(_entriesDirectory, id);
    final entryFile = File(p.join(entryDirectory, _entryFileName));
    if (!await entryFile.exists()) {
      await Directory(entryDirectory).create(recursive: true);
      await _writeJsonAtomically(entryFile, <String, Object?>{
        'schema_version': _schemaVersion,
        'id': id,
        'cache_keys': cacheKeys,
      });
    }
    final token = _randomToken();
    await Directory(
      p.join(entryDirectory, _referencesDirectoryName),
    ).create(recursive: true);
    await _writeJsonAtomically(_referenceFile(id), <String, Object?>{
      'schema_version': _schemaVersion,
      'app_id': appId,
      'last_used_at': DateTime.now().toUtc().toIso8601String(),
      'token': token,
    });
    return token;
  }

  /// Drops this app's reference to [id]; with [token], only when no later
  /// call of this app has rewritten it since.
  Future<void> _dropReference(String id, {String? token}) async {
    final file = _referenceFile(id);
    if (token != null) {
      final json = await _readJson(file);
      if (json == null || json['token'] != token) {
        return;
      }
    }
    try {
      await file.delete();
    } on PathNotFoundException {
      // Already released.
    }
  }

  /// Deletes the entries among [candidates] that no app references, then the
  /// files of those entries, and the [orphans], that no remaining referenced
  /// entry holds. Throws [ModelCacheEntryInUseException] for the [orphans]
  /// kept because an entry references them and for files downloading
  /// elsewhere.
  Future<void> _collect(
    Set<String> candidates, {
    Set<String> orphans = const <String>{},
  }) async {
    final records = await _readEntries();
    final unreferenced = <String>{...orphans};
    final referenced = <String>{};
    for (final record in records) {
      if (record.references.isNotEmpty) {
        referenced.addAll(record.cacheKeys ?? const <String>[]);
      } else if (candidates.contains(record.id)) {
        unreferenced.addAll(record.cacheKeys ?? const <String>[]);
        await _deleteEntryDirectory(record.id);
      }
    }
    if (records.any((record) => record.protectsUnknownFiles)) {
      referenced.addAll(unreferenced);
    }
    final kept = <String>[];
    for (final cacheKey in orphans.intersection(referenced)) {
      final file = await _files.get(cacheKey);
      if (file != null) {
        kept.add(p.dirname(file.filePath));
      }
    }
    for (final cacheKey in unreferenced.difference(referenced)) {
      try {
        await _files.remove(cacheKey);
      } on ModelCacheEntryInUseException catch (error) {
        kept.addAll(error.entryDirectories);
      }
    }
    if (kept.isNotEmpty) {
      throw ModelCacheEntryInUseException(
        '${kept.length} model store '
        '${kept.length == 1 ? 'file is' : 'files are'} referenced by another '
        'app or downloading elsewhere and '
        '${kept.length == 1 ? 'was' : 'were'} not removed.',
        entryDirectories: kept,
      );
    }
  }

  Future<void> _deleteEntryDirectory(String id) async {
    try {
      await Directory(p.join(_entriesDirectory, id)).delete(recursive: true);
    } on PathNotFoundException {
      // Already deleted.
    }
  }

  Future<List<_EntryRecord>> _readEntries() async {
    final root = Directory(_entriesDirectory);
    if (!await root.exists()) {
      return const <_EntryRecord>[];
    }
    final records = <_EntryRecord>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final id = p.basename(entity.path);
      final json = await _readJson(File(p.join(entity.path, _entryFileName)));
      final cacheKeys = json?['cache_keys'];
      // Later schema versions keep `cache_keys`, so an older store version
      // still sees which files a newer app's entry protects.
      final readable =
          json?['id'] == id &&
          cacheKeys is List &&
          cacheKeys.isNotEmpty &&
          cacheKeys.every((key) => key is String);
      records.add(
        _EntryRecord(
          id: id,
          cacheKeys: readable ? cacheKeys.cast<String>() : null,
          references: await _readReferences(id),
        ),
      );
    }
    return records;
  }

  Future<List<ModelStoreReference>> _readReferences(String id) async {
    final directory = Directory(
      p.join(_entriesDirectory, id, _referencesDirectoryName),
    );
    final references = <ModelStoreReference>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || p.extension(entity.path) != '.json') {
          continue;
        }
        final json = await _readJson(entity);
        final referenceAppId = json?['app_id'];
        final lastUsedAt = DateTime.tryParse('${json?['last_used_at']}');
        if (referenceAppId is String && lastUsedAt != null) {
          references.add(
            ModelStoreReference(appId: referenceAppId, lastUsedAt: lastUsedAt),
          );
        } else {
          // A reference that cannot be read still keeps the files.
          references.add(
            ModelStoreReference(
              appId: p.basenameWithoutExtension(entity.path),
              lastUsedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            ),
          );
        }
      }
    } on PathNotFoundException {
      return references;
    }
    references.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return references;
  }

  File _referenceFile(String id) {
    final appKey = sha256.convert(utf8.encode(appId)).toString();
    return File(
      p.join(_entriesDirectory, id, _referencesDirectoryName, '$appKey.json'),
    );
  }

  static DateTime _lastUsed(ModelStoreEntry entry) {
    return entry.references.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : entry.references.first.lastUsedAt;
  }

  static Future<int> _fileLength(ModelCacheEntry file) async {
    try {
      return await File(file.filePath).length();
    } on FileSystemException {
      return 0;
    }
  }

  static Future<Map<String, Object?>?> _readJson(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _writeJsonAtomically(
    File file,
    Map<String, Object?> json,
  ) async {
    final temporary = File('${file.path}.${_randomToken()}.tmp');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(file.path);
  }

  static final Random _random = Random.secure();

  static String _randomToken() {
    return List<String>.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

final class _EntryRecord {
  const _EntryRecord({
    required this.id,
    required this.cacheKeys,
    required this.references,
  });

  final String id;

  /// The entry's file cache keys, or null when its metadata is unreadable.
  final List<String>? cacheKeys;

  final List<ModelStoreReference> references;

  /// Whether this entry keeps files that cannot be named, so no file may be
  /// deleted.
  bool get protectsUnknownFiles => cacheKeys == null && references.isNotEmpty;
}
