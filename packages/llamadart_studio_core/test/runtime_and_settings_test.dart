import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  group('StateStore', () {
    test('deduplicates equal states and emits sliced updates', () async {
      final store = StateStore<int>(1);
      final emitted = <bool>[];
      final sub = store.select((int s) => s.isEven).listen(emitted.add);

      store.set(1);
      store.set(3);
      store.set(4);
      store.set(6);
      store.set(7);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, <bool>[false, true, false]);
      await sub.cancel();
      await store.dispose();
    });
  });

  group('StudioConversation branching & codec', () {
    test('supports non-destructive sibling branches and round-trip JSON', () {
      final root = StudioConversation.create(id: 'c1', title: 'Test');
      final u1 = StudioMessage(
        id: 'u1',
        role: StudioRole.user,
        text: 'Hello',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final a1 = StudioMessage(
        id: 'a1',
        role: StudioRole.assistant,
        text: 'First reply',
        createdAt: DateTime.utc(2026, 1, 1, 0, 1),
      );
      final a2 = StudioMessage(
        id: 'a2',
        role: StudioRole.assistant,
        text: 'Regenerated reply',
        createdAt: DateTime.utc(2026, 1, 1, 0, 2),
      );

      var conv = root
          .appendChild(parentId: null, message: u1)
          .appendChild(parentId: 'u1', message: a1)
          .appendChild(parentId: 'u1', message: a2);

      expect(conv.activeBranch.map((m) => m.id), <String>['u1', 'a2']);
      expect(conv.siblingIdsOf('a2'), <String>['a1', 'a2']);

      conv = conv.selectBranch('a1');
      expect(conv.activeBranch.map((m) => m.id), <String>['u1', 'a1']);

      const codec = StudioConversationCodec();
      final jsonText = codec.encodeJson(conv);
      final restored = codec.decodeJson(jsonText);
      expect(restored.activeBranch.map((m) => m.id), <String>['u1', 'a1']);
      expect(restored.siblingIdsOf('a1'), <String>['a1', 'a2']);
      expect(codec.encodeMarkdown(restored), contains('First reply'));
    });
  });

  group('StudioSettings runtime param mapping', () {
    test('builds LlamaCppModelParams vs LiteRtLmModelParams strictly', () {
      const settings = StudioSettings(
        contextSize: 8192,
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q4_0,
        flashAttention: FlashAttention.disabled,
      );

      final ggufParams = settings.toModelParams(
        format: ModelFormat.gguf,
        isWeb: false,
      );
      expect(ggufParams, isA<LlamaCppModelParams>());
      expect(ggufParams.flashAttention, FlashAttention.enabled);
      expect(ggufParams.cacheTypeK, KvCacheType.q8_0);

      final litertParams = settings.toModelParams(
        format: ModelFormat.liteRtLm,
        isWeb: false,
      );
      expect(litertParams, isA<LiteRtLmModelParams>());
      expect(litertParams.contextSize, 8192);
      expect(litertParams.gpuLayers, ModelParams.maxGpuLayers);

      final litertWebParams = const StudioSettings(
        gpuLayers: 32,
        numberOfThreads: 4,
      ).toModelParams(format: ModelFormat.liteRtLm, isWeb: true);
      expect(litertWebParams.gpuLayers, ModelParams.maxGpuLayers);
      expect(litertWebParams.numberOfThreads, 0);
    });
  });

  group('BootGuardService & MemoryFitEstimator', () {
    test(
      'detects interrupted model load and clears sentinel on next boot',
      () async {
        final kv = InMemoryKeyValueStore();
        final guard = BootGuardService(kv);

        expect(await guard.inspectStartupAndClear(), isNull);
        await guard.beginModelLoad(
          modelName: 'Gemma 4 31B',
          modelIdOrPath: 'gemma-31b',
        );

        final alert = await guard.inspectStartupAndClear();
        expect(alert, isNotNull);
        expect(alert!.modelName, 'Gemma 4 31B');
        expect(await guard.inspectStartupAndClear(), isNull);
      },
    );

    test('classifies GPU fit and hybrid CPU/GPU offload', () {
      final fits = MemoryFitEstimator.evaluate(
        modelSizeBytes: 800 * 1024 * 1024,
        requestedContextSize: 4096,
        cacheTypeK: KvCacheType.f16,
        cacheTypeV: KvCacheType.f16,
        vramFreeBytes: 8 * 1024 * 1024 * 1024,
      );
      expect(fits.status, MemoryFitStatus.fitsInVram);
      expect(fits.recommendedGpuLayers, 99);

      final hybrid = MemoryFitEstimator.evaluate(
        modelSizeBytes: 8 * 1024 * 1024 * 1024,
        requestedContextSize: 8192,
        cacheTypeK: KvCacheType.f16,
        cacheTypeV: KvCacheType.f16,
        vramFreeBytes: 5 * 1024 * 1024 * 1024,
      );
      expect(hybrid.status, MemoryFitStatus.hybridCpuGpu);
      expect(hybrid.recommendedGpuLayers, lessThan(99));
    });
  });

  group('DirectLlamaInferencePort speculative decoding compatibility', () {
    test('resolveTurnGenerationParams gates media, grammar, and budgets', () {
      const capabilities = LlamaEngineCapabilities(
        isSupported: true,
        runtime: LlamaRuntime.llamaCpp,
        supportsThinkingBudget: true,
        supportsPenalty: true,
      );
      const specConfig = SpeculativeDecodingConfig.mtp();
      const specBase = GenerationParams(
        maxTokens: 1024,
        speculativeDecoding: true,
        speculativeDecodingConfig: specConfig,
      );

      final withMedia = DirectLlamaInferencePort.resolveTurnGenerationParams(
        baseGenParams: specBase,
        capabilities: capabilities,
        hasMediaParts: true,
        hasResponseFormat: false,
        effectiveBudgetTokens: 512,
        explicitThinkingBudgetTokens: 0,
      );
      expect(withMedia.speculativeDecoding, isFalse);
      expect(withMedia.speculativeDecodingConfig, isNull);
      expect(withMedia.thinkingBudget, isNull);

      final withSchema = DirectLlamaInferencePort.resolveTurnGenerationParams(
        baseGenParams: specBase,
        capabilities: capabilities,
        hasMediaParts: false,
        hasResponseFormat: true,
        effectiveBudgetTokens: 512,
        explicitThinkingBudgetTokens: 0,
      );
      expect(withSchema.speculativeDecoding, isFalse);
      expect(withSchema.speculativeDecodingConfig, isNull);
      expect(withSchema.thinkingBudget, isNull);

      final withDefaultThinking =
          DirectLlamaInferencePort.resolveTurnGenerationParams(
            baseGenParams: specBase,
            capabilities: capabilities,
            hasMediaParts: false,
            hasResponseFormat: false,
            effectiveBudgetTokens: 512,
            explicitThinkingBudgetTokens: 0,
          );
      expect(withDefaultThinking.speculativeDecoding, isTrue);
      expect(withDefaultThinking.speculativeDecodingConfig, specConfig);
      expect(withDefaultThinking.thinkingBudget, isNull);

      final withExplicitCap =
          DirectLlamaInferencePort.resolveTurnGenerationParams(
            baseGenParams: specBase,
            capabilities: capabilities,
            hasMediaParts: false,
            hasResponseFormat: false,
            effectiveBudgetTokens: 256,
            explicitThinkingBudgetTokens: 256,
          );
      expect(withExplicitCap.speculativeDecoding, isFalse);
      expect(withExplicitCap.speculativeDecodingConfig, isNull);
      expect(withExplicitCap.thinkingBudget?.maxTokens, 256);
    });

    test(
      'streamTurn falls back when backend throws LlamaUnsupportedException for speculative decoding and strips speculative on multimodal history',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'studio_spec_test_',
        );
        final dummyFile = File('${tempDir.path}/gemma-4-test.gguf')
          ..writeAsBytesSync(<int>[0x47, 0x47, 0x55, 0x46]);

        final backend = FakeSpeculativeFallbackBackend();
        final port = DirectLlamaInferencePort(backend: backend);
        final descriptor = StudioModelDescriptor(
          id: 'test-gemma-4',
          name: 'Test Gemma 4',
          publisher: 'Local',
          description: 'Test model',
          category: StudioModelCategory.chat,
          filename: 'gemma-4-test.gguf',
          sourceUri: dummyFile.path,
          sizeBytes: 1024,
        );
        const settings = StudioSettings(
          speculativeMode: StudioSpeculativeMode.mtp,
          toolsEnabled: false,
          thinkingEnabled: true,
        );

        await port.loadModel(
          assets: ResolvedModelAssets(
            descriptor: descriptor,
            primarySource: ModelSource.parse(dummyFile.path),
          ),
          settings: settings,
          isWeb: false,
        );

        // Text-only turn: first call requests speculative decoding, backend
        // throws LlamaUnsupportedException, port retries cleanly without it.
        final textOnlyEvents = await port
            .streamTurn(
              StudioTurnRequest(
                history: <StudioMessage>[
                  StudioMessage(
                    id: 'u1',
                    role: StudioRole.user,
                    text: 'hi',
                    createdAt: DateTime.utc(2026, 1, 1),
                  ),
                ],
                settings: settings,
                systemPrompt: '',
              ),
            )
            .toList();

        expect(backend.recordedSpeculativeFlags, <bool>[true, false]);
        final completed = textOnlyEvents
            .whereType<StudioTurnCompletedEvent>()
            .single
            .result;
        expect(completed.text, 'hello');

        // Conversation with a prior image attachment: port proactively strips
        // speculative decoding before calling the backend (single attempt).
        backend.recordedSpeculativeFlags.clear();
        final multimodalHistoryEvents = await port
            .streamTurn(
              StudioTurnRequest(
                history: <StudioMessage>[
                  StudioMessage(
                    id: 'u1',
                    role: StudioRole.user,
                    text: 'describe this image',
                    createdAt: DateTime.utc(2026, 1, 1),
                    attachments: <StudioAttachment>[
                      StudioAttachment(
                        id: 'att1',
                        kind: StudioAttachmentKind.image,
                        name: 'photo.png',
                        bytes: Uint8List.fromList(<int>[1, 2, 3]),
                      ),
                    ],
                  ),
                  StudioMessage(
                    id: 'a1',
                    role: StudioRole.assistant,
                    text: 'A still life photo.',
                    createdAt: DateTime.utc(2026, 1, 1, 0, 1),
                  ),
                  StudioMessage(
                    id: 'u2',
                    role: StudioRole.user,
                    text: 'hi',
                    createdAt: DateTime.utc(2026, 1, 1, 0, 2),
                  ),
                ],
                settings: settings,
                systemPrompt: '',
              ),
            )
            .toList();

        expect(backend.recordedSpeculativeFlags, <bool>[false]);
        final multimodalCompleted = multimodalHistoryEvents
            .whereType<StudioTurnCompletedEvent>()
            .single
            .result;
        expect(multimodalCompleted.text, 'hello');

        await port.dispose();
        await tempDir.delete(recursive: true);
      },
    );
  });

  group('Extended runtime settings, catalog & history', () {
    test(
      'Curated catalog includes Qwen3.8 27B Coding first and applies thinkingBudgetTokens preset on activation',
      () async {
        final qwen38 = CuratedModelCatalog.byId('qwen3.8-27b-ud-q4-k-xl');
        expect(qwen38, isNotNull);
        expect(qwen38!.isRecommended, isTrue);
        expect(qwen38.supportsVision, isTrue);
        expect(qwen38.supportsToolCalling, isTrue);
        expect(qwen38.supportsThinking, isTrue);
        expect(qwen38.preset.thinkingBudgetTokens, 512);

        final qwen36 = CuratedModelCatalog.byId('qwen3.6-27b-ud-q4-k-xl');
        expect(qwen36, isNotNull);
        expect(qwen36!.isRecommended, isFalse);
        expect(qwen36.preset.thinkingBudgetTokens, 512);

        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        await shell.initialize();
        final storage = FakeStudioStoragePort();
        final inference = UnloadedThenReadyInferencePort();
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

        await hub.activateChatModel(qwen38);
        expect(shell.state.settings.activeModelId, 'qwen3.8-27b-ud-q4-k-xl');
        expect(shell.state.settings.thinkingBudgetTokens, 512);

        await hub.dispose();
        await shell.dispose();
        await storage.dispose();
        await inference.dispose();
      },
    );

    test(
      'StudioSettings maps extended LlamaCppModelParams, sanitizes moeCacheBytes, and maps presencePenalty',
      () {
        const settings = StudioSettings(
          presencePenalty: 0.45,
          numberOfThreads: 8,
          numberOfThreadsBatch: 12,
          batchSize: 2048,
          microBatchSize: 512,
          maxParallelSequences: 3,
          useMmap: false,
          useMlock: true,
          kvUnified: true,
          ropeFrequencyBase: 1000000.0,
          ropeFrequencyScale: 0.5,
          cpuMoeLayers: 0,
          moeCacheBytes: 1024 * 1024 * 512,
        );

        final roundTrip = StudioSettings.fromJson(settings.toJson());
        expect(roundTrip.presencePenalty, 0.45);
        expect(roundTrip.batchSize, 2048);
        expect(roundTrip.microBatchSize, 512);
        expect(roundTrip.maxParallelSequences, 3);
        expect(roundTrip.useMmap, isFalse);
        expect(roundTrip.useMlock, isTrue);
        expect(roundTrip.kvUnified, isTrue);
        expect(roundTrip.ropeFrequencyBase, 1000000.0);
        expect(roundTrip.ropeFrequencyScale, 0.5);

        final nativeParams =
            roundTrip.toModelParams(format: ModelFormat.gguf, isWeb: false)
                as LlamaCppModelParams;
        expect(nativeParams.numberOfThreads, 8);
        expect(nativeParams.numberOfThreadsBatch, 12);
        expect(nativeParams.batchSize, 2048);
        expect(nativeParams.microBatchSize, 512);
        expect(nativeParams.maxParallelSequences, 3);
        expect(nativeParams.useMmap, isFalse);
        expect(nativeParams.useMlock, isTrue);
        expect(nativeParams.kvUnified, isTrue);
        expect(nativeParams.ropeFrequencyBase, 1000000.0);
        expect(nativeParams.ropeFrequencyScale, 0.5);
        // Sanitized to 0 when cpuMoeLayers == 0 so ModelParams.validate() never throws.
        expect(nativeParams.moeCacheBytes, 0);
        expect(() => nativeParams.validate(), returnsNormally);

        final moeEnabledParams =
            roundTrip
                    .copyWith(cpuMoeLayers: 16)
                    .toModelParams(format: ModelFormat.gguf, isWeb: false)
                as LlamaCppModelParams;
        expect(moeEnabledParams.cpuMoeLayers, 16);
        expect(moeEnabledParams.moeCacheBytes, 1024 * 1024 * 512);
        expect(() => moeEnabledParams.validate(), returnsNormally);

        final webParams =
            roundTrip.toModelParams(format: ModelFormat.gguf, isWeb: true)
                as LlamaCppModelParams;
        expect(webParams.batchSize, 0);
        expect(webParams.microBatchSize, 0);
        expect(webParams.useMmap, isTrue);
        expect(webParams.useMlock, isFalse);

        final genParams = roundTrip.toGenerationParams(
          capabilities: const LlamaEngineCapabilities(
            isSupported: true,
            runtime: LlamaRuntime.llamaCpp,
            supportsPresencePenalty: true,
          ),
        );
        expect(genParams.presencePenalty, 0.45);
      },
    );

    test(
      'DirectLlamaInferencePort runExclusiveOnEngine blocks concurrent cross-workspace access cleanly',
      () async {
        final backend = FakeSpeculativeFallbackBackend();
        final port = DirectLlamaInferencePort(backend: backend);
        addTearDown(port.dispose);

        final gate = Completer<void>();
        final firstOp = port.runExclusiveOnEngine<String>('Chat generation', (
          _,
        ) async {
          await gate.future;
          return 'done';
        });

        expect(port.isBusy, isTrue);
        expect(port.activeOperationLabel, 'Chat generation');
        await expectLater(
          () => port.runExclusiveOnEngine<void>(
            'Playground benchmark',
            (_) async {},
          ),
          throwsA(
            isA<LlamaStateException>().having(
              (LlamaStateException e) => e.message,
              'message',
              contains('currently busy (Chat generation)'),
            ),
          ),
        );

        gate.complete();
        expect(await firstOp, 'done');
        expect(port.isBusy, isFalse);
      },
    );

    test(
      'Image/Speech controllers cap in-memory history at 24 items and StudioSettings tracks reload signature',
      () async {
        final storage = FakeStudioStoragePort();
        final imageCtrl = ImageWorkspaceController(
          storagePort: storage,
          imagePort: CountingMockImagePort(),
          isWeb: false,
          isMobile: false,
        );
        final speechCtrl = SpeechWorkspaceController(
          storagePort: storage,
          ttsPort: CountingMockTtsSpeechPort(),
          isWeb: false,
          isMobile: false,
        );
        addTearDown(() async {
          await imageCtrl.dispose();
          await speechCtrl.dispose();
          await storage.dispose();
        });

        await imageCtrl.loadModel(imageCtrl.availableModels.first);
        for (var i = 0; i < 28; i++) {
          await imageCtrl.generate(prompt: 'Prompt $i');
        }
        expect(
          imageCtrl.state.gallery.length,
          ImageWorkspaceController.maxGalleryItems,
        );
        final firstImgId = imageCtrl.state.gallery.first.id;
        imageCtrl.removeGalleryItem(firstImgId);
        expect(
          imageCtrl.state.gallery.length,
          ImageWorkspaceController.maxGalleryItems - 1,
        );
        imageCtrl.clearGallery();
        expect(imageCtrl.state.gallery, isEmpty);

        await speechCtrl.loadTtsModel(speechCtrl.availableTtsModels.first);
        for (var i = 0; i < 27; i++) {
          await speechCtrl.synthesizeText(text: 'Line $i');
        }
        expect(
          speechCtrl.state.synthesizedHistory.length,
          SpeechWorkspaceController.maxHistoryItems,
        );
        expect(
          speechCtrl.state.synthesizedHistory.map((clip) => clip.id).toSet(),
          hasLength(SpeechWorkspaceController.maxHistoryItems),
        );
        final firstClipId = speechCtrl.state.synthesizedHistory.first.id;
        speechCtrl.removeSynthesizedClip(firstClipId);
        expect(
          speechCtrl.state.synthesizedHistory.length,
          SpeechWorkspaceController.maxHistoryItems - 1,
        );
        speechCtrl.clearSynthesizedHistory();
        expect(speechCtrl.state.synthesizedHistory, isEmpty);

        // Verify unapplied engine reload signature & sampling reset.
        const baseSettings = StudioSettings(temperature: 1.4, topK: 90);
        final loadedSnap = StudioRuntimeSnapshot(
          phase: StudioEnginePhase.ready,
          loadedEngineSignature: baseSettings.engineLoadSignature(isWeb: false),
        );
        expect(
          loadedSnap.hasUnappliedEngineChanges(baseSettings, isWeb: false),
          isFalse,
        );
        final editedEngine = baseSettings.copyWith(batchSize: 2048);
        expect(
          loadedSnap.hasUnappliedEngineChanges(editedEngine, isWeb: false),
          isTrue,
        );
        final reset = editedEngine.resetSamplingDefaults();
        expect(reset.temperature, const StudioSettings().temperature);
        expect(reset.topK, const StudioSettings().topK);
        expect(reset.batchSize, 2048);
      },
    );
    test(
      'StudioSettings applies and detects Fast/Balanced/Quality hardware presets and persists inspectorExpertMode',
      () {
        const defaults = StudioSettings();
        expect(defaults.inspectorExpertMode, isFalse);

        final fast = defaults.applyHardwarePreset(StudioHardwarePreset.fast);
        expect(fast.activeHardwarePreset, StudioHardwarePreset.fast);
        expect(fast.contextSize, 2048);
        expect(fast.cacheTypeK, KvCacheType.q8_0);
        expect(fast.cacheTypeV, KvCacheType.q8_0);
        expect(fast.flashAttention, FlashAttention.enabled);

        final balanced = fast.applyHardwarePreset(
          StudioHardwarePreset.balanced,
        );
        expect(balanced.activeHardwarePreset, StudioHardwarePreset.balanced);
        expect(balanced.contextSize, 4096);
        expect(balanced.cacheTypeK, KvCacheType.f16);
        expect(balanced.cacheTypeV, KvCacheType.f16);

        final quality = balanced.applyHardwarePreset(
          StudioHardwarePreset.quality,
        );
        expect(quality.activeHardwarePreset, StudioHardwarePreset.quality);
        expect(quality.contextSize, 16384);
        expect(quality.cacheTypeK, KvCacheType.f16);
        expect(quality.cacheTypeV, KvCacheType.f16);
        expect(quality.flashAttention, FlashAttention.enabled);

        final expert = quality.copyWith(inspectorExpertMode: true);
        final decoded = StudioSettings.fromJson(expert.toJson());
        expect(decoded.inspectorExpertMode, isTrue);
        expect(decoded.activeHardwarePreset, StudioHardwarePreset.quality);
      },
    );
  });
}
