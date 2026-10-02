import 'dart:async';
import 'dart:convert';

import '../../backends/backend.dart';
import 'chat_completion_request_planner.dart';
import 'chat_completion_stream_parser.dart';
import 'chat_template_renderer.dart';
import 'engine_capabilities.dart';
import 'engine_observation.dart';
import 'engine_observer.dart';
import 'generation_cancellation.dart';
import '../exceptions.dart';
import '../models/config/gpu_backend.dart';
import '../models/config/lora_config.dart';
import '../models/config/gpu_device_info.dart';
import '../models/config/log_level.dart';
import '../models/diagnostics/model_file_type.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/completion.dart';
import '../models/chat/completion_chunk.dart';
import '../models/chat/content_part.dart';
import '../models/chat/chat_template_result.dart';
import '../llama_logger.dart';
import '../llama_logging.dart';
import '../models/inference/model_params.dart';
import '../models/inference/generation_params.dart';
import '../models/inference/generation_usage.dart';
import '../models/inference/next_token_scores.dart';
import '../models/inference/structured_output.dart';
import '../models/inference/tool_choice.dart';
import '../models/model_format.dart';
import '../models/model_load_options.dart';
import '../models/model_resolver.dart';
import '../models/model_source.dart';
import '../models/model_target_file.dart';
import '../models/download/model_download_manager.dart';
import '../models/tools/tool_definition.dart';
import '../speech/speech_engine_lease.dart';
import '../url_redaction.dart';

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
/// // Stream a completion
/// await for (final chunk in engine.create(messages)) {
///   stdout.write(chunk.text);
/// }
///
/// // Or wait for the whole reply, append it and continue the conversation
/// final reply = await engine.complete(messages);
/// messages.add(reply.message);
/// messages.add(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Follow up?'));
/// final followUp = await engine.create(messages).text();
/// ```
class LlamaEngine {
  /// The backend implementation used for inference.
  final LlamaBackend backend;

  /// Resolves source-aware model loading requests.
  final ModelResolver modelResolver;

  /// Downloads and caches remote model sources for native/file-backed backends.
  final ModelDownloadManager modelDownloadManager;

  /// The observers of this engine's operations.
  final List<LlamaEngineObserver> observers;
  String? _observedModel;
  LlamaRuntime? _observedRuntime;
  int? _modelHandle;
  int? _contextHandle;
  int? _mmContextHandle;
  // Serializes multimodal projector load/unload so concurrent calls cannot
  // race the native create/free (which could leak or double-free the context).
  Future<void> _mmLifecycle = Future<void>.value();
  Future<void>? _modelLifecycleOperation;
  bool _isReadyState = false;
  // Changes on every load and unload, so a probe that awaits can tell whether
  // the model it started on is still the loaded one.
  int _modelEpoch = 0;
  bool get _isReady => _isReadyState;
  set _isReady(bool value) {
    _isReadyState = value;
    _modelEpoch++;
  }

  String? _completionModel;
  Map<String, String>? _cachedModelMetadata;
  String? _modelChatTemplate;
  final Map<int, int> _decisionHeadHandles = <int, int>{};
  final Map<String, String> _loraLocations = <String, String>{};
  int _nextDecisionHeadHandle = 1;
  int _decisionHeadEpoch = 0;
  late final GenerationCancellation _generationCancellation =
      GenerationCancellation.forEngine(this);

  /// Configures logging for the library.
  ///
  /// Sets the Dart-side [level] and [handler] like [LlamaLogging.configure]
  /// and keeps the current [LlamaLogging.nativeLevel].
  @Deprecated(
    'Use LlamaLogging.configure(level:, nativeLevel:, handler:). '
    'This forwarder will be removed in a future release.',
  )
  static void configureLogging({
    LlamaLogLevel level = LlamaLogLevel.none,
    LlamaLogHandler? handler,
  }) {
    LlamaLogger.instance.setHandler(handler);
    unawaited(applyLogLevels(dart: level, native: LlamaLogging.nativeLevel));
  }

  /// Creates a new [LlamaEngine] instance with the given [backend].
  ///
  /// [observers] see chat completions, text completions, embeddings and
  /// model loads; see [LlamaEngineObserver]. Without observers the engine
  /// does no observation work.
  LlamaEngine(
    this.backend, {
    ModelResolver? modelResolver,
    ModelDownloadManager? modelDownloadManager,
    Iterable<LlamaEngineObserver> observers = const <LlamaEngineObserver>[],
  }) : modelResolver = modelResolver ?? const DefaultModelResolver(),
       modelDownloadManager =
           modelDownloadManager ?? DefaultModelDownloadManager(),
       observers = List<LlamaEngineObserver>.unmodifiable(observers) {
    registerLoggingBackend(backend);
  }

  /// Sets both the Dart-side and native log levels to [level], keeping the
  /// handler.
  @Deprecated(
    'Use LlamaLogging.configure(level:, handler:). '
    'This forwarder will be removed in a future release.',
  )
  Future<void> setLogLevel(LlamaLogLevel level) =>
      applyLogLevels(dart: level, native: level);

  /// Sets the library-wide Dart-side log level, keeping the native level and
  /// the handler.
  @Deprecated(
    'Use LlamaLogging.configure(level:, nativeLevel:, handler:). '
    'This forwarder will be removed in a future release.',
  )
  Future<void> setDartLogLevel(LlamaLogLevel level) =>
      applyLogLevels(dart: level, native: LlamaLogging.nativeLevel);

  /// Sets the library-wide native log level, keeping the Dart-side level and
  /// the handler.
  @Deprecated(
    'Use LlamaLogging.configure(level:, nativeLevel:, handler:). '
    'This forwarder will be removed in a future release.',
  )
  Future<void> setNativeLogLevel(LlamaLogLevel level) =>
      applyLogLevels(dart: LlamaLogging.level, native: level);

  /// The library-wide Dart-side log level.
  @Deprecated('Use LlamaLogging.level.')
  LlamaLogLevel get dartLogLevel => LlamaLogging.level;

  /// The library-wide native log level.
  @Deprecated('Use LlamaLogging.nativeLevel.')
  LlamaLogLevel get nativeLogLevel => LlamaLogging.nativeLevel;

  // ============================================================
  // MODEL LIFECYCLE
  // ============================================================

  /// Whether the engine is initialized and ready for inference.
  bool get isReady => _isReady;

  /// The runtime that runs the loaded model, or null when no model is loaded
  /// or the backend does not report it.
  ///
  /// GGUF models run on [LlamaRuntime.llamaCpp], natively or through the
  /// WebGPU bridge on the web, and `.litertlm` bundles on
  /// [LlamaRuntime.liteRtLm]. Read [capabilities] for what the runtime
  /// supports instead of branching on it where a capability exists.
  LlamaRuntime? get runtime {
    if (!_isReady || _modelHandle == null) return null;
    final candidate = backend;
    return candidate is BackendRuntimeIdentity
        ? (candidate as BackendRuntimeIdentity).runtime
        : null;
  }

  /// What this engine and its loaded model support, as the loaded model's
  /// runtime reports it.
  ///
  /// Before a model loads, [LlamaEngineCapabilities.isSupported] is false
  /// and every capability is false, as it is when a model loads or unloads
  /// while the snapshot is read. Read it again after loading or unloading a
  /// model or multimodal projector.
  Future<LlamaEngineCapabilities> get capabilities async {
    const notLoaded = LlamaEngineCapabilities(
      isSupported: false,
      unsupportedReason: 'No model is loaded. Call loadModel first.',
    );
    if (!_isReady || _modelHandle == null) {
      return notLoaded;
    }
    final epoch = _modelEpoch;
    final candidate = backend;
    final runtime = this.runtime;
    final embeddings = supportsEmbeddings;
    final nextTokenScoring = supportsNextTokenScoring;
    final chatScope = candidate is BackendChatScope
        ? candidate as BackendChatScope
        : null;
    final multiTurnChat = chatScope?.supportsMultiTurnChat ?? true;
    final toolCalling = chatScope?.supportsToolCalling ?? true;
    final grammar = ChatCompletionRequestPlanner.supportsGrammarConstraints(
      candidate,
    );
    final lazyGrammar =
        grammar && ChatCompletionRequestPlanner.supportsLazyGrammar(candidate);
    final mmContextHandle = _mmContextHandle;

    final BackendGenerationCapabilities generation;
    final ({bool vision, bool audio}) directMedia;
    final bool projectorVision;
    final bool projectorAudio;
    String? backendName;
    try {
      generation = await _generationCapabilities();
      directMedia = candidate is BackendDirectMediaInput
          ? await (candidate as BackendDirectMediaInput).directMediaInput()
          : (vision: false, audio: false);
      projectorVision =
          mmContextHandle != null &&
          await _probeMedia(() => candidate.supportsVision(mmContextHandle));
      projectorAudio =
          mmContextHandle != null &&
          await _probeMedia(() => candidate.supportsAudio(mmContextHandle));
      try {
        backendName = await candidate.getBackendName();
      } catch (error, stackTrace) {
        LlamaLogger.instance.warning(
          'Could not read the backend name for capabilities.',
          error,
          stackTrace,
        );
      }
    } catch (_) {
      if (_modelEpoch != epoch) return notLoaded;
      rethrow;
    }
    // A load or unload while probing would mix two models' answers.
    if (_modelEpoch != epoch) return notLoaded;
    return LlamaEngineCapabilities(
      isSupported: true,
      backendName: backendName,
      runtime: runtime,
      supportsVision: directMedia.vision || projectorVision,
      supportsAudio: directMedia.audio || projectorAudio,
      supportsEmbeddings: embeddings,
      supportsNextTokenScoring: nextTokenScoring,
      supportsMultiTurnChat: multiTurnChat,
      supportsToolCalling: toolCalling,
      supportsStructuredOutput: grammar,
      supportsGrammar: grammar,
      supportsLazyGrammar: lazyGrammar,
      supportsPenalty: generation.penalty,
      supportsPresencePenalty: generation.presencePenalty,
      supportsMinP: generation.minP,
      supportsThinkingBudget: generation.thinkingBudget,
      supportsStreamBatching: generation.streamBatching,
      speculativeDecodingStrategies: Set.unmodifiable(
        generation.speculativeDecodingStrategies,
      ),
    );
  }

  /// A media probe that cannot run reports no support instead of throwing.
  Future<bool> _probeMedia(Future<bool> Function() probe) async {
    try {
      return await probe();
    } on LlamaUnsupportedException catch (error, stackTrace) {
      LlamaLogger.instance.warning(
        'Multimodal capability probe failed.',
        error,
        stackTrace,
      );
      return false;
    }
  }

  /// Loads a model from a local [path].
  ///
  /// Optionally provide [ModelParams] to configure context size, GPU offloading,
  /// and more.
  ///
  /// The default native backend reads the file header to choose llama.cpp for
  /// GGUF or LiteRT-LM for a `.litertlm` bundle, so the file name needs no
  /// model extension. Throws [LlamaModelFormatException] when a recognized
  /// header contradicts the file extension. To name the format of a file whose
  /// header cannot be read, load it with [loadModelSource] and a
  /// [ModelSource.format].
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) {
    return _loadModelAs(path, modelParams, null);
  }

  Future<void> _loadModelAs(
    String path,
    ModelParams modelParams,
    ModelFormat? format,
  ) {
    return _observeModelLoad(
      path,
      modelParams,
      () => _withModelLifecycle('load a model', () async {
        await _loadModel(path, modelParams: modelParams, format: format);
        await _captureObservedModel(path);
      }),
    );
  }

  Future<void> _loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
    ModelFormat? format,
  }) async {
    _ensureNotReady();
    modelParams = await _resolveLoraSources(
      modelParams,
      ModelLoadOptions.defaults,
    );
    final modelName = _displayNameForSource(path);
    LlamaLogger.instance.info('Loading model: $modelName');

    if (backend.supportsUrlLoading) {
      LlamaLogger.instance.info(
        'Backend supports URL loading, attempting loadModelFromUrl.',
      );
      return _loadModelFromUrl(path, modelParams: modelParams, format: format);
    }

    final redactedPath = _redactedSource(path);
    try {
      await backend.setLogLevel(LlamaLogging.nativeLevel);
      _completionModel = _modelNameForSource(path);
      _cachedModelMetadata = null;
      _modelHandle = await _backendModelLoad(
        path,
        modelParams,
        format,
        fromUrl: false,
      );
      _contextHandle = await backend.contextCreate(_modelHandle!, modelParams);
      _modelChatTemplate = modelParams.chatTemplate;
      _isReady = true;
      LlamaLogger.instance.info(_modelLoadedMessage(modelName, redactedPath));
    } catch (e, stackTrace) {
      await _cleanupFailedLoadState();
      LlamaLogger.instance.error(
        'Failed to load model $modelName from $redactedPath',
        _redactedErrorDetails(e, path),
        stackTrace,
      );
      if (e is LlamaUnsupportedException || e is LlamaModelFormatException) {
        rethrow;
      }
      if (e is UnsupportedError) {
        throw _unsupportedBackendOperation('Model loading', e);
      }
      throw LlamaModelException(
        'Failed to load model from $redactedPath',
        _redactedErrorDetails(e, path),
      );
    }
  }

  /// Loads a model from a structured [source].
  ///
  /// Local path sources are dispatched through [loadModel]. Remote URL targets
  /// use the native download/cache manager on file-backed backends, then load
  /// the cached local file. URL-capable web backends keep using
  /// [loadModelFromUrl] for unauthenticated prefer-cached requests.
  ///
  /// Adapters in [ModelParams.loras] given as [LoraAdapterConfig.source]
  /// resolve after the model file, with [options] except
  /// [ModelLoadOptions.sha256]; see [ModelParams.loras].
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
    _throwIfSourceLoadCancelled(options);

    if (!backend.supportsUrlLoading) {
      final entry = await ensureModelTargetFile(
        modelDownloadManager,
        source,
        target,
        options: options,
        onProgress: onProgress,
      );
      _throwIfSourceLoadCancelled(options);
      final resolvedParams = await _resolveLoraSources(
        modelParams,
        _withoutSha256(options),
      );
      _throwIfSourceLoadCancelled(options);
      return _loadSourceFile(entry.filePath, resolvedParams, source.format);
    }
    switch (target) {
      case LocalModelFile():
        throw LlamaUnsupportedException(
          'Explicit local model paths are not supported by URL-loading backends.',
        );
      case RemoteModelUrl(:final url, :final useBrowserCache):
        if (!useBrowserCache) {
          throw LlamaUnsupportedException(
            'Remote model loading without browser/backend cache is not supported yet.',
          );
        }
        _rejectUnsupportedUrlBackendOptions(options);
        final urlProgress = onProgress == null
            ? null
            : (double progress) =>
                  onProgress(ModelDownloadProgress.fraction(progress));
        final format = source.format;
        if (format == null) {
          return loadModelFromUrl(
            url.toString(),
            modelParams: modelParams,
            onProgress: urlProgress,
          );
        }
        return _loadModelFromUrlAs(
          url.toString(),
          modelParams,
          urlProgress,
          format,
        );
    }
  }

  /// Loads a model from a [url].
  ///
  /// This is typically used on the Web platform. Use [ModelParams] to
  /// configure loading options.
  ///
  /// The runtime fetches [url] itself, so its content cannot pick the
  /// runtime: the URL path's extension does, and a URL without a model
  /// extension loads as GGUF. For such a URL, load it with [loadModelSource]
  /// and a [ModelSource.format].
  Future<void> loadModelFromUrl(
    String url, {
    ModelParams modelParams = const ModelParams(),
    Function(double progress)? onProgress,
  }) {
    return _loadModelFromUrlAs(url, modelParams, onProgress, null);
  }

  Future<void> _loadModelFromUrlAs(
    String url,
    ModelParams modelParams,
    Function(double progress)? onProgress,
    ModelFormat? format,
  ) {
    return _observeModelLoad(
      url,
      modelParams,
      () => _withModelLifecycle('load a model from URL', () async {
        await _loadModelFromUrl(
          url,
          modelParams: modelParams,
          onProgress: onProgress,
          format: format,
        );
        await _captureObservedModel(url);
      }),
    );
  }

  // Calls the public loader when there is no format, so a subclass that
  // overrides loadModel keeps receiving source loads.
  Future<void> _loadSourceFile(
    String path,
    ModelParams modelParams,
    ModelFormat? format,
  ) {
    if (format == null) return loadModel(path, modelParams: modelParams);
    return _loadModelAs(path, modelParams, format);
  }

  Future<void> _observeModelLoad(
    String source,
    ModelParams modelParams,
    Future<void> Function() load,
  ) {
    if (observers.isEmpty) return load();
    return observeFuture(
      load,
      observers: observers,
      operation: LlamaModelLoadOperation(
        model: _modelNameForSource(source),
        modelParams: modelParams,
      ),
    );
  }

  /// Records the model name and runtime that observed operations report,
  /// when the engine has observers.
  Future<void> _captureObservedModel(String source) async {
    if (observers.isEmpty) return;
    final candidate = backend;
    _observedRuntime = candidate is BackendRuntimeIdentity
        ? (candidate as BackendRuntimeIdentity).runtime
        : null;
    String? name;
    try {
      name = (await _getCachedMetadata())['general.name']?.trim();
    } catch (error, stackTrace) {
      LlamaLogger.instance.warning(
        'Could not read the model name for observers.',
        error,
        stackTrace,
      );
    }
    _observedModel = name == null || name.isEmpty
        ? _modelNameForSource(source)
        : name;
  }

  static final RegExp _sourceScheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]+):');
  static final RegExp _unsafeModelName = RegExp(
    r'[/\\?#@;&=]|%(?:2f|5c|3f|23|40|3b|26|3d)',
    caseSensitive: false,
  );

  String? _modelNameForSource(String source) => _sourceName(source).name;

  /// The last path segment of [source] as `name`, and the userinfo
  /// credentials of a URL [source] that a name must not repeat.
  ///
  /// `name` is null when the segment is empty, holds URL syntax that could
  /// carry more than a file name, as written or as a percent escape, contains
  /// a credential, or [source] is a `data:` or `blob:` URL. A URL's segment is
  /// percent-decoded, and null when that fails; a file name is literal.
  ///
  /// [source] is a URL when it has a scheme of two or more characters (so a
  /// Windows drive letter is not one), starts with `//`, or the backend loads
  /// URLs. Otherwise it is a file path split at `/` and `\`, so `?` and `#`
  /// in its directory names are literal.
  ({String? name, Set<String> credentials}) _sourceName(String source) {
    final scheme = _sourceScheme.firstMatch(source)?[1]?.toLowerCase();
    final isUrl =
        scheme != null || source.startsWith('//') || backend.supportsUrlLoading;
    var path = source.replaceAll('\\', '/');
    var credentials = const <String>{};
    if (isUrl) {
      if (scheme == 'data' || scheme == 'blob') {
        return (name: null, credentials: credentials);
      }
      path = path.split('#').first.split('?').first;
      if (scheme != null) path = path.substring(scheme.length + 1);
      if (const {'http', 'https', 'ws', 'wss', 'ftp'}.contains(scheme)) {
        // Browsers read `https:host/m` and `https:/host/m` as `https://host/m`.
        path = '//${path.replaceFirst(RegExp('^/*'), '')}';
      }
      if (path.startsWith('//')) {
        final pathStart = path.indexOf('/', 2);
        final authority = path.substring(2, pathStart < 0 ? null : pathStart);
        credentials = _userInfoCredentials(authority);
        if (pathStart < 0) return (name: null, credentials: credentials);
        path = path.substring(pathStart);
      }
    }
    final segment = path.split('/').last;
    String? name;
    if (segment.isNotEmpty && !segment.contains(_unsafeModelName)) {
      name = isUrl ? _percentDecodedOrNull(segment) : segment;
    }
    if (name != null && _repeatsCredential(name, credentials)) name = null;
    return (name: name, credentials: credentials);
  }

  /// The userinfo of [authority] and its password, as written and
  /// percent-decoded, matching the credentials that [redactUrlSecrets]
  /// removes.
  static Set<String> _userInfoCredentials(String authority) {
    final at = authority.lastIndexOf('@');
    if (at < 0) return const <String>{};
    final userInfo = authority.substring(0, at);
    final colon = userInfo.indexOf(':');
    return <String>{
      for (final secret in <String>[
        userInfo,
        if (colon >= 0) userInfo.substring(colon + 1),
      ])
        if (secret.isNotEmpty) ...<String>{
          secret,
          ?_percentDecodedOrNull(secret),
        },
    };
  }

  static bool _repeatsCredential(String text, Set<String> credentials) {
    final decoded = _percentDecodedOrNull(text);
    return credentials.any(
      (secret) => text.contains(secret) || (decoded?.contains(secret) ?? false),
    );
  }

  static String? _percentDecodedOrNull(String text) {
    try {
      return Uri.decodeComponent(text);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _loadModelFromUrl(
    String url, {
    ModelParams modelParams = const ModelParams(),
    Function(double progress)? onProgress,
    ModelFormat? format,
  }) async {
    _ensureNotReady();
    final modelName = _displayNameForSource(url);
    final redactedUrl = _redactedSource(url);
    LlamaLogger.instance.info('Loading model from URL: $modelName');

    if (!backend.supportsUrlLoading) {
      throw LlamaUnsupportedException(
        'loadModelFromUrl requires a backend that supports URL loading.',
      );
    }
    modelParams = await _resolveLoraSources(
      modelParams,
      ModelLoadOptions.defaults,
    );

    try {
      await backend.setLogLevel(LlamaLogging.nativeLevel);
      _completionModel = _modelNameForSource(url);
      _cachedModelMetadata = null;

      _modelHandle = await _backendModelLoad(
        url,
        modelParams,
        format,
        fromUrl: true,
        onProgress: onProgress,
      );
      _contextHandle = await backend.contextCreate(_modelHandle!, modelParams);
      _modelChatTemplate = modelParams.chatTemplate;
      _isReady = true;

      LlamaLogger.instance.info(_modelLoadedMessage(modelName, redactedUrl));
    } catch (e, stackTrace) {
      await _cleanupFailedLoadState();

      LlamaLogger.instance.error(
        'Failed to load model $modelName from URL $redactedUrl',
        _redactedErrorDetails(e, url),
        stackTrace,
      );
      if (e is LlamaUnsupportedException) {
        rethrow;
      }
      if (e is UnsupportedError) {
        throw _unsupportedBackendOperation('Model URL loading', e);
      }
      throw LlamaModelException(
        'Failed to load model from $redactedUrl',
        _redactedErrorDetails(e, url),
      );
    }
  }

  Future<int> _backendModelLoad(
    String source,
    ModelParams modelParams,
    ModelFormat? format, {
    required bool fromUrl,
    Function(double progress)? onProgress,
  }) {
    final candidate = backend;
    if (format != null) {
      if (candidate is BackendModelFormatRouting) {
        final router = candidate as BackendModelFormatRouting;
        return fromUrl
            ? router.modelLoadFromUrlAs(
                source,
                modelParams,
                format,
                onProgress: onProgress,
              )
            : router.modelLoadAs(source, modelParams, format);
      }
      final runtime = candidate is BackendRuntimeIdentity
          ? (candidate as BackendRuntimeIdentity).runtime
          : null;
      if (runtime != format.runtime) {
        throw LlamaUnsupportedException(
          'This backend cannot load ModelFormat.${format.name}: '
          '${runtime == null ? 'it cannot choose a runtime by model format' : 'it runs only ${runtime.name}'}. '
          'Use LlamaBackend(), which picks the runtime per model.',
        );
      }
    }
    return fromUrl
        ? candidate.modelLoadFromUrl(
            source,
            modelParams,
            onProgress: onProgress,
          )
        : candidate.modelLoad(source, modelParams);
  }

  // Runs [action] after any in-flight multimodal lifecycle operation, so
  // create/free of the multimodal context never overlap.
  Future<T> _withMmLifecycle<T>(Future<T> Function() action) {
    final result = _mmLifecycle.then((_) => action());
    // Advance the chain on a swallowed copy so one failed operation doesn't
    // wedge subsequent ones; the real result/error still flows to the caller.
    _mmLifecycle = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Loads a multimodal projector model for vision/audio support.
  ///
  /// A model must already be loaded with [loadModel], [loadModelSource], or
  /// [loadModelFromUrl]. Calling this before the model is ready throws a
  /// [LlamaContextException].
  ///
  /// On the native llama.cpp backend, throws [LlamaModelException] when
  /// [mmProjPath] is not an existing file or the runtime rejects the projector
  /// for the loaded model, and [LlamaUnsupportedException] only when the
  /// runtime cannot run an mtmd function this package calls. A backend error
  /// that is not a [LlamaException] becomes a [LlamaModelException] without
  /// the URL secrets of [mmProjPath].
  Future<void> loadMultimodalProjector(String mmProjPath) {
    return _withMmLifecycle(() => _loadMultimodalProjectorLocked(mmProjPath));
  }

  /// Loads a multimodal projector from a structured [source].
  ///
  /// A model must already be loaded with [loadModel], [loadModelSource], or
  /// [loadModelFromUrl]. Calling this before the model is ready throws a
  /// [LlamaContextException].
  ///
  /// This method is lifecycle-compatible with [loadMultimodalProjector]:
  /// source resolution, package-managed download/cache work, and the final
  /// backend projector load are serialized with direct path projector loads and
  /// unloads. Concurrent projector lifecycle calls are applied in call order,
  /// and loading a new projector replaces any active projector.
  ///
  /// Local path sources are validated by the configured
  /// [modelDownloadManager], then loaded from their local file path. Remote
  /// sources use the native download/cache manager on file-backed backends. On
  /// URL-loading backends, remote unauthenticated sources are passed directly to
  /// the backend; package-managed auth, headers, checksum verification, cache
  /// policy changes, cache directories, cancellation, retry/resume settings,
  /// and progress reporting are not available because the backend/browser owns
  /// the network and cache behavior.
  ///
  /// Throws [LlamaUnsupportedException] when the active backend cannot load
  /// multimodal projectors, when a local path is used with a URL-loading
  /// backend, when the resolver returns a remote target that disallows
  /// browser/backend caching, or when URL-backend loading is requested with
  /// options that require the package-managed download/cache manager.
  Future<void> loadMultimodalProjectorSource(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) {
    return _withMmLifecycle(() async {
      _ensureReady(requireContext: false);
      final location = await _resolveAuxiliarySource(
        source,
        options: options,
        onProgress: onProgress,
        assetType: 'multimodal projector',
      );
      return _loadMultimodalProjectorLocked(location);
    });
  }

  /// The local file, or on a URL-loading backend the URL, that the backend
  /// loads for the auxiliary file [source] of [assetType], resolved as
  /// [loadMultimodalProjectorSource] describes.
  Future<String> _resolveAuxiliarySource(
    ModelSource source, {
    required ModelLoadOptions options,
    ModelDownloadProgressCallback? onProgress,
    required String assetType,
  }) async {
    final target = await modelResolver.resolve(
      source,
      ModelResolveRequest(options: options, onProgress: onProgress),
    );

    if (!backend.supportsUrlLoading) {
      final entry = await ensureModelTargetFile(
        modelDownloadManager,
        source,
        target,
        options: options,
        onProgress: onProgress,
        assetType: assetType,
      );
      return entry.filePath;
    }
    switch (target) {
      case LocalModelFile():
        throw LlamaUnsupportedException(
          'Explicit local $assetType paths are not supported by URL-loading backends.',
        );
      case RemoteModelUrl(:final url, :final useBrowserCache):
        if (!useBrowserCache) {
          throw LlamaUnsupportedException(
            'Remote $assetType loading without browser/backend cache is not supported yet.',
          );
        }
        _rejectUnsupportedUrlBackendOptions(options, assetType: assetType);
        return url.toString();
    }
  }

  Future<void> _loadMultimodalProjectorLocked(String mmProjPath) async {
    final mmProjName = _displayNameForSource(mmProjPath);
    LlamaLogger.instance.info('Loading multimodal projector: $mmProjName');
    _ensureReady(requireContext: false);
    try {
      if (_mmContextHandle != null) {
        await _unloadMultimodalProjectorLocked();
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
        _redactedErrorDetails(e, mmProjPath),
        stackTrace,
      );
      if (e is LlamaException) {
        rethrow;
      }
      if (e is UnsupportedError) {
        throw _unsupportedBackendOperation('Multimodal projectors', e);
      }
      throw LlamaModelException(
        'Failed to load multimodal projector $mmProjName',
        _redactedErrorDetails(e, mmProjPath),
      );
    }
  }

  /// Unloads the active multimodal projector while keeping the model loaded.
  Future<void> unloadMultimodalProjector() {
    return _withMmLifecycle(_unloadMultimodalProjectorLocked);
  }

  Future<void> _unloadMultimodalProjectorLocked() async {
    final mmContextHandle = _mmContextHandle;
    if (mmContextHandle == null) {
      return;
    }

    LlamaLogger.instance.info('Unloading multimodal projector');
    // Free the native context before clearing the handle so a concurrent
    // reader never observes a null handle while teardown is still in flight.
    // Serialization via _withMmLifecycle prevents a double free.
    await backend.multimodalContextFree(mmContextHandle);
    if (_mmContextHandle == mmContextHandle) {
      _mmContextHandle = null;
    }
  }

  /// Releases all allocated resources.
  Future<void> dispose() async {
    unregisterLoggingBackend(backend);
    final activeLifecycle = _modelLifecycleOperation;
    if (activeLifecycle != null) {
      try {
        await activeLifecycle;
      } catch (_) {
        // Disposal still needs to release backend resources after a failed
        // lifecycle operation.
      }
    }

    Object? unloadError;
    StackTrace? unloadStackTrace;
    try {
      await unloadModel();
    } catch (error, stackTrace) {
      unloadError = error;
      unloadStackTrace = stackTrace;
    }

    try {
      await backend.dispose();
    } catch (error, stackTrace) {
      if (unloadError == null) {
        unloadError = error;
        unloadStackTrace = stackTrace;
      }
    }

    if (unloadError != null) {
      Error.throwWithStackTrace(unloadError, unloadStackTrace!);
    }
  }

  /// Unloads the currently loaded model and frees its resources.
  Future<void> unloadModel() {
    return _withModelLifecycle('unload the current model', _unloadModel);
  }

  Future<void> _unloadModel() async {
    if (!isReady && _modelHandle == null && _mmContextHandle == null) return;
    LlamaLogger.instance.info('Unloading model...');
    _isReady = false;
    _decisionHeadHandles.clear();
    _decisionHeadEpoch++;
    _loraLocations.clear();
    backend.cancelGeneration();
    SpeechEngineLease.cancelActiveTask(this);
    if (_contextHandle != null) {
      await backend.contextFree(_contextHandle!);
      _contextHandle = null;
    }
    // Always queue the projector unload (even when no handle is set yet): a
    // projector load may be in flight and not have assigned _mmContextHandle.
    // Routing through the serialized lifecycle makes this wait behind that load
    // and free the projector before the model handle is released.
    await unloadMultimodalProjector();
    if (_modelHandle != null) {
      await backend.modelFree(_modelHandle!);
      _modelHandle = null;
    }
    _completionModel = null;
    _cachedModelMetadata = null;
    _modelChatTemplate = null;
    _observedModel = null;
    _observedRuntime = null;
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
  /// Pass [responseFormat] to request strict structured output through
  /// grammar-constrained decoding on compatible backends. Supported shapes are:
  /// - `{'type': 'json_object'}`
  /// - `{'type': 'json_schema', 'json_schema': {'schema': <JSON schema>}}`,
  ///   optionally with `name`, `description` and `strict` beside `schema`
  /// - `{'type': 'text'}`, which requests unconstrained text
  /// Any other type or key throws [LlamaUnsupportedException] before
  /// generation on every backend.
  /// Use [LlamaStructuredOutput.responseFormat] or [createStructuredJson] for a
  /// typed helper that also validates and decodes the final JSON output.
  ///
  /// Backends without grammar-constrained decoding, including LiteRT-LM native
  /// and web today, throw [LlamaUnsupportedException] for strict
  /// [responseFormat] requests instead of silently running unconstrained
  /// generation.
  ///
  /// Structured output is separate from tool-call parsing: LiteRT-LM can still
  /// parse compatible best-effort tool-call text, but it does not currently
  /// enforce arbitrary JSON-schema constraints.
  ///
  /// Example:
  /// ```dart
  /// final messages = [
  ///   LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hello!'),
  /// ];
  /// await for (final chunk in engine.create(messages)) {
  ///   stdout.write(chunk.text);
  /// }
  ///
  /// await engine.create(messages, responseFormat: const {
  ///   'type': 'json_schema',
  ///   'json_schema': {
  ///     'schema': {
  ///       'type': 'object',
  ///       'properties': {
  ///         'ok': {'type': 'boolean'},
  ///       },
  ///       'required': ['ok'],
  ///     },
  ///   },
  /// }).drain();
  /// ```
  ///
  /// Read each chunk with `chunk.text`, `chunk.thinking`, `chunk.toolCalls`
  /// and `chunk.finishReason`, or the whole stream with `text()`,
  /// `textDeltas()` or `collect()`; [complete] is `create(...).collect()`.
  ///
  /// The final chunk's `finishReason` is `tool_calls` when it carries tool
  /// calls. Otherwise it is `length` when the native llama.cpp backend stopped
  /// at [GenerationParams.maxTokens] or a full context before the model ended
  /// its output, and `stop` in every other case, including backends that do
  /// not report a token limit.
  ///
  /// The final chunk's `usage` holds the request's token counts and timings
  /// on the native llama.cpp backend and on WebGPU with bridge assets
  /// `v0.1.54+`. It is null on other backends and whenever the backend reports
  /// none, as for a request cancelled before it reached the backend.
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    final zone = Zone.current;
    final operation = observers.isEmpty
        ? null
        : LlamaChatOperation(
            model: _observedModel,
            runtime: _observedRuntime,
            messages: messages,
            params: params ?? const GenerationParams(),
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
          );
    return _generationCancellation.request((request) {
      Stream<LlamaCompletionChunk> chunks() async* {
        _ensureReady();
        await _rejectUnsupportedVideoInput(
          messages.expand((message) => message.parts),
        );

        // Keep tools available to template routing even with toolChoice.none,
        // matching llama.cpp behavior.
        final effectiveTools = tools;
        final effectiveToolChoice = toolChoice ?? ToolChoice.auto;

        // Apply chat template with tools - returns grammar for constraining
        final result = await chatTemplate(
          messages,
          tools: effectiveTools,
          toolChoice: effectiveToolChoice,
          parallelToolCalls: parallelToolCalls,
          enableThinking: enableThinking,
          responseFormat: responseFormat,
          sourceLangCode: sourceLangCode,
          targetLangCode: targetLangCode,
          chatTemplateKwargs: chatTemplateKwargs,
          templateNow: templateNow,
          includeTokenCount: false,
        );
        final plan = ChatCompletionRequestPlanner.build(
          backend: backend,
          templateResult: result,
          messages: messages,
          params: params,
          tools: effectiveTools,
          toolChoice: effectiveToolChoice,
          parallelToolCalls: parallelToolCalls,
          responseFormat: responseFormat,
        );

        // Generate raw tokens with grammar constraint. Backends that can consume
        // structured chat natively may receive the original messages/tools, while
        // all other backends keep the rendered prompt path.
        BackendGenerationLimit? generationLimit;
        void recordLimit(BackendGenerationLimit limit) =>
            generationLimit = limit;
        LlamaGenerationUsage? generationUsage;
        void recordUsage(LlamaGenerationUsage usage) => generationUsage = usage;

        final tokenStream = plan.usesNativeChatGeneration
            ? _generateNativeChat(
                plan.nativeChatBackend!,
                messages,
                params: plan.generationParams,
                tools: effectiveTools,
                toolChoice: effectiveToolChoice,
                parallelToolCalls: parallelToolCalls,
                enableThinking: enableThinking,
                chatTemplateKwargs: chatTemplateKwargs,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                templateNow: templateNow,
                onLimit: recordLimit,
                onUsage: recordUsage,
                request: request,
              )
            : _generate(
                result.prompt,
                params: plan.generationParams,
                parts: plan.mediaParts,
                onLimit: recordLimit,
                onUsage: recordUsage,
                request: request,
              );

        final completionId = DateTime.now().millisecondsSinceEpoch.toString();
        yield* ChatCompletionStreamParser.parse(
          tokenStream: tokenStream,
          templateResult: plan.templateResult,
          parseToolCallsEnabled: plan.parseToolCallsEnabled,
          enableThinking: enableThinking,
          modelName: _completionModel ?? 'llama_model',
          completionId: completionId,
          tools: effectiveTools,
          stoppedAtLimit: () => generationLimit != null,
          usage: () => generationUsage,
        ).map((chunk) {
          final limit = generationLimit;
          if (limit != null &&
              chunk.choices.isNotEmpty &&
              chunk.choices.first.finishReason == 'length') {
            _completionGenerationLimits[chunk] = limit;
          }
          return chunk;
        });
      }

      if (operation == null) return chunks();
      String? finishReason;
      LlamaGenerationUsage? usage;
      LlamaOperationResult? finalResult;
      return observeStream(
        chunks(),
        observers: observers,
        zone: zone,
        operation: operation,
        onItem: (observation, chunk) {
          observation.chunk(chunk);
          finishReason =
              chunk.choices.firstOrNull?.finishReason ?? finishReason;
          usage = chunk.usage ?? usage;
          if (finishReason != null) {
            finalResult = _generationResult(request, finishReason, usage);
          }
        },
        result: () => _generationResult(request, finishReason, usage),
        cancelResult: () =>
            finalResult ?? LlamaOperationResult(cancelled: true, usage: usage),
      );
    });
  }

  /// Generates strict structured JSON and decodes the final output.
  ///
  /// This helper applies `output.responseFormat` to [create], collects streamed
  /// content deltas, validates the completed JSON value, and returns the typed
  /// value produced by [output]'s decoder. Use [create] directly when you need
  /// to render tokens live; the returned stream can still be finalized with
  /// `await stream.parseStructuredJson(output)`.
  Future<T> createStructuredJson<T>(
    List<LlamaChatMessage> messages, {
    required LlamaStructuredOutput<T> output,
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    return create(
      messages,
      params: params,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      responseFormat: output.responseFormat,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      chatTemplateKwargs: chatTemplateKwargs,
      templateNow: templateNow,
    ).parseStructuredJson(output);
  }

  /// Formats a list of [messages] into a prompt string using the model's template.
  ///
  /// This is useful for preparing messages before calling [generate] directly,
  /// or for inspecting the formatted prompt for debugging purposes.
  ///
  /// The template is the model's own unless the model was loaded with a
  /// non-empty [ModelParams.chatTemplate]; [create] renders with the same
  /// template. Pass [customTemplate] to override both for this call.
  /// Pass [responseFormat] to request structured output grammar generation.
  /// It takes the same shapes as [create] and throws
  /// [LlamaUnsupportedException] for any other.
  /// Use [LlamaStructuredOutput.responseFormat] to avoid hand-writing these
  /// maps in application code.
  ///
  /// [jsonSchema] is a legacy shortcut for
  /// `responseFormat: {'type': 'json_schema', 'json_schema': {'schema': ...}}`.
  /// If both [responseFormat] and [jsonSchema] are provided, [responseFormat]
  /// wins.
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
    @Deprecated(
      'Use responseFormat: {"type": "json_schema", '
      '"json_schema": {"schema": ...}} instead.',
    )
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
    return ChatTemplateRenderer.render(
      loadMetadata: _getCachedMetadata,
      tokenize: tokenize,
      messages: messages,
      addAssistant: addAssistant,
      jsonSchema: jsonSchema,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      responseFormat: responseFormat,
      customTemplate: customTemplate,
      modelTemplate: _modelChatTemplate,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      includeTokenCount: includeTokenCount,
      chatTemplateKwargs: chatTemplateKwargs,
      templateNow: templateNow,
    );
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
  }) {
    final zone = Zone.current;
    final operation = observers.isEmpty
        ? null
        : LlamaTextCompletionOperation(
            model: _observedModel,
            runtime: _observedRuntime,
            prompt: prompt,
            params: params,
            parts: parts,
          );
    return _generationCancellation.request((request) {
      if (operation == null) {
        return _generate(
          prompt,
          params: params,
          parts: parts,
          request: request,
        );
      }
      BackendGenerationLimit? limit;
      LlamaGenerationUsage? usage;
      return observeStream(
        _generate(
          prompt,
          params: params,
          parts: parts,
          onLimit: (reported) => limit = reported,
          onUsage: (reported) => usage = reported,
          request: request,
        ),
        observers: observers,
        zone: zone,
        operation: operation,
        onItem: (observation, text) => observation.text(text),
        result: () => _generationResult(
          request,
          limit == null ? 'stop' : 'length',
          usage,
        ),
        cancelResult: () => const LlamaOperationResult(cancelled: true),
      );
    });
  }

  LlamaOperationResult _generationResult(
    GenerationRequest request,
    String? finishReason,
    LlamaGenerationUsage? usage,
  ) => request.isCancelled()
      ? LlamaOperationResult(cancelled: true, usage: usage)
      : LlamaOperationResult(finishReason: finishReason, usage: usage);

  Stream<String> _generate(
    String prompt, {
    GenerationParams params = const GenerationParams(),
    List<LlamaContentPart>? parts,
    void Function(BackendGenerationLimit limit)? onLimit,
    void Function(LlamaGenerationUsage usage)? onUsage,
    required GenerationRequest request,
  }) async* {
    _ensureReady();
    await _rejectUnsupportedVideoInput(parts ?? const <LlamaContentPart>[]);
    if (request.isCancelled()) return;
    final resolvedParams = await _resolveDraftModel(params, request);
    if (resolvedParams == null) return;
    _ensureReady();

    try {
      final stream = backend.generate(
        _contextHandle!,
        prompt,
        resolvedParams,
        parts: parts,
      );

      await for (final token in _cancellableText(
        stream,
        request,
        'Generation',
      )) {
        yield token;
      }
      _reportGenerationOutcome(stream, onLimit, onUsage);
    } catch (error, stackTrace) {
      // Wrap raw backend failures so callers catching LlamaException (the
      // documented error contract) don't see unexpected error types escape,
      // while preserving the original backend stack trace.
      Error.throwWithStackTrace(
        _generationFailure('Generation', error),
        stackTrace,
      );
    }
  }

  Stream<String> _generateNativeChat(
    BackendNativeChatGeneration nativeBackend,
    List<LlamaChatMessage> messages, {
    required GenerationParams params,
    List<ToolDefinition>? tools,
    required ToolChoice toolChoice,
    required bool parallelToolCalls,
    required bool enableThinking,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
    void Function(BackendGenerationLimit limit)? onLimit,
    void Function(LlamaGenerationUsage usage)? onUsage,
    required GenerationRequest request,
  }) async* {
    _ensureReady();
    if (request.isCancelled()) return;
    final resolvedParams = await _resolveDraftModel(params, request);
    if (resolvedParams == null) return;
    _ensureReady();

    try {
      final stream = nativeBackend.generateChat(
        _contextHandle!,
        messages,
        resolvedParams,
        tools: tools,
        toolChoice: toolChoice,
        parallelToolCalls: parallelToolCalls,
        enableThinking: enableThinking,
        chatTemplateKwargs: chatTemplateKwargs,
        sourceLangCode: sourceLangCode,
        targetLangCode: targetLangCode,
        templateNow: templateNow,
      );

      await for (final token in _cancellableText(
        stream,
        request,
        'Native chat generation',
      )) {
        yield token;
      }
      _reportGenerationOutcome(stream, onLimit, onUsage);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _generationFailure('Native chat generation', error),
        stackTrace,
      );
    }
  }

  /// Returns the [LlamaException] a generation reports for a backend
  /// [error] raised during [operation].
  LlamaException _generationFailure(String operation, Object error) =>
      switch (error) {
        LlamaException() => error,
        UnsupportedError() => _unsupportedBackendOperation(operation, error),
        _ => LlamaInferenceException('$operation failed', error),
      };

  /// Decodes [tokens] into a stream that also ends, cancelling [tokens], as
  /// soon as the subscription of [request] or of an ancestor is cancelled.
  ///
  /// That subscription cancel fails with the [LlamaException] for
  /// [operation] if cancelling [tokens] fails.
  Stream<String> _cancellableText(
    Stream<List<int>> tokens,
    GenerationRequest request,
    String operation,
  ) {
    final text = StreamController<String>(sync: true);
    final subscription = tokens
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(text.add, onError: text.addError, onDone: text.close);
    // Hand out the cancel future of [tokens] once. The stop below returns it;
    // the cancel that closing [text] triggers would drop it, leaving a
    // backend error in it unhandled.
    Future<void>? tokensCancelled;
    Future<void>? cancelTokens() => tokensCancelled == null
        ? tokensCancelled = subscription.cancel()
        : null;
    text
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = cancelTokens;
    request.onSubscriptionCancel(() {
      final cancelled = cancelTokens();
      unawaited(text.close());
      return (cancelled ?? Future<void>.value()).catchError(
        (Object error, StackTrace stackTrace) => Error.throwWithStackTrace(
          _generationFailure(operation, error),
          stackTrace,
        ),
      );
    });
    return text.stream;
  }

  void _reportGenerationOutcome(
    Stream<List<int>> generation,
    void Function(BackendGenerationLimit limit)? onLimit,
    void Function(LlamaGenerationUsage usage)? onUsage,
  ) {
    final reporting = backend;
    if (onLimit != null && reporting is BackendGenerationLimitReporting) {
      final limit = (reporting as BackendGenerationLimitReporting)
          .generationLimitOf(generation);
      if (limit != null) {
        onLimit(limit);
      }
    }
    if (onUsage != null && reporting is BackendGenerationUsageReporting) {
      final usage = (reporting as BackendGenerationUsageReporting)
          .generationUsageOf(generation);
      if (usage != null) {
        onUsage(usage);
      }
    }
  }

  /// Cancels every generation whose [create] or [generate] stream has been
  /// listened to.
  ///
  /// A stream that has not reached the backend yet ends without generating.
  /// A stream listened to after this call is not affected.
  void cancelGeneration() {
    _generationCancellation.cancel();
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

  /// Whether the active backend reports [embed] and [embedBatch] support.
  ///
  /// Native llama.cpp and WebGPU backends report true; LiteRT-LM backends
  /// report false, and calls throw [LlamaUnsupportedException]. Routing
  /// backends such as [LlamaBackend] pick their runtime when a model loads,
  /// so check this after loading. A true value is not a model check: a
  /// rank-pooled or encoder-decoder model, or WebGPU bridge assets older than
  /// `v0.1.7`, still throw [LlamaUnsupportedException].
  bool get supportsEmbeddings {
    final candidate = backend;
    if (candidate is BackendEmbeddingsSupport) {
      return (candidate as BackendEmbeddingsSupport).supportsEmbeddings;
    }
    return candidate is BackendEmbeddings;
  }

  /// Generates a single embedding vector for [text].
  ///
  /// When [normalize] is true, the returned vector is L2-normalized.
  ///
  /// Throws [LlamaUnsupportedException] when [supportsEmbeddings] is false
  /// or the loaded model cannot embed, and [LlamaInferenceException] when
  /// native llama.cpp input exceeds the context or a single embedding pass.
  Future<List<double>> embed(String text, {bool normalize = true}) =>
      _observeEmbeddings(
        <String>[text],
        normalize,
        () => _embed(text, normalize: normalize),
      );

  Future<List<double>> _embed(String text, {required bool normalize}) async {
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
  /// When [normalize] is true, each returned vector is L2-normalized. Throws
  /// the same exceptions as [embed].
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool normalize = true,
  }) => _observeEmbeddings(
    texts,
    normalize,
    () => _embedBatch(texts, normalize: normalize),
  );

  Future<T> _observeEmbeddings<T>(
    List<String> inputs,
    bool normalize,
    Future<T> Function() embed,
  ) {
    if (observers.isEmpty) return embed();
    return observeFuture(
      embed,
      observers: observers,
      operation: LlamaEmbeddingsOperation(
        model: _observedModel,
        runtime: _observedRuntime,
        inputs: inputs,
        normalize: normalize,
      ),
    );
  }

  Future<List<List<double>>> _embedBatch(
    List<String> texts, {
    required bool normalize,
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
    if (!supportsEmbeddings) {
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
  // NEXT-TOKEN SCORING
  // ============================================================

  /// Whether the active backend reports [scoreNextToken] support.
  ///
  /// Native llama.cpp backends support it, as do WebGPU bridge assets
  /// `v0.1.52+`. LiteRT-LM backends and older bridge assets report false,
  /// and calls throw [LlamaUnsupportedException].
  bool get supportsNextTokenScoring {
    final candidate = backend;
    if (candidate is BackendNextTokenScoringSupport) {
      return (candidate as BackendNextTokenScoringSupport)
          .supportsNextTokenScoring;
    }
    return candidate is BackendNextTokenScoring;
  }

  /// Evaluates [prompt] and returns the log-probabilities of the token that
  /// would follow it.
  ///
  /// The result holds one entry per id in [candidates], in the same order,
  /// and the [topK] most probable tokens. Values are a softmax over the raw
  /// logits; sampling settings do not apply. Reading the probabilities of
  /// answer-letter tokens after a multiple-choice prompt turns an LLM into a
  /// classifier.
  ///
  /// [prompt] is tokenized like a [generate] prompt: special-token text is
  /// parsed and the model's BOS token is added unless the prompt starts with
  /// it. Apply the chat template first for an instruction-tuned model. When
  /// [reusePromptPrefix] is true, a prefix shared with the previous prompt on
  /// this context is not evaluated again.
  ///
  /// A call made while a generation runs waits for it to finish.
  ///
  /// Throws [ArgumentError] for an empty [prompt], a negative token id or
  /// [topK], or when both [candidates] and [topK] ask for nothing;
  /// [RangeError] for a token id or [topK] beyond the vocabulary; and
  /// [LlamaUnsupportedException] when [supportsNextTokenScoring] is false.
  Future<LlamaNextTokenScores> scoreNextToken(
    String prompt, {
    List<int> candidates = const [],
    int topK = 0,
    bool reusePromptPrefix = GenerationParams.defaultReusePromptPrefix,
  }) async {
    _ensureReady();
    if (prompt.isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'must not be empty');
    }
    for (final token in candidates) {
      if (token < 0) {
        throw ArgumentError.value(token, 'candidates', 'must not be negative');
      }
    }
    if (topK < 0) {
      throw ArgumentError.value(topK, 'topK', 'must not be negative');
    }
    if (candidates.isEmpty && topK == 0) {
      throw ArgumentError('Pass candidates, a positive topK, or both.');
    }
    final candidate = backend;
    if (!supportsNextTokenScoring) {
      throw LlamaUnsupportedException(
        'Next-token scoring is not supported by the active backend.',
      );
    }
    try {
      return await (candidate as BackendNextTokenScoring).scoreNextToken(
        _contextHandle!,
        prompt,
        candidates: List<int>.of(candidates),
        topK: topK,
        reusePromptPrefix: reusePromptPrefix,
      );
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('Next-token scoring', error);
    }
  }

  // ============================================================
  // STATE PERSISTENCE
  // ============================================================

  /// Whether the active backend reports state save/load support.
  ///
  /// Supported native llama.cpp backends persist to disk. WebGPU backends report
  /// support only after the active JavaScript bridge exposes the `stateSaveFile`
  /// and `stateLoadFile` APIs introduced in bridge assets `v0.1.15`; older or
  /// custom bridge assets report false and calls throw
  /// [LlamaUnsupportedException] before reaching the bridge.
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

  /// Whether a multimodal projector is loaded.
  bool get hasMultimodalProjector => _mmContextHandle != null;

  /// Whether the loaded model supports vision.
  Future<bool> get supportsVision async =>
      _mmContextHandle != null &&
      await backend.supportsVision(_mmContextHandle!);

  /// Whether the loaded model supports audio.
  ///
  /// On the native llama.cpp backend, throws [LlamaUnsupportedException] only
  /// when the runtime cannot run an mtmd function this package calls.
  Future<bool> get supportsAudio async =>
      _mmContextHandle != null &&
      await backend.supportsAudio(_mmContextHandle!);

  /// Whether video input is consumable through the public Dart generation API.
  ///
  /// This remains false even if a custom native library was compiled with mtmd
  /// video helpers: Dart does not yet own frame iteration, timestamp insertion,
  /// cancellation, or lazy video-context cleanup. Use image frames explicitly
  /// until that full contract is implemented.
  Future<bool> get supportsVideo async => false;

  Future<void> _rejectUnsupportedVideoInput(
    Iterable<LlamaContentPart> parts,
  ) async {
    if (!parts.any((part) => part is LlamaVideoContent)) {
      return;
    }

    bool? nativeRuntimeSupportsVideo;
    final mmContextHandle = _mmContextHandle;
    if (mmContextHandle == null) {
      throw LlamaUnsupportedException(
        'Video input is not consumable through llamadart. Without an active '
        'multimodal context, or on a backend that does not expose one, native '
        'video capability cannot be inspected. Loading a compatible projector '
        'on a supported native backend only enables that inspection; it does '
        'not enable public video ingestion. Extract and send image frames '
        'instead.',
      );
    }

    final candidate = backend;
    if (candidate is BackendVideoRuntimeSupport) {
      try {
        nativeRuntimeSupportsVideo =
            await (candidate as BackendVideoRuntimeSupport)
                .supportsVideoRuntime(mmContextHandle);
      } catch (_) {
        // A failed optional capability probe is an unsupported result. The
        // generation request below still receives the typed public error.
      }
    }

    if (nativeRuntimeSupportsVideo == null) {
      throw LlamaUnsupportedException(
        'Video input is not supported by the active backend. It does not '
        'expose a consumable video transport or runtime capability probe. '
        'Extract and send image frames instead.',
      );
    }

    if (!nativeRuntimeSupportsVideo) {
      throw LlamaUnsupportedException(
        'Video input is not supported by the active backend/runtime. Current '
        'llamadart native artifacts compile mtmd video support out; enabling '
        'it requires LLAMA_SUBPROCESS plus FFmpeg/ffprobe packaging. Extract '
        'and send image frames instead until companion-native packaging and '
        'the Dart video-ingestion contract are implemented.',
      );
    }

    throw LlamaUnsupportedException(
      'The loaded native runtime reports mtmd video support, but video is not '
      'yet consumable through llamadart. Dart frame iteration, timestamps, '
      'cancellation, and video-context cleanup must be wired before path or '
      'byte input can be accepted. Extract and send image frames instead.',
    );
  }

  /// Returns backend-native text-to-speech capabilities for the loaded model.
  ///
  /// This is the low-level integration hook used by `TextToSpeechEngine`.
  /// Applications should prefer that typed API instead of calling this method
  /// directly.
  Future<BackendTextToSpeechCapabilities>
  get backendTextToSpeechCapabilities async {
    if (!_isReady || _contextHandle == null || _mmContextHandle == null) {
      return const BackendTextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason:
            'Load a model and its text-to-speech projector first.',
      );
    }
    final candidate = backend;
    if (candidate is! BackendTextToSpeech) {
      return const BackendTextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason:
            'The active backend does not expose dedicated text-to-speech.',
      );
    }
    final textToSpeechBackend = candidate as BackendTextToSpeech;
    return textToSpeechBackend.textToSpeechCapabilities(
      _contextHandle!,
      _mmContextHandle!,
    );
  }

  /// Runs backend-native text-to-speech for `TextToSpeechEngine`.
  ///
  /// Applications should prefer `TextToSpeechEngine.synthesize`, which adds
  /// validation, task ownership, cancellation, and typed completion handling.
  Future<BackendTextToSpeechResult> synthesizeTextToSpeechBackend(
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) {
    _ensureReady();
    final mmContextHandle = _mmContextHandle;
    if (mmContextHandle == null) {
      throw LlamaStateException(
        'Load a text-to-speech multimodal projector first.',
      );
    }
    final candidate = backend;
    if (candidate is! BackendTextToSpeech) {
      throw LlamaUnsupportedException(
        'The active backend does not expose dedicated text-to-speech.',
      );
    }
    final textToSpeechBackend = candidate as BackendTextToSpeech;
    return textToSpeechBackend.synthesizeTextToSpeech(
      _contextHandle!,
      mmContextHandle,
      request,
      onProgress: onProgress,
    );
  }

  /// Cancels backend-native synthesis started by `TextToSpeechEngine`.
  void cancelTextToSpeechBackend() {
    final candidate = backend;
    if (candidate is BackendTextToSpeech) {
      (candidate as BackendTextToSpeech).cancelTextToSpeech();
    }
  }

  /// Returns the optional [GenerationParams] controls that the loaded model's
  /// runtime applies.
  ///
  /// Native llama.cpp applies all of them. LiteRT-LM applies none but
  /// speculative decoding, which native LiteRT-LM runs for
  /// [SpeculativeDecodingStrategy.backendDefault] and
  /// [SpeculativeDecodingStrategy.mtp] on a bundle with a speculative
  /// drafter. WebGPU applies those its bridge assets
  /// report. Each of these runtimes rejects a non-default value of a control
  /// it does not apply with [LlamaUnsupportedException]. Every control is
  /// `false`, and no speculative strategy is reported, before a model loads
  /// and on a backend that does not implement
  /// [BackendGenerationCapabilitiesSupport].
  ///
  /// Since `capabilities` was added, native LiteRT-LM reports
  /// [BackendGenerationCapabilities.streamBatching] as true and no
  /// speculative strategy for a bundle that declares no speculative drafter.
  @Deprecated('Use capabilities, which reports these controls and the rest.')
  Future<BackendGenerationCapabilities> get backendGenerationCapabilities =>
      _generationCapabilities();

  Future<BackendGenerationCapabilities> _generationCapabilities() async {
    final candidate = backend;
    if (!_isReady ||
        _modelHandle == null ||
        candidate is! BackendGenerationCapabilitiesSupport) {
      return const BackendGenerationCapabilities(
        presencePenalty: false,
        minP: false,
        thinkingBudget: false,
      );
    }
    return (candidate as BackendGenerationCapabilitiesSupport)
        .generationCapabilities();
  }

  /// Returns decision-model support for the loaded model.
  ///
  /// This is the low-level integration hook used by `DecisionEngine`.
  /// Applications should prefer `DecisionEngine.capabilitiesFor`.
  Future<BackendDecisionCapabilities> get backendDecisionCapabilities async {
    final candidate = backend;
    if (candidate is! BackendDecision) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason:
            'The active backend does not expose decision models.',
      );
    }
    final modelHandle = _modelHandle;
    if (!_isReady || modelHandle == null) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason: 'Load a model first.',
      );
    }
    return (candidate as BackendDecision).decisionCapabilities(modelHandle);
  }

  /// Loads the decision head at [headPath] for the loaded model.
  ///
  /// This is the low-level integration hook used by `DecisionEngine`.
  /// [configPath] names a JSON config for head files without `laya.config`
  /// metadata. The returned [BackendDecisionHeadInfo.handle] is an engine
  /// handle that this engine never reuses, not the backend's own handle; pass
  /// it to [runDecisionBackend] and [freeDecisionHeadBackend]. The head stays
  /// usable until it is freed or the model is unloaded; on Web, a bridge that
  /// restarts its runtime frees it too.
  Future<BackendDecisionHeadInfo> loadDecisionHeadBackend(
    String headPath, {
    String? configPath,
  }) async {
    final decisionBackend = _decisionBackend();
    _ensureReady(requireContext: false);
    final epoch = _decisionHeadEpoch;
    final head = await decisionBackend.decisionHeadLoad(
      _modelHandle!,
      headPath,
      configPath: configPath,
    );
    if (epoch != _decisionHeadEpoch) {
      await decisionBackend
          .decisionHeadFree(head.handle)
          .catchError((Object _) {});
      throw LlamaStateException(
        'The model was unloaded while its decision head was loading. Load '
        'the model and the DecisionEngine again.',
      );
    }
    final handle = _nextDecisionHeadHandle++;
    _decisionHeadHandles[handle] = head.handle;
    return BackendDecisionHeadInfo(
      handle: handle,
      hiddenSize: head.hiddenSize,
      clsToken: head.clsToken,
      sepToken: head.sepToken,
      maskToken: head.maskToken,
      maskText: head.maskText,
      configJson: head.configJson,
      deviceName: head.deviceName,
    );
  }

  /// Runs [sequences] through the decision head [headHandle].
  ///
  /// This is the low-level integration hook used by `DecisionEngine`, which
  /// builds the sequences and decodes the outputs. [headHandle] is a handle
  /// returned by [loadDecisionHeadBackend]. Throws [LlamaStateException] when
  /// it is not loaded on this engine, such as after it was freed or its model
  /// was unloaded, and on Web when a bridge runtime restart freed it.
  Future<List<BackendDecisionOutput>> runDecisionBackend(
    int headHandle,
    List<BackendDecisionSequence> sequences,
  ) async {
    final backendHandle = _decisionHeadHandles[headHandle];
    if (backendHandle == null) {
      throw LlamaStateException(
        'Decision head $headHandle is not loaded on this engine; it was '
        'freed, its model was unloaded, or it was never loaded. Load the '
        'DecisionEngine again.',
      );
    }
    return _decisionBackend().decisionRun(backendHandle, sequences);
  }

  /// Frees the decision head [headHandle].
  ///
  /// This is the low-level integration hook used by `DecisionEngine`.
  /// [headHandle] is a handle returned by [loadDecisionHeadBackend]. Does
  /// nothing when it is not loaded on this engine, such as after it was freed
  /// or its model was unloaded.
  Future<void> freeDecisionHeadBackend(int headHandle) async {
    final backendHandle = _decisionHeadHandles.remove(headHandle);
    if (backendHandle == null) return;
    await _decisionBackend().decisionHeadFree(backendHandle);
  }

  BackendDecision _decisionBackend() {
    final candidate = backend;
    if (candidate is! BackendDecision) {
      throw LlamaUnsupportedException(
        'The active backend does not expose decision models.',
      );
    }
    return candidate as BackendDecision;
  }

  // ============================================================
  // LORA MANAGEMENT
  // ============================================================

  /// Dynamically loads or updates a LoRA adapter's scale.
  ///
  /// [path] is a local file, or a URL on WebGPU, that the backend loads as
  /// written.
  @Deprecated(
    'Use setLoraSource with ModelSource.path(path), or another ModelSource '
    'to download the adapter. This method will be removed in a future '
    'release.',
  )
  Future<void> setLora(String path, {double scale = 1.0}) async {
    _ensureReady();
    try {
      await backend.setLoraAdapter(_contextHandle!, path, scale);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  /// Applies the LoRA adapter at [source] with [scale], or changes the scale
  /// of an adapter already applied from [source].
  ///
  /// [source] resolves as in [loadModelSource]: [modelResolver] resolves it,
  /// and on file-backed backends [modelDownloadManager] checks a local file,
  /// or downloads a remote one with [download] into the model cache,
  /// resuming an interrupted download and reusing a cached file, reporting
  /// to [onProgress]. [download]'s cancel token stops the download. On
  /// URL-loading backends (WebGPU) a remote source goes to the runtime as a
  /// URL, and options that need the package-managed download manager throw
  /// [LlamaUnsupportedException], as for [loadMultimodalProjectorSource].
  ///
  /// Remove the adapter with [removeLoraSource] and the same [source].
  ///
  /// Throws [LlamaContextException] when no model is loaded,
  /// [LlamaUnsupportedException] when the backend has no runtime LoRA API or
  /// cannot load [source] as described above, [LlamaStateException] when
  /// [download]'s cancel token cancels the download, and what the download
  /// manager throws for a missing file or a failed download.
  Future<void> setLoraSource(
    ModelSource source, {
    double scale = 1.0,
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    _ensureReady();
    final location = await _resolveAuxiliarySource(
      source,
      options: download,
      onProgress: onProgress,
      assetType: 'LoRA adapter',
    );
    if (download.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('LoRA adapter loading was cancelled.');
    }
    _ensureReady();
    try {
      await backend.setLoraAdapter(_contextHandle!, location, scale);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
    _loraLocations[source.canonicalKey] = location;
  }

  /// Removes a specific LoRA adapter from the active session.
  @Deprecated(
    'Use removeLoraSource with the ModelSource the adapter was set from. '
    'This method will be removed in a future release.',
  )
  Future<void> removeLora(String path) async {
    _ensureReady();
    try {
      await backend.removeLoraAdapter(_contextHandle!, path);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  /// Removes the LoRA adapter applied from [source], by [setLoraSource] or
  /// [ModelParams.loras]. Does nothing when no adapter from [source] is
  /// applied.
  Future<void> removeLoraSource(ModelSource source) async {
    _ensureReady();
    final location = _loraLocations[source.canonicalKey] ?? source.path;
    if (location == null) return;
    try {
      await backend.removeLoraAdapter(_contextHandle!, location);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
    _loraLocations.remove(source.canonicalKey);
  }

  /// [params] with every [LoraAdapterConfig.source] of [ModelParams.loras]
  /// resolved as [setLoraSource] resolves it, with [options] for a remote
  /// source and only their cancel token for a local one.
  Future<ModelParams> _resolveLoraSources(
    ModelParams params,
    ModelLoadOptions options,
  ) async {
    if (params.loras.every((lora) => lora.source == null)) return params;
    final localOptions = ModelLoadOptions(cancelToken: options.cancelToken);
    final resolved = <LoraAdapterConfig>[];
    for (final lora in params.loras) {
      final source = lora.source;
      if (source == null) {
        resolved.add(lora);
        continue;
      }
      final location = await _resolveAuxiliarySource(
        source,
        options: source.isLocal ? localOptions : options,
        assetType: 'LoRA adapter',
      );
      _loraLocations[source.canonicalKey] = location;
      // A path config is what backends load and is not resolved again.
      resolved.add(LoraAdapterConfig(path: location, scale: lora.scale));
    }
    return params.copyWith(loras: resolved);
  }

  /// [params] with its [SpeculativeDecodingConfig.draftModel] resolved as
  /// [setLoraSource] resolves a source, or null when [request] is cancelled
  /// meanwhile.
  Future<GenerationParams?> _resolveDraftModel(
    GenerationParams params,
    GenerationRequest request,
  ) async {
    final config = params.speculativeDecodingConfig;
    final source = config?.draftModel;
    if (config == null || source == null) return params;
    var download = config.draftModelDownload;
    if (!backend.supportsUrlLoading) {
      download = _withCancelToken(
        download,
        _RequestCancelToken(request, download.cancelToken),
      );
    }
    final String location;
    try {
      location = await _resolveAuxiliarySource(
        source,
        options: download,
        assetType: 'speculative draft model',
      );
    } on Object {
      if (request.isCancelled()) return null;
      rethrow;
    }
    if (request.isCancelled()) return null;
    return params.copyWith(
      speculativeDecodingConfig: SpeculativeDecodingConfig(
        strategy: config.strategy,
        strategies: config.strategies,
        draftTokenMax: config.draftTokenMax,
        draftTokenMin: config.draftTokenMin,
        minProbability: config.minProbability,
        draftSplitProbability: config.draftSplitProbability,
        draftModelPath: location,
        ngramSize: config.ngramSize,
        ngramSizeN: config.ngramSizeN,
        ngramSizeM: config.ngramSizeM,
        ngramMinHits: config.ngramMinHits,
        ngramMatch: config.ngramMatch,
        ngramTokenMin: config.ngramTokenMin,
        ngramTokenMax: config.ngramTokenMax,
        ngramCacheStaticPath: config.ngramCacheStaticPath,
        ngramCacheDynamicPath: config.ngramCacheDynamicPath,
      ),
    );
  }

  /// Removes all active LoRA adapters from the current context.
  Future<void> clearLoras() async {
    _ensureReady();
    try {
      await backend.clearLoraAdapters(_contextHandle!);
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
    _loraLocations.clear();
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

  String _modelLoadedMessage(String modelName, String source) {
    final candidate = backend;
    if (candidate is BackendDeferredEngineCreation &&
        (candidate as BackendDeferredEngineCreation).defersEngineCreation) {
      return 'Model $modelName loaded from $source; native engine creation is '
          'deferred until the first generation or tokenizer call';
    }
    return 'Model $modelName loaded successfully from $source';
  }

  /// Returns resolved GPU layers for the active model load when available.
  Future<int?> getResolvedGpuLayers() {
    final candidate = backend;
    if (candidate is BackendRuntimeDiagnostics) {
      return (candidate as BackendRuntimeDiagnostics).getResolvedGpuLayers();
    }
    return Future<int?>.value(null);
  }

  /// Returns model file type or quantization metadata when available.
  ///
  /// llama.cpp/GGUF backends expose this via the native `llama_model_ftype` and
  /// `llama_ftype_name` APIs. Backends that do not expose equivalent metadata,
  /// such as LiteRT-LM or older web bridge assets, return null.
  Future<ModelFileType?> getModelFileType() {
    final modelHandle = _modelHandle;
    if (!_isReady || modelHandle == null) {
      return Future<ModelFileType?>.value(null);
    }

    final candidate = backend;
    if (candidate is BackendModelFileTypeDiagnostics) {
      return (candidate as BackendModelFileTypeDiagnostics).getModelFileType(
        modelHandle,
      );
    }
    return Future<ModelFileType?>.value(null);
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

  /// Lists GPU-class devices when the active backend supports enumeration,
  /// otherwise an empty list. With an empty [probeBackends] only
  /// already-registered backends are inspected (no backend module is loaded);
  /// pass backends to opt into loading just those before enumerating.
  Future<List<GpuDeviceInfo>> listGpuDevices({
    List<GpuBackend> probeBackends = const [],
  }) {
    final candidate = backend;
    if (candidate is BackendGpuEnumeration) {
      return (candidate as BackendGpuEnumeration).listGpuDevices(
        probeBackends: probeBackends,
      );
    }
    return Future.value(const []);
  }

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

  Future<void> _withModelLifecycle(
    String operation,
    Future<void> Function() action,
  ) async {
    if (_modelLifecycleOperation != null) {
      throw LlamaStateException(
        'Cannot $operation while another model lifecycle operation is in progress.',
      );
    }
    final lifecycleOperation = action();
    _modelLifecycleOperation = lifecycleOperation;
    try {
      await lifecycleOperation;
    } finally {
      if (identical(_modelLifecycleOperation, lifecycleOperation)) {
        _modelLifecycleOperation = null;
      }
    }
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
    _completionModel = null;
    _cachedModelMetadata = null;
    _modelChatTemplate = null;
    _isReady = false;
  }

  void _rejectUnsupportedUrlBackendOptions(
    ModelLoadOptions options, {
    String assetType = 'model',
  }) {
    final isModel = assetType == 'model';
    if (options.cachePolicy != ModelCachePolicy.preferCached) {
      throw LlamaUnsupportedException(
        '${options.cachePolicy.name} $assetType loading requires the native download/cache manager.',
      );
    }
    if (options.bearerToken != null || options.headers.isNotEmpty) {
      throw LlamaUnsupportedException(
        'Authenticated $assetType URL loading requires the native download/cache manager.',
      );
    }
    if (options.cancelToken != null) {
      throw LlamaUnsupportedException(
        isModel
            ? 'Cancellation tokens require the native download/cache manager.'
            : 'Cancellation tokens for $assetType loading require the native download/cache manager.',
      );
    }
    if (options.sha256 != null) {
      throw LlamaUnsupportedException(
        isModel
            ? 'Checksum verification requires the native download/cache manager.'
            : 'Checksum verification for $assetType loading requires the native download/cache manager.',
      );
    }
    if (options.cacheDirectory != null) {
      throw LlamaUnsupportedException(
        isModel
            ? 'cacheDirectory is not supported by URL-loading backends.'
            : 'cacheDirectory is not supported for $assetType loading by URL-loading backends.',
      );
    }
    if (!options.resume) {
      throw LlamaUnsupportedException(
        isModel
            ? 'Disabling resume is not supported by URL-loading backends.'
            : 'Disabling resume is not supported for $assetType loading by URL-loading backends.',
      );
    }
    if (options.maxRetries != ModelLoadOptions.defaults.maxRetries) {
      throw LlamaUnsupportedException(
        isModel
            ? 'Custom maxRetries is not supported by URL-loading backends.'
            : 'Custom maxRetries is not supported for $assetType loading by URL-loading backends.',
      );
    }
  }

  static ModelLoadOptions _withoutSha256(ModelLoadOptions options) =>
      options.sha256 == null
      ? options
      : ModelLoadOptions(
          cachePolicy: options.cachePolicy,
          cacheDirectory: options.cacheDirectory,
          bearerToken: options.bearerToken,
          headers: options.headers,
          cancelToken: options.cancelToken,
          resume: options.resume,
          maxRetries: options.maxRetries,
        );

  static ModelLoadOptions _withCancelToken(
    ModelLoadOptions options,
    ModelDownloadCancelToken cancelToken,
  ) => ModelLoadOptions(
    cachePolicy: options.cachePolicy,
    cacheDirectory: options.cacheDirectory,
    sha256: options.sha256,
    bearerToken: options.bearerToken,
    headers: options.headers,
    cancelToken: cancelToken,
    resume: options.resume,
    maxRetries: options.maxRetries,
  );

  void _throwIfSourceLoadCancelled(ModelLoadOptions options) {
    if (options.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('Model source loading was cancelled.');
    }
  }

  /// The model name of [source], or else the last segment of [source] with
  /// its URL secrets redacted, or `llama_model` when that segment still
  /// repeats a userinfo credential.
  String _displayNameForSource(String source) {
    final (:name, :credentials) = _sourceName(source);
    if (name != null) return name;
    final redacted = _redactedSource(source);
    final lastSegment = redacted.replaceAll('\\', '/').split('/').last;
    final display = lastSegment.isNotEmpty ? lastSegment : redacted;
    return _repeatsCredential(display, credentials) ? 'llama_model' : display;
  }

  static String _redactedSource(String source) =>
      redactUrlSecrets(source, sourceUrls: <String>[source]);

  // Dart error prefixes repeat when a worker isolate re-wraps an error's
  // `toString` text, e.g. `Exception: LlamaException: ...`.
  static final RegExp _errorTypePrefix = RegExp(
    r'^(?:LlamaException|Exception|Bad state|Unsupported operation|'
    r'Invalid argument\(s\)): ',
  );

  static String _redactedErrorDetails(Object error, String source) {
    var cause = switch (error) {
      LlamaException(:final message, details: null) => message,
      LlamaException(:final message, :final details) => '$message ($details)',
      _ => error.toString(),
    };
    while (_errorTypePrefix.hasMatch(cause)) {
      cause = cause.replaceFirst(_errorTypePrefix, '');
    }
    return redactUrlSecrets(cause, sourceUrls: <String>[source]);
  }

  /// Validates engine is ready for inference.
  void _ensureReady({bool requireContext = true}) {
    if (!_isReady) {
      throw LlamaContextException(
        'Engine not ready: no model is loaded. Call loadModelSource() first.',
      );
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

final Expando<BackendGenerationLimit> _completionGenerationLimits =
    Expando<BackendGenerationLimit>();

/// The token limit behind [chunk]'s `length` finish reason, when the backend
/// reported one to [LlamaEngine.create].
BackendGenerationLimit? completionGenerationLimit(LlamaCompletionChunk chunk) =>
    _completionGenerationLimits[chunk];

/// How many unloads [engine] has started, counting each attempt.
///
/// [LlamaEngine.unloadModel] adds one as it starts, unless nothing is loaded,
/// so a failed unload that is retried adds two. A model loaded after a read
/// taken while another model was loaded sees a greater value, even under the
/// same backend handle.
int modelUnloadEpoch(LlamaEngine engine) => engine._decisionHeadEpoch;

/// One-shot completions for [LlamaEngine].
extension LlamaEngineCompletionExtension on LlamaEngine {
  /// Generates a reply to [messages] and returns it once it is complete.
  ///
  /// This is [LlamaEngine.create] collected with `collect()`; every argument
  /// has the same meaning there. Append [LlamaCompletion.message] to
  /// [messages] to continue the conversation. Use [LlamaEngine.create] to
  /// stream the reply as it is generated.
  Future<LlamaCompletion> complete(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    return create(
      messages,
      params: params,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      responseFormat: responseFormat,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      chatTemplateKwargs: chatTemplateKwargs,
      templateNow: templateNow,
    ).collect();
  }
}

/// Cancelled when [_request] is cancelled, or by its own or [_caller]'s
/// [cancel], so a generation that is cancelled stops its draft model
/// download without cancelling the caller's token.
class _RequestCancelToken extends ModelDownloadCancelToken {
  final GenerationRequest _request;
  final ModelDownloadCancelToken? _caller;

  _RequestCancelToken(this._request, this._caller);

  @override
  bool get isCancelled =>
      super.isCancelled ||
      (_caller?.isCancelled ?? false) ||
      _request.isCancelled();
}
