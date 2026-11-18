import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/widgets/inspector/session_inspector_panel.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';
import 'test_io_helper.dart';

void main() {
  setUpAll(() {
    FilePicker.platform = _SessionFilePicker(
      PlatformFile(name: 'unused.json', size: 0),
    );
  });
  for (final fromDisk in <bool>[false, true]) {
    testWidgets(
      'JSON import preserves UTF-8 from ${fromDisk ? 'disk' : 'bytes'}',
      (WidgetTester tester) async {
        if (fromDisk && kIsWeb) return;
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final deps = await buildTestDeps();
        addTearDown(deps.dispose);
        const prompt = 'Bonjour Montréal, 안녕하세요 👋';
        await deps.chatController.sendMessage(prompt);
        final json = await deps.chatController.exportActiveAsJson();
        final originalId = deps.chatController.state.activeConversationId;
        String? filePath;
        if (fromDisk) {
          final dir = await tester.runAsync(
            () => createTempDir('studio_import_'),
          );
          addTearDown(() => deleteDirIfExists(dir));
          filePath = '$dir/session.json';
          await tester.runAsync(() => writeTextFile(filePath!, json));
        }
        final previousPicker = FilePicker.platform;
        addTearDown(() => FilePicker.platform = previousPicker);
        FilePicker.platform = _SessionFilePicker(
          PlatformFile(
            name: 'session.json',
            size: utf8.encode(json).length,
            path: filePath,
            bytes: fromDisk ? null : Uint8List.fromList(utf8.encode(json)),
          ),
        );
        await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final imported = deps.chatController.store.stream.firstWhere(
            (state) => state.activeConversationId != originalId,
          );
          await tester.tap(find.byTooltip('Import JSON session'));
          await imported.timeout(const Duration(seconds: 5));
        });
        await tester.pumpAndSettle();
        expect(
          deps.chatController.state.activeConversationId,
          isNot(originalId),
        );
        expect(
          deps.chatController.state.activeConversation!.activeBranch.first.text,
          prompt,
        );
      },
    );
  }

  testWidgets(
    'Inspector follows external presets and preserves editing selection',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SessionInspectorPanel),
          matching: find.text('Prompt'),
        ),
      );
      await tester.pumpAndSettle();
      final conversationId = deps.chatController.state.activeConversationId;
      final preset = StudioPreset.builtInPresets.firstWhere(
        (p) => p.jsonSchema != null,
      );
      await deps.chatController.applyPreset(preset);
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(SessionInspectorPanel),
        matching: find.byType(TextField),
      );
      final promptField = fields.at(0);
      final schemaField = fields.at(1);
      final promptController = tester
          .widget<TextField>(promptField)
          .controller!;
      final schemaController = tester
          .widget<TextField>(schemaField)
          .controller!;
      expect(deps.chatController.state.activeConversationId, conversationId);
      expect(promptController.text, preset.systemPrompt);
      expect(schemaController.text, preset.jsonSchema);
      await tester.enterText(promptField, 'Edited instruction');
      await tester.pumpAndSettle();
      expect(
        deps.chatController.state.activeConversation!.jsonSchema,
        preset.jsonSchema,
      );
      promptController.selection = const TextSelection.collapsed(offset: 3);
      deps.chatController.addPendingAttachment(
        const StudioAttachment(
          id: 'test',
          kind: StudioAttachmentKind.image,
          name: 'test.png',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        promptController.selection,
        const TextSelection.collapsed(offset: 3),
      );
      await deps.chatController.applyPreset(
        StudioPreset.builtInPresets.firstWhere((p) => p.jsonSchema == null),
      );
      await tester.pumpAndSettle();
      expect(schemaController.text, isEmpty);
    },
  );
}

class _SessionFilePicker extends FilePicker {
  _SessionFilePicker(this.file);
  final PlatformFile file;

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
  }) async => FilePickerResult(<PlatformFile>[file]);
}
