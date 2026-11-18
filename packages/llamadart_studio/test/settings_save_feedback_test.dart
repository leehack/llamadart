import 'dart:async';
import 'dart:convert';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _SettingsStore extends InMemoryKeyValueStore {
  bool reject = true;
  Completer<void>? gate;

  @override
  Future<void> writeString(String key, String value) async {
    if (key == 'studio.settings.v1') {
      if (gate != null) await gate!.future;
      if (reject) throw StateError('Synthetic settings failure');
    }
    await super.writeString(key, value);
  }
}

void main() {
  testWidgets(
    'settings failure and Retry remain reachable over the inspector',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final kv = _SettingsStore();
      final deps = await buildTestDeps(isMobile: true, keyValueStore: kv);
      addTearDown(deps.dispose);
      await deps.shellController.selectWorkspace(StudioWorkspace.coding);
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.8),
                padding: const EdgeInsets.only(top: 44, bottom: 34),
                viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
              ),
              child: child!,
            ),
            home: const StudioShellScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final appearance = deps.shellController.currentSettings.appearance;
      await tester.tap(find.byTooltip('Cycle Appearance (${appearance.name})'));
      await tester.pumpAndSettle();
      final next = deps.shellController.currentSettings.appearance;
      expect(next, isNot(appearance));
      expect(
        find.byKey(const Key('settings_save_error_banner')),
        findsOneWidget,
      );
      expect(find.text('Settings not saved.'), findsOneWidget);
      final scaffold = Scaffold.of(
        tester.element(find.byKey(const Key('coding_prompt_input'))),
      );
      await tester.tap(find.byKey(const Key('toggle_inspector_button')));
      await tester.pumpAndSettle();
      expect(scaffold.isEndDrawerOpen, isTrue);
      final retry = find.byKey(const Key('retry_settings_save_button'));
      expect(retry.hitTestable(), findsOneWidget);
      expect(tester.getRect(retry).top, greaterThanOrEqualTo(44));
      expect(tester.getRect(retry).right, lessThanOrEqualTo(320));
      kv.reject = false;
      kv.gate = Completer<void>();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('Saving…'), findsOneWidget);
      expect(tester.widget<TextButton>(retry).onPressed, isNull);
      expect(scaffold.isEndDrawerOpen, isTrue);
      kv.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_save_error_banner')), findsNothing);
      expect(scaffold.isEndDrawerOpen, isTrue);
      final saved =
          jsonDecode((await kv.readString('studio.settings.v1'))!) as Map;
      expect(saved['appearance'], next.name);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
