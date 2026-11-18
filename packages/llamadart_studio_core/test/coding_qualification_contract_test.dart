import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'support/coding_qualification_project.dart';

void main() {
  test(
    'shipping qualification detects a real regression and restoration',
    () async {
      final project = await CodingQualificationProject.create();
      addTearDown(project.dispose);
      final baseline = await project.runTests();
      expect(baseline.exitCode, isNot(0));
      expect('${baseline.stderr}', contains('expected 0, got 499'));
      await project.write(
        'lib/shipping.dart',
        CodingQualificationProject.fixedSource,
      );
      final corrected = await project.runTests();
      expect(corrected.exitCode, 0, reason: '${corrected.stderr}');
      expect('${corrected.stdout}', contains('7 boundary and policy checks'));
      await project.write(
        'lib/shipping.dart',
        CodingQualificationProject.originalSource,
      );
      expect((await project.runTests()).exitCode, isNot(0));
    },
  );

  test(
    'configurable shipping qualification needs both source implementations',
    () async {
      final project = await CodingQualificationProject.create();
      addTearDown(project.dispose);
      await project.enableConfigurablePolicyTest();
      const script = 'test/order_total_test.dart';
      expect((await project.runTests(script: script)).exitCode, isNot(0));
      await project.write(
        'lib/shipping.dart',
        CodingQualificationProject.configurableShippingSource,
      );
      expect((await project.runTests(script: script)).exitCode, isNot(0));
      await project.write(
        'lib/order_total.dart',
        CodingQualificationProject.configurableOrderSource,
      );
      final complete = await project.runTests(script: script);
      expect(complete.exitCode, 0, reason: '${complete.stderr}');
      expect('${complete.stdout}', contains('ORDER_POLICY_TEST_PASS'));
      await project.write(
        'lib/shipping.dart',
        CodingQualificationProject.originalSource,
      );
      expect((await project.runTests(script: script)).exitCode, isNot(0));
    },
  );

  test(
    'built-in skill tool instructions match the executable Coding surface',
    () async {
      final project = await CodingQualificationProject.create();
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      final inference = DirectLlamaInferencePort();
      final skills = SkillRegistry(keyValueStore: kv);
      final mcp = McpManager(keyValueStore: kv);
      final coding = CodingWorkspaceController(
        inferencePort: inference,
        shellController: shell,
        keyValueStore: kv,
        mcpManager: mcp,
        skillRegistry: skills,
      );
      addTearDown(() async {
        await coding.dispose();
        await mcp.dispose();
        await skills.dispose();
        await inference.dispose();
        await shell.dispose();
        await project.dispose();
      });
      await skills.initialize();
      await coding.setWorkspaceRoot(project.root.path);
      expect(skills.state.activeSkills.map((skill) => skill.id), <String>[
        'builtin:dart-flutter-engineer',
      ]);
      expect(coding.state.allowShellCommandTool, isFalse);
      expect(coding.state.confirmShellCommands, isTrue);
      expect(
        coding.buildCodingTools().map((tool) => tool.name),
        isNot(contains('bash')),
      );
      coding.setAllowShellCommandTool(true);
      final executableNames = coding
          .buildCodingTools()
          .map((tool) => tool.name)
          .toSet();
      for (final skill in skills.state.skills.where(
        (skill) => skill.isBuiltIn,
      )) {
        // `dispose` names a Dart lifecycle method; the remaining lowercase
        // code identifiers name Coding tool primitives.
        final references = RegExp(r'`([a-z][a-z_]*)`')
            .allMatches(skill.instructions)
            .map((match) => match.group(1)!)
            .where((name) => name != 'dispose');
        for (final name in references) {
          expect(
            executableNames,
            contains(name),
            reason: '${skill.name}: $name',
          );
        }
      }
      expect(coding.state.confirmShellCommands, isTrue);
    },
  );
}
