import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  group('StudioToolRegistry', () {
    test(
      'evaluates arithmetic expressions and parses custom JSON schemas',
      () async {
        expect(
          StudioToolRegistry.evaluateExpression('(12 + 8) * 3 - sqrt(81)'),
          closeTo(51.0, 1e-6),
        );

        final tools = StudioToolRegistry.resolveActiveTools(
          enabledBuiltInNames: const <String>['convertUnits'],
          customDeclarationsJson: '''[
          {
            "name": "lookupOrder",
            "description": "Look up an order status",
            "parameters": {
              "type": "object",
              "properties": { "orderId": { "type": "string" } }
            }
          }
        ]''',
        );
        expect(tools.map((t) => t.name), <String>[
          'convertUnits',
          'lookupOrder',
        ]);
        final customOut =
            await tools.last.invoke(<String, dynamic>{'orderId': 'ORD-42'})
                as Map<String, Object?>;
        expect(customOut['status'], 'simulated_ok');
      },
    );
  });

  group('FileConversationStore & ChatWorkspaceController', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('studio_core_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'exports portable media and imports it into independently owned files',
      () async {
        final kv = InMemoryKeyValueStore();
        final store = createDefaultConversationStore(
          fallbackKeyValueStore: kv,
          directoryPath: tempDir.path,
        );
        final shell = StudioShellController(keyValueStore: kv);
        final inference = FakeInferencePort();
        final chat = ChatWorkspaceController(
          conversationStore: store,
          inferencePort: inference,
          shellController: shell,
        );
        addTearDown(chat.dispose);
        addTearDown(shell.dispose);
        addTearDown(inference.dispose);
        await shell.initialize();
        await chat.initialize();
        final bytes = Uint8List.fromList(<int>[1, 2, 3]);
        final original = StudioConversation.create(id: 'portable')
            .appendToActiveBranch(
              StudioMessage(
                id: 'user',
                role: StudioRole.user,
                text: 'media',
                createdAt: DateTime.now(),
                attachments: <StudioAttachment>[
                  for (final kind in StudioAttachmentKind.values)
                    StudioAttachment(
                      id: kind.name,
                      kind: kind,
                      name: 'media',
                      bytes: bytes,
                    ),
                ],
              ),
            );
        const codec = StudioConversationCodec();
        final inlineJson = codec.encodeJson(original);
        expect(
          codec.decodeJson(inlineJson).nodes.single.attachments.first.bytes,
          bytes,
        );
        final source = await chat.importFromJson(inlineJson);
        final sourcePaths = source.nodes.single.attachments
            .map((a) => a.localPath!)
            .toList();
        final exported = await chat.exportActiveAsJson();
        expect(exported, isNot(contains('localPath')));
        expect(exported, isNot(contains(tempDir.path)));
        final imported = await chat.importFromJson(exported);
        await store.delete(source.id);
        expect(await File(sourcePaths.first).exists(), isFalse);
        for (final attachment in imported.nodes.single.attachments) {
          expect(attachment.bytes, isNull);
          expect(await File(attachment.localPath!).readAsBytes(), bytes);
        }
        final reloaded = (await store.loadAll()).singleWhere(
          (c) => c.id == imported.id,
        );
        expect(
          await store.readAttachmentBytes(
            reloaded.nodes.single.attachments.first,
          ),
          bytes,
        );
        await File(imported.nodes.single.attachments.first.localPath!).delete();
        await expectLater(
          chat.exportActiveAsJson(),
          throwsA(isA<FormatException>()),
        );
        final untrusted = jsonDecode(inlineJson) as Map<String, dynamic>;
        final attachmentJson =
            ((untrusted['nodes'] as List).first as Map)['attachments'] as List;
        (attachmentJson.first as Map)['localPath'] = '/private/secret';
        final sanitized = codec.decodeJson(jsonEncode(untrusted));
        expect(sanitized.nodes.single.attachments.first.localPath, isNull);
        (attachmentJson.first as Map).remove('bytesBase64');
        expect(
          () => codec.decodeJson(jsonEncode(untrusted)),
          throwsFormatException,
        );
      },
    );

    test(
      'Stop during model loading prevents generation and preserves a newer request',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final inference = _GatedReadyInferencePort();
        final firstReady = Completer<bool>();
        final secondReady = Completer<bool>();
        final entered = <Completer<void>>[Completer<void>(), Completer<void>()];
        var loads = 0;
        final chat = ChatWorkspaceController(
          conversationStore: KeyValueConversationStore(kv),
          inferencePort: inference,
          shellController: shell,
          ensureModelReady: () {
            final index = loads++;
            entered[index].complete();
            return index == 0 ? firstReady.future : secondReady.future;
          },
        );
        addTearDown(chat.dispose);
        addTearDown(shell.dispose);
        addTearDown(inference.dispose);
        await shell.initialize();
        await chat.initialize();
        final firstSend = chat.sendMessage('cancel this');
        await entered[0].future;
        chat.stopGeneration();
        expect(chat.activeStreamStore.state.isGenerating, isFalse);
        final secondSend = chat.sendMessage('continue this');
        await entered[1].future;
        firstReady.complete(true);
        await firstSend;
        expect(inference.lastRequest, isNull);
        expect(chat.activeStreamStore.state.isGenerating, isTrue);
        expect(
          chat.state.activeConversation!.nodes.where(
            (n) => n.role == StudioRole.assistant,
          ),
          isEmpty,
        );
        inference.nextEvents = const <StudioTurnEvent>[
          StudioTextDeltaEvent('next answer'),
        ];
        secondReady.complete(true);
        await secondSend;
        expect(inference.lastRequest, isNotNull);
        expect(
          chat.state.activeConversation!.activeBranch.last.text,
          'next answer',
        );
        expect(chat.activeStreamStore.state.isGenerating, isFalse);
        expect(chat.state.lastTurnError, isNull);
      },
    );

    test(
      'persists attachments off-heap and streams turns without structural churn',
      () async {
        final kv = InMemoryKeyValueStore();
        final convStore = createDefaultConversationStore(
          fallbackKeyValueStore: kv,
          directoryPath: tempDir.path,
        );
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();

        final fakeInference = FakeInferencePort()
          ..nextEvents = <StudioTurnEvent>[
            const StudioThinkingDeltaEvent('Analyzing...'),
            const StudioToolInvocationEvent(
              StudioToolInvocation(
                id: 'call_1',
                name: 'getWeather',
                argumentsJson: '{"city":"Seoul"}',
                resultJson: '{"temperature":18}',
                durationMs: 4,
              ),
            ),
            const StudioTextDeltaEvent('Seoul is '),
            const StudioTextDeltaEvent('18°C.'),
            const StudioTurnCompletedEvent(
              StudioTurnResult(
                text: 'Seoul is 18°C.',
                thinkingText: 'Analyzing...',
                toolInvocations: <StudioToolInvocation>[
                  StudioToolInvocation(
                    id: 'call_1',
                    name: 'getWeather',
                    argumentsJson: '{"city":"Seoul"}',
                    resultJson: '{"temperature":18}',
                    durationMs: 4,
                  ),
                ],
                metrics: StudioTurnMetrics(
                  generatedTokens: 6,
                  elapsedMs: 120,
                  decodeElapsedMs: 100,
                  firstTokenLatencyMs: 20,
                ),
              ),
            ),
          ];

        final chat = ChatWorkspaceController(
          conversationStore: convStore,
          inferencePort: fakeInference,
          shellController: shell,
        );
        await chat.initialize();

        var structuralEmissions = 0;
        var streamEmissions = 0;
        final subStruct = chat.store.stream.listen(
          (_) => structuralEmissions++,
        );
        final subStream = chat.activeStreamStore.stream.listen(
          (_) => streamEmissions++,
        );

        chat.addPendingAttachment(
          StudioAttachment(
            id: 'att1',
            kind: StudioAttachmentKind.image,
            name: 'chart.png',
            bytes: Uint8List.fromList(<int>[137, 80, 78, 71]),
          ),
        );
        await chat.sendMessage('What is the weather in Seoul?');

        final branch = chat.state.activeConversation!.activeBranch;
        expect(branch.length, 2);
        expect(branch.first.attachments.first.localPath, isNotNull);
        expect(branch.last.text, 'Seoul is 18°C.');
        expect(branch.last.thinkingText, 'Analyzing...');
        expect(branch.last.toolCalls.single.name, 'getWeather');
        expect(streamEmissions, greaterThanOrEqualTo(3));
        expect(structuralEmissions, lessThan(streamEmissions));

        // Verify edit + branch creates sibling without losing first answer.
        fakeInference.nextEvents = const <StudioTurnEvent>[
          StudioTextDeltaEvent('Tokyo is 20°C.'),
          StudioTurnCompletedEvent(
            StudioTurnResult(
              text: 'Tokyo is 20°C.',
              metrics: StudioTurnMetrics(
                generatedTokens: 4,
                elapsedMs: 80,
                decodeElapsedMs: 70,
              ),
            ),
          ),
        ];
        await chat.editUserMessageAndBranch(
          originalMessageId: branch.first.id,
          editedText: 'What is the weather in Tokyo?',
        );

        final updatedConv = chat.state.activeConversation!;
        expect(updatedConv.activeBranch.last.text, 'Tokyo is 20°C.');
        expect(
          updatedConv.siblingIdsOf(updatedConv.activeBranch.first.id).length,
          2,
        );

        await subStruct.cancel();
        await subStream.cancel();
        await chat.dispose();
        await shell.dispose();
        await fakeInference.dispose();
      },
    );
  });

  group('LocalModelScanner & DefaultStudioModelStorageAdapter', () {
    late Directory scanRoot;
    late Directory extraRoot;

    Future<File> writeDummyFile(
      Directory dir,
      String relativePath, {
      int sizeBytes = 1200 * 1024,
    }) async {
      final file = File('${dir.path}/$relativePath');
      await file.parent.create(recursive: true);
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(sizeBytes);
      await raf.close();
      return file;
    }

    setUp(() async {
      scanRoot = await Directory.systemTemp.createTemp('studio_scan_root_');
      extraRoot = await Directory.systemTemp.createTemp('studio_extra_root_');
    });

    tearDown(() async {
      if (await scanRoot.exists()) {
        await scanRoot.delete(recursive: true);
      }
      if (await extraRoot.exists()) {
        await extraRoot.delete(recursive: true);
      }
    });

    test(
      'matches curated models zero-copy, pairs companions, filters stubs, and surfaces across all controllers',
      () async {
        // 1. Curated model + projector in hash-suffixed cache subdirectories.
        await writeDummyFile(
          scanRoot,
          'Qwen3.5-0.8B-Q4_K_M-d4e3cbd8f81b/Qwen3.5-0.8B-Q4_K_M.gguf',
        );
        await writeDummyFile(
          scanRoot,
          'Qwen3.5-0.8B-mmproj-F16-56e4c6cfe73b/Qwen3.5-0.8B-mmproj-F16.gguf',
        );

        // 2. Curated SD-Turbo + TAESD alias (diffusion_pytorch_model.safetensors).
        await writeDummyFile(
          scanRoot,
          'sd_turbo-f16-q8_0-12701596ebcc/sd_turbo-f16-q8_0.gguf',
        );
        await writeDummyFile(
          scanRoot,
          'diffusion_pytorch_model-3911c92da7ae/diffusion_pytorch_model.safetensors',
        );

        // 3. Standalone multimodal chat model + projector.
        await writeDummyFile(scanRoot, 'SmolVLM-500M-Instruct-Q8_0.gguf');
        await writeDummyFile(scanRoot, 'mmproj-SmolVLM-500M-Instruct-f16.gguf');

        // 4. Standalone TTS model + projector.
        await writeDummyFile(
          scanRoot,
          'Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M-e95839ea00c8/Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf',
        );
        await writeDummyFile(
          scanRoot,
          'Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0-aed0063baa2b/Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf',
        );

        // 5. Standalone Laya decision model + head + EmbeddingGemma-2 in extraRoot.
        await writeDummyFile(extraRoot, 'laya-Q4_K_M.gguf');
        await writeDummyFile(extraRoot, 'laya-head.safetensors');
        await writeDummyFile(extraRoot, 'embeddinggemma-2-740m.litertlm');

        // 6. Auxiliary / stub files that MUST be ignored as standalone models.
        await writeDummyFile(scanRoot, 'ggml-vocab-qwen2.gguf');
        await writeDummyFile(scanRoot, 'adapter-1234/adapter.gguf');
        await writeDummyFile(
          scanRoot,
          'tiny-stub.gguf',
          sizeBytes: 512,
        ); // < 1 MiB

        final storage = DefaultStudioModelStorageAdapter(
          downloadManager: DefaultModelDownloadManager.appPrivate(
            cacheDirectory: '${scanRoot.path}/empty_managed',
          ),
          localScanner: LocalModelScanner(
            defaultRoots: <String>[scanRoot.path],
          ),
        );
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final inference = FakeInferencePort();

        final hub = ModelHubController(
          deps: StudioStorageAndInferenceDeps(
            storagePort: storage,
            inferencePort: inference,
            shellController: shell,
          ),
          isWeb: false,
          isMobile: false,
        );
        await hub.initialize();
        await hub.addCustomModelDirectory(extraRoot.path);

        // Verify curated models matched without managed metadata.json entries!
        expect(
          hub.state.cachedModelIds,
          containsAll(<String>['qwen3.5-0.8b-q4-k-m', 'sd-turbo-q8_0-taesd']),
        );

        // Zero-copy ensureDownloaded on matched curated model must NOT hit network.
        final curatedQwen = CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!;
        final resolvedQwen = await storage.ensureDownloaded(
          curatedQwen,
          isWeb: false,
        );
        expect(resolvedQwen.primarySource.isLocal, isTrue);
        expect(
          resolvedQwen.companionSources['projector']?.path,
          endsWith('Qwen3.5-0.8B-mmproj-F16.gguf'),
        );

        // Verify standalone models & companion pairing.
        final localIds = hub.state.localModels.map((m) => m.id).toSet();
        expect(
          localIds,
          containsAll(<String>[
            'local:smolvlm-500m-instruct-q8_0.gguf',
            'local:qwen3-tts-12hz-0.6b-base.q4_k_m.gguf',
            'local:laya-q4_k_m.gguf',
            'local:embeddinggemma-2-740m.litertlm',
          ]),
        );
        // Stubs, vocab, adapters, and raw mmproj/safetensors are NOT standalone.
        expect(
          localIds.any(
            (id) =>
                id.contains('mmproj') ||
                id.contains('vocab') ||
                id.contains('adapter') ||
                id.contains('tiny-stub'),
          ),
          isFalse,
        );

        final smolVlm = hub.state.localModels.firstWhere(
          (m) => m.id == 'local:smolvlm-500m-instruct-q8_0.gguf',
        );
        expect(smolVlm.supportsVision, isTrue);
        expect(
          smolVlm.projectorCompanion?.filename,
          'mmproj-SmolVLM-500M-Instruct-f16.gguf',
        );

        final embedGemma2 = hub.state.localModels.firstWhere(
          (m) => m.id == 'local:embeddinggemma-2-740m.litertlm',
        );
        expect(
          embedGemma2.embeddingProfile,
          LlamaEmbeddingProfile.embeddingGemma2,
        );

        // Verify Speech & Playground controllers automatically see local models.
        final speech = SpeechWorkspaceController(
          storagePort: storage,
          speechPort: DummySpeechPort(),
          isWeb: false,
          isMobile: false,
        );
        expect(
          speech.availableTtsModels.first.id,
          'local:qwen3-tts-12hz-0.6b-base.q4_k_m.gguf',
        );

        final playground = PlaygroundWorkspaceController(
          storagePort: storage,
          playgroundPort: DummyPlaygroundPort(),
          isWeb: false,
          isMobile: false,
        );
        expect(
          playground.availableLabModels.map((m) => m.id),
          containsAll(<String>[
            'local:laya-q4_k_m.gguf',
            'local:embeddinggemma-2-740m.litertlm',
          ]),
        );

        await speech.dispose();
        await playground.dispose();
        await hub.dispose();
        await shell.dispose();
        await storage.dispose();
        await inference.dispose();
      },
    );

    test(
      'auto-loads best cached chat model on send when unloaded and humanizes errors when cache is empty',
      () async {
        // Case 1: Cached chat model on disk -> sending a message while unloaded
        // automatically activates Qwen3.5 0.8B and streams the reply!
        await writeDummyFile(
          scanRoot,
          'Qwen3.5-0.8B-Q4_K_M-d4e3cbd8f81b/Qwen3.5-0.8B-Q4_K_M.gguf',
        );
        await writeDummyFile(
          scanRoot,
          'Qwen3.5-0.8B-mmproj-F16-56e4c6cfe73b/Qwen3.5-0.8B-mmproj-F16.gguf',
        );

        final storage = DefaultStudioModelStorageAdapter(
          localScanner: LocalModelScanner(
            defaultRoots: <String>[scanRoot.path],
          ),
        );
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();

        final autoLoadInference = UnloadedThenReadyInferencePort();
        final hub = ModelHubController(
          deps: StudioStorageAndInferenceDeps(
            storagePort: storage,
            inferencePort: autoLoadInference,
            shellController: shell,
          ),
          isWeb: false,
          isMobile: false,
        );
        await hub.initialize();
        expect(autoLoadInference.runtimeStore.state.isReady, isFalse);
        expect(hub.installedChatModels().first.id, 'qwen3.5-0.8b-q4-k-m');

        final chat = ChatWorkspaceController(
          conversationStore: KeyValueConversationStore(kv),
          inferencePort: autoLoadInference,
          shellController: shell,
          ensureModelReady: hub.ensureChatModelReady,
        );
        await chat.initialize();
        await chat.sendMessage('Hello after auto-load!');

        expect(autoLoadInference.runtimeStore.state.isReady, isTrue);
        expect(
          autoLoadInference.runtimeStore.state.activeDescriptor?.id,
          'qwen3.5-0.8b-q4-k-m',
        );
        expect(
          chat.state.activeConversation!.activeBranch.last.text,
          'Auto-loaded answer!',
        );
        expect(chat.state.lastTurnError, isNull);

        await chat.dispose();
        await hub.dispose();
        await shell.dispose();
        await storage.dispose();
        await autoLoadInference.dispose();

        // Case 2: Empty cache -> strips raw LlamaStateException prefix cleanly.
        final emptyStorage = DefaultStudioModelStorageAdapter(
          downloadManager: DefaultModelDownloadManager(
            defaultCacheDirectory: '${extraRoot.path}/managed-cache',
          ),
          localScanner: LocalModelScanner(
            defaultRoots: <String>[extraRoot.path],
          ),
        );
        final emptyKv = InMemoryKeyValueStore();
        final emptyShell = StudioShellController(keyValueStore: emptyKv);
        await emptyShell.initialize();
        final unloadedOnly = UnloadedThenReadyInferencePort(refuseLoad: true);
        final emptyHub = ModelHubController(
          deps: StudioStorageAndInferenceDeps(
            storagePort: emptyStorage,
            inferencePort: unloadedOnly,
            shellController: emptyShell,
          ),
          isWeb: false,
          isMobile: false,
        );
        await emptyHub.initialize();
        final emptyChat = ChatWorkspaceController(
          conversationStore: KeyValueConversationStore(emptyKv),
          inferencePort: unloadedOnly,
          shellController: emptyShell,
          ensureModelReady: emptyHub.ensureChatModelReady,
        );
        await emptyChat.initialize();
        await emptyChat.sendMessage('Will fail cleanly');

        final errTurn = emptyChat.state.activeConversation!.activeBranch.last;
        expect(errTurn.isError, isTrue);
        expect(errTurn.text, isNot(contains('LlamaStateException')));
        expect(
          errTurn.text,
          'Load a model in Model Hub before sending a message.',
        );

        await emptyChat.dispose();
        await emptyHub.dispose();
        await emptyShell.dispose();
        await emptyStorage.dispose();
        await unloadedOnly.dispose();
      },
    );
  });

  group('Casual Chat isolation & off-heap Note persistence', () {
    test(
      'FileNoteStore stores media off-heap, strips base64 from JSON, and migrates legacy notes',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'file_note_store_test_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final legacyImageBytes = Uint8List.fromList(<int>[137, 80, 78, 71]);
        final legacyAudioBytes = Uint8List.fromList(<int>[82, 73, 70, 70]);
        final legacyNote = StudioNote(
          id: 'legacy_note_1',
          title: 'Legacy Multimodal Note',
          content: 'Migrated from SharedPreferences.',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 2),
          sourceKind: StudioNoteSourceKind.audio,
          sourceFileName: 'memo.wav',
          imageBase64: base64Encode(legacyImageBytes),
          imageMimeType: 'image/png',
          audioBase64: base64Encode(legacyAudioBytes),
        );
        final kv = InMemoryKeyValueStore(<String, Object>{
          StudioNoteStore.legacyNotesStorageKey: jsonEncode(
            <Map<String, dynamic>>[legacyNote.toJson()],
          ),
        });

        final store = createDefaultNoteStore(
          fallbackKeyValueStore: kv,
          directoryPath: tempDir.path,
        );
        final migrated = await store.loadAll();
        expect(migrated, hasLength(1));
        final note = migrated.single;
        expect(note.id, 'legacy_note_1');
        // Base64 strings are stripped from heap and on-disk JSON!
        expect(note.imageBase64, isNull);
        expect(note.audioBase64, isNull);
        expect(note.imageLocalPath, isNotNull);
        expect(note.audioLocalPath, isNotNull);
        expect(note.hasImage, isTrue);
        expect(note.hasAudio, isTrue);

        // Legacy blob removed from KeyValueStore after migration.
        expect(
          await kv.readString(StudioNoteStore.legacyNotesStorageKey),
          isNull,
        );

        // On-disk JSON contains metadata + local paths without base64 blobs.
        final jsonFile = File('${tempDir.path}/notes/legacy_note_1.json');
        expect(await jsonFile.exists(), isTrue);
        final rawJson = await jsonFile.readAsString();
        expect(rawJson, isNot(contains(base64Encode(legacyImageBytes))));

        // Off-heap binary reads round-trip exact bytes.
        expect(await store.readImageBytes(note), legacyImageBytes);
        expect(await store.readAudioBytes(note), legacyAudioBytes);

        // Deleting note removes both JSON and off-heap media folder.
        await store.delete('legacy_note_1');
        expect(await jsonFile.exists(), isFalse);
        expect(
          await Directory('${tempDir.path}/note_media/legacy_note_1').exists(),
          isFalse,
        );
      },
    );

    test(
      'ChatWorkspaceController isolates casual Chat from AGENTS.md and MCP unless opted in',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final mcp = FakeConnectedMcpManager(keyValueStore: kv);
        await mcp.initialize();

        final inference = FakeInferencePort()
          ..nextEvents = const <StudioTurnEvent>[
            StudioTextDeltaEvent('Hi!'),
            StudioTurnCompletedEvent(
              StudioTurnResult(
                text: 'Hi!',
                metrics: StudioTurnMetrics(
                  generatedTokens: 2,
                  elapsedMs: 10,
                  decodeElapsedMs: 8,
                ),
              ),
            ),
          ];

        final hugeWorkspaceContext =
            'RULE ' * 1200; // > maxChatWorkspaceContextChars (3600)
        final chat = ChatWorkspaceController(
          inferencePort: inference,
          conversationStore: KeyValueConversationStore(kv),
          shellController: shell,
          mcpManager: mcp,
          workspaceInstructionsProvider: () => hugeWorkspaceContext,
        );
        await chat.initialize();

        // Default: casual Chat neither injects AGENTS.md nor bridges MCP schemas.
        expect(shell.state.settings.includeWorkspaceContextInChat, isFalse);
        expect(shell.state.settings.enableMcpInChat, isFalse);
        await chat.sendMessage('Hello there!');
        expect(inference.lastRequest!.extraSystemContext, isEmpty);
        expect(
          inference.lastRequest!.extraTools.any(
            (ToolDefinition t) => t.name == 'mcp_lookup',
          ),
          isFalse,
        );

        // Opt-in: AGENTS.md is budgeted and MCP tools are bridged when enabled.
        await shell.updateSettings(
          (StudioSettings s) => s.copyWith(
            includeWorkspaceContextInChat: true,
            enableMcpInChat: true,
            toolsEnabled: true,
          ),
        );
        await chat.sendMessage('Check with context and MCP');
        expect(
          inference.lastRequest!.extraSystemContext.length,
          lessThanOrEqualTo(
            ChatWorkspaceController.maxChatWorkspaceContextChars + 120,
          ),
        );
        expect(
          inference.lastRequest!.extraSystemContext,
          contains('truncated for fast Chat prompt evaluation'),
        );
        expect(
          inference.lastRequest!.extraTools.any(
            (ToolDefinition t) => t.name == 'mcp_lookup',
          ),
          isTrue,
        );

        await chat.dispose();
        await mcp.dispose();
        await shell.dispose();
        await inference.dispose();
      },
    );
  });
}

class _GatedReadyInferencePort extends FakeInferencePort {
  final StateStore<StudioRuntimeSnapshot> _unloaded =
      StateStore<StudioRuntimeSnapshot>(const StudioRuntimeSnapshot());

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _unloaded;

  @override
  Future<void> dispose() async {
    await _unloaded.dispose();
    await super.dispose();
  }
}
