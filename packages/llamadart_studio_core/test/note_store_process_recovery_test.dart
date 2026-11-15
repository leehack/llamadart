@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'support/note_store_process_fixture.dart' as fixture;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('studio_notes_process_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'cold VMs preserve committed order, metadata and attachment bytes',
    () async {
      final committed = await _runFixture(root, 'seed');
      _expectSnapshot(committed);
      expect(await _runFixture(root, 'read'), committed);
      expect(await _runFixture(root, 'read'), committed);
    },
  );

  test(
    'SIGKILL after completed save preserves notes and media in a cold VM',
    () async {
      final committed = await _runFixture(root, 'seed-hold', kill: true);
      _expectSnapshot(committed);
      expect(await _runFixture(root, 'read'), committed);
    },
    skip: Platform.isWindows ? 'Requires POSIX SIGKILL.' : false,
  );

  test(
    'SIGKILL after completed replacement preserves new media and other notes',
    () async {
      final original = await _runFixture(root, 'seed');
      final replacement = await _runFixture(root, 'replace-hold', kill: true);
      _expectSnapshot(replacement, replacement: true);
      expect(replacement.first, original.first);
      expect(await _runFixture(root, 'read'), replacement);
    },
    skip: Platform.isWindows ? 'Requires POSIX SIGKILL.' : false,
  );

  test(
    'SIGKILL during blocked metadata write preserves prior note and media',
    () async {
      final original = await _runFixture(root, 'seed');
      final fifo = File('${root.path}/notes/media.json.tmp');
      final result = await Process.run('mkfifo', <String>[fifo.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      await _runFixture(
        root,
        'replace-blocked',
        kill: true,
        stalledWrite: fifo,
      );
      expect(await _runFixture(root, 'read'), original);
      final revisions = Directory('${root.path}/note_media/media');
      expect(await revisions.list().length, 2);
      await fifo.delete();
      final reopened = _store(root);
      await reopened.save(
        (await reopened.loadAll()).singleWhere((note) => note.id == 'media'),
      );
      expect(await revisions.list().length, 1);
      expect(await _runFixture(root, 'read'), original);
    },
    skip: Platform.isWindows ? 'Requires POSIX FIFO and SIGKILL.' : false,
  );

  for (final clearMedia in <bool>[false, true]) {
    test(
      'failed metadata write preserves prior media (clear=$clearMedia)',
      () async {
        final store = _store(root);
        final original = await store.save(
          fixture.processFixtureNote(),
          imageBytes: fixture.processFixtureImage(),
          audioWavBytes: fixture.processFixtureAudio(),
        );
        await Directory('${root.path}/notes/media.json.tmp').create();
        await expectLater(
          store.save(
            original.copyWith(content: 'Must not commit'),
            imageBytes: clearMedia
                ? null
                : fixture.processFixtureImage(replacement: true),
            audioWavBytes: clearMedia
                ? null
                : fixture.processFixtureAudio(replacement: true),
            clearImage: clearMedia,
            clearAudio: clearMedia,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final reopened = _store(root);
        final restored = (await reopened.loadAll()).single;
        expect(restored.toJson(), original.toJson());
        expect(
          await reopened.readImageBytes(restored),
          fixture.processFixtureImage(),
        );
        expect(
          await reopened.readAudioBytes(restored),
          fixture.processFixtureAudio(),
        );
      },
    );
  }

  test(
    'legacy media survives failed clear and is collected after replacement',
    () async {
      final directory = await Directory(
        '${root.path}/note_media/media',
      ).create(recursive: true);
      final image = File('${directory.path}/image.png');
      final audio = File('${directory.path}/audio.wav');
      await image.writeAsBytes(fixture.processFixtureImage(), flush: true);
      await audio.writeAsBytes(fixture.processFixtureAudio(), flush: true);
      final store = _store(root);
      final original = await store.save(
        fixture.processFixtureNote().copyWith(
          imageLocalPath: image.path,
          audioLocalPath: audio.path,
        ),
      );
      final obstruction = await Directory(
        '${root.path}/notes/media.json.tmp',
      ).create();
      await expectLater(
        store.save(original, clearImage: true, clearAudio: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await image.readAsBytes(), fixture.processFixtureImage());
      expect(await audio.readAsBytes(), fixture.processFixtureAudio());
      await obstruction.delete();
      final replacement = await store.save(
        original,
        imageBytes: fixture.processFixtureImage(replacement: true),
        audioWavBytes: fixture.processFixtureAudio(replacement: true),
      );
      expect(await image.exists(), isFalse);
      expect(await audio.exists(), isFalse);
      expect(
        await store.readImageBytes(replacement),
        fixture.processFixtureImage(replacement: true),
      );
      expect(
        await store.readAudioBytes(replacement),
        fixture.processFixtureAudio(replacement: true),
      );
      expect(await directory.list().length, 1);
      final cleared = await store.save(
        replacement,
        clearImage: true,
        clearAudio: true,
      );
      expect(cleared.hasImage, isFalse);
      expect(cleared.hasAudio, isFalse);
      expect(await directory.exists(), isFalse);
    },
  );

  test('media cleanup leaves externally owned attachments untouched', () async {
    final image = File('${root.path}/external.png');
    final audio = File('${root.path}/external.wav');
    await image.writeAsBytes(fixture.processFixtureImage(), flush: true);
    await audio.writeAsBytes(fixture.processFixtureAudio(), flush: true);
    final store = _store(root);
    final original = await store.save(
      fixture.processFixtureNote().copyWith(
        imageLocalPath: image.path,
        audioLocalPath: audio.path,
      ),
    );
    final replacement = await store.save(
      original,
      imageBytes: fixture.processFixtureImage(replacement: true),
      audioWavBytes: fixture.processFixtureAudio(replacement: true),
    );
    await store.save(replacement, clearImage: true, clearAudio: true);
    await store.delete(original.id);
    expect(await image.readAsBytes(), fixture.processFixtureImage());
    expect(await audio.readAsBytes(), fixture.processFixtureAudio());
  });

  test(
    'malformed persisted IDs cannot turn media cleanup into app-data deletion',
    () async {
      final sentinel = File('${root.path}/conversations.json');
      await sentinel.writeAsString('unrelated durable data', flush: true);
      final notes = await Directory('${root.path}/notes').create();
      await Directory('${root.path}/note_media').create();
      await File('${notes.path}/corrupt.json').writeAsString(
        jsonEncode(<String, Object?>{
          ...fixture.processFixtureNote().toJson(),
          'id': '..',
        }),
        flush: true,
      );
      final store = _store(root);
      final loaded = await store.loadAll();
      await store.saveAll(loaded);
      expect(await sentinel.readAsString(), 'unrelated durable data');
      expect(loaded, isEmpty);
    },
  );

  test('invalid IDs are rejected before any note-store mutation', () async {
    final store = _store(root);
    for (final id in <String>[
      '',
      '.',
      '..',
      '../escape',
      'nested/note',
      '_order',
    ]) {
      final note = StudioNote.fromJson(<String, Object?>{
        ...fixture.processFixtureNote().toJson(),
        'id': id,
      });
      await expectLater(store.save(note), throwsArgumentError);
      await expectLater(
        store.saveAll(<StudioNote>[fixture.processFixtureTextNote(), note]),
        throwsArgumentError,
      );
      await expectLater(store.delete(id), throwsArgumentError);
    }
    expect(await root.list().isEmpty, isTrue);
  });

  test(
    'stale missing managed media cannot overwrite the current durable note',
    () async {
      final store = _store(root);
      final original = await store.save(
        fixture.processFixtureNote(),
        imageBytes: fixture.processFixtureImage(),
        audioWavBytes: fixture.processFixtureAudio(),
      );
      final current = await store.save(
        original.copyWith(content: 'Current content'),
        imageBytes: fixture.processFixtureImage(replacement: true),
        audioWavBytes: fixture.processFixtureAudio(replacement: true),
      );
      await expectLater(
        store.save(original.copyWith(tags: <String>['stale'])),
        throwsA(isA<FileSystemException>()),
      );
      final canonicalRoot = await root.resolveSymbolicLinks();
      await expectLater(
        store.save(
          original.copyWith(
            imageLocalPath: original.imageLocalPath!.replaceFirst(
              root.path,
              canonicalRoot,
            ),
            audioLocalPath: original.audioLocalPath!.replaceFirst(
              root.path,
              canonicalRoot,
            ),
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      final reopened = _store(root);
      final restored = (await reopened.loadAll()).single;
      expect(restored.toJson(), current.toJson());
      expect(
        await reopened.readImageBytes(restored),
        fixture.processFixtureImage(replacement: true),
      );
      expect(
        await reopened.readAudioBytes(restored),
        fixture.processFixtureAudio(replacement: true),
      );
    },
  );

  test(
    'failed delete order write preserves note and media on cold reload',
    () async {
      final original = await _runFixture(root, 'seed');
      final obstruction = await Directory(
        '${root.path}/notes/_order.json.tmp',
      ).create();
      await expectLater(
        _store(root).delete('media'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await _runFixture(root, 'read'), original);
      await obstruction.delete();
      await _store(root).delete('media');
      final restored = await _runFixture(root, 'read');
      expect(restored, <Object?>[original.first]);
    },
  );

  test(
    'media cleanup preserves unknown owned-directory entries and symlink targets',
    () async {
      final external = await Directory('${root.path}/external').create();
      final externalImage = File('${external.path}/image.png');
      await externalImage.writeAsBytes(fixture.processFixtureImage());
      final mediaRoot = await Directory('${root.path}/note_media').create();
      await Link('${mediaRoot.path}/media').create(external.path);
      await expectLater(
        _store(root).save(fixture.processFixtureNote()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await externalImage.readAsBytes(), fixture.processFixtureImage());
      await Link('${mediaRoot.path}/media').delete();
      final original = await _store(root).save(
        fixture.processFixtureNote(),
        imageBytes: fixture.processFixtureImage(),
      );
      final unknown = File('${mediaRoot.path}/media/unrelated.txt');
      await unknown.writeAsString('keep');
      final linked = Link('${mediaRoot.path}/media/revision_external');
      await linked.create(external.path);
      await _store(root).save(original, clearImage: true);
      expect(await unknown.readAsString(), 'keep');
      expect(await externalImage.readAsBytes(), fixture.processFixtureImage());
      expect(await linked.exists(), isTrue);
    },
    skip: Platform.isWindows ? 'Requires POSIX symlinks.' : false,
  );
}

StudioNoteStore _store(Directory root) => createDefaultNoteStore(
  fallbackKeyValueStore: InMemoryKeyValueStore(),
  directoryPath: root.path,
);

void _expectSnapshot(List<Object?> snapshot, {bool replacement = false}) {
  expect(snapshot, hasLength(2));
  final text = snapshot.first! as Map<String, Object?>;
  expect(text['note'], fixture.processFixtureTextNote().toJson());
  expect(text['image'], isNull);
  expect(text['audio'], isNull);
  final media = snapshot.last! as Map<String, Object?>;
  final note = Map<String, Object?>.from(media['note']! as Map);
  expect(note.remove('imageLocalPath'), isA<String>());
  expect(note.remove('audioLocalPath'), isA<String>());
  final expected = fixture.processFixtureNote();
  expect(
    note,
    (replacement
            ? expected.copyWith(
                content: 'Replacement committed 한국어 🦙',
                updatedAt: DateTime.utc(2026, 11, 15, 13),
              )
            : expected)
        .toJson(),
  );
  expect(
    media['image'],
    base64Encode(fixture.processFixtureImage(replacement: replacement)),
  );
  expect(
    media['audio'],
    base64Encode(fixture.processFixtureAudio(replacement: replacement)),
  );
}

Future<List<Object?>> _runFixture(
  Directory root,
  String operation, {
  bool kill = false,
  File? stalledWrite,
}) async {
  final packageConfig = (await Isolate.packageConfig)!;
  final child = await Process.start(Platform.resolvedExecutable, <String>[
    '--packages=$packageConfig',
    File('test/support/note_store_process_fixture.dart').absolute.path,
    operation,
    root.path,
  ]);
  final errors = StringBuffer();
  final report = Completer<List<Object?>>();
  if (stalledWrite != null) report.future.ignore();
  final stdoutSubscription = child.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (report.isCompleted) return;
          try {
            report.complete(jsonDecode(line) as List<Object?>);
          } catch (error, stackTrace) {
            report.completeError(error, stackTrace);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!report.isCompleted) report.completeError(error, stackTrace);
        },
        onDone: () {
          if (!report.isCompleted && stalledWrite == null) {
            report.completeError(
              StateError('Fixture exited without a report: $errors'),
            );
          }
        },
      );
  final stderrSubscription = child.stderr
      .transform(utf8.decoder)
      .listen(errors.write);
  var exited = false;
  RandomAccessFile? pipe;
  Future<int>? byteRead;
  var writeReached = false;
  try {
    List<Object?> snapshot;
    if (stalledWrite == null) {
      snapshot = await report.future.timeout(const Duration(seconds: 30));
    } else {
      // The writer cannot finish its multi-megabyte JSON until this reader
      // drains the FIFO. Reading one byte proves the child reached that write.
      // Read/write mode opens a POSIX FIFO without waiting for its writer.
      pipe = await stalledWrite.open(mode: FileMode.write);
      byteRead = pipe.readByte();
      final firstByte = await Future.any<int>(<Future<int>>[
        byteRead,
        child.exitCode.then(
          (code) => throw StateError(
            'Fixture exited before stalled write ($code): $errors',
          ),
        ),
      ]).timeout(const Duration(seconds: 30));
      writeReached = true;
      expect(firstByte, '{'.codeUnitAt(0));
      snapshot = <Object?>[];
    }
    if (kill) {
      expect(child.kill(ProcessSignal.sigkill), isTrue);
    }
    final exitCode = await child.exitCode.timeout(const Duration(seconds: 10));
    exited = true;
    expect(
      exitCode,
      kill ? -ProcessSignal.sigkill.signalNumber : 0,
      reason: '$errors',
    );
    return snapshot;
  } finally {
    if (!exited) {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    }
    if (pipe != null && !writeReached && byteRead != null) {
      await pipe.writeByte(0);
      await byteRead;
    }
    await pipe?.close();
    await child.stdin.close();
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}
