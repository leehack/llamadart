@TestOn('browser')
library;

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final explicitEnable in [false, true]) {
    test(
      'Web cannot enable shell with explicit policy=$explicitEnable',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final inference = FakeInferencePort();
        final mcp = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final controller = explicitEnable
            ? CodingWorkspaceController(
                inferencePort: inference,
                shellController: shell,
                keyValueStore: kv,
                mcpManager: mcp,
                skillRegistry: skills,
                localProcessExecutionAvailable: true,
              )
            : CodingWorkspaceController(
                inferencePort: inference,
                shellController: shell,
                keyValueStore: kv,
                mcpManager: mcp,
                skillRegistry: skills,
              );
        addTearDown(() async {
          await controller.dispose();
          await skills.dispose();
          await mcp.dispose();
          await inference.dispose();
          await shell.dispose();
        });
        expect(CodingWorkspaceFs.localProcessExecutionAvailable, isFalse);
        controller.setAllowShellCommandTool(true);
        controller.setAllowShellCommandTool(true);
        expect(controller.state.allowShellCommandTool, isFalse);
      },
    );
  }
}
