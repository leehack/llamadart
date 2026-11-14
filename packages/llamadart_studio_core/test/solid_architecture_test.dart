import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

class _EmbeddingOnlyPort implements StudioEmbeddingPort {
  final List<String> embeddedTexts = <String>[];

  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {}

  @override
  Future<EmbeddingCapabilityInfo> probeEmbeddingCapabilities() async =>
      const EmbeddingCapabilityInfo(
        supportsText: true,
        supportsImage: false,
        supportsAudio: false,
        isReady: true,
      );

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async => EmbeddingComparisonResult(
    texts: texts,
    dimensions: 2,
    similarityMatrix: List<List<double>>.generate(
      texts.length,
      (int r) =>
          List<double>.generate(texts.length, (int c) => r == c ? 1.0 : 0.5),
    ),
    elapsedMs: 2,
  );

  @override
  Future<EmbeddedPassageResult> embedDocuments(
    List<String> documents, {
    List<String?>? titles,
  }) async {
    embeddedTexts.addAll(documents);
    return EmbeddedPassageResult(
      texts: documents,
      dimensions: 2,
      vectors: <List<double>>[
        for (final doc in documents)
          doc.toLowerCase().contains('solid')
              ? const <double>[1.0, 0.0]
              : const <double>[0.0, 1.0],
      ],
      elapsedMs: 3,
    );
  }

  @override
  Future<NoteEmbeddingVectorResult> embedNoteContent(
    NoteEmbeddingInput input,
  ) async {
    embeddedTexts.add(input.text);
    return NoteEmbeddingVectorResult(
      vector: input.text.toLowerCase().contains('solid')
          ? const <double>[1.0, 0.0]
          : const <double>[0.0, 1.0],
      dimensions: 2,
      elapsedMs: 3,
      usedMultimodal: false,
    );
  }

  @override
  Future<EmbeddedQueryResult> embedQuery(String query) async =>
      EmbeddedQueryResult(
        query: query,
        dimensions: 2,
        vector: query.toLowerCase().contains('solid')
            ? const <double>[1.0, 0.0]
            : const <double>[0.0, 1.0],
        elapsedMs: 1,
      );

  @override
  Future<void> dispose() async {}
}

class _DecisionOnlyPort implements StudioDecisionPort {
  int loadCalls = 0;

  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    loadCalls++;
  }

  @override
  Future<SystemOneEvaluation> evaluateSystemOne({
    required String stateText,
    required String yesNoQuestion,
  }) async => SystemOneEvaluation(
    question: yesNoQuestion,
    probabilityTrue: 0.92,
    confidence: 0.88,
    elapsedMs: 2,
    deviceName: 'CPU',
  );

  @override
  Future<SystemOneBatchEvaluation> evaluateSystemOneBatch({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
  }) async => SystemOneBatchEvaluation(
    answers: <SystemOneQuestionAnswer>[
      for (final q in questions)
        switch (q) {
          SystemOneChoiceQuestionSpec(
            :final id,
            :final prompt,
            :final labels,
          ) =>
            SystemOneChoiceAnswer(
              id: id,
              prompt: prompt,
              confidence: 0.95,
              choice: labels.first,
              probabilities: <String, double>{labels.first: 0.95},
            ),
          SystemOneScoreQuestionSpec(:final id, :final prompt, :final levels) =>
            SystemOneScoreAnswer(
              id: id,
              prompt: prompt,
              confidence: 0.9,
              score: levels.length.toDouble(),
              levels: levels,
              levelProbabilities: <String, double>{levels.last: 0.9},
            ),
          SystemOneNoulQuestionSpec(:final id, :final prompt) =>
            SystemOneNoulAnswer(
              id: id,
              prompt: prompt,
              confidence: 0.91,
              probabilityTrue: 0.85,
            ),
        },
    ],
    elapsedMs: 4,
    deviceName: 'CPU',
  );

  @override
  Future<DecisionBenchmarkSummary> runDecisionSpeedBenchmark({
    required Object state,
    required List<SystemOneQuestionSpec> questions,
    int iterations = 15,
    bool compareWithActiveChatLlm = false,
  }) async => DecisionBenchmarkSummary(
    iterations: iterations,
    questionsPerPass: questions.length,
    totalElapsedMs: 20,
    minMs: 1,
    medianMs: 1,
    p95Ms: 2,
    deviceName: 'CPU',
  );

  @override
  Future<void> dispose() async {}
}

void main() {
  group('SOLID Architecture Verification', () {
    test(
      'ISP: NotebookController works with only StudioEmbeddingPort + StudioSttPort (no Playground/Tts port)',
      () async {
        final storage = FakeStudioStoragePort();
        final embeddingOnly = _EmbeddingOnlyPort();
        final sttOnly = MockAsrSpeechPort();
        final noteStore = EphemeralNoteStore();

        final notebook = NotebookController(
          storagePort: storage,
          embeddingPort: embeddingOnly,
          sttPort: sttOnly,
          noteStore: noteStore,
          isWeb: false,
          isMobile: false,
        );
        await notebook.initialize();

        final note = await notebook.createNote(
          title: 'SOLID Architecture',
          content: 'Segregated ports prevent fat fake implementations.',
          sourceKind: StudioNoteSourceKind.audio,
          audioWavBytes: Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3, 4]),
          audioDurationMs: 1000,
        );
        final transcript = await notebook.transcribeAudioNote(note.id);
        expect(transcript, 'Voice note recommends Q8_0 KV cache on Metal.');

        await notebook.indexNotes(forceReindex: true);
        expect(embeddingOnly.embeddedTexts, isNotEmpty);

        final hits = await notebook.searchNotes('SOLID ports');
        expect(hits, isNotEmpty);
        expect(hits.first.note.id, note.id);

        await notebook.dispose();
        await sttOnly.dispose();
        await embeddingOnly.dispose();
        await storage.dispose();
      },
    );

    test(
      'ISP: PlaygroundWorkspaceController runs decision workflows with only StudioDecisionPort',
      () async {
        final storage = FakeStudioStoragePort();
        final decisionOnly = _DecisionOnlyPort();

        final playground = PlaygroundWorkspaceController(
          storagePort: storage,
          modelLoader: decisionOnly,
          decisionPort: decisionOnly,
          isWeb: false,
          isMobile: false,
        );

        await playground.runDecisionHead(
          stateText: '8 GB VRAM free',
          yesNoQuestion: 'Fits cleanly?',
        );
        expect(playground.state.errorMessage, isNull);
        expect(playground.state.decisionEvaluation?.probabilityTrue, 0.92);

        final triage = await playground.runTriageRouterWorkflow(
          'Audit architecture dependencies',
        );
        expect(triage, isNotNull);
        expect(triage!.answers.length, 5);

        await playground.dispose();
        await decisionOnly.dispose();
        await storage.dispose();
      },
    );

    test(
      'OCP: StudioToolRegistry supports runtime registerTool addition and override',
      () async {
        final registry = StudioToolRegistry();
        final initialCount = registry.availableTools.length;

        registry.registerTool(
          BuiltInToolSpec(
            name: 'customPing',
            title: 'Custom Ping',
            description: 'Returns pong with payload.',
            definition: ToolDefinition(
              name: 'customPing',
              description: 'Ping helper.',
              parameters: <ToolParam>[
                ToolParam.string('payload', required: true),
              ],
              handler: (ToolParams params) async => <String, Object?>{
                'pong': params.getString('payload'),
              },
            ),
          ),
        );

        expect(registry.availableTools.length, initialCount + 1);
        var resolved = registry.resolveTools(
          enabledNames: const <String>['customPing'],
        );
        expect(resolved.length, 1);
        final firstResult = await resolved.single.invoke(<String, dynamic>{
          'payload': 'alpha',
        });
        expect(firstResult, <String, Object?>{'pong': 'alpha'});

        // Override same tool name without creating duplicates.
        registry.registerTool(
          BuiltInToolSpec(
            name: 'customPing',
            title: 'Custom Ping V2',
            description: 'Updated ping.',
            definition: ToolDefinition(
              name: 'customPing',
              description: 'Ping v2.',
              parameters: <ToolParam>[],
              handler: (_) async => 'pong-v2',
            ),
          ),
        );

        expect(registry.availableTools.length, initialCount + 1);
        resolved = registry.resolveTools(
          enabledNames: const <String>['customPing'],
        );
        expect(
          await resolved.single.invoke(const <String, dynamic>{}),
          'pong-v2',
        );
      },
    );

    test(
      'LSP: EphemeralNoteStore returns null gracefully on corrupt base64 like KeyValueNoteStore',
      () async {
        final noteWithCorruptMedia = StudioNote(
          id: 'corrupt_1',
          title: 'Corrupt Base64 Note',
          content: 'Body',
          createdAt: DateTime.utc(2026, 3, 1),
          updatedAt: DateTime.utc(2026, 3, 1),
          imageBase64: '!!!not-valid-base64!!!',
          audioBase64: '***broken-base64***',
        );

        final ephemeral = EphemeralNoteStore();
        final kvStore = KeyValueNoteStore(InMemoryKeyValueStore());

        expect(await ephemeral.readImageBytes(noteWithCorruptMedia), isNull);
        expect(await ephemeral.readAudioBytes(noteWithCorruptMedia), isNull);
        expect(await kvStore.readImageBytes(noteWithCorruptMedia), isNull);
        expect(await kvStore.readAudioBytes(noteWithCorruptMedia), isNull);
      },
    );

    test(
      'SRP: McpConfigStore persists non-project servers and normalizes trusted roots',
      () async {
        final kv = InMemoryKeyValueStore();
        final store = McpConfigStore(kv);

        expect(
          McpConfigStore.normalizeWorkspaceRoot('/tmp/my_project///'),
          '/tmp/my_project',
        );

        const globalServer = McpServerConfig(
          id: 'srv_global',
          name: 'Local Tools',
          transportType: McpTransportType.stdio,
          command: 'dart',
          args: <String>['mcp-server'],
          origin: McpServerOrigin.user,
        );
        const projectServer = McpServerConfig(
          id: 'srv_project',
          name: 'Workspace Tools',
          transportType: McpTransportType.stdio,
          command: 'npx',
          origin: McpServerOrigin.project,
        );

        await store.saveServers(const <McpServerConfig>[
          globalServer,
          projectServer,
        ]);
        await store.saveTrustedRoots(<String>{'/tmp/repo_b', '/tmp/repo_a'});

        final loaded = await store.load();
        expect(loaded.servers.length, 1);
        expect(loaded.servers.single.id, 'srv_global');
        expect(
          loaded.trustedRoots,
          containsAll(<String>['/tmp/repo_a', '/tmp/repo_b']),
        );
      },
    );

    test(
      'SRP: McpToolSchemaAdapter sanitizes external schemas, allocates unique names, and coerces legacy params',
      () async {
        final sanitized = McpToolSchemaAdapter.sanitizeMcpInputSchema(
          <String, dynamic>{
            '\$schema': 'https://json-schema.org/draft/2020-12/schema',
            'unknownKeyword': 'should_be_dropped',
            'properties': <String, dynamic>{
              'mode': <String, dynamic>{
                'anyOf': <Object?>[
                  <String, dynamic>{'type': 'null'},
                  <String, dynamic>{
                    'type': 'string',
                    'enum': <String>['fast', 'accurate'],
                  },
                ],
                'description': 'Execution   mode   with extra spacing.',
              },
            },
          },
        );
        expect(sanitized['type'], 'object');
        expect(sanitized.containsKey('unknownKeyword'), isFalse);

        final used = <String>{'search'};
        expect(
          McpToolSchemaAdapter.allocateExposedToolName(
            serverName: 'docs',
            rawToolName: 'search',
            usedNames: used,
          ),
          'docs_search',
        );

        final tool = McpToolSchemaAdapter.toLlamaToolDefinition(
          McpToolDescriptor(
            serverId: 's1',
            serverName: 'Docs',
            name: 'query',
            exposedToolName: 'docs_query',
            description: 'Search docs.',
            inputSchema: sanitized,
          ),
          handler: (ToolParams p) async => p.getString('mode') ?? 'none',
        );
        final coerced = McpToolSchemaAdapter.coerceToLegacyToolDefinition(tool);
        expect(coerced.name, 'docs_query');
        expect(coerced.parameters.map((ToolParam p) => p.name), <String>[
          'mode',
        ]);
        expect(
          await coerced.invoke(const <String, dynamic>{'mode': 'fast'}),
          'fast',
        );
      },
    );

    test(
      'OCP/DIP: CuratedStudioModelCatalog(extraModels) flows through ModelHubController',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();

        const extraModel = StudioModelDescriptor(
          id: 'custom-org-gemma-test-q4',
          name: 'Custom Org Model Q4',
          description: 'Injected extension model.',
          category: StudioModelCategory.chat,
          specialty: StudioModelSpecialty.generalChat,
          filename: 'custom-org-q4.gguf',
          sourceUri: 'https://example.com/custom-org-q4.gguf',
          sizeBytes: 512 * 1024 * 1024,
          quantizationLabel: 'Q4_K_M',
        );

        final catalog = const CuratedStudioModelCatalog(
          extraModels: <StudioModelDescriptor>[extraModel],
        );
        final storage = FakeStudioStoragePort();
        final inference = FakeInferencePort();
        final hub = ModelHubController(
          deps: StudioStorageAndInferenceDeps(
            storagePort: storage,
            inferencePort: inference,
            shellController: shell,
          ),
          modelCatalog: catalog,
          isWeb: false,
          isMobile: false,
        );
        await hub.initialize();

        expect(catalog.byId(extraModel.id), equals(extraModel));
        expect(
          hub.installedChatModels().any(
            (StudioModelDescriptor m) => m.id == extraModel.id,
          ),
          isTrue,
        );

        await hub.dispose();
        await inference.dispose();
        await storage.dispose();
        await shell.dispose();
      },
    );
  });
}
