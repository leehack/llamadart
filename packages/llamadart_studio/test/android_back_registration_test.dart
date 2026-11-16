@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final registrations = <bool>[];
  setUp(() {
    registrations.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            registrations.add(call.arguments as bool);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<StudioDependencies> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps(isMobile: true);
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    await tester.pumpAndSettle();
    expect(registrations, isNotEmpty);
    expect(registrations.last, isFalse, reason: 'Root Back must exit normally');
    return deps;
  }

  testWidgets(
    'Local history updates Android Back registration through the app',
    (tester) async {
      final deps = await mount(tester);
      final root = Directory.systemTemp.createTempSync('back_registration_');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/main.dart').writeAsStringSync('owned file');
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(root.path),
      );
      await tester.pumpAndSettle();
      Future<void> openDrawer(bool end) async {
        await tester.tap(
          find.byKey(
            Key(end ? 'toggle_inspector_button' : 'open_sidebar_drawer_button'),
          ),
        );
        await tester.pumpAndSettle();
        expect(registrations.last, isTrue, reason: 'Open drawer owns Back');
      }

      for (final end in [false, true]) {
        await openDrawer(end);
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(registrations.last, isFalse, reason: 'Last local entry removed');
      }
      await tester.tap(find.text('Files (1)'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_file_main.dart')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      final detail = find.byKey(const Key('coding_back_to_files'));
      expect(detail, findsOneWidget);
      expect(registrations.last, isTrue, reason: 'File detail owns Back');
      for (final section in ['Agent', 'Edits (0)']) {
        await tester.tap(find.text(section));
        await tester.pumpAndSettle();
        expect(registrations.last, isFalse);
        await tester.tap(find.text('Files (1)'));
        await tester.pumpAndSettle();
        expect(registrations.last, isTrue);
      }
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      await tester.pumpAndSettle();
      expect(registrations.last, isFalse);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      expect(registrations.last, isTrue);
      for (final end in [false, true]) {
        await openDrawer(end);
        registrations.clear();
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(registrations, isNot(contains(false)));
        expect(detail, findsOneWidget);
      }
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
      expect(registrations.last, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Pending shell refresh preserves dialog Back ownership', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(
      find.byKey(const Key('coding_prompt_input')),
    );
    final route = ModalRoute.of(context)!;
    final entry = LocalHistoryEntry();
    registrations.clear();
    route.addLocalHistoryEntry(entry);
    // Cover the shell between its dependency rebuild and deferred dispatch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      entry.remove();
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('Back overlay')),
        ),
      );
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Back overlay'), findsOneWidget);
    expect(registrations, isNotEmpty);
    expect(registrations, everyElement(isTrue));
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(registrations.last, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
