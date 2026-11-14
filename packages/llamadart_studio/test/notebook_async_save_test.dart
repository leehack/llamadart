import 'dart:async';
import 'dart:typed_data';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _DelayedNotes extends KeyValueNoteStore {
  _DelayedNotes(super.store);
  Completer<void>? nextSave;

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) async {
    final gate = nextSave;
    nextSave = null;
    if (gate != null) await gate.future;
    return super.save(
      note,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );
  }
}

void main() {
  for (final switchSource in <bool>[false, true]) {
    testWidgets('slow saves preserve newer edits (navigate: $switchSource)', (
      tester,
    ) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      await tester.binding.setSurfaceSize(const Size(1280, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final kv = InMemoryKeyValueStore();
      final notes = _DelayedNotes(kv);
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        noteStore: notes,
        storagePort: FakeStoragePort(),
        inferencePort: FakeInferencePort(),
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
      );
      addTearDown(deps.dispose);
      final selected = deps.notebookController.state.selectedNote!;
      final other = deps.notebookController.state.notes.firstWhere(
        (n) => n.id != selected.id,
      );
      await deps.notebookController.applyAuditedNotes(<StudioNote>[
        selected.copyWith(title: 'First', content: ''),
        other.copyWith(title: 'Second', content: ''),
      ]);
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: const Scaffold(body: NotebookWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalId = deps.notebookController.state.selectedNote!.id;
      final otherId = deps.notebookController.state.notes
          .firstWhere((n) => n.id != originalId)
          .id;
      final gate = Completer<void>();
      notes.nextSave = gate;
      final title = find.byKey(const Key('vault_note_title_input'));
      final body = find.byKey(const Key('vault_note_content_input'));
      await tester.enterText(title, 'Cloud acceptance — Montréal');
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(
        tester.widget<TextField>(title).controller!.text,
        'Cloud acceptance — Montréal',
      );
      if (switchSource) {
        await tester.tap(find.byKey(Key('vault_note_item_$otherId')));
        await tester.pump();
      }
      await tester.enterText(
        body,
        'New text while the earlier save is pending.',
      );
      if (!switchSource) {
        await tester.pump(const Duration(milliseconds: 650));
      }
      gate.complete();
      await tester.pumpAndSettle();
      if (switchSource) {
        expect(deps.notebookController.state.selectedNote!.id, otherId);
        await tester.tap(find.byKey(Key('vault_note_item_$originalId')));
        await tester.pumpAndSettle();
      }
      expect(
        tester.widget<TextField>(title).controller!.text,
        'Cloud acceptance — Montréal',
      );
      expect(
        tester.widget<TextField>(body).controller!.text,
        'New text while the earlier save is pending.',
      );
      final saved = await notes.loadAll();
      expect(
        saved.any(
          (n) =>
              n.title == 'Cloud acceptance — Montréal' &&
              n.content == 'New text while the earlier save is pending.',
        ),
        isTrue,
      );
    });
  }
}
