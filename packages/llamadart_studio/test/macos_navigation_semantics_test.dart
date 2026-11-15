@TestOn('vm && mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  final binding = _CaptureBinding();
  testWidgets('workspace navigation keeps native accessibility tree valid', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(820, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      binding.updates.clear();
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      await deps.chatController.sendMessage(
        'Summarize **Markdown** with `code`.',
      );
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        'Review draft 20261115',
      );
      await deps.shellController.selectWorkspace(StudioWorkspace.models);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        'qwen 27b',
      );
      await tester.pumpAndSettle();
      await deps.shellController.selectWorkspace(StudioWorkspace.chat);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat_composer_input')))
            .controller!
            .text,
        'Review draft 20261115',
      );
      await deps.shellController.toggleInspector();
      await tester.pumpAndSettle();
      await deps.shellController.toggleInspector();
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(820, 900));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      await tester.pumpAndSettle();
      await deps.shellController.selectWorkspace(StudioWorkspace.models);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await deps.shellController.selectWorkspace(StudioWorkspace.chat);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final temporary = Directory.systemTemp.createTempSync(
        'studio_navigation_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final packets = File('${temporary.path}/updates.json');
      packets.writeAsStringSync(jsonEncode(binding.updates));
      final config = File('.dart_tool/package_config.json');
      final packages =
          (jsonDecode(config.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      final flutter = packages.cast<Map<String, dynamic>>().singleWhere(
        (package) => package['name'] == 'flutter',
      );
      final sdk = Directory.fromUri(
        config.absolute.uri.resolve(flutter['rootUri'] as String),
      ).parent.parent;
      final frameworks =
          '${sdk.path}/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64';
      final executable = '${temporary.path}/semantics_test';
      final compile = await tester.runAsync(
        () => Process.run('xcrun', [
          'clang++',
          '-std=c++17',
          '-fobjc-arc',
          '-I',
          '${sdk.path}/engine/src/flutter/shell/platform/embedder',
          '-F',
          frameworks,
          '-framework',
          'Cocoa',
          '-framework',
          'FlutterMacOS',
          '-Wl,-rpath,$frameworks',
          'test/support/macos_static_semantics.mm',
          '-o',
          executable,
        ]),
      );
      expect(
        compile!.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final result = await tester.runAsync(
        () => Process.run(executable, [packets.path]),
      );
      expect(result!.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        isNot(contains('Failed to update ui::AXTree')),
        reason: '${result.stderr}',
      );
      expect(result.stderr, contains('NAVIGATION_SEMANTICS_UPDATE_OK'));
    } finally {
      semantics.dispose();
    }
  });
}

// Capture the actual incremental packets, rather than just the final tree:
// a later valid packet cannot recover the native tree after an orphan update.
class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  final List<List<Map<String, Object?>>> updates = [];
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _CaptureBuilder(updates);
}

class _CaptureBuilder extends Fake implements ui.SemanticsUpdateBuilder {
  _CaptureBuilder(this.updates);
  final List<List<Map<String, Object?>>> updates;
  final ui.SemanticsUpdateBuilder builder = ui.SemanticsUpdateBuilder();
  final List<Map<String, Object?>> nodes = [];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      nodes.add({
        'id': args[#id],
        'label': args[#label],
        'value': args[#value],
        'children': (args[#childrenInTraversalOrder] as List<int>).toList(),
      });
      return Function.apply(
        builder.updateNode,
        invocation.positionalArguments,
        args,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => builder.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );
  @override
  ui.SemanticsUpdate build() {
    updates.add(nodes);
    return builder.build();
  }
}
