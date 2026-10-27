@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/platform/io/model_cache_entry_lock.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llamadart_entry_lock_');
    addTearDown(() => directory.delete(recursive: true));
  });

  String lockPath([String name = 'entry']) =>
      path.join(directory.path, '$name.lock');

  Future<ModelCacheEntryLock> acquire([String name = 'entry']) async {
    final lock = await acquireModelCacheEntryLock(
      lockPath(name),
      throwIfCancelled: () {},
    );
    expect(lock, isNotNull);
    addTearDown(lock!.release);
    return lock;
  }

  test('a second holder in the same isolate waits for the first to '
      'release', () async {
    final first = await acquire();
    var secondAcquired = false;
    final second = acquire().then((lock) {
      secondAcquired = true;
      return lock;
    });

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(secondAcquired, isFalse);
    await first.release();
    await second.timeout(const Duration(seconds: 5));

    expect(secondAcquired, isTrue);
  });

  test('locks on different entries do not wait for each other', () async {
    await acquire('first');

    await acquire('second').timeout(const Duration(seconds: 5));
  });

  test('a waiter that is cancelled stops waiting and leaves the lock '
      'free', () async {
    final first = await acquire();
    var cancelled = false;
    final waiting = acquireModelCacheEntryLock(
      lockPath(),
      throwIfCancelled: () {
        if (cancelled) {
          throw const _Cancelled();
        }
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cancelled = true;

    await expectLater(waiting, throwsA(isA<_Cancelled>()));
    await first.release();
    await acquire().timeout(const Duration(seconds: 5));
  });

  test('release is idempotent', () async {
    final lock = await acquire();
    await lock.release();
    await lock.release();

    await acquire().timeout(const Duration(seconds: 5));
  });

  test('completes with null when the lock file cannot be created', () async {
    final lock = await acquireModelCacheEntryLock(
      path.join(directory.path, 'missing', 'entry.lock'),
      throwIfCancelled: () {},
    );

    expect(lock, isNull);
  });

  test('a lock held by another isolate excludes this one and is freed when '
      'that isolate is killed', () async {
    final held = ReceivePort();
    addTearDown(held.close);
    final isolate = await Isolate.spawn(_holdForever, (
      lockPath(),
      held.sendPort,
    ));
    await held.first;

    final waiting = acquire();
    var acquired = false;
    unawaited(waiting.then((_) => acquired = true));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(acquired, isFalse);

    isolate.kill(priority: Isolate.immediate);

    await waiting.timeout(const Duration(seconds: 10));
  }, testOn: '!windows');

  test('warns once that the cache cannot be locked, and only when warnings '
      'are enabled', () {
    final records = <LlamaLogRecord>[];
    final logger = LlamaLogger.instance;
    final previousLevel = logger.level;
    logger
      ..setLevel(LlamaLogLevel.error)
      ..setHandler(records.add);
    addTearDown(() {
      logger
        ..setLevel(previousLevel)
        ..setHandler(null);
      resetModelCacheLockWarningForTesting();
    });
    resetModelCacheLockWarningForTesting();

    warnModelCacheLockUnavailableOnce('/models');
    expect(records, isEmpty);
    logger.setLevel(LlamaLogLevel.warn);
    warnModelCacheLockUnavailableOnce('/models');
    warnModelCacheLockUnavailableOnce('/models');

    expect(records, hasLength(1));
    expect(records.single.level, LlamaLogLevel.warn);
    expect(records.single.message, contains('/models'));
  });
}

Future<void> _holdForever((String, SendPort) message) async {
  final (lockPath, held) = message;
  final lock = await acquireModelCacheEntryLock(
    lockPath,
    throwIfCancelled: () {},
  );
  held.send(null);
  // An open port keeps this frame, and so the lock, reachable until the
  // isolate is killed; an unreachable lock is closed by its finalizer.
  await ReceivePort().first;
  await lock?.release();
}

class _Cancelled implements Exception {
  const _Cancelled();
}
