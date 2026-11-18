import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

class _Backend extends FakeSpeculativeFallbackBackend {
  @override
  Future<Map<String, String>> modelMetadata(int h) async => {
    'general.architecture': 'gemma4',
    'tokenizer.chat_template':
        '<|turn>user\n{{ messages[0]["content"] }}<turn|>\n{% if add_generation_prompt %}<|turn>model\n{% endif %}',
  };
  int calls = 0;
  @override
  Stream<List<int>> generate(
    int h,
    String p,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    yield utf8.encode(
      calls++ == 0
          ? '<|tool_call>call:mcp_lookup{}<tool_call|>'
          : 'New response',
    );
  }
}

class _GatedMcp extends McpManager {
  _GatedMcp({required super.keyValueStore});
  final entered = Completer<void>();
  final release = Completer<String>();
  @override
  List<ToolDefinition> buildActiveToolDefinitions() => [
    ToolDefinition(
      name: 'mcp_lookup',
      description: 'Waits',
      parameters: [],
      handler: (_) {
        entered.complete();
        return release.future;
      },
    ),
  ];
}

void main() {
  test(
    'Clear blocks new inference until the old tool releases the shared port',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'studio_clear_drain_',
      );
      final file = await File(
        '${directory.path}/model.gguf',
      ).writeAsBytes([0x47, 0x47, 0x55, 0x46]);
      final port = DirectLlamaInferencePort(backend: _Backend());
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      await shell.updateSettings(
        (s) => s.copyWith(toolsEnabled: true, thinkingEnabled: false),
      );
      await port.loadModel(
        assets: ResolvedModelAssets(
          descriptor: StudioModelDescriptor(
            id: 'test',
            name: 'Test',
            description: 'Fake',
            category: StudioModelCategory.chat,
            filename: 'model.gguf',
            sourceUri: file.path,
          ),
          primarySource: ModelSource.path(file.path),
        ),
        settings: shell.currentSettings,
        isWeb: false,
      );
      final mcp = _GatedMcp(keyValueStore: kv);
      final skills = SkillRegistry(keyValueStore: kv);
      final coding = CodingWorkspaceController(
        inferencePort: port,
        shellController: shell,
        keyValueStore: kv,
        mcpManager: mcp,
        skillRegistry: skills,
      );
      addTearDown(() async {
        if (!mcp.release.isCompleted) mcp.release.complete('Cancelled');
        await coding.dispose();
        await skills.dispose();
        await mcp.dispose();
        await shell.dispose();
        await port.dispose();
        await directory.delete(recursive: true);
      });
      final old = coding.sendCodingPrompt('Old');
      await mcp.entered.future;
      coding.clearSession();
      expect(coding.activeStreamStore.state.isGenerating, isTrue);
      expect(
        coding.activeStreamStore.state.statusLabel,
        'Stopping previous turn…',
      );
      expect(port.isBusy, isTrue);
      expect(coding.state.messages, isEmpty);
      await coding.sendCodingPrompt('Next');
      expect(coding.state.messages, isEmpty);
      expect(coding.state.lastError, isNull);
      mcp.release.complete('Completed old handler');
      await old;
      expect(coding.state.messages, isEmpty);
      expect(coding.activeStreamStore.state.isGenerating, isFalse);
      expect(port.isBusy, isFalse);
      await coding.sendCodingPrompt('Next');
      expect(coding.state.lastError, isNull);
      expect(coding.state.messages.last.text, 'New response');
    },
  );
}
