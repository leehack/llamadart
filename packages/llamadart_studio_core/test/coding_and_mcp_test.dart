import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  group('CodingWorkspaceFs & CodingWorkspaceController', () {
    late Directory repoDir;
    late Directory outsideDir;

    setUp(() async {
      repoDir = await Directory.systemTemp.createTemp('studio_coding_repo_');
      outsideDir = await Directory.systemTemp.createTemp('studio_outside_');
      await File('${outsideDir.path}/secret.txt').writeAsString('TOP_SECRET');
    });

    tearDown(() async {
      if (await repoDir.exists()) {
        await repoDir.delete(recursive: true);
      }
      if (await outsideDir.exists()) {
        await outsideDir.delete(recursive: true);
      }
    });

    test(
      'enforces path traversal & symlink sandbox and executes write/patch/search/command tools',
      () async {
        await File('${repoDir.path}/lib/greeter.dart').create(recursive: true);
        await File('${repoDir.path}/lib/greeter.dart').writeAsString(
          'String greet(String name) {\n  return "Hello \$name";\n}\n',
        );
        await Link(
          '${repoDir.path}/escape_link.txt',
        ).create('${outsideDir.path}/secret.txt');

        await expectLater(
          CodingWorkspaceFs.readFile(repoDir.path, '../outside/secret.txt'),
          throwsArgumentError,
        );
        await expectLater(
          CodingWorkspaceFs.readFile(repoDir.path, 'escape_link.txt'),
          throwsArgumentError,
        );

        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final mcp = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final inference = FakeInferencePort();
        final controller = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: mcp,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
        );
        await controller.initialize(autoDetectDefaultRoot: false);

        await File(
          '${repoDir.path}/AGENTS.md',
        ).writeAsString('Always verify Dart code with dart analyze.');
        await File('${repoDir.path}/.agents/mcp.json').create(recursive: true);
        await File('${repoDir.path}/.agents/mcp.json').writeAsString(
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'local-tools': <String, Object?>{
                'command': 'dart',
                'args': <String>['mcp-server'],
              },
            },
          }),
        );

        await controller.setWorkspaceRoot(repoDir.path);
        expect(controller.state.agentsContext.hasInstructions, isTrue);
        expect(
          controller.state.agentsContext.sourceFiles,
          contains('AGENTS.md'),
        );
        expect(
          mcp.state.servers.any(
            (McpServerRuntimeState s) =>
                s.config.isProjectScoped && s.config.name == 'local-tools',
          ),
          isTrue,
        );

        await controller.openFile('lib/greeter.dart');
        expect(controller.state.selectedFileSlice?.content, contains('Hello'));

        final tools = controller.buildCodingTools();
        final byName = <String, ToolDefinition>{
          for (final t in tools) t.name: t,
        };
        expect(
          byName.keys,
          containsAll(<String>['ls', 'read', 'grep', 'write', 'edit']),
        );
        expect(
          controller.state.activeCoreTools,
          containsAll(<String>['ls', 'read', 'grep', 'write', 'edit']),
        );
        expect(byName.containsKey('bash'), isFalse);

        // Edit file via pi.dev-style `edit` tool handler and check diff audit entry.
        final patchRes =
            await byName['edit']!.invoke(<String, dynamic>{
                  'path': 'lib/greeter.dart',
                  'findText': 'Hello',
                  'replaceText': 'Hi',
                })
                as Map<String, Object?>;
        expect(patchRes['status'], 'patched');
        expect(controller.state.recentChanges, isNotEmpty);
        expect(
          await File('${repoDir.path}/lib/greeter.dart').readAsString(),
          contains('Hi \$name'),
        );

        // `grep` finds updated symbol.
        final searchRes =
            await byName['grep']!.invoke(<String, dynamic>{
                  'query': 'Hi \$name',
                })
                as Map<String, Object?>;
        expect((searchRes['matches'] as List<Object?>), isNotEmpty);

        // Shell `bash` tool gated until enabled, and pauses for confirmation by default.
        controller.setAllowShellCommandTool(true);
        expect(controller.state.activeCoreTools, contains('bash'));
        expect(controller.state.confirmShellCommands, isTrue);
        final withShell = controller.buildCodingTools();
        final runCmd = withShell.firstWhere(
          (ToolDefinition t) => t.name == 'bash',
        );

        final pendingFuture = runCmd.invoke(<String, dynamic>{
          'command': 'echo sandbox_ok',
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.state.pendingShellApproval?.command,
          'echo sandbox_ok',
        );
        controller.resolveShellCommandApproval(true);
        final cmdOut = await pendingFuture as Map<String, Object?>;
        expect(cmdOut['exitCode'], 0);
        expect(cmdOut['stdout'].toString().trim(), 'sandbox_ok');
        expect(controller.state.pendingShellApproval, isNull);

        // Rejecting a pending bash invocation cancels execution cleanly.
        final deniedFuture = runCmd.invoke(<String, dynamic>{
          'command': 'echo should_not_run',
        });
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.pendingShellApproval, isNotNull);
        controller.resolveShellCommandApproval(false);
        final deniedOut = await deniedFuture as Map<String, Object?>;
        expect(deniedOut['approved'], isFalse);
        expect(deniedOut['rejected'], isTrue);

        // Turning off confirmation runs directly.
        controller.setConfirmShellCommands(false);
        final directOut =
            await runCmd.invoke(<String, dynamic>{'command': 'echo direct_ok'})
                as Map<String, Object?>;
        expect(directOut['stdout'].toString().trim(), 'direct_ok');

        await controller.dispose();
        await skills.dispose();
        await mcp.dispose();
        await shell.dispose();
        await inference.dispose();
      },
    );
  });

  group('SkillRegistry (SKILL.md)', () {
    late Directory wsDir;

    setUp(() async {
      wsDir = await Directory.systemTemp.createTemp('studio_skills_ws_');
    });

    tearDown(() async {
      if (await wsDir.exists()) {
        await wsDir.delete(recursive: true);
      }
    });

    test(
      'discovers workspace .agents/skills/SKILL.md and compiles active prompt block',
      () async {
        final skillFile = File(
          '${wsDir.path}/.agents/skills/perf-audit/SKILL.md',
        );
        await skillFile.create(recursive: true);
        await skillFile.writeAsString(
          '---\nname: perf-audit\ndescription: Audit allocations and frame timings.\nlicense: MIT\n---\n\nAlways measure allocations before optimizing.\n',
        );

        final kv = InMemoryKeyValueStore();
        final registry = SkillRegistry(keyValueStore: kv);
        await registry.initialize(workspaceRoot: wsDir.path);

        final found = registry.state.skills.firstWhere(
          (StudioSkill s) => s.name == 'perf-audit',
        );
        expect(found.isDiscovered, isTrue);
        expect(found.license, 'MIT');

        await registry.setSkillEnabled(found.id, true);
        final block = registry.buildActiveSkillsSystemContext();
        expect(block, contains('perf-audit'));
        expect(
          block,
          contains('Always measure allocations before optimizing.'),
        );

        await registry.dispose();
      },
    );
  });

  group('McpManager (live mcp_dart stdio integration)', () {
    late Directory mcpTempDir;

    setUp(() async {
      mcpTempDir = await Directory.systemTemp.createTemp('studio_mcp_live_');
    });

    tearDown(() async {
      if (await mcpTempDir.exists()) {
        await mcpTempDir.delete(recursive: true);
      }
    });

    test('rejects discovery budgets that leave no handshake time', () {
      for (final discovery in [Duration.zero, const Duration(seconds: 45)]) {
        expect(
          () => McpManager(
            keyValueStore: InMemoryKeyValueStore(),
            discoveryTimeout: discovery,
          ),
          throwsArgumentError,
        );
      }
    });

    test('sanitizes external MCP tool JSON schemas cleanly', () {
      final sanitized = McpManager.sanitizeMcpInputSchema(<String, dynamic>{
        'title': 'EchoArgs',
        'properties': <String, Object?>{
          'message': <String, Object?>{
            'type': 'string',
            'format': 'custom-unsupported',
            'description': 'Message to echo',
          },
        },
        'required': <String>['message'],
        '\$defs': <String, Object?>{'Unused': <String, Object?>{}},
      });
      expect(sanitized['type'], 'object');
      expect(sanitized.containsKey(r'$defs'), isFalse);
      final msgProp =
          (sanitized['properties'] as Map<String, dynamic>)['message']
              as Map<String, dynamic>;
      expect(msgProp['type'], 'string');
      expect(msgProp.containsKey('format'), isFalse);
    });

    test(
      'connects to a slow-starting stdio server, lists/calls tools, and reads resources',
      () async {
        final serverScript = File('${mcpTempDir.path}/echo_mcp_server.dart');
        await serverScript.writeAsString('''
import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';

Future<void> main() async {
  final server = McpServer(
    const Implementation(name: 'studio-test-mcp', version: '1.0.0'),
  );
  server.registerTool(
    'echo_upper',
    description: 'Echoes text in uppercase.',
    inputSchema: ToolInputSchema(
      properties: <String, JsonSchema>{
        'text': JsonSchema.string(description: 'Input text'),
      },
      required: <String>['text'],
    ),
    callback: (args, extra) async {
      final text = (args['text'] as String?) ?? '';
      return CallToolResult(
        content: <Content>[TextContent(text: text.toUpperCase())],
      );
    },
  );
  server.registerResource(
    'release-notes',
    'studio://notes/release',
    (
      description: 'Test release note resource',
      mimeType: 'text/plain',
    ),
    (uri, extra) async {
      return ReadResourceResult(
        contents: <ResourceContents>[
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: 'MCP stdio resource payload OK',
          ),
        ],
      );
    },
  );
  // Cross the SDK's default discovery deadline to exercise cold-start handling.
  await Future<void>.delayed(const Duration(seconds: 6));
  final transport = StdioServerTransport();
  await server.connect(transport);
}
''');

        final pkgConfig = File(
          '${Directory.current.path}/.dart_tool/package_config.json',
        );
        expect(pkgConfig.existsSync(), isTrue);

        final kv = InMemoryKeyValueStore();
        final manager = McpManager(keyValueStore: kv);
        addTearDown(manager.dispose);
        await manager.initialize();

        const config = McpServerConfig(
          id: 'live-echo',
          name: 'Live Echo MCP',
          transportType: McpTransportType.stdio,
          command: null,
        );
        final effectiveConfig = config.copyWith(
          command: Platform.resolvedExecutable,
          args: <String>['--packages=${pkgConfig.path}', serverScript.path],
        );
        await manager.saveServer(effectiveConfig);
        final results = await Future.wait<McpServerRuntimeState>(
          <Future<McpServerRuntimeState>>[
            manager.connectServer(effectiveConfig.id),
            manager.connectServer(effectiveConfig.id),
          ],
        );
        final runtime = results.first;
        expect(results.last.isConnected, isTrue);

        expect(runtime.isConnected, isTrue);
        expect(
          runtime.tools.map((McpToolDescriptor t) => t.name),
          contains('echo_upper'),
        );
        expect(
          runtime.resources.map((McpResourceDescriptor r) => r.uri),
          contains('studio://notes/release'),
        );

        // Invoke through bridged llamadart ToolDefinition.
        final bridged = manager.buildActiveToolDefinitions();
        expect(bridged, hasLength(1));
        final bridgedRes =
            await bridged.single.invoke(<String, dynamic>{
                  'text': 'llamadart mcp',
                })
                as Map<String, Object?>;
        expect(bridgedRes['text'], 'LLAMADART MCP');
        expect(bridgedRes['isError'], isFalse);

        // Read resource text.
        final resText = await manager.readResource(
          serverId: effectiveConfig.id,
          uri: 'studio://notes/release',
        );
        expect(resText, contains('MCP stdio resource payload OK'));
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'coerces canonical JSON Schema tools (anyOf/const/type-list/minItems) to legacy ToolParams and compacts verbose docs',
      () {
        final complex = McpToolDescriptor(
          serverId: 'dart',
          serverName: 'Dart & Flutter MCP',
          name: 'flutter_driver_command',
          exposedToolName: 'flutter_driver_command',
          description: '${'Verbose docs ' * 30}end.',
          inputSchema: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'target': <String, Object?>{
                'anyOf': <Object?>[
                  <String, Object?>{'type': 'null'},
                  <String, Object?>{
                    'type': 'string',
                    'minLength': 1,
                    'description':
                        '${'Detailed target explanation ' * 12}done.',
                  },
                ],
              },
              'flags': <String, Object?>{
                'type': 'array',
                'minItems': 1,
                'items': <String, Object?>{'type': 'string'},
              },
              'mode': <String, Object?>{'const': 'fast'},
              'count': <String, Object?>{
                'type': <Object?>['integer', 'null'],
              },
            },
            'required': <String>['target'],
          },
        );
        final canonical = McpManager.toLlamaToolDefinition(
          complex,
          handler: (ToolParams params) async => params.raw,
        );
        expect(canonical.description.length, lessThanOrEqualTo(210));
        final legacy = McpManager.coerceToLegacyToolDefinition(canonical);
        expect(legacy.parameters, hasLength(4));
        expect(
          legacy.parameters.map((ToolParam p) => p.name),
          containsAll(<String>['target', 'flags', 'mode', 'count']),
        );
        final schema = legacy.toJsonSchema();
        final props = schema['properties'] as Map<String, dynamic>;
        expect(
          ((props['target'] as Map<String, dynamic>)['description'] as String)
              .length,
          lessThanOrEqualTo(125),
        );
      },
    );
  });

  group('ProjectContextDiscovery & Built-in/Project MCP sync', () {
    late Directory wsDir;

    setUp(() async {
      wsDir = await Directory.systemTemp.createTemp('studio_ctx_disc_');
    });

    tearDown(() async {
      if (await wsDir.exists()) {
        await wsDir.delete(recursive: true);
      }
    });

    test(
      'discovers AGENTS.md, .agents/AGENTS.md, CLAUDE.md and MCP configs from .agents/.mcp/.vscode',
      () async {
        await File(
          '${wsDir.path}/AGENTS.md',
        ).writeAsString('# Root Instructions\nUse Riverpod.');
        await File('${wsDir.path}/.agents/AGENTS.md').create(recursive: true);
        await File(
          '${wsDir.path}/.agents/AGENTS.md',
        ).writeAsString('# Subfolder Rules\nPrefer immutable state.');
        await File(
          '${wsDir.path}/CLAUDE.md',
        ).writeAsString('Run dart format before handoff.');

        final agents = await discoverProjectAgentsContext(wsDir.path);
        expect(agents.hasInstructions, isTrue);
        expect(agents.primaryPath, 'AGENTS.md');
        expect(
          agents.sourceFiles,
          equals(<String>[
            'AGENTS.md',
            p.join('.agents', 'AGENTS.md'),
            'CLAUDE.md',
          ]),
        );
        expect(agents.instructions, contains('Use Riverpod.'));
        expect(agents.instructions, contains('Prefer immutable state.'));
        expect(agents.instructions, contains('Run dart format'));

        // Discover project MCP configs across .agents/mcp.json, .mcp.json,
        // .vscode/mcp.json, and .agents/mcp/*.json.
        await File('${wsDir.path}/.agents/mcp.json').writeAsString(
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'sqlite-local': <String, Object?>{
                'command': 'uvx',
                'args': <String>['mcp-server-sqlite'],
              },
            },
          }),
        );
        await File('${wsDir.path}/.mcp.json').writeAsString(
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'remote-docs': <String, Object?>{
                'url': 'https://mcp.example.com/stream',
                'transport': 'http',
              },
            },
          }),
        );
        await File('${wsDir.path}/.vscode/mcp.json').create(recursive: true);
        await File('${wsDir.path}/.vscode/mcp.json').writeAsString(
          jsonEncode(<String, Object?>{
            'servers': <String, Object?>{
              'vscode-helper': <String, Object?>{
                'command': 'node',
                'args': <String>['helper.js'],
              },
            },
          }),
        );
        await File(
          '${wsDir.path}/.agents/mcp/custom.json',
        ).create(recursive: true);
        await File('${wsDir.path}/.agents/mcp/custom.json').writeAsString(
          jsonEncode(<String, Object?>{
            'command': 'python3',
            'args': <String>['-m', 'custom_mcp'],
          }),
        );

        final discoveredMcp = await discoverProjectMcpConfigs(wsDir.path);
        final names = discoveredMcp.map((McpServerConfig c) => c.name).toSet();
        expect(
          names,
          containsAll(<String>[
            'sqlite-local',
            'remote-docs',
            'vscode-helper',
            'custom',
          ]),
        );
        final remote = discoveredMcp.firstWhere(
          (McpServerConfig c) => c.name == 'remote-docs',
        );
        expect(remote.transportType, McpTransportType.streamableHttp);
        expect(remote.origin, McpServerOrigin.project);
      },
    );

    test(
      'McpManager registers built-in Dart & Flutter MCP and syncs workspace servers',
      () async {
        final kv = InMemoryKeyValueStore();
        final manager = McpManager(keyValueStore: kv);
        await manager.initialize();

        await manager.ensureBuiltInDartFlutterServer(
          workspaceRoot: wsDir.path,
          autoConnect: false,
        );
        final dartExec = await resolveHostExecutable('dart');
        if (dartExec != null) {
          final builtIn = manager.state.servers.firstWhere(
            (McpServerRuntimeState s) =>
                s.config.id == McpManager.builtInDartFlutterServerId,
          );
          expect(builtIn.config.isBuiltIn, isTrue);
          expect(builtIn.config.args, equals(<String>['mcp-server']));
        }

        await File('${wsDir.path}/.agents/mcp.json').create(recursive: true);
        await File('${wsDir.path}/.agents/mcp.json').writeAsString(
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'repo-mcp': <String, Object?>{
                'command': 'dart',
                'args': <String>['run', 'bin/mcp.dart'],
              },
            },
          }),
        );
        await manager.syncWorkspaceServers(wsDir.path, autoConnect: false);
        expect(
          manager.state.servers.any(
            (McpServerRuntimeState s) =>
                s.config.isProjectScoped && s.config.name == 'repo-mcp',
          ),
          isTrue,
        );

        await manager.dispose();
      },
    );
  });

  group('Coding agent optimizations, diff revert & MCP security', () {
    test(
      'McpServerConfig & McpManager filter built-in noisy Dart tools and toggle per-tool exposure',
      () async {
        const defaultBuiltIn = McpServerConfig(
          id: McpManager.builtInDartFlutterServerId,
          name: 'Dart & Flutter MCP',
          transportType: McpTransportType.stdio,
          command: 'dart',
          args: <String>['mcp-server'],
          disabledTools: McpManager.defaultDisabledBuiltInDartTools,
        );
        expect(defaultBuiltIn.hasCustomToolFilter, isFalse);
        expect(defaultBuiltIn.isToolEnabled('hot_reload'), isFalse);
        expect(defaultBuiltIn.isToolEnabled('dtd'), isFalse);
        expect(defaultBuiltIn.isToolEnabled('analyze_files'), isTrue);

        final stateWithBuiltIn = McpManagerState(
          servers: <McpServerRuntimeState>[
            McpServerRuntimeState(
              config: defaultBuiltIn,
              status: McpConnectionStatus.connected,
              tools: const <McpToolDescriptor>[
                McpToolDescriptor(
                  serverId: McpManager.builtInDartFlutterServerId,
                  serverName: 'Dart & Flutter MCP',
                  name: 'analyze_files',
                  exposedToolName: 'mcp_dart_analyze_files',
                  description: 'Analyze files',
                ),
                McpToolDescriptor(
                  serverId: McpManager.builtInDartFlutterServerId,
                  serverName: 'Dart & Flutter MCP',
                  name: 'hot_reload',
                  exposedToolName: 'mcp_dart_hot_reload',
                  description: 'Hot reload',
                ),
                McpToolDescriptor(
                  serverId: McpManager.builtInDartFlutterServerId,
                  serverName: 'Dart & Flutter MCP',
                  name: 'dtd',
                  exposedToolName: 'mcp_dart_dtd',
                  description: 'DTD',
                ),
              ],
            ),
          ],
        );
        expect(
          stateWithBuiltIn.activeTools.map((McpToolDescriptor t) => t.name),
          equals(<String>['analyze_files']),
        );

        final kv = InMemoryKeyValueStore();
        final manager = McpManager(keyValueStore: kv);
        await manager.initialize();
        await manager.saveServer(defaultBuiltIn);

        // Test setToolEnabled customizes filter explicitly.
        await manager.setToolEnabled(
          McpManager.builtInDartFlutterServerId,
          'hot_reload',
          true,
        );
        final updated = manager.state.servers.firstWhere(
          (McpServerRuntimeState s) =>
              s.config.id == McpManager.builtInDartFlutterServerId,
        );
        expect(updated.config.hasCustomToolFilter, isTrue);
        expect(updated.config.isToolEnabled('hot_reload'), isTrue);

        await manager.setToolEnabled(
          McpManager.builtInDartFlutterServerId,
          'analyze_files',
          false,
        );
        final updated2 = manager.state.servers.firstWhere(
          (McpServerRuntimeState s) =>
              s.config.id == McpManager.builtInDartFlutterServerId,
        );
        expect(updated2.config.isToolEnabled('analyze_files'), isFalse);

        await manager.dispose();
      },
    );

    test(
      'CodingWorkspaceController prioritizes Qwen3.8, budgets oversized AGENTS.md, and throttles streaming deltas',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'coding_budget_test_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final hugeAgents = List<String>.filled(1000, 'Rule line X.').join(' ');
        await File('${tempDir.path}/AGENTS.md').writeAsString(hugeAgents);

        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final mcp = McpManager(keyValueStore: kv);
        await mcp.initialize();
        final skills = SkillRegistry(keyValueStore: kv);
        await skills.initialize();

        final inference = FakeInferencePort()
          ..nextEvents = <StudioTurnEvent>[
            for (var i = 0; i < 20; i++) StudioTextDeltaEvent('tok$i '),
            StudioTurnCompletedEvent(
              StudioTurnResult(
                text: List<String>.generate(20, (int i) => 'tok$i ').join(),
                metrics: const StudioTurnMetrics(
                  generatedTokens: 20,
                  elapsedMs: 40,
                  decodeElapsedMs: 35,
                ),
              ),
            ),
          ];

        final coding = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: mcp,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
        );
        await coding.initialize(autoDetectDefaultRoot: false);

        expect(
          CodingWorkspaceController.recommendedCodingModels.first.id,
          'qwen3.8-27b-ud-q4-k-xl',
        );
        expect(
          CodingWorkspaceController.recommendedCodingModels[1].id,
          'qwen3.6-27b-ud-q4-k-xl',
        );

        await coding.setWorkspaceRoot(tempDir.path);
        expect(
          coding.state.agentsContext.instructions.length,
          greaterThan(3600),
        );

        var streamUpdates = 0;
        final sub = coding.activeStreamStore.stream.listen(
          (_) => streamUpdates++,
        );
        await coding.sendCodingPrompt('Check project rules');
        await sub.cancel();

        // Prompt receives budgeted AGENTS.md excerpt instead of full 13KB+ blob.
        final extraContext = inference.lastRequest!.extraSystemContext;
        expect(extraContext, contains('truncated for fast prompt evaluation'));
        expect(extraContext.length, lessThan(6000));

        // 20 rapid synchronous deltas are coalesced by 40ms stream throttle.
        expect(streamUpdates, lessThan(10));

        await coding.dispose();
        await skills.dispose();
        await mcp.dispose();
        await shell.dispose();
        await inference.dispose();
      },
    );

    test(
      'McpManager gates repo .mcp.json servers behind workspace trust before spawning',
      () async {
        final tempRepo = await Directory.systemTemp.createTemp(
          'untrusted_mcp_repo_',
        );
        addTearDown(() async {
          if (await tempRepo.exists()) {
            await tempRepo.delete(recursive: true);
          }
        });
        await File('${tempRepo.path}/.mcp.json').writeAsString(
          jsonEncode(<String, Object>{
            'mcpServers': <String, Object>{
              'repo_helper': <String, Object>{
                'command': 'dart',
                'args': <String>['--version'],
              },
            },
          }),
        );

        var transportSpawnAttempts = 0;
        final kv = InMemoryKeyValueStore();
        final mcp = McpManager(
          keyValueStore: kv,
          transportBuilder: (McpServerConfig config) {
            transportSpawnAttempts++;
            throw StateError('Mock transport intercepted spawn');
          },
        );
        await mcp.initialize();

        // Discovering an untrusted workspace registers the server in
        // disconnected state and NEVER spawns the command automatically.
        expect(mcp.isWorkspaceTrusted(tempRepo.path), isFalse);
        await mcp.syncWorkspaceServers(tempRepo.path, autoConnect: true);
        expect(transportSpawnAttempts, 0);
        expect(
          mcp.state.untrustedProjectServersFor(tempRepo.path),
          hasLength(1),
        );
        expect(
          mcp.state.untrustedProjectServersFor(tempRepo.path).single.status,
          McpConnectionStatus.disconnected,
        );

        // Once explicitly trusted, project MCP servers attempt connection and persist trust.
        await mcp.trustWorkspace(tempRepo.path, connectServers: true);
        expect(mcp.isWorkspaceTrusted(tempRepo.path), isTrue);
        expect(mcp.state.untrustedProjectServersFor(tempRepo.path), isEmpty);
        expect(transportSpawnAttempts, 1);

        await mcp.dispose();
      },
    );

    test(
      'CodingWorkspaceController builds unified diffs and reverts both modify and create changes cleanly',
      () async {
        final tempRepo = await Directory.systemTemp.createTemp(
          'studio_revert_test_',
        );
        addTearDown(() async {
          if (await tempRepo.exists()) {
            await tempRepo.delete(recursive: true);
          }
        });
        await File('${tempRepo.path}/lib/app.dart').create(recursive: true);
        await File(
          '${tempRepo.path}/lib/app.dart',
        ).writeAsString('const String mode = "v1";\n');

        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final mcp = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final inference = FakeInferencePort();
        final controller = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: mcp,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
        );
        addTearDown(() async {
          await controller.dispose();
          await skills.dispose();
          await mcp.dispose();
          await shell.dispose();
          await inference.dispose();
        });

        await controller.initialize(autoDetectDefaultRoot: false);
        await controller.setWorkspaceRoot(tempRepo.path);

        final tools = <String, ToolDefinition>{
          for (final t in controller.buildCodingTools()) t.name: t,
        };

        // 1. Edit existing file -> verify diff & 1-click revert restores v1.
        await tools['edit']!.invoke(<String, dynamic>{
          'path': 'lib/app.dart',
          'findText': '"v1"',
          'replaceText': '"v2"',
        });
        expect(
          await File('${tempRepo.path}/lib/app.dart').readAsString(),
          'const String mode = "v2";\n',
        );
        final editChange = controller.state.recentChanges.first;
        expect(editChange.kind, CodingChangeKind.modified);
        expect(editChange.unifiedDiff, contains('-const String mode = "v1";'));
        expect(editChange.unifiedDiff, contains('+const String mode = "v2";'));
        expect(editChange.canRevert, isTrue);

        await controller.revertChange(editChange.id);
        expect(
          await File('${tempRepo.path}/lib/app.dart').readAsString(),
          'const String mode = "v1";\n',
        );
        expect(controller.state.recentChanges.first.reverted, isTrue);
        expect(controller.state.recentChanges.first.canRevert, isFalse);

        // 2. Write brand new file -> verify diff & 1-click revert deletes it.
        await tools['write']!.invoke(<String, dynamic>{
          'path': 'lib/created.dart',
          'content': 'void helper() {}\n',
        });
        expect(
          await File('${tempRepo.path}/lib/created.dart').exists(),
          isTrue,
        );
        final createChange = controller.state.recentChanges.first;
        expect(createChange.kind, CodingChangeKind.created);
        expect(createChange.canRevert, isTrue);

        await controller.revertChange(createChange.id);
        expect(
          await File('${tempRepo.path}/lib/created.dart').exists(),
          isFalse,
        );
        expect(controller.state.recentChanges.first.reverted, isTrue);
      },
    );
  });
}
