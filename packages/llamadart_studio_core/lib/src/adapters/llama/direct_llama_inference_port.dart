import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';

import '../../domain/studio_message.dart';
import '../../domain/studio_model_descriptor.dart';
import '../../domain/studio_runtime_snapshot.dart';
import '../../domain/studio_settings.dart';
import '../../ports/engine_lease_port.dart';
import '../../ports/inference_port.dart';
import '../../ports/model_storage_port.dart';
import '../../reactive/state_store.dart';
import '../../services/mcp/mcp_tool_schema_adapter.dart';
import '../../services/studio_tool_registry.dart';

part 'direct_llama_inference_helpers.dart';

/// Production [StudioInferencePort] powered directly by `llamadart`'s
/// [LlamaEngine], [ChatSession], [LlamaStructuredOutput], and tool loop.
class DirectLlamaInferencePort
    implements StudioInferencePort, SharedLlamaEngineProvider {
  /// Creates a [DirectLlamaInferencePort].
  DirectLlamaInferencePort({
    LlamaBackend? backend,
    ModelDownloadManager? downloadManager,
    StudioToolCatalog? toolCatalog,
  }) : _engine = LlamaEngine(
         backend ?? LlamaBackend.withTextHistory(),
         modelDownloadManager: downloadManager,
       ),
       _toolCatalog = toolCatalog ?? StudioToolRegistry();

  final LlamaEngine _engine;
  final StudioToolCatalog _toolCatalog;
  final StateStore<StudioRuntimeSnapshot> _runtimeStore =
      StateStore<StudioRuntimeSnapshot>(const StudioRuntimeSnapshot());
  final Lock _lifecycleLock = Lock();

  bool _isDisposed = false;
  bool _cancelRequested = false;
  String? _activeOperationLabel;
  Completer<void>? _activeOperationDone;

  /// Underlying `llamadart` [LlamaEngine] (exposed for lifecycle diagnostics;
  /// shared callers should coordinate access via [SharedLlamaEngineProvider]).
  LlamaEngine get engine => _engine;

  @override
  bool get isEngineReady => !_isDisposed && _engine.isReady;

  /// Whether a turn, benchmark, or shared-engine embedding pass is currently
  /// executing on [_engine].
  bool get isBusy => _activeOperationLabel != null;

  /// Human-readable label of the currently executing operation, if any.
  String? get activeOperationLabel => _activeOperationLabel;

  /// Runs [action] exclusively on the shared [LlamaEngine], failing fast with
  /// an actionable [LlamaStateException] if another workspace is already using
  /// the engine.
  @override
  Future<T> runExclusiveOnEngine<T>(
    String label,
    Future<T> Function(LlamaEngine engine) action,
  ) async {
    _acquireBusySlot(label);
    try {
      return await action(_engine);
    } finally {
      _releaseBusySlot();
    }
  }

  void _acquireBusySlot(String label) {
    if (_isDisposed) {
      throw LlamaStateException('Inference engine has been disposed.');
    }
    final active = _activeOperationLabel;
    if (active != null) {
      throw LlamaStateException(
        'The active model is currently busy ($active). '
        'Stop the running generation or wait for it to finish.',
      );
    }
    _activeOperationLabel = label;
    _activeOperationDone = Completer<void>();
  }

  void _releaseBusySlot() {
    final done = _activeOperationDone;
    _activeOperationLabel = null;
    _activeOperationDone = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  Future<void> _cancelAndDrainActiveOperation() async {
    final done = _activeOperationDone;
    if (done == null) {
      return;
    }
    cancelGeneration();
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => _runtimeStore;

  @override
  Future<void> refreshHardwareDiagnostics() async {
    if (_isDisposed) {
      return;
    }
    try {
      final devices = await _engine.listGpuDevices();
      final vram = await _engine.getVramInfo();
      final backends = await _engine.getAvailableBackends();
      _runtimeStore.update(
        (StudioRuntimeSnapshot s) => s.copyWith(
          gpuDevices: devices,
          vramTotalBytes: vram.total,
          vramFreeBytes: vram.free,
          availableBackends: backends,
        ),
      );
    } catch (_) {
      // Some platforms/stubs only report devices once initialized.
    }
  }

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    final projectorSource = assets.companionSources['projector'];
    await _loadInternal(
      descriptor: assets.descriptor,
      model: LlamaModel(assets.primarySource, projector: projectorSource),
      settings: settings,
      isWeb: isWeb,
    );
  }

  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    final primary = descriptor.primarySource(isWeb: isWeb);
    final projector = descriptor.projectorCompanion?.toModelSource(
      isWeb: isWeb,
    );
    await _loadInternal(
      descriptor: descriptor,
      model: LlamaModel(primary, projector: projector),
      settings: settings,
      isWeb: isWeb,
    );
  }

  Future<void> _loadInternal({
    required StudioModelDescriptor descriptor,
    required LlamaModel model,
    required StudioSettings settings,
    required bool isWeb,
  }) {
    return _lifecycleLock.synchronized(() async {
      await _cancelAndDrainActiveOperation();

      _runtimeStore.update(
        (StudioRuntimeSnapshot s) => s.copyWith(
          phase: StudioEnginePhase.loading,
          activeDescriptor: descriptor,
          activeModelLabel: descriptor.name,
          loadProgressFraction: 0.0,
          statusMessage: 'Initializing ${descriptor.name}...',
          clearErrorMessage: true,
        ),
      );

      try {
        await LlamaLogging.configure(
          level: settings.logLevel,
          nativeLevel: settings.nativeLogLevel,
        );

        final effectiveBytes = descriptor.effectiveSizeBytes(isWeb: isWeb);
        final tunedSettings = settings.copyWith(
          modelBytesHint: effectiveBytes > 0
              ? effectiveBytes
              : settings.modelBytesHint,
        );
        final params = tunedSettings.toModelParams(
          format: descriptor.format,
          isWeb: isWeb,
        );

        final check = await _engine.checkLoad(model, params: params);
        if (check.status == LlamaLoadCheckStatus.unsupported) {
          throw LlamaUnsupportedException(
            check.reason ??
                check.error?.toString() ??
                'This model configuration is unsupported on the current runtime.',
          );
        }

        await _engine.setModel(
          model,
          params: params,
          onProgress: (ModelDownloadProgress progress) {
            _runtimeStore.update(
              (StudioRuntimeSnapshot s) => s.copyWith(
                loadProgressFraction: progress.fraction,
                statusMessage: 'Loading weights into runtime...',
              ),
            );
          },
        );

        final capabilities = await _engine.capabilities;
        final backendName = await _safeString(_engine.getBackendName, 'Auto');
        final availableBackends = await _safeString(
          _engine.getAvailableBackends,
          '',
        );
        final resolvedCtx = await _safeInt(_engine.getContextSize);
        final resolvedLayers = await _safeNullableInt(
          _engine.getResolvedGpuLayers,
        );
        final vram = await _safeVram();
        final devices = await _safeDevices();
        final metadata = await _safeMetadata();
        final perf = await _safePerf();

        _runtimeStore.set(
          StudioRuntimeSnapshot(
            phase: StudioEnginePhase.ready,
            activeDescriptor: descriptor,
            activeModelLabel: descriptor.name,
            backendName: backendName,
            availableBackends: availableBackends,
            capabilities: capabilities,
            resolvedContextSize: resolvedCtx,
            resolvedGpuLayers: resolvedLayers,
            loadedEngineSignature: tunedSettings.engineLoadSignature(
              isWeb: isWeb,
            ),
            vramTotalBytes: vram.total,
            vramFreeBytes: vram.free,
            gpuDevices: devices,
            metadata: _selectDisplayMetadataHelper(metadata),
            perfContext: perf,
          ),
        );
      } catch (error) {
        _runtimeStore.update(
          (StudioRuntimeSnapshot s) => s.copyWith(
            phase: StudioEnginePhase.error,
            clearLoadProgress: true,
            clearStatusMessage: true,
            errorMessage: error.toString(),
          ),
        );
        rethrow;
      }
    });
  }

  @override
  Future<void> unloadModel() {
    return _lifecycleLock.synchronized(() async {
      await _cancelAndDrainActiveOperation();
      if (!_engine.isReady) {
        _runtimeStore.update(
          (StudioRuntimeSnapshot s) => s.copyWith(
            phase: StudioEnginePhase.unloaded,
            clearActiveDescriptor: true,
            clearActiveModelLabel: true,
            clearCapabilities: true,
            clearLoadedEngineSignature: true,
            clearPerfContext: true,
            clearErrorMessage: true,
          ),
        );
        return;
      }
      _runtimeStore.update(
        (StudioRuntimeSnapshot s) => s.copyWith(
          phase: StudioEnginePhase.unloading,
          statusMessage: 'Releasing model buffers...',
        ),
      );
      await _engine.unloadModel();
      final vram = await _safeVram();
      _runtimeStore.update(
        (StudioRuntimeSnapshot s) => StudioRuntimeSnapshot(
          phase: StudioEnginePhase.unloaded,
          availableBackends: s.availableBackends,
          gpuDevices: s.gpuDevices,
          vramTotalBytes: vram.total,
          vramFreeBytes: vram.free,
        ),
      );
    });
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    if (!_engine.isReady) {
      throw LlamaStateException(
        'Load a model in Model Hub before sending a message.',
      );
    }
    if (request.history.isEmpty) {
      throw LlamaArgumentException('Turn history cannot be empty.');
    }

    _acquireBusySlot('Chat / Agent generation');
    try {
      yield* _streamTurnBody(request);
    } finally {
      _releaseBusySlot();
    }
  }

  Stream<StudioTurnEvent> _streamTurnBody(StudioTurnRequest request) async* {
    _cancelRequested = false;
    final snapshot = _runtimeStore.state;
    final capabilities = snapshot.capabilities ?? await _engine.capabilities;
    final baseGenParams = request.settings.toGenerationParams(
      capabilities: capabilities,
    );

    final promptSegments = <String>[
      if (request.systemPrompt.trim().isNotEmpty) request.systemPrompt.trim(),
      if (request.extraSystemContext.trim().isNotEmpty)
        request.extraSystemContext.trim(),
    ];
    final systemPromptText = promptSegments.isEmpty
        ? null
        : promptSegments.join('\n\n');
    final effectiveMaxContext =
        snapshot.resolvedContextSize ?? request.settings.contextSize;

    final session = ChatSession(
      _engine,
      maxContextTokens: effectiveMaxContext,
      systemPrompt: systemPromptText,
    );

    // Seed prior messages up to (but excluding) the trailing user turn.
    final priorMessages = request.history.sublist(
      0,
      request.history.length - 1,
    );
    for (final msg in priorMessages) {
      if (msg.isError) {
        continue;
      }
      session.addMessage(_toLlamaMessageHelper(msg));
    }

    final latestTurn = request.history.last;
    final latestParts = _toUserPartsHelper(latestTurn);
    final hasMediaParts = request.history.any(
      (StudioMessage m) => !m.isError && m.attachments.isNotEmpty,
    );

    // Prepare optional structured output grammar.
    LlamaStructuredOutput<Object?>? structuredOutput;
    Map<String, dynamic>? responseFormat;
    final rawSchema = request.jsonSchema?.trim();
    if (rawSchema != null && rawSchema.isNotEmpty) {
      if (!capabilities.supportsStructuredOutput) {
        throw LlamaUnsupportedException(
          'The loaded runtime does not support strict JSON Schema output. '
          'Choose a runtime with grammar constraints or clear the schema.',
        );
      }
      final decodedSchema = jsonDecode(rawSchema);
      if (decodedSchema is! Map) {
        throw LlamaArgumentException('The JSON Schema must be an object.');
      }
      structuredOutput = LlamaStructuredOutput<Object?>.jsonValueSchema(
        schema: Map<String, dynamic>.from(decodedSchema),
        decoder: (Object? value) => value,
      );
      responseFormat = structuredOutput.responseFormat;
    }

    // Prepare active tools when supported and no strict JSON schema overrides.
    final effectiveToolsEnabled =
        request.toolsEnabledOverride ?? request.settings.toolsEnabled;
    var rawTools =
        effectiveToolsEnabled &&
            capabilities.supportsToolCalling &&
            responseFormat == null
        ? _mergeToolDefinitionsHelper(
            request.includeBuiltInTools
                ? _toolCatalog.resolveTools(
                    enabledNames: request.settings.enabledBuiltInTools,
                    customDeclarationsJson:
                        request.settings.customToolDeclarationsJson,
                  )
                : const <ToolDefinition>[],
            request.extraTools,
          )
        : const <ToolDefinition>[];

    final int? effectiveBudgetTokens = request.settings.thinkingEnabled
        ? (request.settings.thinkingBudgetTokens > 0
              ? request.settings.thinkingBudgetTokens
              : (baseGenParams.maxTokens * 0.55).round().clamp(32, 1536))
        : null;
    final nativeBudgetEligible =
        effectiveBudgetTokens != null &&
        capabilities.supportsThinkingBudget &&
        !hasMediaParts &&
        responseFormat == null;
    var genParams = resolveTurnGenerationParams(
      baseGenParams: baseGenParams,
      capabilities: capabilities,
      hasMediaParts: hasMediaParts,
      hasResponseFormat: responseFormat != null,
      effectiveBudgetTokens: effectiveBudgetTokens,
      explicitThinkingBudgetTokens: request.settings.thinkingBudgetTokens,
    );

    final stopwatch = Stopwatch()..start();
    int? firstTokenMs;
    int? thinkingStartMs;
    int? thinkingEndMs;
    var generatedTokens = 0;
    int? promptTokens;
    var reachedTokenLimit = false;
    final textBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    final invocations = <StudioToolInvocation>[];

    final templateKwargs = _buildThinkingTemplateKwargsHelper(
      settings: request.settings,
      capabilities: capabilities,
      effectiveBudgetTokens: effectiveBudgetTokens,
    );

    var currentParts = latestParts;
    var round = 0;

    while (true) {
      final roundToolCalls = <LlamaCompletionChunkToolCall>[];
      final roundText = StringBuffer();

      Stream<LlamaCompletionChunk> openRoundStream() => session.create(
        currentParts,
        params: genParams,
        tools: rawTools.isEmpty ? null : rawTools,
        toolChoice: rawTools.isEmpty ? null : ToolChoice.auto,
        enableThinking: request.settings.thinkingEnabled,
        chatTemplateKwargs: templateKwargs,
        responseFormat: responseFormat,
      );

      var retriedWithoutSpeculative = false;
      var retriedWithoutNativeBudget = false;
      var retriedWithLegacyTools = false;
      while (true) {
        var roundGeneratedTokens = 0;
        try {
          await for (final chunk in openRoundStream()) {
            final thinkingDelta = chunk.thinking;
            if (thinkingDelta.isNotEmpty) {
              firstTokenMs ??= stopwatch.elapsedMilliseconds;
              thinkingStartMs ??= stopwatch.elapsedMilliseconds;
              thinkingEndMs = stopwatch.elapsedMilliseconds;
              generatedTokens++;
              roundGeneratedTokens++;
              thinkingBuffer.write(thinkingDelta);
              yield StudioThinkingDeltaEvent(thinkingDelta);
            }

            final textDelta = chunk.text;
            if (textDelta.isNotEmpty) {
              firstTokenMs ??= stopwatch.elapsedMilliseconds;
              generatedTokens++;
              roundGeneratedTokens++;
              roundText.write(textDelta);
              textBuffer.write(textDelta);
              yield StudioTextDeltaEvent(textDelta);
            }

            if (chunk.toolCalls.isNotEmpty) {
              roundToolCalls.addAll(chunk.toolCalls);
            }

            if (chunk.finishReason == LlamaFinishReason.length) {
              reachedTokenLimit = true;
            }
            final usage = chunk.usage;
            if (usage != null) {
              promptTokens = usage.promptTokens;
              if (usage.completionTokens > 0) {
                generatedTokens = usage.completionTokens;
              }
            }
          }
          break;
        } on LlamaUnsupportedException catch (error) {
          if (roundGeneratedTokens == 0 &&
              roundToolCalls.isEmpty &&
              !retriedWithoutSpeculative &&
              (genParams.speculativeDecoding ||
                  genParams.speculativeDecodingConfig != null)) {
            retriedWithoutSpeculative = true;
            genParams = genParams.copyWith(
              speculativeDecoding: false,
              clearSpeculativeDecodingConfig: true,
              thinkingBudget:
                  nativeBudgetEligible && !retriedWithoutNativeBudget
                  ? ThinkingBudget(maxTokens: effectiveBudgetTokens)
                  : null,
            );
            continue;
          }
          if (roundGeneratedTokens == 0 &&
              roundToolCalls.isEmpty &&
              !retriedWithoutNativeBudget &&
              genParams.thinkingBudget != null) {
            retriedWithoutNativeBudget = true;
            genParams = genParams.copyWith(clearThinkingBudget: true);
            continue;
          }
          if (roundGeneratedTokens == 0 &&
              roundToolCalls.isEmpty &&
              !retriedWithLegacyTools &&
              rawTools.isNotEmpty &&
              error.message.contains('Canonical JSON Schema')) {
            retriedWithLegacyTools = true;
            rawTools = rawTools
                .map(McpToolSchemaAdapter.coerceToLegacyToolDefinition)
                .toList(growable: false);
            continue;
          }
          rethrow;
        } on LlamaException catch (error) {
          if (roundGeneratedTokens == 0 &&
              roundToolCalls.isEmpty &&
              rawTools.isNotEmpty &&
              error.toString().contains('prompt too long')) {
            final nextCount = rawTools.length > 5
                ? math.max(5, rawTools.length ~/ 2)
                : (rawTools.length > 1 ? rawTools.length ~/ 2 : 0);
            rawTools = nextCount == 0
                ? const <ToolDefinition>[]
                : rawTools.sublist(0, nextCount);
            continue;
          }
          rethrow;
        }
      }

      if (roundToolCalls.isEmpty ||
          rawTools.isEmpty ||
          round >= request.maxToolRounds) {
        break;
      }

      round++;
      for (var i = 0; i < roundToolCalls.length; i++) {
        final call = roundToolCalls[i];
        final callName = call.function?.name ?? 'tool';
        final rawArgsText = call.function?.arguments ?? '{}';
        final parsedArgs = _decodeToolArgumentsHelper(rawArgsText);
        final callId = call.id ?? 'call_${round}_$i';
        final argsPretty = _prettyJsonHelper(parsedArgs);
        var record = StudioToolInvocation(
          id: callId,
          name: callName,
          argumentsJson: argsPretty,
          isRunning: true,
        );
        invocations.add(record);
        yield StudioToolInvocationEvent(record);

        final callWatch = Stopwatch()..start();
        Object? toolResult;
        var isError = false;
        try {
          final matching = _findToolHelper(rawTools, callName);
          if (matching == null) {
            isError = true;
            toolResult = <String, Object?>{
              'error': 'Tool "$callName" is not enabled.',
            };
          } else {
            toolResult = await matching.invoke(parsedArgs);
          }
        } catch (error) {
          isError = true;
          toolResult = <String, Object?>{'error': error.toString()};
        }
        callWatch.stop();

        final resultEncoded = _encodeToolOutputHelper(toolResult);
        record = record.copyWith(
          resultJson: resultEncoded,
          durationMs: callWatch.elapsedMilliseconds,
          isRunning: false,
          isError: isError,
        );
        invocations[invocations.length - 1] = record;
        yield StudioToolInvocationEvent(record);

        session.addMessage(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: <LlamaContentPart>[
              LlamaToolResultContent(
                id: call.id,
                name: callName,
                result: toolResult,
              ),
            ],
          ),
        );
      }

      // Continue the assistant turn with tool results now in session history.
      currentParts = const <LlamaContentPart>[];
    }

    // Safety recovery: if a reasoning model exhausted its token window inside
    // `<think>...</think>` without emitting any visible answer or tool call
    // (for example on multimodal turns where native ThinkingBudget is disabled),
    // seamlessly run a non-thinking continuation pass so the user always gets
    // a visible answer right below the preserved thought block.
    if (!_cancelRequested &&
        thinkingBuffer.isNotEmpty &&
        textBuffer.toString().trim().isEmpty &&
        invocations.isEmpty) {
      reachedTokenLimit = false;
      final recoverySession = ChatSession(
        _engine,
        maxContextTokens: effectiveMaxContext,
        systemPrompt: systemPromptText,
      );
      for (final msg in priorMessages) {
        if (msg.isError) {
          continue;
        }
        recoverySession.addMessage(_toLlamaMessageHelper(msg));
      }
      final recoveryParams = baseGenParams.copyWith(
        clearThinkingBudget: true,
        maxTokens: math.max(512, baseGenParams.maxTokens),
      );
      var recoveryTokens = 0;
      await for (final chunk in recoverySession.create(
        latestParts,
        params: recoveryParams,
        enableThinking: false,
        chatTemplateKwargs: const <String, dynamic>{
          'enable_thinking': false,
          'thinking': false,
          'reasoning': false,
        },
        responseFormat: responseFormat,
      )) {
        final textDelta = chunk.text;
        if (textDelta.isNotEmpty) {
          firstTokenMs ??= stopwatch.elapsedMilliseconds;
          recoveryTokens++;
          textBuffer.write(textDelta);
          yield StudioTextDeltaEvent(textDelta);
        }
        if (chunk.finishReason == LlamaFinishReason.length) {
          reachedTokenLimit = true;
        }
        final usage = chunk.usage;
        if (usage != null && usage.completionTokens > 0) {
          recoveryTokens = usage.completionTokens;
        }
      }
      generatedTokens += recoveryTokens;
    }

    stopwatch.stop();
    final perf = await _safePerf();
    if (perf != null) {
      _runtimeStore.update(
        (StudioRuntimeSnapshot s) => s.copyWith(perfContext: perf),
      );
    }

    final finalText = textBuffer.toString();
    bool? jsonValid;
    String? jsonError;
    if (structuredOutput != null) {
      try {
        structuredOutput.parse(finalText);
        jsonValid = true;
      } catch (error) {
        jsonValid = false;
        jsonError = error.toString();
      }
    }

    final totalMs = stopwatch.elapsedMilliseconds;
    final decodeMs = firstTokenMs != null
        ? (totalMs - firstTokenMs).clamp(1, totalMs)
        : totalMs;
    final thinkingDuration = (thinkingStartMs != null && thinkingEndMs != null)
        ? (thinkingEndMs - thinkingStartMs).clamp(0, totalMs)
        : null;

    yield StudioTurnCompletedEvent(
      StudioTurnResult(
        text: finalText,
        thinkingText: thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
        thinkingDurationMs: thinkingDuration,
        toolInvocations: List<StudioToolInvocation>.unmodifiable(invocations),
        structuredJsonValid: jsonValid,
        structuredJsonError: jsonError,
        metrics: StudioTurnMetrics(
          generatedTokens: generatedTokens,
          elapsedMs: totalMs,
          decodeElapsedMs: decodeMs,
          promptTokens: promptTokens,
          firstTokenLatencyMs: firstTokenMs,
          reachedTokenLimit: reachedTokenLimit,
          modelName: snapshot.activeModelLabel,
          backendLabel: snapshot.backendName,
        ),
      ),
    );
  }

  @override
  void cancelGeneration() {
    _cancelRequested = true;
    _engine.cancelGeneration();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _cancelAndDrainActiveOperation();
    await _engine.dispose();
    await _runtimeStore.dispose();
  }

  /// Resolves per-turn [GenerationParams] while enforcing backend compatibility
  /// rules for speculative decoding and native thinking budgets.
  @visibleForTesting
  static GenerationParams resolveTurnGenerationParams({
    required GenerationParams baseGenParams,
    required LlamaEngineCapabilities capabilities,
    required bool hasMediaParts,
    required bool hasResponseFormat,
    required int? effectiveBudgetTokens,
    required int explicitThinkingBudgetTokens,
  }) {
    final speculativeRequested =
        baseGenParams.speculativeDecoding ||
        baseGenParams.speculativeDecodingConfig != null;
    final nativeBudgetEligible =
        effectiveBudgetTokens != null &&
        capabilities.supportsThinkingBudget &&
        !hasMediaParts &&
        !hasResponseFormat;
    final hasExplicitThinkingCap =
        nativeBudgetEligible && explicitThinkingBudgetTokens > 0;
    final canApplySpeculative =
        speculativeRequested &&
        !hasMediaParts &&
        !hasResponseFormat &&
        baseGenParams.grammar == null &&
        !hasExplicitThinkingCap;
    final applyNativeBudget = nativeBudgetEligible && !canApplySpeculative;

    return baseGenParams.copyWith(
      thinkingBudget: applyNativeBudget
          ? ThinkingBudget(maxTokens: effectiveBudgetTokens)
          : null,
      clearThinkingBudget: !applyNativeBudget,
      speculativeDecoding: canApplySpeculative,
      clearSpeculativeDecodingConfig: !canApplySpeculative,
    );
  }
}
