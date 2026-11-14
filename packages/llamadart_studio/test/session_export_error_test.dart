// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('JSON export reports unavailable media without copying success', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    deps.chatController.addPendingAttachment(
      const StudioAttachment(
        id: 'missing',
        kind: StudioAttachmentKind.image,
        name: 'missing.png',
        localPath: '/private/secret/missing.png',
      ),
    );
    await deps.chatController.sendMessage('Describe this image');
    var clipboardWrites = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') clipboardWrites++;
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_command_palette_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('command_palette_search_field')),
      'JSON',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Active Session Tree as JSON'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Attachment media is unavailable. Restore or remove the attachment before exporting.',
      ),
      findsOneWidget,
    );
    expect(find.text('Copied session JSON to clipboard'), findsNothing);
    expect(find.textContaining('/private/secret'), findsNothing);
    expect(clipboardWrites, 0);
    expect(tester.takeException(), isNull);
  });
}
