import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Runs in an owned child VM so no store or in-memory fallback survives restart.
Future<void> main(List<String> arguments) async {
  final operation = arguments[0];
  final store = createDefaultNoteStore(
    fallbackKeyValueStore: InMemoryKeyValueStore(),
    directoryPath: arguments[1],
  );
  if (operation == 'seed' || operation == 'seed-hold') {
    final media = await store.save(
      processFixtureNote(),
      imageBytes: processFixtureImage(),
      audioWavBytes: processFixtureAudio(),
    );
    await store.saveAll(<StudioNote>[processFixtureTextNote(), media]);
  } else if (operation == 'replace-hold' || operation == 'replace-blocked') {
    final media = (await store.loadAll()).singleWhere(
      (note) => note.id == 'media',
    );
    await store.save(
      media.copyWith(
        // Exceeds a POSIX pipe's capacity so the parent can stop a real write.
        content: operation == 'replace-blocked'
            ? 'Uncommitted replacement' * 100000
            : 'Replacement committed 한국어 🦙',
        updatedAt: DateTime.utc(2026, 11, 15, 13),
      ),
      imageBytes: processFixtureImage(replacement: true),
      audioWavBytes: processFixtureAudio(replacement: true),
    );
  } else if (operation != 'read') {
    throw ArgumentError.value(operation, 'operation');
  }

  final snapshot = <Map<String, Object?>>[];
  for (final note in await store.loadAll()) {
    final image = await store.readImageBytes(note);
    final audio = await store.readAudioBytes(note);
    snapshot.add(<String, Object?>{
      'note': note.toJson(),
      'image': image == null ? null : base64Encode(image),
      'audio': audio == null ? null : base64Encode(audio),
    });
  }
  stdout.writeln(jsonEncode(snapshot));
  await stdout.flush();
  if (operation.endsWith('-hold')) {
    // Parent kills only this process after receiving the completed-save report.
    await stdin.drain<void>();
  }
}

StudioNote processFixtureNote() => StudioNote(
  id: 'media',
  title: 'Durable multimodal note',
  content: 'Previously committed 한국어 🦙',
  createdAt: DateTime.utc(2026, 11, 15, 12),
  updatedAt: DateTime.utc(2026, 11, 15, 12, 30),
  tags: const <String>['release', 'offline'],
  pinned: true,
  sourceKind: StudioNoteSourceKind.audio,
  sourceFileName: 'memo.wav',
  imageMimeType: 'image/png',
  audioDurationMs: 1000,
  transcript: 'Durable transcript',
  embedding: const <double>[0.25, 0.5, 0.75],
  embeddingModelId: 'fixture-embedding',
  isMultimodalIndexed: true,
);

StudioNote processFixtureTextNote() => StudioNote(
  id: 'text',
  title: 'Text note',
  content: 'Independent durable note',
  createdAt: DateTime.utc(2026, 11, 15, 11),
  updatedAt: DateTime.utc(2026, 11, 15, 11),
);

Uint8List processFixtureImage({bool replacement = false}) => Uint8List.fromList(
  <int>[137, 80, 78, 71, 13, 10, 26, 10, if (replacement) 2 else 1],
);

Uint8List processFixtureAudio({bool replacement = false}) => Uint8List.fromList(
  <int>[82, 73, 70, 70, 4, 0, 0, 0, 87, 65, 86, 69, if (replacement) 2 else 1],
);
