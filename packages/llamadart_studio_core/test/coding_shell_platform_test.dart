import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final available in [true, false]) {
    test(
      'local process policy $available preserves file and network tools',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final inference = FakeInferencePort();
        final mcp = _NetworkMcp(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final root = await Directory.systemTemp.createTemp(
          'studio_process_policy_',
        );
        final controller = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: mcp,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
          localProcessExecutionAvailable: available,
        );
        addTearDown(() async {
          await controller.dispose();
          await skills.dispose();
          await mcp.dispose();
          await inference.dispose();
          await shell.dispose();
          await root.delete(recursive: true);
        });
        await controller.setWorkspaceRoot(root.path);
        controller.setAllowShellCommandTool(true);
        controller.setAllowShellCommandTool(true);
        expect(controller.state.allowShellCommandTool, available);
        final tools = controller.buildCodingTools();
        expect(tools.any((tool) => tool.name == 'bash'), available);
        expect(tools.any((tool) => tool.name == 'read'), isTrue);
        final network = tools.singleWhere(
          (tool) => tool.name == 'network_docs',
        );
        expect(await network.invoke({}), 'network response');
        controller.setAllowShellCommandTool(false);
        expect(
          controller.buildCodingTools().any((tool) => tool.name == 'bash'),
          isFalse,
        );
      },
    );
  }

  test(
    'coding commands use an OS-provided shell in the selected workspace',
    () async {
      final root = await Directory.systemTemp.createTemp('studio shell ');
      addTearDown(() => root.delete(recursive: true));
      final shell = await CodingWorkspaceFs.runCommand(
        root.path,
        Platform.isWindows ? 'echo %COMSPEC%' : r'''printf '%s' "$0"''',
      );
      expect(shell.exitCode, 0, reason: shell.stderr);
      if (Platform.isWindows) {
        expect(shell.stdout.trim().toLowerCase(), endsWith(r'\cmd.exe'));
      } else {
        expect(shell.stdout.trim(), Platform.isMacOS ? '/bin/zsh' : '/bin/sh');
      }
      final cwd = await CodingWorkspaceFs.runCommand(
        root.path,
        Platform.isWindows ? 'cd' : 'pwd',
      );
      expect(cwd.exitCode, 0, reason: cwd.stderr);
      expect(
        Directory(cwd.stdout.trim()).resolveSymbolicLinksSync(),
        root.resolveSymbolicLinksSync(),
      );
    },
  );
}

class _NetworkMcp extends McpManager {
  _NetworkMcp({required super.keyValueStore});

  @override
  List<ToolDefinition> buildActiveToolDefinitions() => [
    ToolDefinition(
      name: 'network_docs',
      description: 'Connected network documentation',
      parameters: [],
      handler: (_) async => 'network response',
    ),
  ];
}
