import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets(
    'Notes retains failed draft across removal and retries navigation',
    (WidgetTester tester) async {
      final capture = FakeMicChannels(tester);
      addTearDown(capture.dispose);
      final notes = RecoverableNoteStore();
      final deps = await buildTestDeps(noteStore: notes);
      addTearDown(deps.dispose);
      _drainMediaOnTearDown(tester);
      await deps.shellController.selectWorkspace(StudioWorkspace.notes);
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      notes.fail = true;
      await tester.enterText(
        find.byKey(const Key('vault_note_content_input')),
        'Keep this even when saving fails',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('Save failed'), findsOneWidget);
      expect(
        find.byKey(const Key('notebook_retry_save_button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await deps.shellController.selectWorkspace(StudioWorkspace.models);
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.notes);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('vault_note_content_input')),
            )
            .controller!
            .text,
        'Keep this even when saving fails',
      );
      notes.fail = false;
      await tester.tap(find.byKey(const Key('notebook_retry_save_button')));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      await deps.shellController.selectWorkspace(StudioWorkspace.models);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.models,
      );
      expect(
        deps.notebookController.state.selectedNote!.content,
        'Keep this even when saving fails',
      );
    },
  );

  for (final workspace in <StudioWorkspace>[
    StudioWorkspace.notes,
    StudioWorkspace.speech,
  ]) {
    // Recovery reuses a WAV file returned by the native recorder channel.
    testWidgets('${workspace.name} keeps capture when navigation save fails', (
      WidgetTester tester,
    ) async {
      final capture = FakeMicChannels(tester);
      addTearDown(capture.dispose);
      final notes = RecoverableNoteStore();
      final speech = RecoverableSpeechPort();
      final deps = await buildTestDeps(noteStore: notes, speechPort: speech);
      addTearDown(deps.dispose);
      _drainMediaOnTearDown(tester);
      await deps.shellController.selectWorkspace(workspace);
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      final record = workspace == StudioWorkspace.notes
          ? find.byKey(const Key('notebook_record_audio_button'))
          : find.text('Record Mic');
      await tester.ensureVisible(record);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(record);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
        capture.starts,
        1,
        reason:
            '${capture.methods}; ${find.byType(SnackBar).evaluate().map((e) => (e.widget as SnackBar).content)}',
      );
      notes.fail = workspace == StudioWorkspace.notes;
      speech.fail = workspace == StudioWorkspace.speech;
      await tester.runAsync(
        () => deps.shellController.selectWorkspace(StudioWorkspace.models),
      );
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, workspace);
      expect(capture.stops, 1);
      notes.fail = false;
      speech.fail = false;
      await tester.runAsync(
        () => deps.shellController.selectWorkspace(StudioWorkspace.models),
      );
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.models,
      );
      expect(
        capture.stops,
        1,
        reason: 'Retry must reuse the stopped recording',
      );
      if (workspace == StudioWorkspace.notes) {
        final note = deps.notebookController.state.notes.firstWhere(
          (n) => n.hasAudio,
        );
        expect(
          await deps.notebookController.readNoteAudioBytes(note),
          capture.bytes,
        );
      } else {
        expect(
          deps.speechController.state.latestTranscript!.text,
          'Captured words',
        );
        expect(speech.lastAudio, capture.bytes);
      }
      expect(tester.takeException(), isNull);
    }, skip: kIsWeb);
  }

  for (final workspace in [StudioWorkspace.notes, StudioWorkspace.speech]) {
    // Concurrent stops share the native recorder operation and its WAV file.
    testWidgets('${workspace.name} coalesces Stop with navigation capture', (
      tester,
    ) async {
      final capture = FakeMicChannels(tester);
      addTearDown(capture.dispose);
      final speech = RecoverableSpeechPort();
      final deps = await buildTestDeps(speechPort: speech);
      addTearDown(deps.dispose);
      _drainMediaOnTearDown(tester);
      await deps.shellController.selectWorkspace(workspace);
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      final start = workspace == StudioWorkspace.notes
          ? find.byKey(const Key('notebook_record_audio_button'))
          : find.text('Record Mic');
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(start);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      capture.stopGate = Completer<void>();
      late Future<void> navigation;
      await tester.runAsync(() async {
        navigation = deps.shellController.selectWorkspace(
          StudioWorkspace.models,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      final stop = workspace == StudioWorkspace.notes
          ? find.byKey(const Key('notebook_record_audio_button'))
          : find.text('Stop & Transcribe');
      await tester.ensureVisible(stop);
      await tester.pumpAndSettle();
      await tester.tap(stop);
      await tester.pump();
      final pendingStopCalls = capture.stops;
      capture.stopGate!.complete();
      await tester.runAsync(() => navigation);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.activeWorkspace,
        StudioWorkspace.models,
      );
      expect(capture.starts, 1);
      expect(
        pendingStopCalls,
        1,
        reason: 'Stop must join the navigation operation',
      );
      expect(capture.stops, 1);
      if (workspace == StudioWorkspace.notes) {
        expect(
          deps.notebookController.state.notes.where((note) => note.hasAudio),
          hasLength(1),
        );
      } else {
        expect(speech.transcriptions, 1);
      }
      expect(tester.takeException(), isNull);
    }, skip: kIsWeb);
  }

  for (final workspace in [StudioWorkspace.notes, StudioWorkspace.speech]) {
    testWidgets(
      '${workspace.name} permission error never claims a recording was retained',
      (tester) async {
        final capture = FakeMicChannels(tester)..permission = false;
        addTearDown(capture.dispose);
        final deps = await buildTestDeps();
        addTearDown(deps.dispose);
        _drainMediaOnTearDown(tester);
        await deps.shellController.selectWorkspace(workspace);
        await tester.pumpWidget(_app(deps));
        await tester.pumpAndSettle();
        final start = workspace == StudioWorkspace.notes
            ? find.byKey(const Key('notebook_record_audio_button'))
            : find.text('Record Mic');
        await tester.ensureVisible(start);
        await tester.pumpAndSettle();
        await tester.tap(start);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not start recording.'),
          findsOneWidget,
        );
        expect(find.textContaining('kept for retry'), findsNothing);
        expect(capture.starts, 0);
        expect(capture.stops, 0);
        expect(tester.takeException(), isNull);
      },
      // Permission denial is injected through the native recorder MethodChannel.
      skip: kIsWeb,
    );
  }

  testWidgets(
    'Speech stages transcript beside an existing draft while Chat is busy',
    (WidgetTester tester) async {
      final capture = FakeMicChannels(tester);
      addTearDown(capture.dispose);
      final inference = ControllableStreamingInferencePort()..manualMode = true;
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(deps.dispose);
      _drainMediaOnTearDown(tester);
      final turn = deps.chatController.sendMessage('Still generating');
      await tester.pump();
      deps.chatController.setComposerDraft('Existing draft');
      await deps.speechController.loadSttModel(
        deps.speechController.availableSttModels.first,
      );
      await deps.speechController.transcribeAudio(audioBytes: Uint8List(32));
      await deps.shellController.selectWorkspace(StudioWorkspace.speech);
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      final handoff = find.text('Use in Chat');
      await tester.ensureVisible(handoff);
      await tester.pumpAndSettle();
      await tester.tap(handoff);
      await tester.pumpAndSettle();
      expect(deps.shellController.state.activeWorkspace, StudioWorkspace.chat);
      expect(
        deps.chatController.state.composerDraft,
        'Existing draft\n\nHello Studio',
      );
      expect(
        deps.chatController.state.activeConversation!.activeBranch
            .where((m) => m.role == StudioRole.user)
            .length,
        1,
      );
      inference.complete(finalText: 'Done');
      await turn;
    },
  );
}

void _drainMediaOnTearDown(WidgetTester tester) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  });
}

Widget _app(StudioDependencies deps) => StudioScope(
  deps: deps,
  child: MaterialApp(
    theme: StudioTheme.dark(),
    home: Scaffold(
      body: StoreBuilder<StudioShellState>(
        store: deps.shellController.store,
        builder: (context, state) => switch (state.activeWorkspace) {
          StudioWorkspace.notes => const NotebookWorkspaceView(),
          StudioWorkspace.speech => const SpeechWorkspaceView(),
          _ => const SizedBox(),
        },
      ),
    ),
  ),
);

class RecoverableNoteStore extends EphemeralNoteStore {
  bool fail = false;

  @override
  Future<StudioNote> save(
    StudioNote note, {
    Uint8List? imageBytes,
    Uint8List? audioWavBytes,
    bool clearImage = false,
    bool clearAudio = false,
  }) async {
    if (fail) throw StateError('disk full');
    return super.save(
      note,
      imageBytes: imageBytes,
      audioWavBytes: audioWavBytes,
      clearImage: clearImage,
      clearAudio: clearAudio,
    );
  }
}

class RecoverableSpeechPort extends FakeSpeechPort {
  bool fail = false;
  Uint8List? lastAudio;
  int transcriptions = 0;

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    transcriptions++;
    lastAudio = audioBytes;
    if (fail) throw StateError('transcription failed');
    return const StudioTranscriptResult(text: 'Captured words', elapsedMs: 1);
  }
}

class FakeMicChannels {
  FakeMicChannels(this.tester) {
    if (!kIsWeb) {
      directory = Directory.systemTemp.createTempSync('studio_fake_mic_');
    }
    for (final name in <String>[
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
    ]) {
      final channel = MethodChannel(name);
      events.add(channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (name == 'xyz.luan/audioplayers' && call.method == 'create') {
          final playerId = (call.arguments as Map)['playerId'];
          final event = MethodChannel('xyz.luan/audioplayers/events/$playerId');
          events.add(event);
          messenger.setMockMethodCallHandler(event, (_) async => null);
        }
        return null;
      });
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory?.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        methods.add(call.method);
        final args = (call.arguments as Map).cast<String, Object?>();
        if (call.method == 'create') {
          final channel = MethodChannel(
            'com.llfbandit.record/events/${args['recorderId']}',
          );
          events.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        }
        if (call.method == 'hasPermission') return permission;
        if (call.method == 'start') {
          starts++;
          path = args['path']! as String;
          File(path!).writeAsBytesSync(bytes);
        }
        if (call.method == 'stop') {
          stops++;
          await stopGate?.future;
          return path;
        }
        return null;
      },
    );
  }
  final WidgetTester tester;
  TestDefaultBinaryMessenger get messenger =>
      tester.binding.defaultBinaryMessenger;
  final List<MethodChannel> events = <MethodChannel>[];
  final Uint8List bytes = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3, 4]);
  Directory? directory;
  String? path;
  final List<String> methods = <String>[];
  bool permission = true;
  int starts = 0;
  int stops = 0;
  Completer<void>? stopGate;

  void dispose() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      null,
    );
    for (final event in events) {
      messenger.setMockMethodCallHandler(event, null);
    }
    directory?.deleteSync(recursive: true);
  }
}
