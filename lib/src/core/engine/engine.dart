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
import '../models/config/compute_device.dart';
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
import '../models/model_file_store.dart';
import '../models/model_format.dart';
import '../models/model_load_options.dart';
import '../models/model_resolver.dart';
import '../models/model_source.dart';
import '../models/model_target_file.dart';
import '../models/download/model_download_manager.dart';
import '../models/tools/tool_definition.dart';
import '../speech/speech_engine_lease.dart';
import '../template/handlers/translate_gemma_handler.dart';
import '../url_redaction.dart';

/// Stateless chat completions engine (like OpenAI's Chat Completions API).
///
/// [LlamaEngine] is the primary API for chat-based inference. Each call to
/// [create] is stateless - you must pass the full conversation history.
/// For automatic history management, use [ChatSession] instead.
///
/// Example (OpenAI-style stateless usage):
/// ```dart
/// final engine = await LlamaEngine.load(
///   // or model.litertlm, or a download: ModelSource.parse('hf://...')
///   LlamaModel(ModelSource.path('path/to/model.gguf')),
/// );
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
  Future<void>? _disposal;
  // Fails every pending file resolution when disposal abandons its load.
  final Set<void Function()> _abandonResolutions = {};
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
  final Map<String, String> _draftLocations = <String, String>{};
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
  /// Before a model loads and after [dispose],
  /// [LlamaEngineCapabilities.isSupported] is false and every capability is
  /// false, as it is when a model loads or unloads while the snapshot is
  /// read; [LlamaEngineCapabilities.unsupportedReason] says which. Read it
  /// again after loading or unloading a model or multimodal projector.
  Future<LlamaEngineCapabilities> get capabilities async {
    const disposed = LlamaEngineCapabilities(
      isSupported: false,
      unsupportedReason: _disposedMessage,
    );
    const notLoaded = LlamaEngineCapabilities(
      isSupported: false,
      unsupportedReason:
          'No model is loaded. Call LlamaEngine.load or setModel first.',
    );
    if (isDisposed) return disposed;
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

    final BackendGenerationCapabilities generation;
    final ({bool vision, bool audio}) media;
    String? backendName;
    try {
      generation = await _generationCapabilities();
      media = await _mediaSupport();
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
      if (isDisposed) return disposed;
      if (_modelEpoch != epoch) return notLoaded;
      rethrow;
    }
    if (isDisposed) return disposed;
    // A load or unload while probing would mix two models' answers.
    if (_modelEpoch != epoch) return notLoaded;
    return LlamaEngineCapabilities(
      isSupported: true,
      backendName: backendName,
      runtime: runtime,
      supportsVision: media.vision,
      supportsAudio: media.audio,
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

  /// The media inputs the loaded model takes: direct media of the runtime,
  /// or what the loaded multimodal projector reports.
  Future<({bool vision, bool audio})> _mediaSupport() async {
    final candidate = backend;
    final mmContextHandle = _mmContextHandle;
    final direct = candidate is BackendDirectMediaInput
        ? await (candidate as BackendDirectMediaInput).directMediaInput()
        : (vision: false, audio: false);
    final vision =
        direct.vision ||
        mmContextHandle != null &&
            await _probeMedia(() => candidate.supportsVision(mmContextHandle));
    final audio =
        direct.audio ||
        mmContextHandle != null &&
            await _probeMedia(() => candidate.supportsAudio(mmContextHandle));
    return (vision: vision, audio: audio);
  }

  /// Whether a model is loaded and still the one loaded at [epoch].
  bool _isLoadedAt(int epoch) =>
      !isDisposed && _isReady && _modelHandle != null && _modelEpoch == epoch;

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

  /// Creates an engine and loads [model] into it.
  ///
  /// The returned engine owns [backend] (by default `LlamaBackend()`):
  /// [dispose] disposes it, and so does a load that fails. [store] is where
  /// the engine finds and keeps model files, by default a
  /// [DefaultModelResolver] and a [DefaultModelDownloadManager]; its parts
  /// become [modelResolver] and [modelDownloadManager]. [observers] are those
  /// of the [LlamaEngine] constructor. [setModel] does the load, so [params],
  /// [download] and [onProgress] mean what they mean there, and this throws
  /// what it throws.
  ///
  /// The load is atomic: when it throws, the engine and [backend] are
  /// disposed and nothing stays loaded. Downloaded files stay in the model
  /// cache.
  ///
  /// ```dart
  /// final engine = await LlamaEngine.load(
  ///   LlamaModel(ModelSource.parse('hf://owner/repo/model.gguf')),
  ///   params: const ModelParams(contextSize: 4096),
  ///   onProgress: (progress) => print(progress.fraction),
  /// );
  /// ```
  static Future<LlamaEngine> load(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
    ModelFileStore? store,
    LlamaBackend? backend,
    Iterable<LlamaEngineObserver> observers = const <LlamaEngineObserver>[],
  }) async {
    final (engine, _) = await loadLlamaEngine(
      model,
      params: params,
      download: download,
      onProgress: onProgress,
      store: store,
      backend: backend,
      observers: observers,
    );
    return engine;
  }

  /// Loads [model] with [params], replacing the model this engine holds.
  ///
  /// Before any download or file access, the call throws for what it can
  /// already tell: an invalid [params] ([ModelParams.validate]), a
  /// [LlamaModel.projector] or [ComputeDevice.npu] that the model's runtime
  /// does not take, when [ModelSource.format] or the file name gives the
  /// format, [ModelLoadOptions.sha256] for a model with a projector, and on a
  /// URL-loading backend a [download] option only the package download
  /// manager provides.
  ///
  /// Then every file resolves, the model first, then the projector and the
  /// [ModelParams.loras] sources. [modelResolver] resolves each
  /// `ModelSource`, and on a backend that loads files [modelDownloadManager]
  /// checks a local file, or downloads a remote one into the model cache,
  /// resuming an interrupted download and reusing a cached file. [download]
  /// applies to every remote file: cache policy and directory,
  /// authentication, resume, retries and the cancel token. A local file takes
  /// only the cancel token and, without a projector,
  /// [ModelLoadOptions.sha256]. The bearer token and headers are never sent
  /// across hosts: when they are set and the model and projector, or the URLs
  /// the resolver returns for them, span more than one origin (scheme, host
  /// and port), the call throws before downloading from another host. An
  /// adapter of [ModelParams.loras] takes its own
  /// [LoraAdapterConfig.download], or only the non-secret parts of
  /// [download]. The download manager gets a copy of [download] whose cancel
  /// token is also cancelled by [dispose]. [onProgress] reports the model
  /// and projector together: `receivedBytes` counts the files resolved so
  /// far plus the current download, and `totalBytes` is their combined size
  /// once every size is known. With a projector that is null, and so is
  /// `fraction`, until the model has downloaded and the projector reports
  /// its size.
  ///
  /// The model this engine already holds keeps serving until every file has
  /// resolved. Only then is it unloaded, which cancels its generations, and
  /// [model] loaded, then its projector. Tool loops cut off by the unload
  /// report `cancelled`. A chat-session request keeps a partial reply, or
  /// rolls back and throws [LlamaStateException] before any output. A failure
  /// from there on leaves nothing loaded, and so does [download]'s cancel token
  /// when it is cancelled that late; cancelled earlier, it leaves the old
  /// model loaded.
  ///
  /// A URL-loading backend, as on the Web, fetches each file itself during
  /// the load, so the old model is unloaded before the new one is fetched,
  /// and a fetch that fails leaves nothing loaded. There a local path is a
  /// URL relative to the document, or a `blob:` URL, [download] must leave
  /// every option at its default, and [onProgress] reports only the model's
  /// fetch, as a fraction that ends at 0.5 when there is a projector.
  ///
  /// While a call runs, another [setModel] and [unloadModel] throw
  /// [LlamaStateException]; stop it with [download]'s cancel token.
  /// [dispose] stops its downloads at once.
  ///
  /// Throws:
  /// - [LlamaArgumentException] for an invalid [params], and when [download]
  ///   would send credentials to more than one host; the message names the
  ///   origins, never the credentials.
  /// - [LlamaUnsupportedException] for the checks above, for an explicit
  ///   [ModelParams.device] the runtime cannot use, and when the backend
  ///   cannot load the model's format or a projector.
  /// - [LlamaModelException] when a file is missing, cannot be downloaded,
  ///   fails its checksum or cannot be loaded, and its subtype
  ///   [LlamaModelFormatException] when a file's content contradicts its
  ///   declared format.
  /// - [LlamaStateException] after [dispose], when [dispose] or [download]'s
  ///   cancel token stops the load, and while another model load or unload
  ///   runs.
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    await _setModel(model, params, download, onProgress);
  }

  /// [setModel], naming the load [operation] and its files [assetType] in
  /// errors. [companions] are further files of the model: they resolve after
  /// the model's own, under the same rules, and this returns where each
  /// resolved, in order: a local path, or on a URL-loading backend what the
  /// backend fetches.
  Future<List<String>> _setModel(
    LlamaModel model,
    ModelParams params,
    ModelLoadOptions download,
    ModelDownloadProgressCallback? onProgress, {
    String operation = 'Model loading',
    String assetType = 'model',
    List<ModelSource> companions = const <ModelSource>[],
  }) async {
    var companionLocations = const <String>[];
    final source = model.source;
    final observedSource =
        source.path ??
        (backend.supportsUrlLoading
            ? '${source.resolvedUri}'
            : source.fileName);
    Future<void> load() => _withModelLifecycle('set a model', () async {
      params.validate();
      final sources = <ModelSource>[
        model.source,
        ?model.projector,
        ...companions,
      ];
      _checkModelBeforeIo(model, params);

      void throwIfCancelled() {
        if (download.cancelToken?.isCancelled ?? false) {
          throw LlamaStateException('$operation was cancelled.');
        }
      }

      final loraLocations = <String, String>{};
      final (locations, resolvedParams) = await _unlessDisposed(
        _resolveModelFiles(
          sources,
          params,
          download,
          onProgress,
          operation,
          assetType,
          loraLocations,
        ),
      );
      throwIfCancelled();

      await _unloadModel();
      _throwIfDisposedDuringLoad();
      final location = locations.first;
      final projector = model.projector == null ? null : locations[1];
      if (backend.supportsUrlLoading) {
        final fileCount = projector == null ? 1 : 2;
        await _loadModelFromUrl(
          location,
          modelParams: resolvedParams,
          onProgress: onProgress == null
              ? null
              : (double fraction) => onProgress(
                  ModelDownloadProgress.fraction(fraction / fileCount),
                ),
          format: source.format,
        );
      } else {
        await _loadModel(
          location,
          modelParams: resolvedParams,
          format: source.format,
        );
      }
      _loraLocations.addAll(loraLocations);
      try {
        _throwIfDisposedDuringLoad();
        if (projector != null) {
          await _withMmLifecycle(
            () => _loadMultimodalProjectorLocked(projector),
          );
        }
        throwIfCancelled();
      } catch (_) {
        try {
          await _unloadModel();
        } catch (_) {
          // The load failure is the error the caller needs.
        }
        rethrow;
      }
      await _captureObservedModel(location);
      _throwIfDisposedDuringLoad();
      companionLocations = locations.sublist(
        sources.length - companions.length,
      );
    });

    await _observeModelLoad(observedSource, params, load);
    return companionLocations;
  }

  /// Throws [LlamaUnsupportedException] for what [setModel] can reject from
  /// its arguments alone.
  void _checkModelBeforeIo(LlamaModel model, ModelParams params) {
    final source = model.source;
    final format =
        source.format ??
        ModelFormat.fromPath(
          source.path ??
              (backend.supportsUrlLoading
                  ? '${source.resolvedUri}'
                  : source.fileName),
        );
    if (model.projector != null && format == ModelFormat.liteRtLm) {
      throw LlamaUnsupportedException(
        'A LiteRT-LM model takes no multimodal projector: a .litertlm bundle '
        'carries its own media encoders. Leave LlamaModel.projector unset.',
      );
    }
    if (params.device == ComputeDevice.npu && format == ModelFormat.gguf) {
      throw LlamaUnsupportedException(
        'ComputeDevice.npu is not available for llama.cpp, which runs GGUF '
        'models: only LiteRT-LM on Android has an NPU backend. Use '
        'ComputeDevice.auto, cpu or gpu.',
      );
    }
    if (source.format case final declared?) _checkBackendLoads(declared);
  }

  /// Where the backend loads each of [sources] from, in order, and [params]
  /// with its [ModelParams.loras] sources resolved, recorded in
  /// [loraLocations].
  Future<(List<String>, ModelParams)> _resolveModelFiles(
    List<ModelSource> sources,
    ModelParams params,
    ModelLoadOptions download,
    ModelDownloadProgressCallback? onProgress,
    String operation,
    String assetType,
    Map<String, String> loraLocations,
  ) async {
    final List<String> locations;
    var options = download;
    if (backend.supportsUrlLoading) {
      locations = await resolveModelSourceUrls(
        sources,
        resolver: modelResolver,
        download: download,
        assetType: assetType,
      );
    } else {
      final callerToken = download.cancelToken;
      options = _withCancelToken(
        download,
        _LinkedCancelToken([
          () => isDisposed,
          if (callerToken != null) () => callerToken.isCancelled,
        ]),
      );
      locations = await resolveModelSourceFiles(
        sources,
        store: ModelFileStore(
          resolver: modelResolver,
          downloadManager: modelDownloadManager,
        ),
        download: options,
        operation: operation,
        onProgress: onProgress,
        assetType: assetType,
      );
    }
    final resolvedParams = await _resolveLoraSources(
      params,
      options,
      loraLocations,
    );
    return (locations, resolvedParams);
  }

  /// [work], or [LlamaStateException] as soon as [dispose] is called, so a
  /// download that reads its cancel token late does not hold [dispose] up.
  Future<T> _unlessDisposed<T>(Future<T> work) {
    final result = Completer<T>();
    void abandon() {
      if (result.isCompleted) return;
      result.completeError(
        LlamaStateException(_disposedDuringLoadMessage),
        StackTrace.current,
      );
    }

    _abandonResolutions.add(abandon);
    if (isDisposed) abandon();
    work.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    return result.future.whenComplete(() {
      _abandonResolutions.remove(abandon);
    });
  }

  /// Loads a model from a local [path].
  ///
  /// Optionally provide [ModelParams] to configure context size, GPU offloading,
  /// the [ModelParams.device], and more. [ModelParams.validate] runs first and
  /// throws [LlamaArgumentException]; an explicit device that is unavailable
  /// throws [LlamaUnsupportedException].
  ///
  /// The default native backend reads the file header to choose llama.cpp for
  /// GGUF or LiteRT-LM for a `.litertlm` bundle, so the file name needs no
  /// model extension. Throws [LlamaModelFormatException] when a recognized
  /// header contradicts the file extension. To name the format of a file whose
  /// header cannot be read, load it with [setModel] and a
  /// [ModelSource.format].
  @Deprecated(
    'Use LlamaEngine.load or setModel with '
    'LlamaModel(ModelSource.path(path)). This will be removed in 1.0.',
  )
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
        modelParams.validate();
        await _loadModel(path, modelParams: modelParams, format: format);
        _throwIfDisposedDuringLoad();
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
    final modelName = _displayNameForSource(path);
    LlamaLogger.instance.info('Loading model: $modelName');

    if (backend.supportsUrlLoading) {
      LlamaLogger.instance.info(
        'Backend supports URL loading, attempting loadModelFromUrl.',
      );
      // Resolves and records the adapters of modelParams itself.
      return _loadModelFromUrl(path, modelParams: modelParams, format: format);
    }

    final loraLocations = <String, String>{};
    modelParams = await _resolveLoraSources(
      modelParams,
      ModelLoadOptions.defaults,
      loraLocations,
    );

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
      _loraLocations.addAll(loraLocations);
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
  /// [loadModelFromUrl] for unauthenticated prefer-cached requests, and load
  /// a local path as a URL relative to the document.
  ///
  /// Adapters in [ModelParams.loras] given as [LoraAdapterConfig.source]
  /// resolve after the model file, with their own
  /// [LoraAdapterConfig.download] or only the non-secret parts of [options];
  /// see [ModelParams.loras].
  ///
  /// [ModelParams.validate] runs before anything resolves or downloads and
  /// throws [LlamaArgumentException]. Throws [LlamaStateException] before
  /// anything resolves or downloads when a model is already loaded.
  ///
  /// On file-backed backends, [dispose] cancels model and LoRA downloads and
  /// makes this call throw [LlamaStateException] without waiting for a custom
  /// resolver or download manager that ignores cancellation. The resolver and
  /// download manager receive a copy of [options] with a cancel token linked
  /// to disposal and the caller's token; disposal never cancels the caller's
  /// token. URL-loading backends keep their runtime-owned fetch behavior.
  @Deprecated(
    'Use LlamaEngine.load or setModel with LlamaModel(source). This will be '
    'removed in 1.0.',
  )
  Future<void> loadModelSource(
    ModelSource source, {
    ModelParams modelParams = const ModelParams(),
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    _throwIfDisposed();
    modelParams.validate();
    _ensureNotReady();
    if (!backend.supportsUrlLoading) {
      final callerToken = options.cancelToken;
      options = _withCancelToken(
        options,
        _LinkedCancelToken([
          () => isDisposed,
          if (callerToken != null) () => callerToken.isCancelled,
        ]),
      );
      final loraLocations = <String, String>{};
      Future<(String, ModelParams)> resolve() async {
        final target = await modelResolver.resolve(
          source,
          ModelResolveRequest(options: options, onProgress: onProgress),
        );
        _throwIfSourceLoadCancelled(options);
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
          options,
          loraLocations,
        );
        _throwIfSourceLoadCancelled(options);
        return (entry.filePath, resolvedParams);
      }

      final (path, resolvedParams) = await _unlessDisposed(resolve());
      await _loadSourceFile(path, resolvedParams, source.format);
      if (_isReady) _loraLocations.addAll(loraLocations);
      return;
    }
    final target = await modelResolver.resolve(
      source,
      ModelResolveRequest(options: options, onProgress: onProgress),
    );
    _throwIfSourceLoadCancelled(options);
    final String url;
    switch (target) {
      case LocalModelFile(:final path):
        url = path;
      case RemoteModelUrl(url: final remote, :final useBrowserCache):
        if (!useBrowserCache) {
          throw LlamaUnsupportedException(
            'Remote model loading without browser/backend cache is not supported yet.',
          );
        }
        url = remote.toString();
    }
    rejectUnsupportedUrlBackendOptions(options);
    final urlProgress = onProgress == null
        ? null
        : (double progress) =>
              onProgress(ModelDownloadProgress.fraction(progress));
    final format = source.format;
    if (format == null) {
      return loadModelFromUrl(
        url,
        modelParams: modelParams,
        onProgress: urlProgress,
      );
    }
    return _loadModelFromUrlAs(url, modelParams, urlProgress, format);
  }

  /// Loads a model from a [url].
  ///
  /// This is typically used on the Web platform. Use [ModelParams] to
  /// configure loading options.
  ///
  /// The runtime fetches [url] itself, so its content cannot pick the
  /// runtime: the URL path's extension does, and a URL without a model
  /// extension loads as GGUF. For such a URL, load it with [setModel] and a
  /// [ModelSource.format].
  @Deprecated(
    'Use LlamaEngine.load or setModel with LlamaModel(ModelSource.parse(url)), '
    'or with ModelSource.path(url) for a relative or blob: URL. This will be '
    'removed in 1.0.',
  )
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
        modelParams.validate();
        await _loadModelFromUrl(
          url,
          modelParams: modelParams,
          onProgress: onProgress,
          format: format,
        );
        _throwIfDisposedDuringLoad();
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
    final loraLocations = <String, String>{};
    modelParams = await _resolveLoraSources(
      modelParams,
      ModelLoadOptions.defaults,
      loraLocations,
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
      _loraLocations.addAll(loraLocations);

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
      _checkBackendLoads(format);
    }
    return fromUrl
        ? candidate.modelLoadFromUrl(
            source,
            modelParams,
            onProgress: onProgress,
          )
        : candidate.modelLoad(source, modelParams);
  }

  /// Throws [LlamaUnsupportedException] when the backend neither routes by
  /// model format nor runs the runtime of [format].
  void _checkBackendLoads(ModelFormat format) {
    final candidate = backend;
    if (candidate is BackendModelFormatRouting) return;
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
  /// A model must already be loaded. Calling this before the model is ready
  /// throws a [LlamaContextException].
  ///
  /// On the native llama.cpp backend, throws [LlamaModelException] when
  /// [mmProjPath] is not an existing file or the runtime rejects the projector
  /// for the loaded model, and [LlamaUnsupportedException] only when the
  /// runtime cannot run an mtmd function this package calls. A backend error
  /// that is not a [LlamaException] becomes a [LlamaModelException] without
  /// the URL secrets of [mmProjPath].
  /// Throws [LlamaStateException] if the model is unloaded, replaced or
  /// the engine disposed while the projector loads.
  @Deprecated(
    'Use LlamaModel(source, projector: ModelSource.path(path)) with '
    'LlamaEngine.load or setModel, or loadMultimodalProjectorSource to change '
    'the projector of a loaded model. This will be removed in 1.0.',
  )
  Future<void> loadMultimodalProjector(String mmProjPath) {
    return _withMmLifecycle(() => _loadMultimodalProjectorLocked(mmProjPath));
  }

  /// Loads a multimodal projector from a structured [source], replacing the
  /// one the loaded model has.
  ///
  /// To load a model with its projector, pass both to [LlamaEngine.load] or
  /// [setModel] as `LlamaModel(source, projector: projector)`. A model must
  /// already be loaded here; before that this throws
  /// [LlamaContextException].
  ///
  /// Source resolution, package-managed download/cache work, and the backend
  /// projector load are serialized with projector unloads and with other
  /// projector loads, which apply in call order.
  ///
  /// [modelResolver] resolves [source]. On file-backed backends
  /// [modelDownloadManager] checks a local file, or downloads a remote one
  /// with [download] into the model cache, reporting to [onProgress].
  /// [download]'s cancel token stops the download, and so do [unloadModel],
  /// [setModel] replacing the model, and [dispose]: the download manager
  /// gets a copy of [download] whose cancel token they also cancel. On
  /// URL-loading backends the backend fetches [source] itself: a local path
  /// is a URL relative to the document, or a `blob:` URL, and
  /// package-managed auth, headers, checksum verification, cache policy
  /// changes, cache directories, cancellation, retry/resume settings, and
  /// progress reporting are not available because the backend/browser owns
  /// the network and cache behavior.
  ///
  /// [options] is the deprecated name of [download]; setting both throws
  /// [LlamaArgumentException].
  ///
  /// Throws [LlamaUnsupportedException] when the active backend cannot load
  /// multimodal projectors, when the resolver returns a remote target that
  /// disallows browser/backend caching, or when URL-backend loading is
  /// requested with options that require the package-managed download/cache
  /// manager; and [LlamaStateException] when the model is unloaded or the
  /// engine disposed before the projector loads.
  Future<void> loadMultimodalProjectorSource(
    ModelSource source, {
    ModelLoadOptions? download,
    @Deprecated('Use download. This will be removed in 1.0.')
    ModelLoadOptions? options,
    ModelDownloadProgressCallback? onProgress,
  }) {
    if (download != null && options != null) {
      throw LlamaArgumentException(
        'loadMultimodalProjectorSource takes download or the deprecated '
        'options, not both. Pass download.',
        name: 'options',
      );
    }
    final requested = download ?? options ?? ModelLoadOptions.defaults;
    return _withMmLifecycle(() async {
      _ensureReady(requireContext: false);
      final epoch = _modelEpoch;
      bool abandoned() => isDisposed || _modelEpoch != epoch;
      var resolveOptions = requested;
      if (!backend.supportsUrlLoading) {
        final callerToken = requested.cancelToken;
        resolveOptions = _withCancelToken(
          requested,
          _LinkedCancelToken([
            abandoned,
            if (callerToken != null) () => callerToken.isCancelled,
          ]),
        );
      }
      final String location;
      try {
        location = await _resolveAuxiliarySource(
          source,
          options: resolveOptions,
          onProgress: onProgress,
          assetType: 'multimodal projector',
        );
      } on Object {
        if (abandoned()) throw _projectorModelChanged();
        rethrow;
      }
      if (abandoned()) throw _projectorModelChanged();
      return _loadMultimodalProjectorLocked(location);
    });
  }

  LlamaStateException _projectorModelChanged() => LlamaStateException(
    isDisposed
        ? _disposedDuringLoadMessage
        : 'The model was unloaded while its multimodal projector loaded, so '
              'the projector was not loaded.',
  );

  /// The local file, or on a URL-loading backend the URL or document-relative
  /// path, that the backend loads for the auxiliary file [source] of
  /// [assetType], resolved as [loadMultimodalProjectorSource] describes.
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
      try {
        final entry = await ensureModelTargetFile(
          modelDownloadManager,
          source,
          target,
          options: options,
          onProgress: onProgress,
          assetType: assetType,
        );
        return entry.filePath;
      } on UncacheableLocalModelFileException catch (file) {
        return file.filePath;
      }
    }
    switch (target) {
      case LocalModelFile(:final path):
        rejectUnsupportedUrlBackendOptions(options, assetType: assetType);
        return path;
      case RemoteModelUrl(:final url, :final useBrowserCache):
        if (!useBrowserCache) {
          throw LlamaUnsupportedException(
            'Remote $assetType loading without browser/backend cache is not supported yet.',
          );
        }
        rejectUnsupportedUrlBackendOptions(options, assetType: assetType);
        return url.toString();
    }
  }

  Future<void> _loadMultimodalProjectorLocked(String mmProjPath) async {
    final mmProjName = _displayNameForSource(mmProjPath);
    LlamaLogger.instance.info('Loading multimodal projector: $mmProjName');
    _ensureReady(requireContext: false);
    final epoch = _modelEpoch;
    try {
      if (_mmContextHandle != null) {
        await _unloadMultimodalProjectorLocked();
      }
      if (!_isLoadedAt(epoch)) throw _projectorModelChanged();

      _mmContextHandle = await backend.multimodalContextCreate(
        _modelHandle!,
        mmProjPath,
      );
      if (!_isLoadedAt(epoch)) throw _projectorModelChanged();
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

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposal != null;

  /// Waits for a model load or unload in progress, unloads the model, which
  /// cancels running generations, and disposes [backend].
  ///
  /// Immediately marks the engine as disposed, before teardown callbacks run.
  /// Idempotent: every call, including a synchronous reentrant call, returns
  /// the same future, even if teardown fails. A failed disposal is not retried.
  /// Terminal: afterwards,
  /// loads, requests and the backend queries [getBackendName],
  /// [getAvailableBackends], [isGpuSupported], [getVramInfo],
  /// [listGpuDevices] and [getResolvedGpuLayers] throw
  /// [LlamaStateException]; [capabilities] reports the engine as disposed;
  /// model queries such as [getMetadata] and [getContextSize] return their
  /// no-model values; and [unloadModel] and [cancelGeneration] do nothing. A
  /// load running when this is called throws [LlamaStateException], and a
  /// model it loaded is unloaded. The downloads of a running [setModel],
  /// [loadModelSource] or [loadMultimodalProjectorSource] stop. Resolution or
  /// download work from [setModel] or [loadModelSource] does not hold this
  /// call up, even when a custom resolver or manager ignores cancellation.
  Future<void> dispose() {
    final existing = _disposal;
    if (existing != null) return existing;

    // Publish terminal state and the shared future before synchronous logging,
    // cancellation or backend hooks can reenter disposal.
    final disposal = Completer<void>();
    _disposal = disposal.future;
    disposal.complete(_dispose());
    return disposal.future;
  }

  Future<void> _dispose() async {
    for (final abandon in _abandonResolutions.toList()) {
      abandon();
    }
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
      await _withModelLifecycle(
        'unload the current model',
        _unloadModel,
        whileDisposing: true,
      );
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
  ///
  /// Cancels running generations, including chat-session requests and tool
  /// loops, with the same history behavior as [cancelGeneration].
  ///
  /// Does nothing after [dispose].
  Future<void> unloadModel() {
    if (isDisposed) return Future<void>.value();
    return _withModelLifecycle('unload the current model', _unloadModel);
  }

  Future<void> _unloadModel() async {
    if (!isReady && _modelHandle == null && _mmContextHandle == null) return;
    LlamaLogger.instance.info('Unloading model...');
    _isReady = false;
    _decisionHeadHandles.clear();
    _decisionHeadEpoch++;
    _loraLocations.clear();
    _draftLocations.clear();
    _generationCancellation.cancel();
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
  /// Use [chatTemplateKwargs] to inject additional template globals (equivalent
  /// to llama.cpp `chat_template_kwargs`). TranslateGemma templates read their
  /// language codes from it, as llama.cpp does:
  /// `chatTemplateKwargs: {'source_lang_code': 'en', 'target_lang_code': 'ko'}`.
  /// The deprecated [sourceLangCode] and [targetLangCode] set those keys,
  /// replacing any in [chatTemplateKwargs].
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
  /// On native llama.cpp, an image or audio part that the loaded multimodal
  /// projector has no encoder for throws [LlamaUnsupportedException]. A
  /// template that fails to render, by raising or through invalid syntax,
  /// throws [LlamaInferenceException] with the template's message.
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
    @Deprecated("Use chatTemplateKwargs: {'source_lang_code': ...} instead.")
    String? sourceLangCode,
    @Deprecated("Use chatTemplateKwargs: {'target_lang_code': ...} instead.")
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    final zone = Zone.current;
    final templateKwargs = chatTemplateKwargsWithLanguageCodes(
      chatTemplateKwargs,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
    );
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
          chatTemplateKwargs: templateKwargs,
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
                chatTemplateKwargs: templateKwargs,
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
  ///
  /// The deprecated [sourceLangCode] and [targetLangCode] behave as in
  /// [create]; pass the codes in [chatTemplateKwargs] instead.
  Future<T> createStructuredJson<T>(
    List<LlamaChatMessage> messages, {
    required LlamaStructuredOutput<T> output,
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    @Deprecated("Use chatTemplateKwargs: {'source_lang_code': ...} instead.")
    String? sourceLangCode,
    @Deprecated("Use chatTemplateKwargs: {'target_lang_code': ...} instead.")
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
      chatTemplateKwargs: chatTemplateKwargsWithLanguageCodes(
        chatTemplateKwargs,
        sourceLangCode: sourceLangCode,
        targetLangCode: targetLangCode,
      ),
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
  /// A template that fails to render, by raising or through invalid syntax,
  /// throws [LlamaInferenceException] with the template's message.
  ///
  /// [jsonSchema] is a legacy shortcut for
  /// `responseFormat: {'type': 'json_schema', 'json_schema': {'schema': ...}}`.
  /// If both [responseFormat] and [jsonSchema] are provided, [responseFormat]
  /// wins.
  ///
  /// Set [includeTokenCount] to false to skip the prompt tokenization pass
  /// and reduce per-request overhead when token count is not needed.
  ///
  /// Use [chatTemplateKwargs] to inject additional template globals (equivalent
  /// to llama.cpp `chat_template_kwargs`), including TranslateGemma's
  /// `source_lang_code` and `target_lang_code`; the deprecated
  /// [sourceLangCode] and [targetLangCode] behave as in [create].
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
    @Deprecated("Use chatTemplateKwargs: {'source_lang_code': ...} instead.")
    String? sourceLangCode,
    @Deprecated("Use chatTemplateKwargs: {'target_lang_code': ...} instead.")
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
      includeTokenCount: includeTokenCount,
      chatTemplateKwargs: chatTemplateKwargsWithLanguageCodes(
        chatTemplateKwargs,
        sourceLangCode: sourceLangCode,
        targetLangCode: targetLangCode,
      ),
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
    late final Stream<String> generation;
    generation = _generationCancellation.request((request) {
      BackendGenerationLimit? limit;
      void recordLimit(BackendGenerationLimit reported) {
        limit = reported;
        if (!request.isCancelled()) {
          _rawGenerationLimits[generation] = reported;
        }
      }

      if (operation == null) {
        return _generate(
          prompt,
          params: params,
          parts: parts,
          onLimit: recordLimit,
          request: request,
        );
      }
      LlamaGenerationUsage? usage;
      return observeStream(
        _generate(
          prompt,
          params: params,
          parts: parts,
          onLimit: recordLimit,
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
    return generation;
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
  ///
  /// Does nothing after [dispose].
  void cancelGeneration() {
    if (isDisposed) return;
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

  /// Whether the loaded model takes image input, as
  /// [LlamaEngineCapabilities.supportsVision] of [capabilities] reports it.
  ///
  /// False when no model is loaded, after [dispose], and when the model
  /// loads or unloads during the probe.
  Future<bool> get supportsVision async => (await _loadedMediaSupport()).vision;

  /// Whether the loaded model takes audio input, as
  /// [LlamaEngineCapabilities.supportsAudio] of [capabilities] reports it.
  ///
  /// False when no model is loaded, after [dispose], and when the model
  /// loads or unloads during the probe.
  Future<bool> get supportsAudio async => (await _loadedMediaSupport()).audio;

  Future<({bool vision, bool audio})> _loadedMediaSupport() async {
    const none = (vision: false, audio: false);
    final epoch = _modelEpoch;
    if (!_isLoadedAt(epoch)) return none;
    try {
      final media = await _mediaSupport();
      return _isLoadedAt(epoch) ? media : none;
    } catch (_) {
      if (!_isLoadedAt(epoch)) return none;
      rethrow;
    }
  }

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
  /// [source] resolves as in [setModel]: [modelResolver] resolves it, and on
  /// file-backed backends [modelDownloadManager] checks a local file, or
  /// downloads a remote one with [download] into the model cache, resuming
  /// an interrupted download and reusing a cached file, reporting to
  /// [onProgress]. [download]'s cancel token stops the download. On
  /// URL-loading backends (WebGPU) the runtime fetches [source] itself, a
  /// local path as a URL relative to the document or a `blob:` URL, and
  /// options that need the package-managed download manager throw
  /// [LlamaUnsupportedException], as for [loadMultimodalProjectorSource].
  ///
  /// Remove the adapter with [removeLoraSource] and the same [source].
  /// Setting [source] again with options that resolve it to another file,
  /// such as another cache directory, replaces the adapter applied from it.
  ///
  /// Throws [LlamaContextException] when no model is loaded,
  /// [LlamaUnsupportedException] when the backend has no runtime LoRA API or
  /// cannot load [source] as described above, [LlamaStateException] when
  /// [download]'s cancel token cancels the download or the model is
  /// unloaded before the adapter applies (unloading also stops the
  /// download), and what the download manager throws for a missing file or
  /// a failed download.
  Future<void> setLoraSource(
    ModelSource source, {
    double scale = 1.0,
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    _ensureReady();
    if (runtime == LlamaRuntime.liteRtLm) {
      throw LlamaUnsupportedException(
        'LiteRT-LM has no runtime LoRA adapter API, so the adapter is not '
        'downloaded.',
      );
    }
    final epoch = _modelEpoch;
    bool unloaded() => _modelEpoch != epoch;
    var options = download;
    if (!backend.supportsUrlLoading) {
      final callerToken = download.cancelToken;
      options = _withCancelToken(
        download,
        _LinkedCancelToken([
          unloaded,
          if (callerToken != null) () => callerToken.isCancelled,
        ]),
      );
    }
    final String location;
    try {
      location = await _resolveAuxiliarySource(
        source,
        options: options,
        onProgress: onProgress,
        assetType: 'LoRA adapter',
      );
    } on Object {
      if (unloaded()) throw _loraModelChanged();
      rethrow;
    }
    if (download.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('LoRA adapter loading was cancelled.');
    }
    if (unloaded()) throw _loraModelChanged();
    _ensureReady();
    final previous = _loraLocations[source.canonicalKey];
    try {
      await backend.setLoraAdapter(_contextHandle!, location, scale);
      _loraLocations[source.canonicalKey] = location;
      if (previous != null && previous != location) {
        await backend.removeLoraAdapter(_contextHandle!, previous);
      }
    } on UnsupportedError catch (error) {
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
  }

  static LlamaStateException _loraModelChanged() => LlamaStateException(
    'The model was unloaded while its LoRA adapter loaded, so the adapter '
    'was not applied.',
  );

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
    final applied = _loraLocations[source.canonicalKey];
    final location = applied ?? source.path;
    if (location == null) return;
    try {
      await backend.removeLoraAdapter(_contextHandle!, location);
    } on UnsupportedError catch (error) {
      // Only the deprecated setLora applies an untracked path, and a backend
      // without a runtime LoRA API rejects it.
      if (applied == null) return;
      throw _unsupportedBackendOperation('LoRA adapters', error);
    }
    _loraLocations.remove(source.canonicalKey);
  }

  /// [params] with every [LoraAdapterConfig.source] of [ModelParams.loras]
  /// resolved as [setLoraSource] resolves it, with the adapter's own
  /// [LoraAdapterConfig.download], or else only the non-secret parts of the
  /// model load's [options]. Records where each adapter resolved in
  /// [locations], a path configuration under its [ModelSource.path], which
  /// the caller keeps once the model loads.
  Future<ModelParams> _resolveLoraSources(
    ModelParams params,
    ModelLoadOptions options,
    Map<String, String> locations,
  ) async {
    final resolved = <LoraAdapterConfig>[];
    for (final lora in params.loras) {
      final source = lora.source;
      if (source == null) {
        if (lora.path.isNotEmpty) {
          locations[ModelSource.path(lora.path).canonicalKey] = lora.path;
        }
        resolved.add(lora);
        continue;
      }
      final location = await _resolveAuxiliarySource(
        source,
        options: _loraDownloadOptions(source, lora.download, options),
        assetType: 'LoRA adapter',
      );
      locations[source.canonicalKey] = location;
      resolved.add(resolvedLoraAdapterConfig(location, lora.scale));
    }
    if (params.loras.every((lora) => lora.source == null)) return params;
    return params.copyWith(loras: resolved);
  }

  /// The download options of the [ModelParams.loras] adapter at [source]:
  /// its own [download] with the model load's cancel token linked, or
  /// without them only the cache policy and directory, resume, retries and
  /// cancel token of [load]. The model load's bearer token, headers and
  /// checksum belong to the model's host and file, never an adapter's.
  static ModelLoadOptions _loraDownloadOptions(
    ModelSource source,
    ModelLoadOptions? download,
    ModelLoadOptions load,
  ) {
    final loadToken = load.cancelToken;
    if (download != null) {
      final ownToken = download.cancelToken;
      if (loadToken == null || identical(ownToken, loadToken)) return download;
      return _withCancelToken(
        download,
        ownToken == null
            ? loadToken
            : _LinkedCancelToken([
                () => ownToken.isCancelled,
                () => loadToken.isCancelled,
              ]),
      );
    }
    if (source.isLocal) return ModelLoadOptions(cancelToken: loadToken);
    return ModelLoadOptions(
      cachePolicy: load.cachePolicy,
      cacheDirectory: load.cacheDirectory,
      cancelToken: loadToken,
      resume: load.resume,
      maxRetries: load.maxRetries,
    );
  }

  /// [params] with its [SpeculativeDecodingConfig.draftModel] resolved as
  /// [setLoraSource] resolves a source, or null when [request] is cancelled
  /// meanwhile. A model change during resolution throws [LlamaStateException].
  ///
  /// A draft model resolves once per loaded model, source, cache directory
  /// and checksum; later generations reuse its file.
  Future<GenerationParams?> _resolveDraftModel(
    GenerationParams params,
    GenerationRequest request,
  ) async {
    final config = params.speculativeDecodingConfig;
    if (config == null) return params;
    final source = config.draftModel;
    if (source == null) {
      // Download options apply only to the engine's own download; they can
      // hold credentials and a cancel token that must not reach a backend
      // or its worker isolate.
      return identical(config.draftModelDownload, ModelLoadOptions.defaults)
          ? params
          : params.copyWith(
              speculativeDecodingConfig: config.withDraftModelDownload(
                ModelLoadOptions.defaults,
              ),
            );
    }
    final download = config.draftModelDownload;
    final policy = download.cachePolicy;
    if (policy == ModelCachePolicy.noCache ||
        policy == ModelCachePolicy.refresh) {
      throw LlamaUnsupportedException(
        'SpeculativeDecodingConfig.draftModelDownload cannot use '
        'ModelCachePolicy.${policy.name}: a draft model resolves once per '
        'loaded model and generations reuse it. Use preferCached or '
        'cacheOnly.',
      );
    }
    final key = [
      source.canonicalKey,
      download.cachePolicy.name,
      download.cacheDirectory ?? '',
      download.sha256 ?? '',
    ].join('\n');
    var location = _draftLocations[key];
    if (location == null) {
      final epoch = _modelEpoch;
      void checkModelEpoch() {
        if (_modelEpoch != epoch) {
          throw LlamaStateException(
            'The model changed while resolving the speculative draft model. Retry the request with the loaded model.',
          );
        }
      }

      await _rejectUnsupportedDraftModel(config);
      checkModelEpoch();
      bool abandoned() => _modelEpoch != epoch || request.isCancelled();
      var options = download;
      if (!backend.supportsUrlLoading) {
        final callerToken = download.cancelToken;
        options = _withCancelToken(
          download,
          _LinkedCancelToken([
            abandoned,
            if (callerToken != null) () => callerToken.isCancelled,
          ]),
        );
      }
      try {
        location = await _resolveAuxiliarySource(
          source,
          options: options,
          assetType: 'speculative draft model',
        );
      } on Object {
        checkModelEpoch();
        if (request.isCancelled()) return null;
        rethrow;
      }
      checkModelEpoch();
      if (request.isCancelled()) return null;
      _draftLocations[key] = location;
    }
    // A URL-loading backend reads a local path as a URL relative to the
    // document, or a `blob:` URL, which only a path source can carry.
    final remote = backend.supportsUrlLoading ? Uri.tryParse(location) : null;
    final resolved =
        remote != null && (remote.isScheme('http') || remote.isScheme('https'))
        ? ModelSource.url(remote, fileName: source.fileName)
        : ModelSource.path(location);
    // The resolved file needs no download options, and the caller's bearer
    // token, headers and cancel token must not reach the backend or its
    // worker isolate.
    return params.copyWith(
      speculativeDecodingConfig: config.withDraftModel(resolved),
    );
  }

  /// Throws [LlamaUnsupportedException] before a draft model downloads when
  /// the active runtime could not use it: LiteRT-LM, which loads no external
  /// draft model, or a backend that does not report every strategy of
  /// [config].
  Future<void> _rejectUnsupportedDraftModel(
    SpeculativeDecodingConfig config,
  ) async {
    final candidate = backend;
    if (candidate is BackendRuntimeIdentity &&
        (candidate as BackendRuntimeIdentity).runtime ==
            LlamaRuntime.liteRtLm) {
      throw LlamaUnsupportedException(
        'LiteRT-LM cannot load an external speculative draft model, so '
        'SpeculativeDecodingConfig.draftModel is not downloaded. Leave it '
        'null.',
      );
    }
    if (candidate is! BackendGenerationCapabilitiesSupport) return;
    final supported =
        (await _generationCapabilities()).speculativeDecodingStrategies;
    final missing = [
      for (final strategy in config.effectiveStrategies)
        if (!supported.contains(strategy)) strategy.name,
    ];
    if (missing.isNotEmpty) {
      throw LlamaUnsupportedException(
        'The active backend does not support speculative strategy '
        '${missing.join(', ')}, so SpeculativeDecodingConfig.draftModel is '
        'not downloaded.',
      );
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
    _loraLocations.clear();
  }

  // ============================================================
  // BACKEND UTILITIES
  // ============================================================

  /// Returns the name of the active GPU backend.
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<String> getBackendName() async {
    _throwIfDisposed();
    return backend.getBackendName();
  }

  /// Returns backend options available for user selection.
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<String> getAvailableBackends() async {
    _throwIfDisposed();
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
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<int?> getResolvedGpuLayers() async {
    _throwIfDisposed();
    final candidate = backend;
    if (candidate is BackendRuntimeDiagnostics) {
      return (candidate as BackendRuntimeDiagnostics).getResolvedGpuLayers();
    }
    return null;
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
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<bool> isGpuSupported() async {
    _throwIfDisposed();
    return backend.isGpuSupported();
  }

  /// Returns total and free VRAM in bytes.
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<({int total, int free})> getVramInfo() async {
    _throwIfDisposed();
    return backend.getVramInfo();
  }

  /// Lists GPU-class devices when the active backend supports enumeration,
  /// otherwise an empty list. With an empty [probeBackends] only
  /// already-registered backends are inspected (no backend module is loaded);
  /// pass backends to opt into loading just those before enumerating.
  ///
  /// Throws [LlamaStateException] after [dispose].
  Future<List<GpuDeviceInfo>> listGpuDevices({
    List<GpuBackend> probeBackends = const [],
  }) async {
    _throwIfDisposed();
    final candidate = backend;
    if (candidate is BackendGpuEnumeration) {
      return (candidate as BackendGpuEnumeration).listGpuDevices(
        probeBackends: probeBackends,
      );
    }
    return const [];
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
    Future<void> Function() action, {
    bool whileDisposing = false,
  }) async {
    if (!whileDisposing) _throwIfDisposed();
    if (_modelLifecycleOperation != null) {
      throw LlamaStateException(
        'Cannot $operation while another model lifecycle operation is in progress.',
      );
    }
    // Disposal must be able to join this operation even if it is first called
    // by a synchronous hook inside action. Preserve action's synchronous prefix.
    final lifecycle = Completer<void>();
    final lifecycleOperation = lifecycle.future;
    _modelLifecycleOperation = lifecycleOperation;
    Future<void> run() async {
      try {
        await action();
      } finally {
        if (identical(_modelLifecycleOperation, lifecycleOperation)) {
          _modelLifecycleOperation = null;
        }
      }
    }

    // Joiners resume only after the slot is released, including joiners that
    // subscribed from action's synchronous prefix before this caller could.
    lifecycle.complete(run());
    await lifecycleOperation;
  }

  Future<void> _cleanupFailedLoadState() async {
    _loraLocations.clear();
    _draftLocations.clear();
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
    _throwIfDisposed();
    if (!_isReady) {
      throw LlamaContextException(
        'Engine not ready: no model is loaded. Call LlamaEngine.load or '
        'setModel first.',
      );
    }
    if (requireContext && _contextHandle == null) {
      throw LlamaContextException("Context not initialized.");
    }
  }

  static const String _disposedMessage =
      'The LlamaEngine is disposed. Create a new LlamaEngine.';

  void _throwIfDisposed() {
    if (isDisposed) throw LlamaStateException(_disposedMessage);
  }

  /// Throws when [dispose] was called while a load ran; [dispose] then
  /// unloads what it loaded.
  void _throwIfDisposedDuringLoad() {
    if (isDisposed) throw LlamaStateException(_disposedDuringLoadMessage);
  }

  static const String _disposedDuringLoadMessage =
      'The LlamaEngine was disposed while loading, so the load was undone.';

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

final Expando<BackendGenerationLimit> _rawGenerationLimits =
    Expando<BackendGenerationLimit>();

/// The runtime-reported limit of a completed [LlamaEngine.generate] stream.
///
/// Inspect the original stream after it closes. Null means no reliable limit
/// was reported; cancellation and errors never publish a limit here.
BackendGenerationLimit? rawGenerationLimit(Stream<String> generation) =>
    _rawGenerationLimits[generation];

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
      chatTemplateKwargs: chatTemplateKwargs,
      templateNow: templateNow,
    ).collect();
  }
}

/// [LlamaEngine.load] for the engines built on a [LlamaEngine].
///
/// [operation] names the load, and [assetType] its files, in errors.
/// [companions] are further files of the model. They resolve after the
/// model's own and under the same rules: one combined progress, one cancel
/// token, and credentials for one origin only. Returns the engine and where
/// each companion resolved, in order: a local path, or on a URL-loading
/// backend what the backend fetches.
Future<(LlamaEngine, List<String>)> loadLlamaEngine(
  LlamaModel model, {
  required ModelParams params,
  required ModelLoadOptions download,
  required ModelDownloadProgressCallback? onProgress,
  required ModelFileStore? store,
  required LlamaBackend? backend,
  Iterable<LlamaEngineObserver> observers = const <LlamaEngineObserver>[],
  String operation = 'Model loading',
  String assetType = 'model',
  List<ModelSource> companions = const <ModelSource>[],
}) async {
  final engine = LlamaEngine(
    backend ?? LlamaBackend(),
    modelResolver: store?.resolver,
    modelDownloadManager: store?.downloadManager,
    observers: observers,
  );
  try {
    final locations = await engine._setModel(
      model,
      params,
      download,
      onProgress,
      operation: operation,
      assetType: assetType,
      companions: companions,
    );
    return (engine, locations);
  } catch (_) {
    try {
      await engine.dispose();
    } catch (_) {
      // The load failure is the error the caller needs.
    }
    rethrow;
  }
}

/// Low-level hooks that `TextToSpeechEngine`, `DecisionEngine` and backend
/// integrations use on a [LlamaEngine].
///
/// Applications should use those engines instead. These are extension
/// members, not instance members, so a subclass of [LlamaEngine] cannot
/// override them: fake a backend that implements the matching `Backend*`
/// interface instead.
extension LlamaEngineBackendHooks on LlamaEngine {
  /// Internal model handle.
  int? get modelHandle => _modelHandle;

  /// Internal context handle.
  int? get contextHandle => _contextHandle;

  /// Returns backend-native text-to-speech capabilities for the loaded model.
  ///
  /// This is the low-level integration hook used by `TextToSpeechEngine`.
  /// Applications should prefer that typed API instead of calling this method
  /// directly.
  Future<BackendTextToSpeechCapabilities>
  get backendTextToSpeechCapabilities async {
    if (isDisposed) {
      return const BackendTextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason: LlamaEngine._disposedMessage,
      );
    }
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

  /// Returns decision-model support for the loaded model.
  ///
  /// This is the low-level integration hook used by `DecisionEngine`.
  /// Applications should prefer `DecisionEngine.capabilitiesFor`.
  Future<BackendDecisionCapabilities> get backendDecisionCapabilities async {
    if (isDisposed) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason: LlamaEngine._disposedMessage,
      );
    }
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
}

/// Cancelled by its own [cancel] or when any of [_checks] reports
/// cancellation, so the engine can stop a download for its own reasons
/// without cancelling a caller's token.
class _LinkedCancelToken extends ModelDownloadCancelToken {
  final List<bool Function()> _checks;

  _LinkedCancelToken(this._checks);

  @override
  bool get isCancelled => super.isCancelled || _checks.any((check) => check());
}
