@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/grammar/json_schema_converter.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import '../../../test/support/qwen35_tool_result_fixture.dart';
import 'support/studio_structured_qualification.dart';

const _settings = StudioSettings(
  computeDevice: ComputeDevice.cpu,
  gpuLayers: 0,
  autoTuneHardware: false,
  contextSize: 4096,
  requestedContextSize: 4096,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  maxTokens: 256,
  temperature: 0,
  thinkingEnabled: false,
  enabledBuiltInTools: <String>[],
);
const _schema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'answer': <String, Object?>{'type': 'integer', 'const': 7},
  },
  'required': <String>['answer'],
  'additionalProperties': false,
};
StudioMessage _message(
  String id,
  StudioRole role,
  String text, {
  List<StudioToolInvocation> calls = const [],
}) => StudioMessage(
  id: id,
  role: role,
  text: text,
  toolCalls: calls,
  createdAt: DateTime.utc(2026),
);

Future<void> _load(DirectLlamaInferencePort port, String path) =>
    port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'structured-qualification',
          name: 'Explicit qualification model',
          description: 'Local model supplied by the operator.',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: path,
        ),
        primarySource: ModelSource.path(path),
      ),
      settings: _settings,
      isWeb: false,
    );

ToolDefinition _studioTool(Future<Object?> Function(ToolParams) handler) =>
    McpToolSchemaAdapter.toLlamaToolDefinition(
      McpToolDescriptor(
        serverId: 'synthetic',
        serverName: 'Synthetic',
        name: 'inspect',
        exposedToolName: 'inspect',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'code': {'type': 'string'},
            'options': {
              'type': 'object',
              'properties': <String, Object?>{},
              'additionalProperties': false,
            },
            'items': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'count': {'type': 'integer'},
            'active': {'type': 'boolean'},
            'empty': {'type': 'null'},
          },
          'required': ['code', 'options', 'items', 'count', 'active', 'empty'],
          'additionalProperties': false,
        },
      ),
      handler: handler,
    );

void main() {
  group('deterministic Studio adapter structured proof', () {
    late Directory directory;
    late StructuredRecordingBackend backend;
    late DirectLlamaInferencePort port;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('studio_structure_');
      final file = await File(
        '${directory.path}/model.gguf',
      ).writeAsBytes([0x47, 0x47, 0x55, 0x46]);
      backend = StructuredRecordingBackend(StructuredFixtureBackend());
      port = DirectLlamaInferencePort(backend: backend);
      await _load(port, file.path);
    });
    tearDown(() async {
      await port.dispose();
      await directory.delete(recursive: true);
    });

    test(
      'MCP constraints are preserved or rejected before tool publication',
      () {
        for (final constraint in <Map<String, dynamic>>[
          {'type': 'string', 'pattern': r'^x$'},
          {'type': 'integer', 'minimum': 1},
          {
            'oneOf': [
              {'type': 'integer'},
              {'type': 'null'},
            ],
          },
        ]) {
          expect(
            () => McpToolSchemaAdapter.toLlamaToolDefinition(
              McpToolDescriptor(
                serverId: 'synthetic',
                serverName: 'Synthetic',
                name: 'strict',
                exposedToolName: 'strict',
                inputSchema: {
                  'type': 'object',
                  'properties': {'value': constraint},
                  'required': ['value'],
                  'additionalProperties': false,
                },
              ),
              handler: (_) async => null,
            ),
            throwsA(isA<LlamaUnsupportedException>()),
            reason: '$constraint',
          );
        }
      },
    );

    test(
      'MCP canonical union const and scalar enum survive mapping without lossy legacy fallback',
      () {
        for (final constraint in <Map<String, dynamic>>[
          {
            'anyOf': [
              {'type': 'integer'},
              {'type': 'null'},
            ],
          },
          {'type': 'integer', 'const': 7},
          {
            'type': 'boolean',
            'enum': [true],
          },
        ]) {
          final tool = McpToolSchemaAdapter.toLlamaToolDefinition(
            McpToolDescriptor(
              serverId: 'synthetic',
              serverName: 'Synthetic',
              name: 'strict',
              exposedToolName: 'strict',
              inputSchema: {
                'type': 'object',
                'properties': {'value': constraint},
                'required': ['value'],
                'additionalProperties': false,
              },
            ),
            handler: (_) async => null,
          );
          expect(
            (tool.toJsonSchema()['properties'] as Map)['value'],
            constraint,
          );
          expect(
            () => McpToolSchemaAdapter.coerceToLegacyToolDefinition(tool),
            throwsA(isA<LlamaUnsupportedException>()),
          );
        }
      },
    );

    test(
      'unrepresentable canonical MCP schema refuses Qwen XML before generation',
      () async {
        var invoked = 0;
        final tool = McpToolSchemaAdapter.toLlamaToolDefinition(
          const McpToolDescriptor(
            serverId: 'synthetic',
            serverName: 'Synthetic',
            name: 'strict',
            exposedToolName: 'strict',
            inputSchema: {
              'type': 'object',
              'properties': {
                'value': {'type': 'integer', 'const': 7},
              },
              'required': ['value'],
              'additionalProperties': false,
            },
          ),
          handler: (_) async {
            invoked++;
            return null;
          },
        );
        await expectLater(
          port
              .streamTurn(
                StudioTurnRequest(
                  history: [_message('u', StudioRole.user, 'Inspect.')],
                  settings: _settings,
                  includeBuiltInTools: false,
                  extraTools: [tool],
                  toolChoice: ToolChoice.required,
                  requiredToolName: 'strict',
                ),
              )
              .toList(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(invoked, 0);
        expect(backend.requests, isEmpty);
      },
    );

    test(
      'saved tool history renders typed results and preserves role and bytes',
      () async {
        backend.scriptedReplies.add(['Complete.']);
        final events = await port
            .streamTurn(
              StudioTurnRequest(
                history: [
                  _message('u1', StudioRole.user, 'Inspect Montréal 👋.'),
                  _message(
                    'a1',
                    StudioRole.assistant,
                    'Inspection complete.',
                    calls: [
                      StudioToolInvocation(
                        id: 'saved-call',
                        name: 'inspect',
                        argumentsJson: jsonEncode(qwenResultPayload),
                        resultJson: jsonEncode(qwenResultPayload),
                      ),
                    ],
                  ),
                  _message('u2', StudioRole.user, 'Use the same values.'),
                ],
                settings: _settings,
                includeBuiltInTools: false,
                toolsEnabledOverride: false,
              ),
            )
            .toList();
        expect(events.whereType<StudioTurnCompletedEvent>(), hasLength(1));
        final prompt = backend.prompts.single;
        expect(prompt, contains('Inspect Montréal 👋.'));
        expect(prompt, contains('<function=inspect>'));
        expect(
          prompt,
          contains(
            '<tool_response>\n${jsonEncode(qwenResultPayload)}\n</tool_response>',
          ),
        );
        expect(prompt, contains('Inspection complete.'));
        expect(prompt, contains('<|im_start|>user\nUse the same values.'));
      },
    );

    for (final thinking in [false, true]) {
      for (final size in [1, 7]) {
        test(
          'Studio auto reconstructs schema types across $size-byte chunks with thinking=$thinking',
          () async {
            final called = <Map<String, dynamic>>[];
            final tool = _studioTool((params) async {
              called.add(params.raw);
              return qwenResultPayload;
            });
            final output =
                '${thinking ? 'reason</think>\n\n' : ''}$qwenResultEnvelope';
            backend.scriptedReplies.addAll([
              [
                for (var i = 0; i < output.length; i += size)
                  output.substring(i, (i + size).clamp(0, output.length)),
              ],
              [thinking ? 'done</think>\n\nComplete.' : 'Complete.'],
            ]);
            final events = await port
                .streamTurn(
                  StudioTurnRequest(
                    history: [
                      _message('u', StudioRole.user, 'Inspect these values.'),
                    ],
                    settings: _settings.copyWith(thinkingEnabled: thinking),
                    includeBuiltInTools: false,
                    extraTools: [tool],
                  ),
                )
                .toList();
            expect(called, [qwenResultPayload]);
            final completed = events
                .whereType<StudioTurnCompletedEvent>()
                .single
                .result;
            expect(completed.toolInvocations, hasLength(1));
            expect(
              jsonDecode(completed.toolInvocations.single.argumentsJson),
              qwenResultPayload,
            );
            expect(
              jsonDecode(completed.toolInvocations.single.resultJson!),
              qwenResultPayload,
            );
            expect(completed.text, contains('Complete.'));
            expect(
              backend.prompts.last,
              contains(jsonEncode(qwenResultPayload)),
            );
            if (thinking) expect(completed.thinkingText, contains('reason'));
          },
        );
      }
    }

    for (final malformed in [
      qwenResultEnvelope.substring(0, qwenResultEnvelope.length - 15),
      qwenResultEnvelope.replaceFirst(
        '<function=inspect>',
        '<function=unknown>',
      ),
    ]) {
      test(
        'Studio never executes incomplete or undeclared final tool envelope ${malformed.length}',
        () async {
          var calls = 0;
          final tool = _studioTool((_) async {
            calls++;
            return null;
          });
          backend.scriptedReplies.addAll([
            malformed.split(''),
            ['No tool executed.'],
          ]);
          final events = <StudioTurnEvent>[];
          LlamaException? rejected;
          try {
            await for (final event in port.streamTurn(
              StudioTurnRequest(
                history: [_message('u', StudioRole.user, 'Inspect.')],
                settings: _settings,
                includeBuiltInTools: false,
                extraTools: [tool],
              ),
            )) {
              events.add(event);
            }
          } on LlamaException catch (error) {
            rejected = error;
          }
          expect(rejected, isNotNull);
          expect(rejected.toString(), contains('no visible answer'));
          expect(calls, 0);
          expect(events.whereType<StudioToolInvocationEvent>(), isEmpty);
          expect(events.whereType<StudioTurnCompletedEvent>(), isEmpty);
        },
      );
    }

    test(
      'Studio-produced tool schema retains auto required none and thinking semantics',
      () async {
        final tool = McpToolSchemaAdapter.coerceToLegacyToolDefinition(
          _studioTool((_) async => qwenResultPayload),
        );
        for (final choice in ToolChoice.values) {
          for (final thinking in [false, true]) {
            backend.scriptedReplies.add([
              '${thinking ? 'reason</think>\n\n' : ''}$qwenResultEnvelope',
            ]);
            final chunks = await port.engine
                .create(
                  [
                    const LlamaChatMessage.fromText(
                      role: LlamaChatRole.user,
                      text: 'Inspect.',
                    ),
                  ],
                  params: const GenerationParams(maxTokens: 512),
                  tools: [tool],
                  toolChoice: choice,
                  enableThinking: thinking,
                )
                .toList();
            final calls = chunks.expand((chunk) => chunk.toolCalls).toList();
            expect(calls, choice == ToolChoice.none ? isEmpty : hasLength(1));
            if (calls.isNotEmpty) {
              expect(
                jsonDecode(calls.single.function!.arguments!),
                qwenResultPayload,
              );
            }
            expect(
              backend.requests.last.grammar,
              choice == ToolChoice.none ? isNull : isNotNull,
            );
            if (choice == ToolChoice.required) {
              expect(backend.requests.last.grammarLazy, isFalse);
            }
          }
        }
      },
    );

    test('disabled tools cannot execute a tool-shaped response', () async {
      var calls = 0;
      backend.scriptedReplies.addAll([
        [qwenResultEnvelope],
        ['No tools.'],
      ]);
      await port
          .streamTurn(
            StudioTurnRequest(
              history: [_message('u', StudioRole.user, 'Inspect.')],
              settings: _settings,
              includeBuiltInTools: false,
              toolsEnabledOverride: false,
              extraTools: [
                _studioTool((_) async {
                  calls++;
                  return null;
                }),
              ],
            ),
          )
          .toList();
      expect(calls, 0);
    });
  });

  final modelPath = Platform.environment['STUDIO_STRUCTURED_MODEL'];
  group(
    'native Studio structured qualification',
    () {
      late StructuredRecordingBackend backend;
      late DirectLlamaInferencePort port;
      setUpAll(() async {
        expect(
          modelPath,
          isNotNull,
          reason:
              'Set STUDIO_STRUCTURED_MODEL to the exact local affected-family GGUF.',
        );
        expect(File(modelPath!).existsSync(), isTrue);
        backend = StructuredRecordingBackend(LlamaBackend.withTextHistory());
        port = DirectLlamaInferencePort(backend: backend);
        await _load(port, modelPath);
        expect(
          port.runtimeStore.state.capabilities!.supportsStructuredOutput,
          isTrue,
        );
        print(
          'STUDIO_STRUCTURED_NATIVE ${jsonEncode({'modelSha256': (await sha256.bind(File(modelPath).openRead()).first).toString(), 'backend': await backend.getBackendName(), 'threads': 2, 'computeDevice': 'cpu'})}',
        );
      });
      tearDownAll(() async {
        await port.dispose();
      });

      test(
        'Studio strict schema compiles native acceptance and malformed unknown missing wrong-type rejection',
        () async {
          backend.scriptedReplies.add(['{"answer":7}']);
          final events = await port
              .streamTurn(
                StudioTurnRequest(
                  history: [
                    _message('schema', StudioRole.user, 'Return answer 7.'),
                  ],
                  settings: _settings,
                  jsonSchema: jsonEncode(_schema),
                  includeBuiltInTools: false,
                ),
              )
              .toList();
          expect(
            events
                .whereType<StudioTurnCompletedEvent>()
                .single
                .result
                .structuredJsonValid,
            isTrue,
          );
          final params = backend.requests.last;
          expect(params.grammar, isNotNull);
          expect(params.grammarLazy, isFalse);
          validateStudioCompiledGrammar(modelPath!, params.grammar!, {
            '{"answer":7}': true,
            '{"answer":"7"}': false,
            '{"answer":8}': false,
            '{}': false,
            '{"answer":7,"unknown":true}': false,
            '{"answer":7': false,
          });
        },
      );

      test(
        'Studio canonical union const and scalar enum enforce native grammar and handler validation',
        () async {
          var invoked = 0;
          final tool = McpToolSchemaAdapter.toLlamaToolDefinition(
            const McpToolDescriptor(
              serverId: 'synthetic',
              serverName: 'Synthetic',
              name: 'strict',
              exposedToolName: 'strict',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'value': {
                    'anyOf': [
                      {'type': 'integer', 'const': 7},
                      {
                        'type': 'boolean',
                        'enum': [true],
                      },
                      {'type': 'null'},
                    ],
                  },
                },
                'required': ['value'],
                'additionalProperties': false,
              },
            ),
            handler: (_) async {
              invoked++;
              return null;
            },
          );
          validateStudioCompiledGrammar(
            modelPath!,
            JsonSchemaConverter.convert(tool.toJsonSchema()),
            {
              '{"value":7}': true,
              '{"value":true}': true,
              '{"value":null}': true,
              '{"value":8}': false,
              '{"value":false}': false,
              '{"value":"7"}': false,
              '{}': false,
              '{"value":7,"unknown":true}': false,
              '{"value":7': false,
            },
          );
          await tool.invoke({'value': 7});
          await tool.invoke({'value': true});
          await tool.invoke({'value': null});
          for (final value in [8, false, '7']) {
            await expectLater(
              tool.invoke({'value': value}),
              throwsA(isA<LlamaArgumentException>()),
            );
          }
          expect(invoked, 3);
        },
      );

      test(
        'Studio MCP schema compiles required tool native grammar with valid and invalid shapes',
        () async {
          final tool = McpToolSchemaAdapter.coerceToLegacyToolDefinition(
            _studioTool((_) async => qwenResultPayload),
          );
          final rendered = await port.engine.chatTemplate(
            [
              const LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'Inspect.',
              ),
            ],
            tools: [tool],
            toolChoice: ToolChoice.required,
            enableThinking: false,
            includeTokenCount: false,
          );
          expect(
            rendered.format,
            ChatFormat.qwen3CoderXml.index,
            reason:
                'This qualification requires the affected Qwen3.5/3.6/3.8 XML family.',
          );
          expect(rendered.grammar, isNotNull);
          expect(rendered.grammarLazy, isFalse);
          validateStudioCompiledGrammar(modelPath!, rendered.grammar!, {
            qwenResultEnvelope: true,
            qwenResultEnvelope.replaceFirst(
              '<function=inspect>',
              '<function=unknown>',
            ): false,
            qwenResultEnvelope.replaceFirst(
              '<parameter=count>\n7',
              '<parameter=count>\nwrong',
            ): false,
            qwenResultEnvelope.replaceFirst(
              '<parameter=count>\n7\n</parameter>\n',
              '',
            ): false,
            qwenResultEnvelope.substring(0, qwenResultEnvelope.length - 15):
                false,
          });
        },
      );

      test(
        'native Studio default Dart MCP reports narrowed and unavailable tools and validates before dispatch',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'studio_native_mcp_',
          );
          await Directory('${directory.path}/lib').create();
          await File('${directory.path}/pubspec.yaml').writeAsString(
            'name: studio_native_mcp_probe\nenvironment:\n  sdk: ^3.10.0\n',
          );
          await File(
            '${directory.path}/lib/main.dart',
          ).writeAsString('void main() {}\n');
          final manager = McpManager(keyValueStore: InMemoryKeyValueStore());
          try {
            await manager.initialize();
            await manager.ensureBuiltInDartFlutterServer(
              workspaceRoot: directory.path,
              autoConnect: false,
            );
            final server = await manager.connectServer(
              McpManager.builtInDartFlutterServerId,
            );
            expect(server.isConnected, isTrue, reason: server.errorMessage);
            final canonicalRoot = Directory(
              await directory.resolveSymbolicLinks(),
            ).uri.toString();
            // The SDK starts with no permitted roots, independently of cwd.
            final registered = await manager.callTool(
              serverId: McpManager.builtInDartFlutterServerId,
              toolName: 'roots',
              arguments: {
                'command': 'add',
                'uris': [canonicalRoot],
              },
            );
            expect(
              registered['isError'],
              isFalse,
              reason: jsonEncode(registered),
            );
            var dispatched = 0;
            final tools = [
              for (final descriptor in manager.state.activeTools)
                McpToolSchemaAdapter.toLlamaToolDefinition(
                  descriptor,
                  handler: (params) async {
                    dispatched++;
                    return manager.callTool(
                      serverId: descriptor.serverId,
                      toolName: descriptor.name,
                      arguments: params.raw,
                    );
                  },
                ),
            ];
            expect(
              tools,
              hasLength(7),
              reason:
                  'The pinned Dart3.14 default MCP profile has seven active tools.',
            );
            backend.scriptedReplies.add(['Complete.']);
            final events = await port
                .streamTurn(
                  StudioTurnRequest(
                    history: [
                      _message(
                        'mcp',
                        StudioRole.user,
                        'Do not call a tool; reply Complete.',
                      ),
                    ],
                    settings: _settings,
                    includeBuiltInTools: false,
                    extraTools: tools,
                  ),
                )
                .toList();
            final notices = events
                .whereType<StudioToolAvailabilityEvent>()
                .expand((event) => event.notices)
                .toList();
            expect(
              notices.where((n) => n.isUnavailable).map((n) => n.toolName),
              ['rip_grep_packages'],
            );
            expect(
              notices
                  .where((n) => !n.isUnavailable)
                  .map((n) => n.toolName)
                  .toSet(),
              {'pub', 'analyze_files'},
            );
            expect(notices.every((n) => n.reason.trim().isNotEmpty), isTrue);
            expect(dispatched, 0);
            final ripgrep = tools.singleWhere(
              (tool) => tool.name == 'rip_grep_packages',
            );
            await expectLater(
              ripgrep.invoke({
                'arguments': <String>[],
                'packageNames': <String>[],
                'root': canonicalRoot,
              }),
              throwsA(isA<LlamaArgumentException>()),
            );
            final analyze = tools.singleWhere(
              (tool) => tool.name == 'analyze_files',
            );
            final projectedAnalyze =
                McpToolSchemaAdapter.coerceToLegacyToolDefinition(
                  analyze,
                  allowClosedObjectSubset: true,
                );
            await expectLater(
              projectedAnalyze.invoke({'roots': 17}),
              throwsA(isA<LlamaArgumentException>()),
            );
            expect(
              dispatched,
              0,
              reason: 'Invalid schemas must fail before external MCP dispatch.',
            );
            final result = await projectedAnalyze.invoke({
              'roots': [
                {
                  'root': canonicalRoot,
                  'paths': ['lib/main.dart'],
                },
              ],
              'applyFixes': false,
            });
            expect(dispatched, 1);
            expect(
              (result as Map)['isError'],
              isFalse,
              reason: jsonEncode(result),
            );
            print(
              'STUDIO_DEFAULT_MCP_COMPATIBILITY ${jsonEncode({
                'sdk': Platform.version,
                'activeTools': tools.map((t) => t.name).toList(),
                'notices': [
                  for (final n in notices) {'tool': n.toolName, 'unavailable': n.isUnavailable, 'reason': n.reason},
                ],
                'invalidDispatches': 0,
                'validAnalyzeDispatches': dispatched,
              })}',
            );
          } finally {
            await manager.dispose();
            await directory.delete(recursive: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'Studio saved typed history matches pinned upstream apply-template bytes',
        () async {
          final server =
              Platform.environment['STUDIO_STRUCTURED_UPSTREAM_SERVER'];
          final source =
              Platform.environment['STUDIO_STRUCTURED_UPSTREAM_SOURCE'];
          expect(
            server,
            isNotNull,
            reason: 'Parity requires an operator-started pinned llama-server.',
          );
          expect(
            source,
            isNotNull,
            reason:
                'Name the exact pinned llama.cpp source used to build the server.',
          );
          final pinned = File(
            '../../tool/testing/llama_cpp_templates.ref',
          ).readAsStringSync().trim();
          final actualRef = await Process.run('git', [
            '-C',
            source!,
            'rev-parse',
            'HEAD',
          ]);
          final expectedRef = await Process.run('git', [
            '-C',
            source,
            'rev-parse',
            '$pinned^{commit}',
          ]);
          expect(actualRef.exitCode, 0);
          expect(expectedRef.exitCode, 0);
          expect(actualRef.stdout, expectedRef.stdout);
          final tool = McpToolSchemaAdapter.coerceToLegacyToolDefinition(
            _studioTool((_) async => qwenResultPayload),
          );
          backend.scriptedReplies.add(['Complete.']);
          await port
              .streamTurn(
                StudioTurnRequest(
                  history: [
                    _message('u1', StudioRole.user, 'Inspect Montréal 👋.'),
                    _message(
                      'a1',
                      StudioRole.assistant,
                      'Inspection complete.',
                      calls: [
                        StudioToolInvocation(
                          id: 'saved-call',
                          name: 'inspect',
                          argumentsJson: jsonEncode(qwenResultPayload),
                          resultJson: jsonEncode(qwenResultPayload),
                        ),
                      ],
                    ),
                    _message('u2', StudioRole.user, 'Use the same values.'),
                  ],
                  settings: _settings,
                  includeBuiltInTools: false,
                  extraTools: [tool],
                ),
              )
              .toList();
          final body = {
            'messages': [
              {'role': 'user', 'content': 'Inspect Montréal 👋.'},
              {
                'role': 'assistant',
                'content': 'Inspection complete.',
                'tool_calls': [
                  {
                    'id': 'saved-call',
                    'type': 'function',
                    'function': {
                      'name': 'inspect',
                      'arguments': qwenResultPayload,
                    },
                  },
                ],
              },
              {
                'role': 'tool',
                'name': 'inspect',
                'tool_call_id': 'saved-call',
                'content': jsonEncode(qwenResultPayload),
              },
              {'role': 'user', 'content': 'Use the same values.'},
            ],
            'tools': [
              {
                'type': 'function',
                'function': {
                  'name': tool.name,
                  'description': tool.description,
                  'parameters': tool.toJsonSchema(),
                },
              },
            ],
            'add_generation_prompt': true,
            'chat_template_kwargs': {'enable_thinking': false},
          };
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 15);
          try {
            final request = await client.postUrl(
              Uri.parse(server!).resolve('/apply-template'),
            );
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
            final response = await request.close().timeout(
              const Duration(seconds: 30),
            );
            final text = await utf8.decoder.bind(response).join();
            expect(response.statusCode, 200, reason: text);
            final oracle = jsonDecode(text) as Map<String, dynamic>;
            expect(backend.prompts.last, oracle['prompt']);
            print(
              'STUDIO_UPSTREAM_PARITY ${jsonEncode({'sourceCommit': (actualRef.stdout as String).trim(), 'promptSha256': sha256.convert(utf8.encode(backend.prompts.last)).toString()})}',
            );
          } finally {
            client.close(force: true);
          }
        },
      );

      test('real Studio native generation obeys strict schema', () async {
        expect(backend.scriptedReplies, isEmpty);
        final events = await port
            .streamTurn(
              StudioTurnRequest(
                history: [
                  _message('real', StudioRole.user, 'Return answer 7.'),
                ],
                settings: _settings,
                jsonSchema: jsonEncode(_schema),
                includeBuiltInTools: false,
              ),
            )
            .toList();
        final result = events
            .whereType<StudioTurnCompletedEvent>()
            .single
            .result;
        expect(result.structuredJsonValid, isTrue);
        expect(jsonDecode(result.text), {'answer': 7});
        print(
          'STUDIO_STRUCTURED_GENERATION ${jsonEncode({'result': result.text, 'scripted': false})}',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    tags: const ['local-only'],
    skip: modelPath == null
        ? 'Native qualification pending: explicit STUDIO_STRUCTURED_MODEL is required; this skip is not model evidence.'
        : false,
  );
}
