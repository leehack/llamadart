@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final explicitEnable in [false, true]) {
    test(
      'Web cannot enable shell with ${explicitEnable ? 'explicit true' : 'default'} policy',
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

  test(
    'browser conversation factory reopens caller-owned storage and media',
    () async {
      final kv = InMemoryKeyValueStore();
      final bytes = Uint8List.fromList([1, 2, 3, 255]);
      final attachment = StudioAttachment(
        id: 'photo',
        kind: StudioAttachmentKind.image,
        name: 'photo.png',
        bytes: bytes,
      );
      final first = createDefaultConversationStore(
        fallbackKeyValueStore: kv,
        directoryPath: '/browser-not-a-native-directory',
      );
      final conversation =
          StudioConversation.create(
            id: 'browser-session',
            title: 'Persisted browser chat',
          ).appendToActiveBranch(
            StudioMessage(
              id: 'message',
              role: StudioRole.user,
              text: 'remember this',
              createdAt: DateTime.utc(2026),
              attachments: [attachment],
            ),
          );
      await first.save(conversation);
      final reopened = createDefaultConversationStore(
        fallbackKeyValueStore: kv,
        directoryPath: '/browser-not-a-native-directory',
      );
      final records = await reopened.loadAll();
      expect(
        records,
        hasLength(1),
        reason: 'Reopened store must retain the saved record',
      );
      final restored = records.single;
      expect(restored.title, 'Persisted browser chat');
      expect(restored.activeBranch.single.text, 'remember this');
      expect(
        await reopened.readAttachmentBytes(
          restored.activeBranch.single.attachments.single,
        ),
        bytes,
      );
      await reopened.delete(restored.id);
      expect(await first.loadAll(), isEmpty);
    },
  );

  test(
    'browser note factory reopens caller-owned storage and binary media',
    () async {
      final kv = InMemoryKeyValueStore();
      final image = Uint8List.fromList([10, 20, 30]);
      final audio = Uint8List.fromList([82, 73, 70, 70, 255]);
      final first = createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: '/unused',
      );
      await first.save(
        StudioNote(
          id: 'browser-note',
          title: 'Browser note',
          content: 'Saved content',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        imageBytes: image,
        audioWavBytes: audio,
      );
      final reopened = createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: '/unused',
      );
      final records = await reopened.loadAll();
      expect(
        records,
        hasLength(1),
        reason: 'Reopened store must retain the saved record',
      );
      final restored = records.single;
      expect(restored.content, 'Saved content');
      expect(await reopened.readImageBytes(restored), image);
      expect(await reopened.readAudioBytes(restored), audio);
      await reopened.delete(restored.id);
      expect(await first.loadAll(), isEmpty);
    },
  );

  test(
    'browser coding filesystem refuses local IO and shell execution',
    () async {
      expect(await CodingWorkspaceFs.detectDefaultWorkspaceRoot(), isNull);
      final operations = <String, Future<Object?> Function()>{
        'browsing': () => CodingWorkspaceFs.listFiles('/workspace'),
        'reading': () => CodingWorkspaceFs.readFile('/workspace', 'secret.txt'),
        'search': () => CodingWorkspaceFs.searchCode('/workspace', 'secret'),
        'writing': () =>
            CodingWorkspaceFs.writeFile('/workspace', 'a.txt', 'content'),
        'patching': () => CodingWorkspaceFs.patchFile(
          '/workspace',
          'a.txt',
          findText: 'a',
          replaceText: 'b',
        ),
        'deletion': () => CodingWorkspaceFs.deleteFile('/workspace', 'a.txt'),
      };
      for (final operation in operations.entries) {
        await expectLater(
          operation.value(),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'missing host capability',
              contains('IO host'),
            ),
          ),
          reason: operation.key,
        );
      }
      await expectLater(
        CodingWorkspaceFs.runCommand('/workspace', 'echo unsafe'),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'unsupported platform',
            contains('Web'),
          ),
        ),
      );
    },
  );

  test('browser local model scanner never invents filesystem assets', () async {
    expect(LocalModelScanner.defaultDesktopRoots(), isEmpty);
    final scanner = LocalModelScanner(defaultRoots: ['/models']);
    final storage = DefaultStudioModelStorageAdapter(localScanner: scanner);
    addTearDown(storage.dispose);
    expect(
      await storage.refreshLocalModels(extraDirectories: ['/another/cache']),
      isEmpty,
    );
    expect(storage.discoveredLocalModels, isEmpty);
    expect(storage.discoveredLocalBytes, 0);
    final result = await scanner.scan(extraDirectories: ['/another/cache']);
    expect(result.curatedAssetsById, isEmpty);
    expect(result.standaloneModels, isEmpty);
    expect(result.allFiles, isEmpty);
    expect(result.totalUniqueBytes, 0);
  });

  test(
    'browser project discovery preserves explicit environment only',
    () async {
      final context = await discoverProjectAgentsContext('/workspace');
      expect(context.primaryPath, isNull);
      expect(context.sourceFiles, isEmpty);
      expect(context.instructions, isEmpty);
      expect(context.hasInstructions, isFalse);
      expect(await discoverProjectMcpConfigs('/workspace'), isEmpty);
      expect(await resolveHostExecutable('dart'), isNull);
      expect(buildMcpProcessEnvironment({}), isNull);
      expect(buildMcpProcessEnvironment({'EXPLICIT_SETTING': 'keep-me'}), {
        'EXPLICIT_SETTING': 'keep-me',
      });
    },
  );

  test(
    'browser skill registry retains imported skills without filesystem discoveries',
    () async {
      final registry = SkillRegistry(keyValueStore: InMemoryKeyValueStore());
      addTearDown(registry.dispose);
      await registry.initialize(workspaceRoot: '/workspace');
      final initialIds = registry.state.skills.map((skill) => skill.id).toSet();
      final imported = await registry.importSkillMarkdown(
        '---\nname: browser-import\ndescription: Imported explicitly\n---\nUse the supplied context.',
      );
      await registry.addSkillDirectory('/not-browser-readable');
      await registry.refreshDiscoveredSkills(workspaceRoot: '/workspace');
      expect(
        registry.state.skills.where((skill) => skill.isDiscovered),
        isEmpty,
        reason: 'Browser registry cannot discover filesystem skills',
      );
      expect(registry.state.skills.map((skill) => skill.id).toSet(), {
        ...initialIds,
        imported.id,
      });
      expect(
        registry.buildActiveSkillsSystemContext(),
        contains('Use the supplied context.'),
      );
      expect(
        await discoverSkillsInDirectories([
          '/not-browser-readable',
        ], workspaceRoot: '/workspace'),
        isEmpty,
      );
    },
  );

  test('browser MCP factory refuses subprocesses and invalid remote URLs', () {
    expect(
      () => createMcpTransport(
        const McpServerConfig(
          id: 'stdio',
          name: 'stdio',
          transportType: McpTransportType.stdio,
          command: 'dart',
        ),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'unsupported host',
          contains('IO host'),
        ),
      ),
    );
    for (final type in [
      McpTransportType.streamableHttp,
      McpTransportType.sse,
    ]) {
      expect(
        () => createMcpTransport(
          McpServerConfig(
            id: type.name,
            name: type.name,
            transportType: type,
            url: '  ',
          ),
        ),
        throwsArgumentError,
      );
    }
  });

  for (final type in [McpTransportType.streamableHttp, McpTransportType.sse]) {
    test(
      'browser MCP ${type.name} sends configured endpoint, headers and JSON',
      () async {
        final requests = <http.Request>[];
        final events = StreamController<List<int>>();
        final mock = MockClient.streaming((request, body) async {
          final captured = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..bodyBytes = await body.toBytes();
          requests.add(captured);
          if (request.method == 'GET') {
            events.add(
              utf8.encode(
                'event: endpoint\ndata: /message?sessionId=browser-contract\n\n',
              ),
            );
            return http.StreamedResponse(
              events.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(const Stream<List<int>>.empty(), 202);
        });
        addTearDown(() async {
          if (type == McpTransportType.sse) await events.close();
          mock.close();
        });
        await http.runWithClient(() async {
          final transport = createMcpTransport(
            McpServerConfig(
              id: 'remote',
              name: 'Remote',
              transportType: type,
              url: ' https://browser-contract.invalid/${type.name} ',
              headers: const {'X-Studio-Contract': 'forwarded'},
            ),
          );
          addTearDown(transport.close);
          await transport.start();
          await transport.send(
            JsonRpcNotification(method: 'notifications/initialized'),
          );
          final post = requests.singleWhere(
            (request) => request.method == 'POST',
          );
          expect(post.url.host, 'browser-contract.invalid');
          expect(
            post.url.path,
            type == McpTransportType.sse ? '/message' : '/streamableHttp',
          );
          if (type == McpTransportType.sse) {
            expect(post.url.queryParameters['sessionId'], 'browser-contract');
          }
          expect(post.headers['X-Studio-Contract'], 'forwarded');
          expect(jsonDecode(post.body), {
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
          });
          await transport.close();
        }, () => mock);
      },
    );
  }
}
