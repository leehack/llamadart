import 'dart:async';
import 'dart:convert';

import '../../backends/backend.dart';
import '../template/chat_template_engine.dart';
import '../exceptions.dart';
import '../models/config/log_level.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/completion_chunk.dart';
import '../models/chat/content_part.dart';
import '../models/chat/chat_template_result.dart';
import '../llama_logger.dart';

import '../models/inference/model_params.dart';
import '../models/inference/generation_params.dart';
import '../models/inference/tool_choice.dart';
import '../models/model_load_options.dart';
import '../models/model_resolver.dart';
import '../models/model_source.dart';
import '../models/download/model_download_manager.dart';
import '../models/tools/tool_definition.dart';

enum _ToolStreamingMode { undecided, raw, parsed }

class _ThinkingSplitEmission {
  final String text;
  final bool isThinking;

  const _ThinkingSplitEmission({required this.text, required this.isThinking});
}

class _ThinkingSplitResult {
  final String pendingBuffer;
  final bool isThinking;
  final List<_ThinkingSplitEmission> emissions;

  const _ThinkingSplitResult({
    required this.pendingBuffer,
    required this.isThinking,
    required this.emissions,
  });
}

/// Stateless chat completions engine (like OpenAI's Chat Completions API).
///
/// [LlamaEngine] is the primary API for chat-based inference. Each call to
/// [create] is stateless - you must pass the full conversation history.
/// For automatic history management, use [ChatSession] instead.
///
/// Example (OpenAI-style stateless usage):
/// ```dart
/// final engine = LlamaEngine(LlamaBackend());
/// await engine.loadModel('path/to/model.gguf'); // or model.litertlm on native
///
/// // Build messages array (you manage history)
/// final messages = [
///   LlamaChatMessage.fromText(role: LlamaChatRole.system, text: 'You are helpful.'),
///   LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hello!'),
/// ];
///
/// // Create completion
/// final response = await engine.create(messages).join();
///
/// // Append response and continue conversation
/// messages.add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: response));
/// messages.add(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Follow up?'));
/// final response2 = await engine.create(messages).join();
/// ```
class LlamaEngine {
  /// The backend implementation used for inference.
  final LlamaBackend backend;

  /// Resolves source-aware model loading requests.
  final ModelResolver modelResolver;

  /// Downloads and caches remote model sources for native/file-backed backends.
  final ModelDownloadManager modelDownloadManager;
  int? _modelHandle;
  int? _contextHandle;
  int? _mmContextHandle;
  bool _isReady = false;
  String? _modelPath;
  Map<String, String>? _cachedModelMetadata;
  LlamaLogLevel _dartLogLevel = LlamaLogLevel.none;
  LlamaLogLevel _nativeLogLevel = LlamaLogLevel.none;

  /// Configures logging for the library.
  ///
  /// [level] determines which logs are output.
  /// [handler] is an optional custom callback. If null and level != none,
  /// logs are printed to stdout.
  static void configureLogging({
    LlamaLogLevel level = LlamaLogLevel.none,
    LlamaLogHandler? handler,
  }) {
    LlamaLogger.instance.setLevel(level);
    LlamaLogger.instance.setHandler(handler);
  }

  /// Creates a new [LlamaEngine] instance with the given [backend].
  LlamaEngine(
    this.backend, {
    ModelResolver? modelResolver,
    ModelDownloadManager? modelDownloadManager,
  }) : modelResolver = modelResolver ?? const DefaultModelResolver(),
       modelDownloadManager =
           modelDownloadManager ?? DefaultModelDownloadManager();

  /// Sets both Dart and native log levels to [level].
  ///
  /// For independent control, use [setDartLogLevel] and [setNativeLogLevel].
  Future<void> setLogLevel(LlamaLogLevel level) async {
    await setDartLogLevel(level);
    await setNativeLogLevel(level);
  }

  /// Sets only the Dart-side logger level.
  Future<void> setDartLogLevel(LlamaLogLevel level) async {
    _dartLogLevel = level;
    LlamaLogger.instance.setLevel(level);
  }

  /// Sets only the native backend logger level.
  Future<void> setNativeLogLevel(LlamaLogLevel level) async {
    _nativeLogLevel = level;
    await backend.setLogLevel(level);
  }

  /// Current Dart-side logger level.
  LlamaLogLevel get dartLogLevel => _dartLogLevel;

  /// Current native backend logger level.
  LlamaLogLevel get nativeLogLevel => _nativeLogLevel;

  // ============================================================
  // MODEL LIFECYCLE
  // ============================================================

  /// Whether the engine is initialized and ready for inference.
  bool get isReady => _isReady;

  /// Loads a model from a local [path].
  ///
  /// Optionally provide [ModelParams] to configure context size, GPU offloading,
  /// and more.
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async {
    final modelName = _displayNameForSource(path);
    LlamaLogger.instance.info('Loading model: $modelName');

    if (backend.supportsUrlLoading) {
      LlamaLogger.instance.info(
        'Backend supports URL loading, attempting loadModelFromUrl.',
      );
      return loadModelFromUrl(path, modelParams: modelParams);
    }

    try {
      await backend.setLogLevel(_nativeLogLevel);
      _ensureNotReady();
      _modelPath = path;
      _cachedModelMetadata = null;
      _modelHandle = await backend.modelLoad(path, modelParams);
      _contextHandle = await backend.contextCreate(_modelHandle!, modelParams);
      _isReady = true;
      LlamaLogger.instance.info(
        'Model $modelName loaded successfully from $path',
      );
    } catch (e, stackTrace) {
      await _cleanupFailedLoadState();
      LlamaLogger.instance.error(
        'Failed to load model $modelName from $path',
        e,
        stackTrace,
      );
      throw LlamaModelException('Failed to load model from $path', e);
    }
  }

  /// Loads a model from a structured [source].
  ///
  /// Local path sources are dispatched through [loadModel]. Remote URL targets
  /// use the native download/cache manager on file-backed backends, then load
  /// the cached local file. URL-capable web backends keep using
  /// [loadModelFromUrl] for unauthenticated prefer-cached requests.
  Future<void> loadModelSource(
    ModelSource source, {
    ModelParams modelParams = const ModelParams(),
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final target = await modelResolver.resolve(
      source,
      ModelResolveRequest(options: options, onProgress: onProgress),
    );

    switch (target) {
      case LocalModelFile(:final path):
        if (backend.supportsUrlLoading) {
          throw LlamaUnsupportedException(
            'Explicit local model paths are not supported by URL-loading backends.',
          );
        }
        final localSource = ModelSource.path(path);
        final entry = await modelDownloadManager.ensureModel(
          localSource,
          options: options,
          onProgress: onProgress,
        );
        return loadModel(entry.filePath, modelParams: modelParams);
      case RemoteModelUrl(:final url, :final useBrowserCache):
        if (!useBrowserCache) {
          throw LlamaUnsupportedException(
            'Remote model loading without browser/backend cache is not supported yet.',
          );
        }
        if (!backend.supportsUrlLoading) {
          final downloadSource = source.isRemote
              ? source.withResolvedUri(url)
              : ModelSource.url(url, fileName: source.fileName);
          final entry = await modelDownloadManager.ensureModel(
            downloadSource,
            options: options,
            onProgress: onProgress,
          );
          return loadModel(entry.filePath, modelParams: modelParams);
        }
        _rejectUnsupportedUrlBackendOptions(options);
        return loadModelFromUrl(
          url.toString(),
          modelParams: modelParams,
          onProgress: onProgress == null
              ? null
              : (progress) =>
                    onProgress(ModelDownloadProgress.fraction(progress)),
        );
    }
  }

  /// Loads a model from a [url].
  ///
  /// This is typically used on the Web platform. Use [ModelParams] to
  /// configure loading options.
  Future<void> loadModelFromUrl(
    String url, {
    ModelParams modelParams = const ModelParams(),
    Function(double progress)? onProgress,
  }) async {
    final modelName = _displayNameForSource(url);
    final redactedUrl = _redactedUriForLogs(url);
    LlamaLogger.instance.info('Loading model from URL: $modelName');

    if (!backend.supportsUrlLoading) {
      throw LlamaUnsupportedException(
        'loadModelFromUrl requires a backend that supports URL loading.',
      );
    }

    try {
      await backend.setLogLevel(_nativeLogLevel);
      _ensureNotReady();
      _modelPath = redactedUrl;
      _cachedModelMetadata = null;

      _modelHandle = await backend.modelLoadFromUrl(
        url,
        modelParams,
        onProgress: onProgress,
      );
      _contextHandle = await backend.contextCreate(_modelHandle!, modelParams);
      _isReady = true;

      LlamaLogger.instance.info(
        'Model $modelName loaded successfully from $redactedUrl',
      );
    } catch (e, stackTrace) {
      await _cleanupFailedLoadState();

      LlamaLogger.instance.error(
        'Failed to load model $modelName from URL $redactedUrl',
        _redactedErrorDetails(e),
        stackTrace,
      );
      throw LlamaModelException(
        'Failed to load model from $redactedUrl',
        _redactedErrorDetails(e),
      );
    }
  }

  /// Loads a multimodal projector model for vision/audio support.
  Future<void> loadMultimodalProjector(String mmProjPath) async {
    final mmProjName = _displayNameForSource(mmProjPath);
    LlamaLogger.instance.info('Loading multimodal projector: $mmProjName');
    _ensureReady(requireContext: false);
    try {
      if (_mmContextHandle != null) {
        await unloadMultimodalProjector();
      }

      _mmContextHandle = await backend.multimodalContextCreate(
        _modelHandle!,
        mmProjPath,
      );
      LlamaLogger.instance.info(
        'Multimodal projector $mmProjName loaded successfully',
      );
    } catch (e, stackTrace) {
      LlamaLogger.instance.error(
        'Failed to load multimodal projector $mmProjName',
        e,
        stackTrace,
      );
      if (e is UnsupportedError) {
        throw _unsupportedBackendOperation('Multimodal projectors', e);
      }
      rethrow;
    }
  }

  /// Unloads the active multimodal projector while keeping the model loaded.
  Future<void> unloadMultimodalProjector() async {
    final mmContextHandle = _mmContextHandle;
    if (mmContextHandle == null) {
      return;
    }

    LlamaLogger.instance.info('Unloading multimodal projector');
    _mmContextHandle = null;
    await backend.multimodalContextFree(mmContextHandle);
  }

  /// Releases all allocated resources.
  Future<void> dispose() async {
    await unloadModel();
    await backend.dispose();
  }

  /// Unloads the currently loaded model and frees its resources.
  Future<void> unloadModel() async {
    if (!isReady && _modelHandle == null && _mmContextHandle == null) return;
    LlamaLogger.instance.info('Unloading model...');
    if (_contextHandle != null) {
      await backend.contextFree(_contextHandle!);
      _contextHandle = null;
    }
    if (_mmContextHandle != null) {
      await backend.multimodalContextFree(_mmContextHandle!);
      _mmContextHandle = null;
    }
    if (_modelHandle != null) {
      await backend.modelFree(_modelHandle!);
      _modelHandle = null;
    }
    _modelPath = null;
    _cachedModelMetadata = null;
    _isReady = false;
    LlamaLogger.instance.info('Model unloaded.');
  }

  // ============================================================
  // CHAT COMPLETIONS (Primary API)
  // ============================================================

  /// Creates a chat completion from a list of [messages].
  ///
  /// This is the primary stateless API (like OpenAI's Chat Completions).
  /// You must pass the full conversation history with each call.
  ///
  /// Pass [tools] to enable function calling. Use [toolChoice] to control
  /// whether the model should use tools:
  /// - [ToolChoice.none]: Model won't call any tool
  /// - [ToolChoice.auto]: Model can choose (default when tools present)
  /// - [ToolChoice.required]: Model must call at least one tool
  ///
  /// Set [parallelToolCalls] to allow multiple tool calls in one response for
  /// templates that support it.
  ///
  /// For TranslateGemma-style templates, set [sourceLangCode] and
  /// [targetLangCode] to control language metadata injected into user
  /// content blocks.
  ///
  /// Use [chatTemplateKwargs] to inject additional template globals (equivalent
  /// to llama.cpp `chat_template_kwargs`).
  /// Use [templateNow] to set deterministic template time context.
  ///
  /// Example:
  /// ```dart
  /// final messages = [
  ///   LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hello!'),
  /// ];
  /// await for (final token in engine.create(messages)) {
  ///   print(token);
  /// }
  /// ```
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    _ensureReady();

    // Keep tools available to template routing even with toolChoice.none,
    // matching llama.cpp behavior.
    final effectiveTools = tools;

    // Apply chat template with tools - returns grammar for constraining
    final result = await chatTemplate(
      messages,
      tools: effectiveTools,
      toolChoice: toolChoice ?? ToolChoice.auto,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      chatTemplateKwargs: chatTemplateKwargs,
      templateNow: templateNow,
      includeTokenCount: false,
    );
    final stops = {...result.stopSequences, ...?params?.stopSequences}.toList();

    LlamaLogger.instance.debug('Chat template result:');
    LlamaLogger.instance.debug('  Format: ${result.format}');
    LlamaLogger.instance.debug('  Prompt: ${result.prompt}');
    LlamaLogger.instance.debug('  Stop sequences: $stops');
    LlamaLogger.instance.debug('  Grammar present: ${result.grammar != null}');
    LlamaLogger.instance.debug('  Grammar lazy: ${result.grammarLazy}');
    LlamaLogger.instance.debug(
      '  Grammar triggers: ${result.grammarTriggers.length}',
    );
    LlamaLogger.instance.debug(
      '  Thinking forced open: ${result.thinkingForcedOpen}',
    );

    // Collect media parts from all messages
    final allParts = messages.expand((m) => m.parts).toList();

    final activeBackend = backend;
    final backendSupportsGrammarConstraints =
        activeBackend is BackendGrammarConstraintsSupport
        ? (activeBackend as BackendGrammarConstraintsSupport)
              .supportsGrammarConstraints
        : true;
    if (!backendSupportsGrammarConstraints && result.grammar != null) {
      LlamaLogger.instance.debug(
        '  Template grammar skipped: backend does not support grammar constraints',
      );
    }

    final hasTemplateGrammar =
        result.grammar != null && backendSupportsGrammarConstraints;
    final effectiveGrammar = hasTemplateGrammar
        ? result.grammar
        : params?.grammar;
    final effectiveGrammarLazy = hasTemplateGrammar
        ? result.grammarLazy
        : (params?.grammarLazy ?? false);
    final effectiveGrammarTriggers = hasTemplateGrammar
        ? result.grammarTriggers
              .map(
                (trigger) => GenerationGrammarTrigger(
                  type: trigger.type,
                  value: trigger.value,
                  token: trigger.token,
                ),
              )
              .toList(growable: false)
        : (params?.grammarTriggers ?? const <GenerationGrammarTrigger>[]);
    final effectivePreservedTokens = {
      if (backendSupportsGrammarConstraints) ...result.preservedTokens,
      ...?params?.preservedTokens,
    }.toList(growable: false);

    // Generate raw tokens with grammar constraint
    final tokenStream = generate(
      result.prompt,
      params: (params ?? const GenerationParams()).copyWith(
        stopSequences: stops,
        grammar: effectiveGrammar,
        grammarLazy: effectiveGrammarLazy,
        grammarTriggers: effectiveGrammarTriggers,
        preservedTokens: effectivePreservedTokens,
      ),
      parts: allParts,
    );

    // Parse the tokens into structured chunks using the detected format
    final completionId = DateTime.now().millisecondsSinceEpoch.toString();
    final buffer = StringBuffer();
    final parseToolCallsEnabled =
        effectiveTools != null &&
        effectiveTools.isNotEmpty &&
        (toolChoice ?? ToolChoice.auto) != ToolChoice.none;
    var streamedContent = '';
    var streamedReasoning = '';
    const structuredPartialParseInterval = 8;
    const plainPartialParseProbeInterval = 4;
    const signalDrivenPartialParseMinTokens = 2;
    const partialParseMinIntervalMs = 24;
    var tokensSincePartialParse = 0;
    var sawStructuredOutputSignal = false;
    var didInitialPartialParse = false;
    var lastPartialParseAtMs = 0;
    final partialParseStopwatch = Stopwatch()..start();
    var streamingMode = _ToolStreamingMode.undecided;
    var undecidedPrefix = '';
    final thinkingTags = ChatTemplateEngine.thinkingTagsFor(result.format);
    final startTag = thinkingTags.startTag;
    final endTag = thinkingTags.endTag;
    var isThinking = result.thinkingForcedOpen;
    var pendingBuffer = '';

    if (parseToolCallsEnabled) {
      await for (final token in tokenStream) {
        buffer.write(token);

        if (streamingMode == _ToolStreamingMode.undecided) {
          undecidedPrefix += token;
          final mode = _decideToolStreamingMode(undecidedPrefix);
          if (mode == _ToolStreamingMode.undecided) {
            continue;
          }

          if (mode == _ToolStreamingMode.raw) {
            streamingMode = _ToolStreamingMode.raw;
          } else {
            streamingMode = _ToolStreamingMode.parsed;
            undecidedPrefix = '';
          }
        }

        if (streamingMode == _ToolStreamingMode.raw) {
          if (undecidedPrefix.isNotEmpty) {
            pendingBuffer += undecidedPrefix;
            undecidedPrefix = '';
          } else if (token.isNotEmpty) {
            pendingBuffer += token;
          }

          final split = _splitThinkingBuffer(
            pendingBuffer: pendingBuffer,
            isThinking: isThinking,
            startTag: startTag,
            endTag: endTag,
          );
          pendingBuffer = split.pendingBuffer;
          isThinking = split.isThinking;
          for (final emission in split.emissions) {
            if (emission.isThinking) {
              streamedReasoning += emission.text;
            } else {
              streamedContent += emission.text;
            }
            yield LlamaCompletionChunk(
              id: 'chatcmpl-$completionId',
              object: 'chat.completion.chunk',
              created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              model: _modelPath ?? 'llama_model',
              choices: [
                LlamaCompletionChunkChoice(
                  index: 0,
                  delta: emission.isThinking
                      ? LlamaCompletionChunkDelta(thinking: emission.text)
                      : LlamaCompletionChunkDelta(content: emission.text),
                ),
              ],
            );
          }
          continue;
        }

        tokensSincePartialParse++;
        final tokenHasSignal = _mayNeedStructuredPartialParse(token);
        if (tokenHasSignal) {
          sawStructuredOutputSignal = true;
        }
        final elapsedMs = partialParseStopwatch.elapsedMilliseconds;
        final intervalElapsed =
            elapsedMs - lastPartialParseAtMs >= partialParseMinIntervalMs;
        final signalParseReady =
            tokenHasSignal &&
            intervalElapsed &&
            tokensSincePartialParse >= signalDrivenPartialParseMinTokens;
        final periodicParseReady =
            (sawStructuredOutputSignal &&
                tokensSincePartialParse >= structuredPartialParseInterval) ||
            (!sawStructuredOutputSignal &&
                tokensSincePartialParse >= plainPartialParseProbeInterval);
        final shouldRunPartialParse =
            !didInitialPartialParse || signalParseReady || periodicParseReady;
        if (!shouldRunPartialParse) {
          continue;
        }
        didInitialPartialParse = true;
        tokensSincePartialParse = 0;
        lastPartialParseAtMs = elapsedMs;

        try {
          final partialParsed = ChatTemplateEngine.parse(
            result.format,
            buffer.toString(),
            isPartial: true,
            parseToolCalls: true,
            thinkingForcedOpen: result.thinkingForcedOpen,
            parser: result.parser,
          );

          final partialReasoning = partialParsed.reasoningContent ?? '';
          if (partialReasoning.length > streamedReasoning.length) {
            final delta = partialReasoning.substring(streamedReasoning.length);
            if (delta.isNotEmpty) {
              yield LlamaCompletionChunk(
                id: 'chatcmpl-$completionId',
                object: 'chat.completion.chunk',
                created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                model: _modelPath ?? 'llama_model',
                choices: [
                  LlamaCompletionChunkChoice(
                    index: 0,
                    delta: LlamaCompletionChunkDelta(thinking: delta),
                  ),
                ],
              );
            }
          }

          if (partialParsed.content.length > streamedContent.length) {
            final delta = partialParsed.content.substring(
              streamedContent.length,
            );
            if (delta.isNotEmpty) {
              yield LlamaCompletionChunk(
                id: 'chatcmpl-$completionId',
                object: 'chat.completion.chunk',
                created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                model: _modelPath ?? 'llama_model',
                choices: [
                  LlamaCompletionChunkChoice(
                    index: 0,
                    delta: LlamaCompletionChunkDelta(content: delta),
                  ),
                ],
              );
            }
          }

          if (partialReasoning.length >= streamedReasoning.length) {
            streamedReasoning = partialReasoning;
          }
          if (partialParsed.content.length >= streamedContent.length) {
            streamedContent = partialParsed.content;
          }
        } catch (_) {
          // Partial parser failures are expected during incremental generation.
          // Keep buffering and let the final parse determine structured output.
        }
      }

      // Preserve raw output for whitespace-only replies where routing mode
      // never resolved (no non-whitespace token observed).
      if (streamingMode == _ToolStreamingMode.undecided &&
          undecidedPrefix.isNotEmpty) {
        streamedContent += undecidedPrefix;
        yield LlamaCompletionChunk(
          id: 'chatcmpl-$completionId',
          object: 'chat.completion.chunk',
          created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          model: _modelPath ?? 'llama_model',
          choices: [
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(content: undecidedPrefix),
            ),
          ],
        );
      }

      if (streamingMode == _ToolStreamingMode.raw && pendingBuffer.isNotEmpty) {
        if (isThinking) {
          streamedReasoning += pendingBuffer;
        } else {
          streamedContent += pendingBuffer;
        }
        yield LlamaCompletionChunk(
          id: 'chatcmpl-$completionId',
          object: 'chat.completion.chunk',
          created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          model: _modelPath ?? 'llama_model',
          choices: [
            LlamaCompletionChunkChoice(
              index: 0,
              delta: isThinking
                  ? LlamaCompletionChunkDelta(thinking: pendingBuffer)
                  : LlamaCompletionChunkDelta(content: pendingBuffer),
            ),
          ],
        );
      }
    } else {
      await for (final token in tokenStream) {
        buffer.write(token);
        pendingBuffer += token;
        final split = _splitThinkingBuffer(
          pendingBuffer: pendingBuffer,
          isThinking: isThinking,
          startTag: startTag,
          endTag: endTag,
        );
        pendingBuffer = split.pendingBuffer;
        isThinking = split.isThinking;
        for (final emission in split.emissions) {
          yield LlamaCompletionChunk(
            id: 'chatcmpl-$completionId',
            object: 'chat.completion.chunk',
            created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            model: _modelPath ?? 'llama_model',
            choices: [
              LlamaCompletionChunkChoice(
                index: 0,
                delta: emission.isThinking
                    ? LlamaCompletionChunkDelta(thinking: emission.text)
                    : LlamaCompletionChunkDelta(content: emission.text),
              ),
            ],
          );
        }
      }

      // Final flush of any pending buffer
      if (pendingBuffer.isNotEmpty) {
        yield LlamaCompletionChunk(
          id: 'chatcmpl-$completionId',
          object: 'chat.completion.chunk',
          created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          model: _modelPath ?? 'llama_model',
          choices: [
            LlamaCompletionChunkChoice(
              index: 0,
              delta: isThinking
                  ? LlamaCompletionChunkDelta(thinking: pendingBuffer)
                  : LlamaCompletionChunkDelta(content: pendingBuffer),
            ),
          ],
        );
      }
    }

    // After generation completes, parse the full output for tool calls
    final fullOutput = buffer.toString();
    final parsed = ChatTemplateEngine.parse(
      result.format,
      fullOutput,
      parseToolCalls: parseToolCallsEnabled,
      thinkingForcedOpen: result.thinkingForcedOpen,
      parser: result.parser,
    );

    if (parseToolCallsEnabled) {
      final finalReasoning = parsed.reasoningContent ?? '';
      final reasoningDelta = _computeFinalReconciliationDelta(
        streamedValue: streamedReasoning,
        finalValue: finalReasoning,
        channel: 'thinking',
      );
      if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
        yield LlamaCompletionChunk(
          id: 'chatcmpl-$completionId',
          object: 'chat.completion.chunk',
          created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          model: _modelPath ?? 'llama_model',
          choices: [
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(thinking: reasoningDelta),
            ),
          ],
        );
      }

      final contentDelta = _computeFinalReconciliationDelta(
        streamedValue: streamedContent,
        finalValue: parsed.content,
        channel: 'content',
      );
      if (contentDelta != null && contentDelta.isNotEmpty) {
        yield LlamaCompletionChunk(
          id: 'chatcmpl-$completionId',
          object: 'chat.completion.chunk',
          created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          model: _modelPath ?? 'llama_model',
          choices: [
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(content: contentDelta),
            ),
          ],
        );
      }
    }

    LlamaLogger.instance.debug('Parsed result: $parsed');
    if (parsed.hasToolCalls) {
      for (final tc in parsed.toolCalls) {
        LlamaLogger.instance.debug(
          '  Tool call: ${tc.function?.name}(${tc.function?.arguments})',
        );
      }
    }
    if (parsed.hasReasoning) {
      LlamaLogger.instance.debug(
        '  Reasoning: ${parsed.reasoningContent?.length ?? 0} chars',
      );
    }

    if (parsed.hasToolCalls) {
      final toolCallsWithIds = parsed.toolCalls
          .asMap()
          .entries
          .map(
            (entry) => LlamaCompletionChunkToolCall(
              index: entry.value.index,
              id: (entry.value.id == null || entry.value.id!.isEmpty)
                  ? 'call_${entry.key}'
                  : entry.value.id,
              type: entry.value.type,
              function: entry.value.function,
            ),
          )
          .toList(growable: false);
      // Emit a final chunk with tool calls
      yield LlamaCompletionChunk(
        id: 'chatcmpl-$completionId',
        object: 'chat.completion.chunk',
        created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        model: _modelPath ?? 'llama_model',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(toolCalls: toolCallsWithIds),
            finishReason: 'tool_calls',
          ),
        ],
      );
    } else {
      // Emit the stop chunk
      yield LlamaCompletionChunk(
        id: 'chatcmpl-$completionId',
        object: 'chat.completion.chunk',
        created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        model: _modelPath ?? 'llama_model',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(),
            finishReason: 'stop',
          ),
        ],
      );
    }
  }

  /// Formats a list of [messages] into a prompt string using the model's template.
  ///
  /// This is useful for preparing messages before calling [generate] directly,
  /// or for inspecting the formatted prompt for debugging purposes.
  ///
  /// Pass [customTemplate] to override default routing.
  /// Pass [responseFormat] or legacy [jsonSchema] to request structured output
  /// grammar generation.
  ///
  /// For TranslateGemma-style templates, [sourceLangCode] and
  /// [targetLangCode] are forwarded to the template renderer.
  ///
  /// Set [includeTokenCount] to false to skip the prompt tokenization pass
  /// and reduce per-request overhead when token count is not needed.
  ///
  /// Use [chatTemplateKwargs] to inject additional template globals (equivalent
  /// to llama.cpp `chat_template_kwargs`).
  /// Use [templateNow] to set deterministic template time context.
  ///
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async {
    _ensureReady(requireContext: false);

    String? templateSource;

    // Get metadata for template source and token info
    Map<String, String> metadata = {};
    try {
      metadata = await _getCachedMetadata();
      templateSource = metadata['tokenizer.chat_template'];
    } catch (e) {
      LlamaLogger.instance.warning('Failed to read metadata: $e');
    }

    if (sourceLangCode != null && sourceLangCode.isNotEmpty) {
      metadata['source_lang_code'] = sourceLangCode;
    }
    if (targetLangCode != null && targetLangCode.isNotEmpty) {
      metadata['target_lang_code'] = targetLangCode;
    }

    // Use ChatTemplateEngine for format detection, rendering, and grammar
    try {
      final effectiveResponseFormat =
          responseFormat ??
          (jsonSchema == null
              ? null
              : {
                  'type': 'json_schema',
                  'json_schema': {'schema': jsonSchema},
                });

      final result = ChatTemplateEngine.render(
        templateSource: templateSource,
        messages: messages,
        metadata: metadata,
        addAssistant: addAssistant,
        tools: tools,
        toolChoice: toolChoice,
        parallelToolCalls: parallelToolCalls,
        enableThinking: enableThinking,
        responseFormat: effectiveResponseFormat,
        customTemplate: customTemplate,
        chatTemplateKwargs: chatTemplateKwargs,
        now: templateNow,
      );

      int? tokenCount;
      if (includeTokenCount) {
        try {
          final tokens = await tokenize(result.prompt, addSpecial: false);
          tokenCount = tokens.length;
        } on UnsupportedError catch (error) {
          LlamaLogger.instance.debug(
            'Skipping chat template token count because backend tokenization '
            'is unsupported: $error',
          );
        } on LlamaUnsupportedException catch (error) {
          LlamaLogger.instance.debug(
            'Skipping chat template token count because backend tokenization '
            'is unsupported: $error',
          );
        }
      }

      return LlamaChatTemplateResult(
        prompt: result.prompt,
        format: result.format,
        grammar: result.grammar,
        grammarLazy: result.grammarLazy,
        additionalStops: result.additionalStops,
        grammarTriggers: result.grammarTriggers,
        thinkingForcedOpen: result.thinkingForcedOpen,
        preservedTokens: result.preservedTokens,
        parser: result.parser,
        tokenCount: tokenCount,
      );
    } catch (_) {
      rethrow;
    }
  }

  // ============================================================
  // LOW-LEVEL GENERATION
  // ============================================================

  /// Generates a stream of text tokens based on the provided raw [prompt].
  ///
  /// This is the low-level generation API. For chat-style interactions with
  /// proper template formatting, use [create] instead.
  ///
  /// Use [GenerationParams] to tune the sampling process.
  ///
  /// If [parts] contains media content, markers will be automatically injected
  /// into the prompt if missing.
  Stream<String> generate(
    String prompt, {
    GenerationParams params = const GenerationParams(),
    List<LlamaContentPart>? parts,
  }) async* {
    _ensureReady();

    try {
      final stream = backend.generate(
        _contextHandle!,
        prompt,
        params,
        parts: parts,
      );

      await for (final token in stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        yield token;
      }
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Generation', error);
    }
  }

  /// Immediately cancels any ongoing generation process.
  void cancelGeneration() {
    backend.cancelGeneration();
  }

  // ============================================================
  // TOKENIZATION
  // ============================================================

  /// Encodes the given [text] into a list of token IDs.
  Future<List<int>> tokenize(String text, {bool addSpecial = true}) async {
    _ensureReady(requireContext: false);
    try {
      return await backend.tokenize(
        _modelHandle!,
        text,
        addSpecial: addSpecial,
      );
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Tokenization', error);
    }
  }

  /// Decodes a list of [tokens] back into a human-readable string.
  Future<String> detokenize(List<int> tokens, {bool special = false}) async {
    _ensureReady(requireContext: false);
    try {
      return await backend.detokenize(_modelHandle!, tokens, special: special);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Detokenization', error);
    }
  }

  /// Utility to count the number of tokens in [text] without running inference.
  Future<int> getTokenCount(String text) async {
    final tokens = await tokenize(text, addSpecial: false);
    return tokens.length;
  }

  // ============================================================
  // EMBEDDINGS
  // ============================================================

  /// Generates a single embedding vector for [text].
  ///
  /// When [normalize] is true, the returned vector is L2-normalized.
  Future<List<double>> embed(String text, {bool normalize = true}) async {
    _ensureReady();
    try {
      final embeddingBackend = _resolveEmbeddingBackend();
      return await embeddingBackend.embed(
        _contextHandle!,
        text,
        normalize: normalize,
      );
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Embeddings', error);
    }
  }

  /// Generates embedding vectors for all [texts] in order.
  ///
  /// When [normalize] is true, each returned vector is L2-normalized.
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool normalize = true,
  }) async {
    _ensureReady();
    if (texts.isEmpty) {
      return const <List<double>>[];
    }

    final embeddingBackend = _resolveEmbeddingBackend();
    try {
      if (embeddingBackend is BackendBatchEmbeddings) {
        return await embeddingBackend.embedBatch(
          _contextHandle!,
          texts,
          normalize: normalize,
        );
      }

      final vectors = <List<double>>[];
      for (final text in texts) {
        final vector = await embeddingBackend.embed(
          _contextHandle!,
          text,
          normalize: normalize,
        );
        vectors.add(vector);
      }
      return vectors;
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Embeddings', error);
    }
  }

  LlamaUnsupportedException _unsupportedBackendOperation(
    String operation,
    UnsupportedError error,
  ) {
    final message = error.message;
    final detail = message == null ? '' : message.toString();
    if (detail.isEmpty) {
      return LlamaUnsupportedException(
        '$operation is not supported by the active backend.',
      );
    }
    return LlamaUnsupportedException(
      '$operation is not supported by the active backend: $detail',
    );
  }

  BackendEmbeddings _resolveEmbeddingBackend() {
    final candidate = backend;
    if (candidate is BackendEmbeddingsSupport &&
        !(candidate as BackendEmbeddingsSupport).supportsEmbeddings) {
      throw LlamaUnsupportedException(
        'Embeddings are not supported by the active backend.',
      );
    }
    if (candidate is BackendEmbeddings) {
      return candidate as BackendEmbeddings;
    }

    throw LlamaUnsupportedException(
      'Embeddings are not supported by the active backend.',
    );
  }

  // ============================================================
  // STATE PERSISTENCE
  // ============================================================

  /// Whether the active backend reports state save/load support.
  ///
  /// Native backends persist to disk. WebGPU backends report support only after
  /// the active JavaScript bridge exposes the `stateSaveFile` and
  /// `stateLoadFile` APIs introduced in bridge assets `v0.1.15`; older or
  /// custom bridge assets report false and calls throw [LlamaUnsupportedException]
  /// before reaching the bridge.
  bool get supportsStatePersistence {
    final candidate = backend;
    if (candidate is BackendStatePersistenceSupport) {
      return (candidate as BackendStatePersistenceSupport)
          .supportsStatePersistence;
    }
    return candidate is BackendStatePersistence;
  }

  /// Persists the KV-cache state of the loaded model to [path] together
  /// with [tokens] — the token sequence the current state was produced
  /// from. A later [stateLoadFile] call rebuilds the same in-memory
  /// state without re-evaluating the prompt, which is the difference
  /// between a 30-second resume on phone CPUs and an instant one.
  ///
  /// File format is whatever llama.cpp emits — opaque, not portable
  /// across builds, and tied to the same model used at save time.
  ///
  /// Returns true on success.
  Future<bool> stateSaveFile(String path, {required List<int> tokens}) async {
    _ensureReady();
    final persistence = await _resolveStatePersistence();
    try {
      return await persistence.stateSaveFile(_contextHandle!, path, tokens);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('State persistence', error);
    }
  }

  /// Restores a previously saved state from [path]. [tokenCapacity]
  /// caps how many tokens to read back; passing the loaded model's
  /// `n_ctx` is a safe default.
  ///
  /// Returns the token sequence the saved state was originally produced
  /// from. This API restores the native KV cache only — callers that use
  /// [ChatSession] must persist and reconstruct the chat message history
  /// separately (e.g. on disk), since [ChatSession.addMessage] takes
  /// [LlamaChatMessage] objects, not raw token ids. The returned token
  /// list is exposed mainly for diagnostics and for callers driving the
  /// engine at the raw prompt level.
  Future<StateLoadResult> stateLoadFile(
    String path, {
    required int tokenCapacity,
  }) async {
    _ensureReady();
    final persistence = await _resolveStatePersistence();
    try {
      return await persistence.stateLoadFile(
        _contextHandle!,
        path,
        tokenCapacity,
      );
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('State persistence', error);
    }
  }

  Future<BackendStatePersistence> _resolveStatePersistence() async {
    final candidate = backend;
    if (candidate is BackendStatePersistenceSupport &&
        !(candidate as BackendStatePersistenceSupport)
            .supportsStatePersistence) {
      throw LlamaUnsupportedException(
        await _statePersistenceUnsupportedMessage(),
      );
    }
    if (candidate is BackendStatePersistence) {
      return candidate as BackendStatePersistence;
    }
    throw LlamaUnsupportedException(
      'State persistence is not supported by the active backend.',
    );
  }

  Future<String> _statePersistenceUnsupportedMessage() async {
    String backendName = '';
    try {
      backendName = await backend.getBackendName();
    } catch (_) {
      // Fall back to the generic message when backend diagnostics are not
      // available on the active runtime.
    }

    final normalizedBackendName = backendName.toLowerCase();
    if (normalizedBackendName.contains('litert-lm')) {
      return 'State persistence is not supported by the active LiteRT-LM '
          'backend because the LiteRT-LM APIs exposed through llamadart do not '
          'provide KV-cache save/load yet.';
    }
    if (normalizedBackendName.contains('webgpu') ||
        normalizedBackendName.contains('web gpu')) {
      return 'State persistence is not supported by the active backend. '
          'For WebGPU, use bridge assets that expose '
          'stateSaveFile/stateLoadFile (v0.1.15 or newer).';
    }
    return 'State persistence is not supported by the active backend.';
  }

  // ============================================================
  // MODEL INTROSPECTION
  // ============================================================

  /// Retrieves all available metadata from the loaded model.
  Future<Map<String, String>> getMetadata() async {
    if (!_isReady || _modelHandle == null) {
      return <String, String>{};
    }
    final metadata = await backend.modelMetadata(_modelHandle!);
    _cachedModelMetadata = Map<String, String>.from(metadata);
    return metadata;
  }

  /// Returns the actual context size being used by the current session.
  Future<int> getContextSize() async {
    if (_isReady && _contextHandle != null) {
      final size = await backend.getContextSize(_contextHandle!);
      if (size > 0) return size;
    }
    final meta = await getMetadata();
    // Try common context length keys in metadata
    final ctx =
        meta['llm.context_length'] ??
        meta['llama.context_length'] ??
        meta['model.context_length'] ??
        meta['n_ctx'] ??
        "0";
    return int.tryParse(ctx) ?? 0;
  }

  /// Whether the loaded model supports vision.
  Future<bool> get supportsVision async =>
      _mmContextHandle != null &&
      await backend.supportsVision(_mmContextHandle!);

  /// Whether the loaded model supports audio.
  Future<bool> get supportsAudio async =>
      _mmContextHandle != null &&
      await backend.supportsAudio(_mmContextHandle!);

  // ============================================================
  // LORA MANAGEMENT
  // ============================================================

  /// Dynamically loads or updates a LoRA adapter's scale.
  Future<void> setLora(String path, {double scale = 1.0}) async {
    _ensureReady();
    try {
      await backend.setLoraAdapter(_contextHandle!, path, scale);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  /// Removes a specific LoRA adapter from the active session.
  Future<void> removeLora(String path) async {
    _ensureReady();
    try {
      await backend.removeLoraAdapter(_contextHandle!, path);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  /// Removes all active LoRA adapters from the current context.
  Future<void> clearLoras() async {
    _ensureReady();
    try {
      await backend.clearLoraAdapters(_contextHandle!);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  // ============================================================
  // BACKEND UTILITIES
  // ============================================================

  /// Internal model handle.
  int? get modelHandle => _modelHandle;

  /// Internal context handle.
  int? get contextHandle => _contextHandle;

  /// Returns the name of the active GPU backend.
  Future<String> getBackendName() => backend.getBackendName();

  /// Returns backend options available for user selection.
  Future<String> getAvailableBackends() {
    final candidate = backend;
    if (candidate is BackendAvailability) {
      return (candidate as BackendAvailability).getAvailableBackends();
    }
    return candidate.getBackendName();
  }

  /// Returns resolved GPU layers for the active model load when available.
  Future<int?> getResolvedGpuLayers() {
    final candidate = backend;
    if (candidate is BackendRuntimeDiagnostics) {
      return (candidate as BackendRuntimeDiagnostics).getResolvedGpuLayers();
    }
    return Future<int?>.value(null);
  }

  /// Returns native llama.cpp perf timings for the active context when available.
  Future<BackendPerfContextData?> getPerformanceContext() {
    final candidate = backend;
    final contextHandle = _contextHandle;
    if (contextHandle == null) {
      return Future<BackendPerfContextData?>.value(null);
    }
    if (candidate is BackendPerformanceDiagnostics) {
      return (candidate as BackendPerformanceDiagnostics).getPerformanceContext(
        contextHandle,
      );
    }
    return Future<BackendPerfContextData?>.value(null);
  }

  /// Returns true if the current hardware and backend support GPU acceleration.
  Future<bool> isGpuSupported() => backend.isGpuSupported();

  /// Returns total and free VRAM in bytes.
  Future<({int total, int free})> getVramInfo() => backend.getVramInfo();

  // ============================================================
  // INTERNAL HELPERS
  // ============================================================

  Future<Map<String, String>> _getCachedMetadata() async {
    if (_cachedModelMetadata != null) {
      return Map<String, String>.from(_cachedModelMetadata!);
    }

    final metadata = await getMetadata();
    _cachedModelMetadata = Map<String, String>.from(metadata);
    return Map<String, String>.from(_cachedModelMetadata!);
  }

  bool _mayNeedStructuredPartialParse(String token) {
    for (var i = 0; i < token.length; i++) {
      switch (token.codeUnitAt(i)) {
        case 0x22: // "
        case 0x2C: // ,
        case 0x3A: // :
        case 0x3C: // <
        case 0x3E: // >
        case 0x5B: // [
        case 0x5C: // \
        case 0x5D: // ]
        case 0x7B: // {
        case 0x7D: // }
          return true;
      }
    }
    return false;
  }

  Future<void> _cleanupFailedLoadState() async {
    if (_contextHandle != null) {
      try {
        await backend.contextFree(_contextHandle!);
      } catch (_) {}
      _contextHandle = null;
    }
    if (_modelHandle != null) {
      try {
        await backend.modelFree(_modelHandle!);
      } catch (_) {}
      _modelHandle = null;
    }
    _modelPath = null;
    _cachedModelMetadata = null;
    _isReady = false;
  }

  void _rejectUnsupportedUrlBackendOptions(ModelLoadOptions options) {
    if (options.cachePolicy != ModelCachePolicy.preferCached) {
      throw LlamaUnsupportedException(
        '${options.cachePolicy.name} model loading requires the native download/cache manager.',
      );
    }
    if (options.bearerToken != null || options.headers.isNotEmpty) {
      throw LlamaUnsupportedException(
        'Authenticated model URL loading requires the native download/cache manager.',
      );
    }
    if (options.cancelToken != null) {
      throw LlamaUnsupportedException(
        'Cancellation tokens require the native download/cache manager.',
      );
    }
    if (options.sha256 != null) {
      throw LlamaUnsupportedException(
        'Checksum verification requires the native download/cache manager.',
      );
    }
    if (options.cacheDirectory != null) {
      throw LlamaUnsupportedException(
        'cacheDirectory is not supported by URL-loading backends.',
      );
    }
    if (!options.resume) {
      throw LlamaUnsupportedException(
        'Disabling resume is not supported by URL-loading backends.',
      );
    }
    if (options.maxRetries != ModelLoadOptions.defaults.maxRetries) {
      throw LlamaUnsupportedException(
        'Custom maxRetries is not supported by URL-loading backends.',
      );
    }
  }

  String _displayNameForSource(String source) {
    final parsedUri = Uri.tryParse(source);
    if (parsedUri != null &&
        parsedUri.hasScheme &&
        parsedUri.pathSegments.isNotEmpty) {
      final lastSegment = parsedUri.pathSegments.last;
      if (lastSegment.isNotEmpty) {
        return Uri.decodeComponent(lastSegment);
      }
    }

    final normalizedSource = source.replaceAll('\\', '/');
    final segments = normalizedSource.split('/');
    final lastSegment = segments.isNotEmpty ? segments.last : source;
    return lastSegment.isNotEmpty ? lastSegment : source;
  }

  String _redactedUriForLogs(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme) {
      return _displayNameForSource(source);
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.hasAuthority ? uri.host : null,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  Object _redactedErrorDetails(Object error) {
    final message = error.toString().replaceAllMapped(
      RegExp(r'https?://[^\s)]+'),
      (match) => _redactedUriForLogs(match.group(0)!),
    );
    return <String, Object?>{
      'type': error.runtimeType.toString(),
      'message': message,
    };
  }

  int? _firstNonWhitespaceIndex(String value) {
    for (var i = 0; i < value.length; i++) {
      if (!_isWhitespaceCodeUnit(value.codeUnitAt(i))) {
        return i;
      }
    }
    return null;
  }

  _ToolStreamingMode _decideToolStreamingMode(String value) {
    const maxProbeChars = 256;
    final start = _firstNonWhitespaceIndex(value);
    if (start == null) {
      return _ToolStreamingMode.undecided;
    }

    final trimmed = value.substring(start);
    if (trimmed.isEmpty) {
      return _ToolStreamingMode.undecided;
    }

    final first = trimmed.codeUnitAt(0);
    _ToolStreamingMode mode;
    if (first == 0x7B) {
      mode = _decideJsonEnvelopeMode(trimmed);
    } else if (first == 0x3C) {
      mode = _decideXmlEnvelopeMode(trimmed);
    } else if (first == 0x5B) {
      mode = _decideBracketEnvelopeMode(trimmed);
    } else {
      mode = _ToolStreamingMode.raw;
    }

    if (mode == _ToolStreamingMode.undecided &&
        trimmed.length >= maxProbeChars) {
      return _ToolStreamingMode.raw;
    }

    return mode;
  }

  _ToolStreamingMode _decideJsonEnvelopeMode(String text) {
    var i = 1;
    while (i < text.length && _isWhitespaceCodeUnit(text.codeUnitAt(i))) {
      i++;
    }

    if (i >= text.length) {
      return _ToolStreamingMode.undecided;
    }

    if (text.codeUnitAt(i) != 0x22) {
      return _ToolStreamingMode.raw;
    }

    i++;
    final keyStart = i;
    while (i < text.length) {
      final ch = text.codeUnitAt(i);
      if (ch == 0x22) {
        final key = text.substring(keyStart, i);
        return _isGenericEnvelopeKey(key)
            ? _ToolStreamingMode.parsed
            : _ToolStreamingMode.raw;
      }
      if (ch == 0x5C) {
        if (i + 1 >= text.length) {
          return _ToolStreamingMode.undecided;
        }
        i += 2;
        continue;
      }
      i++;
    }

    return _ToolStreamingMode.undecided;
  }

  bool _isGenericEnvelopeKey(String key) {
    return key == 'tool_call' || key == 'tool_calls' || key == 'response';
  }

  _ToolStreamingMode _decideBracketEnvelopeMode(String text) {
    const marker = '[TOOL_CALLS]';
    final upper = text.toUpperCase();
    if (upper.startsWith(marker)) {
      return _ToolStreamingMode.parsed;
    }
    if (marker.startsWith(upper)) {
      return _ToolStreamingMode.undecided;
    }
    return _ToolStreamingMode.raw;
  }

  _ToolStreamingMode _decideXmlEnvelopeMode(String text) {
    final lower = text.toLowerCase();
    const parsedPrefixes = <String>[
      '<tool_call',
      '<tool_calls',
      '<function',
      '<function_call',
      '<start_function_call',
      '<|python_tag|>',
      '<tool_response',
    ];

    for (final prefix in parsedPrefixes) {
      if (lower.startsWith(prefix)) {
        return _ToolStreamingMode.parsed;
      }
      if (prefix.startsWith(lower)) {
        return _ToolStreamingMode.undecided;
      }
    }

    final tagNameMatch = RegExp(
      r'^<\s*/?\s*([a-zA-Z_][a-zA-Z0-9_:-]*)',
    ).firstMatch(lower);
    if (tagNameMatch != null) {
      final tagName = tagNameMatch.group(1);
      if (tagName == 'tool_call' ||
          tagName == 'tool_calls' ||
          tagName == 'function' ||
          tagName == 'function_call' ||
          tagName == 'start_function_call' ||
          tagName == 'tool_response') {
        return _ToolStreamingMode.parsed;
      }
      return _ToolStreamingMode.raw;
    }

    if (RegExp(r'^<\s*/?\s*[a-zA-Z_][a-zA-Z0-9_:-]*$').hasMatch(lower)) {
      return _ToolStreamingMode.undecided;
    }

    return _ToolStreamingMode.raw;
  }

  _ThinkingSplitResult _splitThinkingBuffer({
    required String pendingBuffer,
    required bool isThinking,
    required String startTag,
    required String endTag,
  }) {
    final emissions = <_ThinkingSplitEmission>[];
    var localPendingBuffer = pendingBuffer;
    var localIsThinking = isThinking;

    while (localPendingBuffer.isNotEmpty) {
      if (!localIsThinking) {
        final startIdx = localPendingBuffer.indexOf(startTag);
        final endIdx = localPendingBuffer.indexOf(endTag);

        if (startIdx != -1 && (endIdx == -1 || startIdx < endIdx)) {
          final before = localPendingBuffer.substring(0, startIdx);
          if (before.isNotEmpty) {
            emissions.add(
              _ThinkingSplitEmission(text: before, isThinking: false),
            );
          }
          localIsThinking = true;
          localPendingBuffer = localPendingBuffer.substring(
            startIdx + startTag.length,
          );
          continue;
        } else if (endIdx != -1) {
          final reasoning = localPendingBuffer.substring(0, endIdx);
          if (reasoning.isNotEmpty) {
            emissions.add(
              _ThinkingSplitEmission(text: reasoning, isThinking: true),
            );
          }
          localIsThinking = false;
          localPendingBuffer = localPendingBuffer.substring(
            endIdx + endTag.length,
          );
          continue;
        }

        var potentialMatch = false;
        for (var i = startTag.length - 1; i >= 1; i--) {
          if (localPendingBuffer.endsWith(startTag.substring(0, i))) {
            final emitIdx = localPendingBuffer.length - i;
            if (emitIdx > 0) {
              emissions.add(
                _ThinkingSplitEmission(
                  text: localPendingBuffer.substring(0, emitIdx),
                  isThinking: false,
                ),
              );
              localPendingBuffer = localPendingBuffer.substring(emitIdx);
            }
            potentialMatch = true;
            break;
          }
        }
        if (!potentialMatch) {
          emissions.add(
            _ThinkingSplitEmission(text: localPendingBuffer, isThinking: false),
          );
          localPendingBuffer = '';
        }
        break;
      }

      final endIdx = localPendingBuffer.indexOf(endTag);
      if (endIdx != -1) {
        final reasoning = localPendingBuffer.substring(0, endIdx);
        if (reasoning.isNotEmpty) {
          emissions.add(
            _ThinkingSplitEmission(text: reasoning, isThinking: true),
          );
        }
        localIsThinking = false;
        localPendingBuffer = localPendingBuffer.substring(
          endIdx + endTag.length,
        );
        continue;
      }

      var potentialMatch = false;
      for (var i = endTag.length - 1; i >= 1; i--) {
        if (localPendingBuffer.endsWith(endTag.substring(0, i))) {
          final emitIdx = localPendingBuffer.length - i;
          if (emitIdx > 0) {
            emissions.add(
              _ThinkingSplitEmission(
                text: localPendingBuffer.substring(0, emitIdx),
                isThinking: true,
              ),
            );
            localPendingBuffer = localPendingBuffer.substring(emitIdx);
          }
          potentialMatch = true;
          break;
        }
      }
      if (!potentialMatch) {
        emissions.add(
          _ThinkingSplitEmission(text: localPendingBuffer, isThinking: true),
        );
        localPendingBuffer = '';
      }
      break;
    }

    return _ThinkingSplitResult(
      pendingBuffer: localPendingBuffer,
      isThinking: localIsThinking,
      emissions: emissions,
    );
  }

  String? _computeFinalReconciliationDelta({
    required String streamedValue,
    required String finalValue,
    required String channel,
  }) {
    if (finalValue.length <= streamedValue.length) {
      return null;
    }

    if (!finalValue.startsWith(streamedValue)) {
      LlamaLogger.instance.warning(
        'Skipping final $channel delta due to prefix mismatch '
        '(streamed=${streamedValue.length}, final=${finalValue.length})',
      );
      return null;
    }

    return finalValue.substring(streamedValue.length);
  }

  bool _isWhitespaceCodeUnit(int codeUnit) {
    return codeUnit == 0x20 || // space
        codeUnit == 0x09 || // \t
        codeUnit == 0x0A || // \n
        codeUnit == 0x0D; // \r
  }

  /// Validates engine is ready for inference.
  void _ensureReady({bool requireContext = true}) {
    if (!_isReady) {
      throw LlamaContextException("Engine not ready. Call loadModel first.");
    }
    if (requireContext && _contextHandle == null) {
      throw LlamaContextException("Context not initialized.");
    }
  }

  /// Ensures the engine is NOT currently loaded.
  void _ensureNotReady() {
    if (_isReady) {
      throw LlamaStateException(
        'Model is already loaded. Call unloadModel() first.',
      );
    }
  }
}
