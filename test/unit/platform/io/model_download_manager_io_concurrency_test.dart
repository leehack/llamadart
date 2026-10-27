@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/model_load_options.dart';
import 'package:llamadart/src/core/models/model_source.dart';
import 'package:llamadart/src/platform/io/model_cache_entry_lock.dart';
import 'package:llamadart/src/platform/io/model_download_manager_io.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../support/dart_script_snapshot.dart';

const String _fileName = 'tiny.gguf';

void main() {
  late String childSnapshot;
  late Directory root;
  late _HoldingServer server;

  setUpAll(() async {
    childSnapshot = await compileDartScript(
      'test/support/model_cache_download_child.dart',
    );
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('llamadart_cache_lock_');
    addTearDown(() => root.delete(recursive: true));
    server = await _HoldingServer.start();
    addTearDown(server.close);
  });

  ModelSource source() => ModelSource.url(server.uri, fileName: _fileName);
  Directory entryDirectory() =>
      Directory(path.join(root.path, source().cacheDirectoryName));
  String lockPath() =>
      path.join(root.path, '.locks', '${source().cacheDirectoryName}.lock');

  Future<_Child> spawnChild() => _Child.spawn(childSnapshot, <String>[
    root.path,
    server.uri.toString(),
    _fileName,
  ]);

  List<String> leftovers() => entryDirectory().existsSync()
      ? entryDirectory()
            .listSync()
            .map((entity) => path.basename(entity.path))
            .where(
              (name) =>
                  name.endsWith('.part') ||
                  name.endsWith('.part.json') ||
                  name.endsWith('.tmp'),
            )
            .toList()
      : const <String>[];

  test('two processes sharing a cache root download once and both return '
      'the complete file', () async {
    final first = await spawnChild();
    final second = await spawnChild();
    await Future.wait(<Future<void>>[first.started, second.started]);
    await server.firstResponseHeld;
    // A second request can only arrive if the other process did not wait.
    await Future.any(<Future<void>>[
      server.requestArrived(2),
      Future<void>.delayed(const Duration(milliseconds: 1500)),
    ]);
    server.release();

    final results = await Future.wait(<Future<Map<String, Object?>>>[
      first.done,
      second.done,
    ]);

    for (final result in results) {
      expect(result['bytes'], server.payload.length);
      expect(result['fileBytes'], server.payload.length);
      expect(result['sha256'], server.sha256Digest);
    }
    expect(server.requestCount, 1);
    expect(server.maxActiveRequests, 1);
    expect(leftovers(), isEmpty);
  });

  test('two isolates sharing a cache root download once', () async {
    final rootPath = root.path;
    final url = server.uri.toString();
    final downloads = <Future<(int?, String)>>[
      _downloadInIsolate(rootPath, url),
      _downloadInIsolate(rootPath, url),
    ];
    await server.firstResponseHeld;
    await Future.any(<Future<void>>[
      server.requestArrived(2),
      Future<void>.delayed(const Duration(milliseconds: 1500)),
    ]);
    server.release();

    for (final (bytes, digest) in await Future.wait(
      downloads,
    ).timeout(const Duration(seconds: 30))) {
      expect(bytes, server.payload.length);
      expect(digest, server.sha256Digest);
    }
    expect(server.requestCount, 1);
    expect(server.maxActiveRequests, 1);
  });

  test('without file locks, overlapping downloads each return their own '
      'complete file', () async {
    // Different lengths make any shared or swapped file visible; without a
    // validator neither download can resume the other's bytes.
    final longer = <int>[...server.payload, ...List<int>.filled(4096, 9)];
    server
      ..etag = null
      ..payloadOverrides[2] = longer
      ..holdAtOverrides[1] = 0
      ..holdAtOverrides[2] = longer.length - 1;
    final rootPath = root.path;
    final url = server.uri.toString();
    final downloads = <Future<(int?, String)>>[
      _downloadInIsolate(rootPath, url, lockable: false),
      _downloadInIsolate(rootPath, url, lockable: false),
    ];
    await Future.wait(<Future<void>>[server.held(1), server.held(2)]);
    await _waitForPartFile(entryDirectory(), longer.length - 1);
    server.releaseRequest(1);
    // Release the other download only once the first has returned and read
    // its file: Windows cannot replace a file another handle has open.
    await Future.any(downloads).timeout(const Duration(seconds: 30));
    server.release();

    final lengths = <String, int>{
      server.sha256Digest: server.payload.length,
      sha256.convert(longer).toString(): longer.length,
    };
    final results = await Future.wait(
      downloads,
    ).timeout(const Duration(seconds: 30));
    for (final (bytes, digest) in results) {
      expect(lengths, containsPair(digest, bytes));
    }
    expect(results.map((result) => result.$2).toSet(), hasLength(2));
    expect(leftovers(), isEmpty);
  });

  test('a waiting process takes over and resumes after the downloading '
      'process is killed', () async {
    final crashed = await spawnChild();
    await server.firstResponseHeld;
    await _waitForPartFile(entryDirectory(), server.holdAfter);

    final waiter = await spawnChild();
    await waiter.started;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(server.requestCount, 1, reason: 'the waiter must not download');

    crashed.kill();
    final result = await waiter.done;

    expect(result['bytes'], server.payload.length);
    expect(result['sha256'], server.sha256Digest);
    expect(server.requestCount, 2);
    expect(server.ranges.last, 'bytes=${server.holdAfter}-');
    expect(leftovers(), isEmpty);
  });

  group('in one process', () {
    late DefaultModelDownloadManager manager;

    setUp(() {
      manager = DefaultModelDownloadManager(defaultCacheDirectory: root.path);
      server.holdFirst = false;
    });

    test('a waiter re-validates the entry once the holder releases the lock '
        'and never returns a truncated file', () async {
      final cached = await manager.ensureModel(source());
      expect(server.requestCount, 1);

      final holder = await acquireModelCacheEntryLock(
        lockPath(),
        throwIfCancelled: () {},
      );
      expect(holder, isNotNull);
      final waiting = manager.ensureModel(source());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // The holder leaves a file whose size no longer matches its metadata.
      File(cached.filePath).writeAsBytesSync(server.payload.sublist(0, 7));
      await holder!.release();

      final entry = await waiting;

      expect(server.requestCount, 2);
      expect(await File(entry.filePath).readAsBytes(), server.payload);
    });

    test('a waiter honours cancellation while another holder has the '
        'lock', () async {
      Directory(path.dirname(lockPath())).createSync(recursive: true);
      final holder = await acquireModelCacheEntryLock(
        lockPath(),
        throwIfCancelled: () {},
      );
      expect(holder, isNotNull);
      addTearDown(() => holder?.release());
      final token = ModelDownloadCancelToken();
      final waiting = manager.ensureModel(
        source(),
        options: ModelLoadOptions(cancelToken: token),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();

      await expectLater(waiting, throwsA(isA<LlamaStateException>()));
      expect(server.requestCount, 0);
    });

    test('resumes from the largest orphaned attempt and removes the '
        'rest', () async {
      final directory = entryDirectory()..createSync(recursive: true);
      final validator = jsonEncode(<String, Object?>{'etag': server.etag});
      void orphan(String id, List<int> bytes) {
        File(
          path.join(directory.path, '$_fileName.$id.part'),
        ).writeAsBytesSync(bytes);
        File(
          path.join(directory.path, '$_fileName.$id.part.json'),
        ).writeAsStringSync(validator);
      }

      orphan('00000000000000a1', <int>[1, 2]);
      orphan('00000000000000a2', server.payload.sublist(0, 9));
      File(path.join(directory.path, '$_fileName.part')).writeAsStringSync('x');
      File(
        path.join(directory.path, 'metadata.json.00000000000000a3.tmp'),
      ).writeAsStringSync('{');
      File(
        path.join(directory.path, '$_fileName.00000000000000a4.part.json'),
      ).writeAsStringSync(validator);

      final entry = await manager.ensureModel(source());

      expect(server.ranges, <String?>['bytes=9-']);
      expect(await File(entry.filePath).readAsBytes(), server.payload);
      expect(leftovers(), isEmpty);
    });

    test('drops a resume validator left without its part file', () async {
      final directory = entryDirectory()..createSync(recursive: true);
      File(
        path.join(directory.path, '$_fileName.part.json'),
      ).writeAsStringSync(jsonEncode(<String, Object?>{'etag': server.etag}));

      final entry = await manager.ensureModel(source());

      expect(server.ranges, <String?>[null]);
      expect(await File(entry.filePath).readAsBytes(), server.payload);
      expect(leftovers(), isEmpty);
    });

    test('a failed attempt leaves its bytes as <file>.part for the next '
        'resume', () async {
      server.failAfterHold = true;
      server.holdFirst = true;
      final failing = manager.ensureModel(
        source(),
        options: ModelLoadOptions(maxRetries: 0),
      );
      await server.firstResponseHeld;
      server.release();
      await expectLater(failing, throwsA(isA<LlamaModelException>()));

      expect(
        leftovers(),
        unorderedEquals(<String>['$_fileName.part', '$_fileName.part.json']),
      );
      final part = File(path.join(entryDirectory().path, '$_fileName.part'));
      expect(part.lengthSync(), server.holdAfter);

      final entry = await manager.ensureModel(source());

      expect(server.ranges.last, 'bytes=${server.holdAfter}-');
      expect(await File(entry.filePath).readAsBytes(), server.payload);
      expect(leftovers(), isEmpty);
    });

    test('a locked caller that resumes a part file another writer is still '
        'appending to discards the result and downloads again', () async {
      // The other writer cannot lock: an older llamadart, or a process whose
      // lock failed. The locked caller adopts its in-flight part file.
      server
        ..holdFirst = true
        ..holdHeaders.add(2);
      final rootPath = root.path;
      final url = server.uri.toString();
      final unlocked = _downloadInIsolate(rootPath, url, lockable: false);
      await server.firstResponseHeld;
      await _waitForPartFile(entryDirectory(), server.holdAfter);
      final locked = manager.ensureModel(source());
      await server.headersHeld(2);
      // Windows refuses to rename a file another handle has open, so there
      // the locked caller cannot adopt the in-flight file and starts afresh.
      expect(
        server.ranges[1],
        Platform.isWindows ? isNull : 'bytes=${server.holdAfter}-',
      );
      server.releaseRequest(1);
      final (unlockedBytes, unlockedDigest) = await unlocked.timeout(
        const Duration(seconds: 30),
      );
      server.releaseHeaders(2);
      final entry = await locked.timeout(const Duration(seconds: 30));

      expect(unlockedBytes, server.payload.length);
      expect(unlockedDigest, server.sha256Digest);
      expect(entry.bytes, server.payload.length);
      expect(await File(entry.filePath).readAsBytes(), server.payload);
      final cached = await manager.get(source().cacheKey);
      expect(cached?.bytes, server.payload.length);
    });

    test('downloads a gzip-encoded response whose Content-Length counts the '
        'encoded bytes', () async {
      server.gzipBody = true;

      final entry = await manager.ensureModel(
        source(),
        options: ModelLoadOptions(maxRetries: 0),
      );

      expect(await File(entry.filePath).readAsBytes(), server.payload);
      expect(entry.bytes, server.payload.length);
    });

    test(
      'a body shorter than the reported total is kept and resumed',
      () async {
        server.shortBodies.add(1);

        final entry = await manager.ensureModel(source());

        expect(server.ranges, <String?>[null, 'bytes=${server.holdAfter}-']);
        expect(await File(entry.filePath).readAsBytes(), server.payload);
      },
    );

    test('a resumed attempt writes at the offset it requested while a writer '
        'without the lock extends the same file', () async {
      // An older llamadart writes <file>.part directly, without the lock, and
      // keeps its handle open. The locked caller adopts the file at [adopted]
      // bytes; the old writer reaches [extended] during the round trip.
      const adopted = 128 * 1024;
      const extended = 192 * 1024;
      server
        ..holdHeaders.add(1)
        ..holdAtOverrides[1] = 16 * 1024
        ..failAfterHold = true
        ..releaseRequest(1);
      final directory = entryDirectory()..createSync(recursive: true);
      final part = File(path.join(directory.path, '$_fileName.part'));
      File(
        '${part.path}.json',
      ).writeAsStringSync(jsonEncode(<String, Object?>{'etag': server.etag}));
      final oldWriter = await part.open(mode: FileMode.write);
      addTearDown(oldWriter.close);
      await oldWriter.writeFrom(server.payload, 0, adopted);
      await oldWriter.flush();

      final locked = manager.ensureModel(source());
      await server.headersHeld(1);
      expect(server.ranges.first, 'bytes=$adopted-');
      await oldWriter.writeFrom(server.payload, adopted, extended);
      await oldWriter.flush();
      server.releaseHeaders(1);
      final entry = await locked.timeout(const Duration(seconds: 30));

      expect(entry.bytes, server.payload.length);
      expect(await File(entry.filePath).readAsBytes(), server.payload);
    }, testOn: '!windows');

    test('never touches a metadata temp file another writer owns', () async {
      final directory = entryDirectory()..createSync(recursive: true);
      final foreign = File(path.join(directory.path, 'metadata.json.tmp'))
        ..writeAsStringSync('foreign');

      await manager.ensureModel(source());

      expect(foreign.readAsStringSync(), 'foreign');
    });

    test('a cacheOnly miss creates no lock directory', () async {
      final missingRoot = path.join(root.path, 'missing');

      await expectLater(
        manager.ensureModel(
          source(),
          options: ModelLoadOptions(
            cachePolicy: ModelCachePolicy.cacheOnly,
            cacheDirectory: missingRoot,
          ),
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(Directory(missingRoot).existsSync(), isFalse);
    });

    test('without file locks, a failed attempt without a validator drops '
        'a stale one left at <file>.part.json', () async {
      final previousLocker = modelCacheEntryLocker;
      modelCacheEntryLocker = (lockPath, {required throwIfCancelled}) async =>
          null;
      addTearDown(() => modelCacheEntryLocker = previousLocker);
      final directory = entryDirectory()..createSync(recursive: true);
      final staleValidator = File(
        path.join(directory.path, '$_fileName.part.json'),
      )..writeAsStringSync(jsonEncode(<String, Object?>{'etag': '"old"'}));
      server
        ..etag = null
        ..holdFirst = true
        ..failAfterHold = true
        ..release();

      await expectLater(
        manager.ensureModel(source(), options: ModelLoadOptions(maxRetries: 0)),
        throwsA(isA<LlamaModelException>()),
      );

      expect(
        File(path.join(directory.path, '$_fileName.part')).existsSync(),
        isTrue,
      );
      expect(staleValidator.existsSync(), isFalse);
    });

    test('without file locks it warns once, downloads into its own attempt '
        'file and leaves other attempts alone', () async {
      final previousLocker = modelCacheEntryLocker;
      modelCacheEntryLocker = (lockPath, {required throwIfCancelled}) async =>
          null;
      final records = <LlamaLogRecord>[];
      final logger = LlamaLogger.instance;
      final previousLevel = logger.level;
      logger
        ..setLevel(LlamaLogLevel.warn)
        ..setHandler(records.add);
      addTearDown(() {
        modelCacheEntryLocker = previousLocker;
        logger
          ..setLevel(previousLevel)
          ..setHandler(null);
      });
      resetModelCacheLockWarningForTesting();
      final directory = entryDirectory()..createSync(recursive: true);
      final foreign = File(
        path.join(directory.path, '$_fileName.00000000000000b1.part'),
      )..writeAsStringSync('in-flight');

      final entry = await manager.ensureModel(source());
      await manager.ensureModel(
        source(),
        options: ModelLoadOptions(cachePolicy: ModelCachePolicy.refresh),
      );

      expect(await File(entry.filePath).readAsBytes(), server.payload);
      expect(foreign.readAsStringSync(), 'in-flight');
      expect(records, hasLength(1));
      expect(records.single.level, LlamaLogLevel.warn);
      expect(records.single.message, contains('Cannot lock'));
    });
  });
}

// A top-level function, so the closure sent to the isolate captures only
// [root] and [url].
Future<(int?, String)> _downloadInIsolate(
  String root,
  String url, {
  bool lockable = true,
}) => Isolate.run(() => _download(root, url, lockable));

Future<(int?, String)> _download(String root, String url, bool lockable) async {
  if (!lockable) {
    modelCacheEntryLocker = (lockPath, {required throwIfCancelled}) async =>
        null;
  }
  final manager = DefaultModelDownloadManager(defaultCacheDirectory: root);
  final entry = await manager.ensureModel(
    ModelSource.url(Uri.parse(url), fileName: _fileName),
  );
  final bytes = await File(entry.filePath).readAsBytes();
  return (entry.bytes, sha256.convert(bytes).toString());
}

Future<void> _waitForPartFile(Directory directory, int length) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is File &&
            entity.path.endsWith('.part') &&
            entity.lengthSync() == length) {
          return;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('No $length-byte part file appeared in ${directory.path}.');
}

/// A child process running `model_cache_download_child.dart`.
class _Child {
  _Child._(this._process) {
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final event = jsonDecode(line) as Map<String, Object?>;
          switch (event['event']) {
            case 'started':
              _started.complete();
            case 'done':
              _done.complete(event);
          }
        });
    _stderr = _process.stderr.transform(utf8.decoder).listen(_errors.write);
    _process.exitCode.then((code) {
      if (!_done.isCompleted && !_killed) {
        _done.completeError(
          StateError('child exited $code before finishing:\n$_errors'),
        );
      }
    });
  }

  static Future<_Child> spawn(String snapshot, List<String> args) async {
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      snapshot,
      ...args,
    ]);
    final child = _Child._(process);
    addTearDown(child._dispose);
    return child;
  }

  final Process _process;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  final StringBuffer _errors = StringBuffer();
  final Completer<void> _started = Completer<void>();
  final Completer<Map<String, Object?>> _done =
      Completer<Map<String, Object?>>();
  bool _killed = false;

  Future<void> get started => _started.future;

  Future<Map<String, Object?>> get done =>
      _done.future.timeout(const Duration(seconds: 30));

  void kill() {
    _killed = true;
    _process.kill(ProcessSignal.sigkill);
  }

  Future<void> _dispose() async {
    _killed = true;
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    await _stdout.cancel();
    await _stderr.cancel();
  }
}

/// Serves one payload with an ETag and byte ranges. The first full response
/// pauses after [holdAfter] bytes until [release], so a test controls when
/// that download can finish.
class _HoldingServer {
  _HoldingServer._(this._server) {
    _subscription = _server.listen(_accept);
  }

  static Future<_HoldingServer> start() async =>
      _HoldingServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final Set<Future<void>> _inFlight = <Future<void>>{};
  final List<int> payload = List<int>.generate(
    256 * 1024,
    (index) => (index * 31 + 7) % 251,
  );
  String? etag = '"holding-v1"';
  final List<String?> ranges = <String?>[];
  final Map<int, Completer<void>> _held = <int, Completer<void>>{};
  final Map<int, Completer<void>> _released = <int, Completer<void>>{};
  final Map<int, Completer<void>> _arrivals = <int, Completer<void>>{};
  bool _releasedAll = false;
  bool holdFirst = true;

  /// Bodies, and mid-body pause offsets, by request number.
  final Map<int, List<int>> payloadOverrides = <int, List<int>>{};
  final Map<int, int> holdAtOverrides = <int, int>{};
  bool failAfterHold = false;

  /// Sends every body gzip-encoded, with the encoded Content-Length.
  bool gzipBody = false;

  /// Request numbers whose full response ends at [holdAfter] bytes.
  final Set<int> shortBodies = <int>{};

  /// Request numbers whose headers wait for [releaseHeaders].
  final Set<int> holdHeaders = <int>{};
  final Map<int, Completer<void>> _headersHeld = <int, Completer<void>>{};
  final Map<int, Completer<void>> _headersReleased = <int, Completer<void>>{};

  Future<void> headersHeld(int number) =>
      (_headersHeld[number] ??= Completer<void>()).future;

  void releaseHeaders(int number) {
    final released = _headersReleased[number] ??= Completer<void>();
    if (!released.isCompleted) {
      released.complete();
    }
  }

  int requestCount = 0;
  int activeRequests = 0;
  int maxActiveRequests = 0;

  int get holdAfter => payload.length ~/ 2;

  Uri get uri =>
      Uri.parse('http://127.0.0.1:${_server.port}/models/$_fileName');

  String get sha256Digest => sha256.convert(payload).toString();

  Future<void> get firstResponseHeld => held(1);

  /// Completes once full response [number] has paused mid-body.
  Future<void> held(int number) => (_held[number] ??= Completer<void>()).future;

  Future<void> requestArrived(int count) =>
      (_arrivals[count] ??= Completer<void>()).future;

  /// Lets every held response, and any held later, finish.
  void release() {
    _releasedAll = true;
    _released.keys.toList().forEach(releaseRequest);
    _headersReleased.keys.toList().forEach(releaseHeaders);
  }

  void releaseRequest(int number) {
    final released = _released[number] ??= Completer<void>();
    if (!released.isCompleted) {
      released.complete();
    }
  }

  Future<void> close() async {
    release();
    await _subscription.cancel();
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
    await _server.close(force: true);
  }

  void _accept(HttpRequest request) {
    late final Future<void> tracked;
    tracked = _handle(request)
        .catchError((Object _) {
          // A killed client leaves the held response writing to a dead socket.
        })
        .whenComplete(() => _inFlight.remove(tracked));
    _inFlight.add(tracked);
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount += 1;
    final number = requestCount;
    (_arrivals[number] ??= Completer<void>()).complete();
    activeRequests += 1;
    if (activeRequests > maxActiveRequests) {
      maxActiveRequests = activeRequests;
    }
    try {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (holdHeaders.contains(number)) {
        (_headersHeld[number] ??= Completer<void>()).complete();
        if (_releasedAll) {
          releaseHeaders(number);
        }
        await (_headersReleased[number] ??= Completer<void>()).future;
      }
      final response = request.response;
      final currentEtag = etag;
      if (currentEtag != null) {
        response.headers.set(HttpHeaders.etagHeader, currentEtag);
      }
      final body = payloadOverrides[number] ?? payload;
      var start = 0;
      if (range != null &&
          currentEtag != null &&
          request.headers.value(HttpHeaders.ifRangeHeader) == currentEtag) {
        start = int.parse(range.substring('bytes='.length).split('-').first);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${body.length - 1}/${body.length}',
        );
      }
      if (gzipBody) {
        final encoded = gzip.encode(body.sublist(start));
        response.headers
          ..set(HttpHeaders.contentEncodingHeader, 'gzip')
          ..contentLength = encoded.length;
        response.add(encoded);
        await response.close();
        return;
      }
      if (shortBodies.contains(number) && start == 0) {
        // Ends cleanly at half the body: no Content-Length to fall short of,
        // only the Content-Range total.
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${holdAfter - 1}/${body.length}',
        );
        response.add(body.sublist(0, holdAfter));
        await response.close();
        return;
      }
      response.headers.contentLength = body.length - start;
      final holdAt =
          holdAtOverrides[number] ??
          (holdFirst && number == 1 && start == 0 ? holdAfter : null);
      if (holdAt == null) {
        response.add(body.sublist(start));
        await response.close();
        return;
      }
      // [holdAt] counts bytes of this response, from [start].
      response.add(body.sublist(start, start + holdAt));
      await response.flush();
      (_held[number] ??= Completer<void>()).complete();
      if (_releasedAll) {
        releaseRequest(number);
      }
      await (_released[number] ??= Completer<void>()).future;
      if (failAfterHold) {
        // Closing short of Content-Length drops the connection mid-body.
        await response.close();
        return;
      }
      response.add(body.sublist(start + holdAt));
      await response.close();
    } finally {
      activeRequests -= 1;
    }
  }
}
