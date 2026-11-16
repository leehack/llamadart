import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _UnloadedInference extends FakeInferencePort {
  final state = StateStore<StudioRuntimeSnapshot>(
    const StudioRuntimeSnapshot(phase: StudioEnginePhase.unloaded),
  );

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => state;

  @override
  Future<void> dispose() async {
    await state.dispose();
    await super.dispose();
  }
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'Coding retains focused input across keyboard resize: $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(402, 874);
        tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        addTearDown(tester.view.reset);
        final deps = await buildTestDeps(
          isMobile: true,
          inferencePort: _UnloadedInference(),
          storagePort: EmptyCacheStoragePort(),
        );
        addTearDown(deps.dispose);
        await deps.shellController.selectWorkspace(StudioWorkspace.coding);
        await tester.pumpWidget(
          StudioScope(
            deps: deps,
            child: MaterialApp(
              theme: StudioTheme.light(),
              home: const StudioShellScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('coding_prompt_input'));
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        final editor = tester.state<EditableTextState>(editable);
        final field = tester.widget<TextField>(input);
        expect(field.maxLines, 2);
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        tester.testTextInput.enterText('Keep this draft');
        await tester.pump();

        for (final inset in [100.0, 300.0, 0.0, 300.0]) {
          tester.testTextInput.log.clear();
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          tester.view.padding = FakeViewPadding(
            top: 62,
            bottom: inset > 0 ? 0 : 34,
          );
          await tester.pumpAndSettle();
          expect(tester.state<EditableTextState>(editable), same(editor));
          expect(editor.mounted, isTrue);
          expect(field.focusNode!.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(
            tester.testTextInput.log.map((call) => call.method),
            isNot(contains(anyOf('TextInput.clearClient', 'TextInput.hide'))),
          );
          expect(field.controller!.text, 'Keep this draft');
          if (inset == 300) {
            expect(tester.widget<TextField>(input).maxLines, 1);
          }
        }
        tester.testTextInput.enterText('Continue typing');
        await tester.pump();
        expect(field.controller!.text, 'Continue typing');
        tester.testTextInput.log.clear();
        await tester.tap(find.text('Files (0)'));
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(field.controller!.text, 'Continue typing');
        expect(
          tester.testTextInput.log.map((call) => call.method),
          contains('TextInput.hide'),
        );
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        await tester.pumpAndSettle();
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editable), same(editor));
        expect(tester.testTextInput.isVisible, isTrue);
        tester.testTextInput.log.clear();
        await tester.tap(find.byKey(const Key('coding_send_button')));
        await tester.pumpAndSettle();
        expect(field.controller!.text, isEmpty);
        expect(field.focusNode!.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.map((call) => call.method),
          isNot(contains('TextInput.hide')),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
