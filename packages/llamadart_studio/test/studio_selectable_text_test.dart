import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/src/widgets/studio_selectable_text.dart';

void main() {
  testWidgets('changing selectable output keeps static text semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    Future<void> render(String text, {bool rich = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: rich
                ? StudioSelectableText.rich(TextSpan(text: text))
                : StudioSelectableText(text),
          ),
        ),
      );
      var readable = false;
      void checkOutputSemantics(SemanticsNode node) {
        final data = node.getSemanticsData();
        expect(data.flagsCollection.isTextField, isFalse);
        readable |= data.label == text;
        node.visitChildren((child) {
          checkOutputSemantics(child);
          return true;
        });
      }

      checkOutputSemantics(tester.getSemantics(find.text(text)));
      expect(readable, isTrue, reason: 'Output remains in the semantics tree');
      expect(find.byType(EditableText), findsNothing);
    }

    try {
      await render('Before');
      await render('After');
      await render('Styled output', rich: true);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('selectable output supports keyboard select all and copy', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StudioSelectableText('Copy this output')),
      ),
    );
    await tester.tap(find.text('Copy this output'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copied, 'Copy this output');
  });
}
