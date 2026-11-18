import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/workspaces/chat/multimodal_composer.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('unreadable image attachment keeps its message readable', (
    tester,
  ) async {
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    deps.chatController.addPendingAttachment(
      StudioAttachment(
        id: 'broken',
        kind: StudioAttachmentKind.image,
        name: 'damaged.png',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      ),
    );
    await deps.chatController.sendMessage('Keep this message readable');
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('damaged.png'), findsOneWidget);
    expect(find.byTooltip('Image preview unavailable'), findsOneWidget);
  });

  for (final tooltip in ['Attach image (Vision)', 'Attach audio clip']) {
    testWidgets('$tooltip reports picker failure and permits retry', (
      tester,
    ) async {
      final picker = _ControlledPicker();
      FilePicker.platform = picker;
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      await tester.pumpWidget(_app(deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(tooltip));
      picker.result.completeError(StateError('picker unavailable'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Could not attach'), findsOneWidget);
      expect(deps.chatController.state.pendingAttachments, isEmpty);
      picker.result = Completer<FilePickerResult?>();
      await tester.tap(find.byTooltip(tooltip));
      picker.result.complete(null);
      await tester.pumpAndSettle();
      expect(deps.chatController.state.pendingAttachments, isEmpty);
    });
  }

  for (final removeComposer in [false, true]) {
    testWidgets(
      'delayed attachment ignores ${removeComposer ? 'removed composer' : 'changed conversation'}',
      (tester) async {
        final picker = _ControlledPicker();
        FilePicker.platform = picker;
        final deps = await buildTestDeps();
        addTearDown(deps.dispose);
        await tester.pumpWidget(_app(deps));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Attach image (Vision)'));
        if (removeComposer) {
          await tester.pumpWidget(const SizedBox());
        } else {
          await deps.chatController.createConversation();
        }
        picker.result.complete(
          FilePickerResult([
            PlatformFile(
              name: 'late.png',
              size: 4,
              bytes: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ]),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(deps.chatController.state.pendingAttachments, isEmpty);
      },
    );
  }
}

Widget _app(StudioDependencies deps) => StudioScope(
  deps: deps,
  child: MaterialApp(
    theme: StudioTheme.dark(),
    home: const Scaffold(body: MultimodalComposer()),
  ),
);

class _ControlledPicker extends FilePicker {
  Completer<FilePickerResult?> result = Completer<FilePickerResult?>();

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
  }) => result.future;
}
