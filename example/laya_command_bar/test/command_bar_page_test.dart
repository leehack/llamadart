import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/slots.dart';
import 'package:laya_command_bar_example/src/sources.dart';
import 'package:laya_command_bar_example/src/ui/command_bar_page.dart';

import 'support.dart';

void main() {
  late List<String> reads;
  late List<(AppSetting, bool)> changes;

  Future<IntentReading> fakeReader(String text) async {
    reads.add(text);
    return switch (text) {
      'text sam I am here' => readingOf(
        CommandIntent.message,
        0.96,
        confidence: 0.89,
        text: text,
      ),
      _ => readingOf(CommandIntent.ask, 0.4, confidence: 0.15, text: text),
    };
  }

  SourceOption fakeSource(
    String name, {
    IntentReader? reader,
    double enter = 0.6,
    Future<void> Function(CommandIntent, String)? learn,
  }) => SourceOption(
    name,
    '$name detail',
    (_) async => IntentSource(
      reader: reader ?? fakeReader,
      enter: enter,
      label: 'Test · CPU',
      learn: learn,
      dispose: () async {},
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    List<SourceOption>? sources,
  }) async {
    reads = [];
    changes = [];
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandBarPage(
          sources: sources ?? [fakeSource('Fake')],
          settings: {for (final s in AppSetting.values) s: false},
          onSetting: (s, on) => changes.add((s, on)),
          typingInterval: const Duration(milliseconds: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('stays plain while Laya is unsure', (tester) async {
    await pumpPage(tester);
    await type(tester, 'text sam');
    expect(
      find.textContaining('Not sure yet (confidence 0.15)'),
      findsOneWidget,
    );
    expect(find.text('Send'), findsNothing);
  });

  testWidgets('takes the message shape when Laya is sure, and Enter runs it', (
    tester,
  ) async {
    await pumpPage(tester);
    await type(tester, 'text sam I am here');
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('To Sam'), findsOneWidget);
    expect(find.text('I am here'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('Send'), findsNothing);
  });

  testWidgets('Enter without an intent asks for a pick', (tester) async {
    await pumpPage(tester);
    await type(tester, 'turn on dark mode');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Pick one, then press Enter'), findsOneWidget);
  });

  testWidgets('a picked intent overrides Laya and applies a setting', (
    tester,
  ) async {
    await pumpPage(tester);
    await type(tester, 'turn on dark mode');
    await tester.tap(find.bySemanticsLabel(RegExp('^Settings,')));
    await tester.pumpAndSettle();
    expect(find.text('Enter turns it on'), findsOneWidget);
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    expect(
      controller.selection,
      TextSelection.collapsed(offset: 'turn on dark mode'.length),
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes, [(AppSetting.darkMode, true)]);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Turned on'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Esc clears the bar and the pick', (tester) async {
    await pumpPage(tester);
    await type(tester, 'turn on dark mode');
    await tester.tap(find.bySemanticsLabel(RegExp('^Settings,')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('Enter turns it on'), findsNothing);
  });

  testWidgets('a sample chip types its command and the bar follows', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('text sam I am here'));
    for (var i = 0; i < 'text sam I am here'.length; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'text sam I am here',
    );
    expect(reads.last, 'text sam I am here');
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('switching sources reads the text with the new one', (
    tester,
  ) async {
    final second = <String>[];
    await pumpPage(
      tester,
      sources: [
        fakeSource('First'),
        fakeSource(
          'Second',
          enter: 0.1,
          reader: (text) async {
            second.add(text);
            return readingOf(
              CommandIntent.settings,
              0.5,
              confidence: 0.15,
              text: text,
            );
          },
        ),
      ],
    );
    await type(tester, 'turn on dark mode');
    expect(find.text('Enter turns it on'), findsNothing);

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(second, ['turn on dark mode']);
    expect(find.text('Enter turns it on'), findsOneWidget);
    expect(find.textContaining('Second detail'), findsOneWidget);
  });

  testWidgets('a picked command teaches every loaded source that learns', (
    tester,
  ) async {
    final learned = <(CommandIntent, String)>[];
    await pumpPage(
      tester,
      sources: [
        fakeSource('Learner', learn: (i, t) async => learned.add((i, t))),
      ],
    );
    await type(tester, 'text sam I am here');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(learned, isEmpty);

    await type(tester, 'turn on dark mode');
    await tester.tap(find.bySemanticsLabel(RegExp('^Settings,')));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(learned, [(CommandIntent.settings, 'turn on dark mode')]);
  });

  testWidgets('a source that fails to load can be retried', (tester) async {
    var attempts = 0;
    await pumpPage(
      tester,
      sources: [
        SourceOption('Flaky', 'Flaky detail', (_) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return IntentSource(
            reader: fakeReader,
            enter: 0.6,
            label: 'Test',
            dispose: () async {},
          );
        }),
      ],
    );
    expect(find.textContaining('Could not load Flaky'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    await type(tester, 'text sam I am here');
    expect(find.text('Send'), findsOneWidget);
  });
}
