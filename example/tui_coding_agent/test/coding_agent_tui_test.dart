import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_tui_coding_agent/tui_coding_agent.dart';
import 'package:nocterm/nocterm.dart'
    show AutoScrollController, Color, ListView, Size;
import 'package:nocterm/nocterm_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('coding-agent-tui-');
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  test('restores the TurboVision shell and preserves failure state', () async {
    final config = _configFor(workspace, enableThinking: true, readOnly: true);

    await testNocterm('TurboVision shell and failed initialization', (
      tester,
    ) async {
      await tester.pumpComponent(CodingAgentTui(config: config));
      await _pumpUntilIdle(tester);

      final initial = tester.renderToString();
      expect(initial, contains('Initialization failed'));
      expect(initial, contains('llamadart coding agent'));
      expect(initial, contains('m: missing.gguf'));
      expect(initial, contains('[thinking]'));
      expect(initial, contains('[read-only]'));
      expect(initial, contains('/help'));
      expect(initial, contains('╔'));
      expect(initial, contains('╚'));

      final state = tester.terminalState;
      final transcript = tester.findAllComponents<ListView>().single;
      expect(transcript.lazy, isTrue);
      expect(transcript.controller, isA<AutoScrollController>());
      final header = state.findText('llamadart').first;
      expect(
        state.getCellAt(header.x, header.y)?.style.backgroundColor,
        const Color.fromRGB(192, 192, 192),
      );
      final frame = state.findText('╔').first;
      expect(
        state.getCellAt(frame.x, frame.y)?.style.color,
        const Color.fromRGB(255, 255, 254),
      );
      expect(
        state.getCellAt(0, 2)?.style.backgroundColor,
        const Color.fromRGB(0, 0, 170),
      );
      final shortcut = state.findText('Esc/Ctrl+C cancel/quit').single;
      expect(
        state.getCellAt(shortcut.x, shortcut.y)?.style.backgroundColor,
        const Color.fromRGB(192, 192, 192),
      );

      await tester.enterText('/clear');
      await tester.sendEnter();
      await tester.pump();

      final rendered = tester.renderToString();
      expect(rendered, contains('Initialization failed'));
      expect(rendered, contains('model is not ready'));
      expect(rendered, isNot(contains('Conversation cleared.')));
    });
  });

  test('TurboVision shell collapses badges in a 40-column terminal', () async {
    final config = _configFor(workspace, enableThinking: true, readOnly: true);

    await testNocterm('40-column TurboVision shell', (tester) async {
      await tester.pumpComponent(CodingAgentTui(config: config));
      await _pumpUntilIdle(tester);

      final rendered = tester.renderToString();
      expect(rendered, contains('llamadart coding agent'));
      expect(rendered, contains('╔'));
      expect(rendered, contains('╚'));
      expect(rendered, contains('[T]'));
      expect(rendered, contains('[RO]'));
      expect(rendered, isNot(contains('[thinking]')));
      expect(rendered, isNot(contains('[read-only]')));
      expect(rendered, contains('Esc/Ctrl+C'));
    }, size: const Size(40, 16));
  });

  test('lazy transcript auto-follows and preserves manual scroll-up', () async {
    final config = _configFor(workspace);

    await testNocterm('lazy transcript scrolling', (tester) async {
      await tester.pumpComponent(CodingAgentTui(config: config));
      await _pumpUntilIdle(tester);

      final transcript = tester.findAllComponents<ListView>().single;
      final controller = transcript.controller! as AutoScrollController;

      for (var index = 0; index < 16; index++) {
        await tester.enterText('/x');
        await tester.sendEnter();
      }
      await tester.pump();

      expect(controller.isAutoScrollEnabled, isTrue);
      expect(controller.atEnd, isTrue);

      controller.scrollUp(4);
      final offsetBeforeAppend = controller.offset;
      expect(controller.isAutoScrollEnabled, isFalse);

      await tester.enterText('/x');
      await tester.sendEnter();
      await tester.pump();

      expect(controller.isAutoScrollEnabled, isFalse);
      expect(controller.atEnd, isFalse);
      expect(controller.offset, offsetBeforeAppend);
    }, size: const Size(80, 14));
  });
}

CodingAgentConfig _configFor(
  Directory workspace, {
  bool enableThinking = false,
  bool readOnly = false,
}) {
  return CodingAgentConfig(
    workspaceRoot: workspace.path,
    modelSource: p.join(workspace.path, 'missing.gguf'),
    modelCacheDirectory: p.join(workspace.path, 'cache'),
    modelParams: const ModelParams(contextSize: 128, gpuLayers: 0),
    generationParams: const GenerationParams(maxTokens: 16),
    enableThinking: enableThinking,
    readOnly: readOnly,
  );
}

Future<void> _pumpUntilIdle(NoctermTester tester) async {
  for (var i = 0; i < 20; i++) {
    final rendered = tester.renderToString();
    if (rendered.contains('[READY]') || rendered.contains('[ERROR]')) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
  fail('TUI did not return to an idle state.');
}
