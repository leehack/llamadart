@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/app/platform_file_helper.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:record/record.dart';
import 'package:web/web.dart' as web;

import 'studio_widget_test_helpers.dart';

void main() {
  for (final workspace in [StudioWorkspace.notes, StudioWorkspace.speech]) {
    testWidgets('${workspace.name} consumes and releases browser WAV blob', (
      tester,
    ) async {
      final recorder = _BlobRecorder();
      final previousRecorder = RecordPlatform.instance;
      RecordPlatform.instance = recorder;
      addTearDown(() => RecordPlatform.instance = previousRecorder);
      final kv = InMemoryKeyValueStore();
      final speech = _CapturedSpeech();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: FakeInferencePort(),
        speechPort: speech,
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isWeb: true,
      );
      addTearDown(deps.dispose);
      await tester.binding.setSurfaceSize(const Size(1280, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: Scaffold(
              body: workspace == StudioWorkspace.notes
                  ? const NotebookWorkspaceView()
                  : const SpeechWorkspaceView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (workspace == StudioWorkspace.notes) {
        expect(find.text('Import Image'), findsOneWidget);
        expect(find.text('Import File'), findsOneWidget);
        final picker = _BytesPicker(
          PlatformFile(
            name: 'unicode.txt',
            size: 24,
            bytes: Uint8List.fromList(utf8.encode('Bonjour Montréal 👋')),
          ),
        );
        FilePicker.platform = picker;
        await tester.tap(find.text('Import File'));
        await tester.pumpAndSettle();
        expect(
          deps.notebookController.state.selectedNote!.content,
          'Bonjour Montréal 👋',
        );
        final imageBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=',
        );
        picker.file = PlatformFile(
          name: 'reference.png',
          size: imageBytes.length,
          bytes: imageBytes,
        );
        await tester.tap(find.text('Import Image'));
        await tester.pumpAndSettle();
        expect(
          await deps.notebookController.readNoteImageBytes(
            deps.notebookController.state.selectedNote!,
          ),
          imageBytes,
        );
      }
      final start = workspace == StudioWorkspace.notes
          ? find.byKey(const Key('notebook_record_audio_button'))
          : find.text('Record Mic');
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(start);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        recorder.starts,
        1,
        reason:
            '${find.byType(SnackBar).evaluate().map((e) => (e.widget as SnackBar).content)}',
      );
      final stop = workspace == StudioWorkspace.notes
          ? find.byKey(const Key('notebook_record_audio_button'))
          : find.text('Stop & Transcribe');
      await tester.runAsync(() async {
        await tester.tap(stop);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(recorder.stops, 1);
      if (workspace == StudioWorkspace.notes) {
        final note = deps.notebookController.state.notes.firstWhere(
          (note) => note.hasAudio,
        );
        expect(
          await deps.notebookController.readNoteAudioBytes(note),
          recorder.bytes,
        );
      } else {
        expect(speech.audio, recorder.bytes);
      }
      // A successful consumer releases the object URL; it is no longer readable.
      await tester.runAsync(
        () => expectLater(
          StudioPlatformFileHelper.readBytesFromPath(recorder.url!),
          throwsA(anything),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(recorder.disposed.isCompleted, isTrue);
    });
  }
}

class _BlobRecorder extends RecordPlatform {
  final Uint8List bytes = Uint8List.fromList([82, 73, 70, 70, 1, 2, 3, 4]);
  int starts = 0;
  int stops = 0;
  String? url;
  final Completer<void> disposed = Completer<void>();

  @override
  Future<void> create(String recorderId) async {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => encoder == AudioEncoder.wav;

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    expect(path, 'studio_recording.wav');
    expect(config.encoder, AudioEncoder.wav);
    starts++;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    return url = web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'audio/wav')),
    );
  }

  @override
  Future<void> dispose(String recorderId) async => disposed.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturedSpeech extends FakeSpeechPort {
  Uint8List? audio;

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    audio = audioBytes;
    expect(audioFilePath, isNull);
    return const StudioTranscriptResult(text: 'Browser capture', elapsedMs: 1);
  }
}

class _BytesPicker extends FilePicker {
  _BytesPicker(this.file);
  PlatformFile file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([file]);
}
