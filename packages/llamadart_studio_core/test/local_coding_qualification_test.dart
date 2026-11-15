@Tags(<String>['local-only'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'support/coding_qualification_project.dart';

/// Runs only with an explicitly supplied, locally cached Qwen3.8 27B GGUF.
/// No downloads, fake inference, synthetic MCP transport, or remote tools.
void main() {
  final modelPath = Platform.environment['STUDIO_CODING_QUALIFICATION_MODEL'];
  const settings = StudioSettings(
    activeModelId: 'qwen3.8-27b-ud-q4-k-xl',
    preferredBackend: GpuBackend.metal,
    computeDevice: ComputeDevice.gpu,
    gpuLayers: 99,
    autoTuneHardware: false,
    contextSize: 16384,
    requestedContextSize: 16384,
    numberOfThreads: 2,
    numberOfThreadsBatch: 2,
    maxTokens: 2048,
    temperature: 0,
    thinkingEnabled: false,
  );
  final inference = DirectLlamaInferencePort();
  late _QualificationSession session;

  group(
    'real macOS Coding release qualification',
    () {
      setUpAll(() async {
        expect(Platform.isMacOS, isTrue, reason: 'This qualifies macOS Metal.');
        expect(File(modelPath!).existsSync(), isTrue);
        addTearDown(inference.dispose);
        await inference.loadModel(
          assets: ResolvedModelAssets(
            descriptor: CuratedModelCatalog.byId(settings.activeModelId!)!,
            primarySource: ModelSource.path(modelPath),
          ),
          settings: settings,
          isWeb: false,
        );
        final runtime = inference.runtimeStore.state;
        _evidence('runtime', <String, Object?>{
          'modelFile': File(modelPath).uri.pathSegments.last,
          'modelBytes': await File(modelPath).length(),
          'modelId': runtime.activeDescriptor?.id,
          'modelLabel': runtime.activeModelLabel,
          'backend': runtime.backendName,
          'gpuLayers': runtime.resolvedGpuLayers,
          'contextSize': runtime.resolvedContextSize,
          'decodeThreads': settings.numberOfThreads,
          'batchThreads': settings.numberOfThreadsBatch,
          'engineSignature': runtime.loadedEngineSignature,
          'thinkingEnabled': settings.thinkingEnabled,
        });
        expect(runtime.isReady, isTrue, reason: runtime.errorMessage);
        expect(runtime.backendName.toLowerCase(), contains('metal'));
        expect(runtime.resolvedGpuLayers, greaterThan(0));
        expect(runtime.resolvedContextSize, 16384);
        expect(runtime.supportsToolCalling, isTrue);
      });

      setUp(() async {
        session = await _QualificationSession.create(inference, settings);
        addTearDown(session.dispose);
      });

      test(
        'repairs, tests, reviews with default MCP, and reverts a real project',
        () async {
          final project = session.project;
          final baseline = await project.runTests();
          expect(baseline.exitCode, isNot(0));
          expect('${baseline.stderr}', contains('expected 0, got 499'));
          final testCommand = project.dartCommand('test/shipping_test.dart');
          final repair = await session.prompt(
            'Fix the free standard shipping boundary bug in this project. '
            'Read lib/shipping.dart and test/shipping_test.dart before editing. '
            'First reproduce the failure by running exactly `$testCommand` with '
            'bash. Make the minimal source-only correction, then run that same '
            'command again and report the actual result. Do not modify tests.',
            approvedCommands: <String>{testCommand},
          );
          expect(repair.isError, isFalse);
          final tools = repair.toolCalls;
          final editIndex = tools.indexWhere(
            (t) => t.name == 'edit' || t.name == 'write',
          );
          expect(editIndex, greaterThanOrEqualTo(0));
          expect(
            tools
                .take(editIndex)
                .where((t) => t.name == 'read')
                .map((t) => _arguments(t)['path']),
            containsAll(<String>[
              'lib/shipping.dart',
              'test/shipping_test.dart',
            ]),
          );
          final testCalls = tools.where(
            (t) => t.name == 'bash' && _arguments(t)['command'] == testCommand,
          );
          expect(testCalls.length, greaterThanOrEqualTo(2));
          expect(_result(testCalls.first)['exitCode'], isNot(0));
          expect(_result(testCalls.last)['exitCode'], 0);
          expect(
            _result(testCalls.last)['stdout'],
            contains('SHIPPING_TEST_PASS'),
          );
          final verification = await project.runTests();
          expect(verification.exitCode, 0, reason: '${verification.stderr}');
          expect('${verification.stdout}', contains('SHIPPING_TEST_PASS'));
          await session.expectProtectedFiles();
          final changed = await project.git(<String>['diff', '--name-only']);
          expect('${changed.stdout}'.trim(), 'lib/shipping.dart');
          final diff = await project.git(<String>[
            'diff',
            '--',
            'lib/shipping.dart',
          ]);
          expect('${diff.stdout}', contains('diff --git a/lib/shipping.dart'));

          final analyze = session.mcp.state.activeTools.singleWhere(
            (tool) => tool.name == 'analyze_files',
          );
          const diffCommand = 'git diff -- lib/shipping.dart';
          final review = await session.prompt(
            'Review the actual patch now. Use bash to run exactly '
            '`$diffCommand`, then use the default Dart MCP tool '
            '`${analyze.exposedToolName}` to analyze lib/shipping.dart. '
            'Register the active workspace root with the MCP server first if '
            'required. Do not change any files. Report the diff and actual '
            'analysis outcome, including any failures.',
            approvedCommands: const <String>{diffCommand},
          );
          expect(review.isError, isFalse);
          final inspected = review.toolCalls.singleWhere(
            (t) => t.name == 'bash' && _arguments(t)['command'] == diffCommand,
          );
          expect(_result(inspected)['exitCode'], 0);
          expect(
            _result(inspected)['stdout'],
            contains('diff --git a/lib/shipping.dart'),
          );
          final analyzed = review.toolCalls.where(
            (t) => t.name == analyze.exposedToolName && !t.isError,
          );
          expect(
            analyzed,
            isNotEmpty,
            reason: 'Real default MCP use is required.',
          );
          expect(analyzed.any((t) => _result(t)['isError'] != true), isTrue);
          expect(session.coding.state.lastError, isNull);

          final changes = session.coding.state.recentChanges;
          expect(changes, isNotEmpty);
          expect(
            changes.every((c) => c.relativePath == 'lib/shipping.dart'),
            isTrue,
          );
          for (final change in changes.where((c) => c.canRevert)) {
            expect(await session.coding.revertChange(change.id), isTrue);
          }
          expect(
            await project.file('lib/shipping.dart').readAsString(),
            CodingQualificationProject.originalSource,
          );
          final restored = await project.git(<String>['diff', '--exit-code']);
          expect(restored.exitCode, 0, reason: '${restored.stdout}');
          expect((await project.runTests()).exitCode, isNot(0));
          await session.expectProtectedFiles();
          _evidence('repair_review_revert', <String, Object?>{
            'baselineExit': baseline.exitCode,
            'verifiedExit': verification.exitCode,
            'reviewedDiff': diff.stdout,
            'mcpAnalysis': analyzed.map((t) => t.toJson()).toList(),
            'revertedChangeCount': changes.length,
            'restoredByteForByte': true,
          });
        },
      );

      test(
        'implements a policy across two modules, tests, reviews, and reverts',
        () async {
          final project = session.project;
          await project.enableConfigurablePolicyTest();
          const script = 'test/order_total_test.dart';
          final baseline = await project.runTests(script: script);
          expect(baseline.exitCode, isNot(0));
          expect('${baseline.stderr}', contains('freeShippingThresholdCents'));
          final command = project.dartCommand(script);
          final implementation = await session.prompt(
            'Add configurable free standard shipping to both shippingCostCents '
            'in lib/shipping.dart and orderTotalCents in lib/order_total.dart. '
            'Each API must accept an optional named int '
            'freeShippingThresholdCents defaulting to 5000. The order-total API '
            'must pass the policy to the shipping API. Standard shipping is free '
            'at or above the threshold, otherwise 499 cents; express remains '
            '1499 cents. Negative subtotals or thresholds throw ArgumentError. '
            'Read both source files and test/order_total_test.dart before editing. '
            'Modify only those two source files, preserve the protected tests, '
            'then run exactly `$command` with bash and report the actual result.',
            approvedCommands: <String>{command},
          );
          expect(implementation.isError, isFalse);
          const sourcePaths = <String>[
            'lib/shipping.dart',
            'lib/order_total.dart',
          ];
          final calls = implementation.toolCalls;
          for (final path in sourcePaths) {
            final edited = calls.indexWhere(
              (t) =>
                  (t.name == 'edit' || t.name == 'write') &&
                  _arguments(t)['path'] == path &&
                  !t.isError,
            );
            expect(
              edited,
              greaterThanOrEqualTo(0),
              reason: '$path must be edited.',
            );
            expect(
              calls
                  .take(edited)
                  .any(
                    (t) => t.name == 'read' && _arguments(t)['path'] == path,
                  ),
              isTrue,
              reason: '$path must be read before its actual edit.',
            );
          }
          final testCall = calls.lastWhere(
            (t) => t.name == 'bash' && _arguments(t)['command'] == command,
          );
          expect(_result(testCall)['exitCode'], 0);
          expect(
            _result(testCall)['stdout'],
            contains('ORDER_POLICY_TEST_PASS'),
          );
          final verification = await project.runTests(script: script);
          expect(verification.exitCode, 0, reason: '${verification.stderr}');
          expect((await project.runTests()).exitCode, 0);
          await session.expectProtectedFiles();
          final changed = await project.git(<String>['diff', '--name-only']);
          expect(
            '${changed.stdout}'.trim().split('\n'),
            unorderedEquals(sourcePaths),
          );

          const diffCommand =
              'git diff -- lib/shipping.dart lib/order_total.dart';
          final analyze = session.mcp.state.activeTools.singleWhere(
            (tool) => tool.name == 'analyze_files',
          );
          final review = await session.prompt(
            'Review both changed modules. Use bash to run exactly `$diffCommand` '
            'and use the default MCP `${analyze.exposedToolName}` tool to analyze '
            'both lib/shipping.dart and lib/order_total.dart. Register the '
            'workspace root first if required. Do not edit files. Report the '
            'actual diff and analysis outcomes.',
            approvedCommands: const <String>{diffCommand},
          );
          final inspected = review.toolCalls.singleWhere(
            (t) => t.name == 'bash' && _arguments(t)['command'] == diffCommand,
          );
          expect(_result(inspected)['exitCode'], 0);
          for (final path in sourcePaths) {
            expect(
              _result(inspected)['stdout'],
              contains('diff --git a/$path'),
            );
          }
          final analyzed = review.toolCalls.where(
            (t) =>
                t.name == analyze.exposedToolName &&
                !t.isError &&
                _result(t)['isError'] != true,
          );
          expect(analyzed, isNotEmpty);
          await session.expectProtectedFiles();

          final changes = session.coding.state.recentChanges;
          expect(
            changes.map((c) => c.relativePath).toSet(),
            sourcePaths.toSet(),
          );
          for (final change in changes.where((c) => c.canRevert)) {
            expect(await session.coding.revertChange(change.id), isTrue);
          }
          expect(
            await project.file('lib/shipping.dart').readAsString(),
            CodingQualificationProject.originalSource,
          );
          expect(
            await project.file('lib/order_total.dart').readAsString(),
            CodingQualificationProject.originalOrderSource,
          );
          final restored = await project.git(<String>['diff', '--exit-code']);
          expect(restored.exitCode, 0, reason: '${restored.stdout}');
          expect((await project.runTests(script: script)).exitCode, isNot(0));
          await session.expectProtectedFiles();
          _evidence('multifile_policy_review_revert', <String, Object?>{
            'baselineExit': baseline.exitCode,
            'verifiedExit': verification.exitCode,
            'reviewedDiff': _result(inspected)['stdout'],
            'mcpAnalysis': analyzed.map((t) => t.toJson()).toList(),
            'restoredSources': sourcePaths,
            'restoredByteForByte': true,
          });
        },
      );

      test('rejected command never executes', () async {
        final command = session.project.dartCommand('tool/approval_probe.dart');
        final response = await session.prompt(
          'Use bash to run exactly `$command` once. Do not use other tools '
          'or modify files. If approval is rejected, stop and report it; '
          'do not retry or bypass the decision.',
          rejectCommands: true,
        );
        final call = response.toolCalls.singleWhere((t) => t.name == 'bash');
        expect(_result(call)['approved'], isFalse);
        expect(_result(call)['rejected'], isTrue);
        expect(_result(call).containsKey('exitCode'), isFalse);
        expect(response.toolCalls.every((t) => t.name == 'bash'), isTrue);
        expect(session.project.file('approval-ran.txt').existsSync(), isFalse);
        expect(session.coding.state.pendingShellApproval, isNull);
        await session.expectProtectedFiles();
      });

      test(
        'Stop at approval prevents execution and a new turn reads real data',
        () async {
          final command = session.project.dartCommand(
            'tool/approval_probe.dart',
          );
          await session.prompt(
            'Use bash to run exactly `$command` once. Do not use any other tool '
            'or write files. Wait for the command approval decision.',
            cancelAtApproval: true,
          );
          expect(
            session.project.file('approval-ran.txt').existsSync(),
            isFalse,
          );
          expect(session.coding.state.pendingShellApproval, isNull);
          expect(session.coding.activeStreamStore.state.isGenerating, isFalse);
          session.coding.clearSession();
          final recovered = await session.prompt(
            'Read release.txt with the read tool and report the exact recovery '
            'token from the file. Do not run commands or change files.',
            requireApproval: false,
          );
          expect(recovered.isError, isFalse);
          expect(recovered.text, contains('CODING-RECOVERED-7319'));
          expect(
            recovered.toolCalls.any(
              (t) =>
                  t.name == 'read' &&
                  (t.resultJson?.contains('CODING-RECOVERED-7319') ?? false),
            ),
            isTrue,
          );
          expect(
            session.project.file('approval-ran.txt').existsSync(),
            isFalse,
          );
          await session.expectProtectedFiles();
        },
      );

      test(
        'approved failing command exposes its real exit code and stderr',
        () async {
          final command = session.project.dartCommand(
            'tool/expected_failure.dart',
          );
          final response = await session.prompt(
            'Run exactly `$command` once with bash. This diagnostic command '
            'intentionally fails. Report its actual numeric exit code and '
            'diagnostic. Do not retry, modify files, or describe it as successful.',
            approvedCommands: <String>{command},
          );
          final call = response.toolCalls.singleWhere((t) => t.name == 'bash');
          expect(_result(call)['exitCode'], 9);
          expect(
            _result(call)['stderr'],
            contains('EXPECTED_QUALIFICATION_FAILURE'),
          );
          expect(response.text, contains('9'));
          expect(response.text, contains('EXPECTED_QUALIFICATION_FAILURE'));
          expect(response.toolCalls.every((t) => t.name == 'bash'), isTrue);
          await session.expectProtectedFiles();
        },
      );
    },
    skip: modelPath == null
        ? 'Set STUDIO_CODING_QUALIFICATION_MODEL to a local Qwen3.8 27B GGUF.'
        : false,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

class _QualificationSession {
  _QualificationSession({
    required this.project,
    required this.shell,
    required this.mcp,
    required this.skills,
    required this.coding,
  });

  final CodingQualificationProject project;
  final StudioShellController shell;
  final McpManager mcp;
  final SkillRegistry skills;
  final CodingWorkspaceController coding;

  static Future<_QualificationSession> create(
    DirectLlamaInferencePort inference,
    StudioSettings settings,
  ) async {
    final project = await CodingQualificationProject.create();
    final kv = InMemoryKeyValueStore();
    final shell = StudioShellController(keyValueStore: kv);
    final mcp = McpManager(keyValueStore: kv);
    final skills = SkillRegistry(keyValueStore: kv);
    final coding = CodingWorkspaceController(
      inferencePort: inference,
      shellController: shell,
      keyValueStore: kv,
      mcpManager: mcp,
      skillRegistry: skills,
    );
    final session = _QualificationSession(
      project: project,
      shell: shell,
      mcp: mcp,
      skills: skills,
      coding: coding,
    );
    try {
      await shell.initialize();
      await shell.updateSettings((_) => settings);
      await skills.initialize();
      await mcp.initialize();
      await coding.initialize(autoDetectDefaultRoot: false);
      await coding.setWorkspaceRoot(project.root.path);
      expect(coding.state.lastError, isNull);
      expect(coding.state.allowShellCommandTool, isFalse);
      expect(coding.state.confirmShellCommands, isTrue);
      expect(
        coding.buildCodingTools().map((t) => t.name),
        isNot(contains('bash')),
      );
      expect(skills.state.activeSkills.map((s) => s.id), <String>[
        'builtin:dart-flutter-engineer',
      ]);
      await mcp.ensureBuiltInDartFlutterServer(
        workspaceRoot: project.root.path,
        autoConnect: false,
      );
      final server = await mcp.connectServer(
        McpManager.builtInDartFlutterServerId,
      );
      expect(server.isConnected, isTrue, reason: server.errorMessage);
      expect(server.config.args, <String>['mcp-server']);
      expect(server.config.enabled, isTrue);
      expect(server.config.hasCustomToolFilter, isFalse);
      expect(
        server.config.disabledTools,
        McpManager.defaultDisabledBuiltInDartTools,
      );
      expect(
        mcp.state.activeTools.map((t) => t.name),
        contains('analyze_files'),
      );
      _evidence('defaults', <String, Object?>{
        'skills': skills.state.activeSkills.map((s) => s.id).toList(),
        'mcpCommand': server.config.command,
        'mcpArguments': server.config.args,
        'mcpTools': mcp.state.activeTools
            .map((t) => t.exposedToolName)
            .toList(),
        'disabledMcpTools': server.config.disabledTools,
        'shellInitiallyEnabled': coding.state.allowShellCommandTool,
        'confirmShellCommands': coding.state.confirmShellCommands,
      });
      coding.setAllowShellCommandTool(true);
      return session;
    } catch (_) {
      await session.dispose();
      rethrow;
    }
  }

  Future<StudioMessage> prompt(
    String text, {
    Set<String> approvedCommands = const <String>{},
    bool rejectCommands = false,
    bool cancelAtApproval = false,
    bool requireApproval = true,
  }) async {
    final decisions = <Map<String, Object?>>[];
    final unexpected = <String>[];
    final seen = <String>{};
    final subscription = coding.store.stream.listen((state) {
      final pending = state.pendingShellApproval;
      if (pending == null || !seen.add(pending.id)) return;
      final controlledRoot = pending.workspaceRoot == project.root.path;
      final approved =
          controlledRoot && approvedCommands.contains(pending.command);
      if (!controlledRoot ||
          (!approved && !rejectCommands && !cancelAtApproval)) {
        unexpected.add(pending.command);
      }
      decisions.add(<String, Object?>{
        'command': pending.command,
        'approved': approved && !rejectCommands && !cancelAtApproval,
        'cancelled': cancelAtApproval,
      });
      if (cancelAtApproval) {
        coding.cancelGeneration();
      } else {
        coding.resolveShellCommandApproval(approved && !rejectCommands);
      }
    });
    try {
      await coding.sendCodingPrompt(text);
    } finally {
      await subscription.cancel();
      _evidence('turn', <String, Object?>{
        'prompt': text,
        'approvalDecisions': decisions,
        'lastError': coding.state.lastError,
        'messages': coding.state.messages.map((m) => m.toJson()).toList(),
      });
    }
    expect(
      unexpected,
      isEmpty,
      reason: 'Only explicit fixture commands are approved.',
    );
    if (requireApproval) expect(decisions, isNotEmpty);
    expect(coding.activeStreamStore.state.isGenerating, isFalse);
    final assistant = coding.state.messages.last;
    expect(assistant.role, StudioRole.assistant);
    if (!cancelAtApproval) expect(coding.state.lastError, isNull);
    return assistant;
  }

  Future<void> expectProtectedFiles() async {
    for (final entry in project.expectedProtectedFiles.entries) {
      expect(
        await project.file(entry.key).readAsString(),
        entry.value,
        reason: '${entry.key} must remain unchanged.',
      );
    }
  }

  Future<void> dispose() async {
    coding.cancelGeneration();
    await coding.dispose();
    await skills.dispose();
    await mcp.dispose();
    await shell.dispose();
    await project.dispose();
  }
}

Map<String, dynamic> _arguments(StudioToolInvocation call) =>
    jsonDecode(call.argumentsJson) as Map<String, dynamic>;

Map<String, dynamic> _result(StudioToolInvocation call) =>
    jsonDecode(call.resultJson!) as Map<String, dynamic>;

void _evidence(String phase, Map<String, Object?> data) {
  print(
    'STUDIO_CODING_QUALIFICATION ${jsonEncode(<String, Object?>{'phase': phase, ...data})}',
  );
}
