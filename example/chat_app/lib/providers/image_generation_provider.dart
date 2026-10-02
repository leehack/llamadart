import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../models/image_model_profile.dart';
import '../services/app_exit_coordinator.dart';
import '../services/image_generation_service.dart';
import '../services/image_model_service.dart';

/// What the image screen is doing.
enum ImageGenerationStage {
  /// Ready for a new request.
  idle,

  /// Loading the selected model before its first generation.
  loadingModel,

  /// Generating an image.
  generating,
}

/// The last generated image, encoded as PNG.
class GeneratedImageOutput {
  /// PNG bytes.
  final Uint8List png;

  /// Seed the image used.
  final int seed;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Generation time, excluding model load.
  final Duration elapsed;

  /// Model that generated the image.
  final ImageModelProfile profile;

  /// Creates a generated image output.
  const GeneratedImageOutput({
    required this.png,
    required this.seed,
    required this.width,
    required this.height,
    required this.elapsed,
    required this.profile,
  });
}

Future<Uint8List> _encodePngInBackground(GeneratedImage image) =>
    compute(_encodePng, image);

Uint8List _encodePng(GeneratedImage image) => image.toPng();

/// Whether [error] is the engine's memory preflight refusal.
///
/// The library has no dedicated exception type for it, so this matches the
/// stable phrasing of the `LlamaModelException` thrown by
/// `ImageGenerationEngine.load` when the model does not fit ("The image model
/// needs about ... GiB ..., but only ... GiB is available (...)"). Other load
/// failures, such as a missing file, must not match.
bool isImageMemoryRefusal(Object error) =>
    error is LlamaModelException &&
    error.message.startsWith('The image model needs about ') &&
    error.message.contains(' GiB is available (');

/// State and engine lifecycle of the image-generation screen.
///
/// The model loads on the first generation and stays loaded while it stays
/// selected; selecting another model, deleting it, or disposing this
/// provider frees it. With an [AppExitCoordinator], the app's exit waits for
/// that release, even after this provider is disposed. It can be loaded next
/// to a chat model: the library's memory check refuses a model that does not
/// fit, and the provider then offers to unload the chat model.
class ImageGenerationProvider extends ChangeNotifier {
  /// Output sizes offered by the screen.
  static const List<int> sizes = <int>[256, 512];

  /// Largest step count offered by the screen.
  static const int maxSteps = 4;

  final ImageGenerationService _generationService;
  final ImageModelService _modelService;
  final bool Function() _isChatModelLoaded;
  final Future<void> Function()? _unloadChatModel;
  final Future<Uint8List> Function(GeneratedImage image) _encode;
  final AppExitCoordinator? _exitCoordinator;
  VoidCallback? _removeExitRelease;

  /// Models the screen offers.
  final List<ImageModelProfile> profiles;

  ImageGenerationCapabilities? _capabilities;
  final Map<String, InstalledImageModel> _installed =
      <String, InstalledImageModel>{};
  late ImageModelProfile _selected;
  int _size = 512;
  late int _steps;

  String? _installingId;
  CancelToken? _installToken;
  double _installProgress = 0;
  bool _isVerifyingInstall = false;
  String? _deletingId;

  ImageGenerator? _generator;
  String? _generatorModelId;
  Future<ImageGenerator?>? _loading;
  Future<void>? _initializing;
  final Set<Future<void>> _disposals = <Future<void>>{};
  Future<void>? _shutdown;
  ImageGenerationRun? _run;
  ImageGenerationStage _stage = ImageGenerationStage.idle;
  bool _cancelRequested = false;
  ImageGenerationProgressEvent? _progress;
  GeneratedImageOutput? _output;
  String? _status;
  String? _error;
  bool _canUnloadChatModel = false;
  bool _disposed = false;

  /// Creates the provider. Tests inject fakes for the services.
  ImageGenerationProvider({
    ImageGenerationService? generationService,
    ImageModelService? modelService,
    bool Function()? isChatModelLoaded,
    Future<void> Function()? unloadChatModel,
    Future<Uint8List> Function(GeneratedImage image)? encodePng,
    AppExitCoordinator? exitCoordinator,
    this.profiles = ImageModelProfile.defaultModels,
  }) : _generationService = generationService ?? ImageGenerationService(),
       _modelService = modelService ?? ImageModelService(),
       _isChatModelLoaded = isChatModelLoaded ?? _never,
       _unloadChatModel = unloadChatModel,
       _encode = encodePng ?? _encodePngInBackground,
       _exitCoordinator = exitCoordinator {
    _removeExitRelease = exitCoordinator?.addRelease(shutdown);
    _selected = profiles.firstWhere(
      (profile) => profile.isRecommended,
      orElse: () => profiles.first,
    );
    _steps = _selected.defaults.steps;
  }

  static bool _never() => false;

  /// Whether [initialize] has probed the runtime.
  bool get isInitialized => _capabilities != null;

  /// Whether this build and device can generate images.
  bool get isSupported =>
      _capabilities?.isSupported == true && _modelService.isSupported;

  /// Why images cannot be generated, when [isSupported] is false.
  String? get unsupportedReason {
    final capabilities = _capabilities;
    if (capabilities == null || isSupported) {
      return null;
    }
    return capabilities.unsupportedReason ??
        'Image models cannot be installed on this platform.';
  }

  /// Device the runtime would use, such as `MTL0` or `CPU`.
  String? get runtimeBackend => _capabilities?.backendName;

  /// Model selected for generation.
  ImageModelProfile get selectedProfile => _selected;

  /// Whether every file of [profile] is installed.
  bool isInstalled(ImageModelProfile profile) =>
      _installed.containsKey(profile.id);

  /// Whether the selected model is installed.
  bool get isSelectedInstalled => isInstalled(_selected);

  /// Model being downloaded, if any.
  String? get installingId => _installingId;

  /// Download progress from 0 to 1.
  double get installProgress => _installProgress;

  /// Whether the download is being verified.
  bool get isVerifyingInstall => _isVerifyingInstall;

  /// Output width and height in pixels.
  int get size => _size;

  /// Sampling steps for the next generation.
  int get steps => _steps;

  /// Current stage.
  ImageGenerationStage get stage => _stage;

  /// Whether a load or generation is running.
  bool get isBusy => _stage != ImageGenerationStage.idle;

  bool get _isLocked => isBusy || _deletingId != null;

  bool get _isClosed => _disposed || _shutdown != null;

  /// Latest progress event of the running generation.
  ImageGenerationProgressEvent? get progress => _progress;

  /// Last generated image.
  GeneratedImageOutput? get output => _output;

  /// Informational message, such as a cancellation.
  String? get status => _status;

  /// Last error, as the library reported it.
  String? get error => _error;

  /// Whether [error] was the engine's memory refusal while a chat model is
  /// loaded, so unloading the chat model may free enough memory.
  bool get canUnloadChatModel =>
      _canUnloadChatModel && _unloadChatModel != null;

  /// Model family and device of the loaded engine, such as `SD 2.x on MTL0`.
  String? get loadedEngineLabel {
    final generator = _generator;
    if (generator == null) {
      return null;
    }
    final capabilities = generator.capabilities;
    return [
      capabilities.modelVersion,
      capabilities.backendName,
    ].whereType<String>().join(' on ');
  }

  /// Whether a generation can start now.
  bool get canGenerate =>
      isSupported && isSelectedInstalled && !_isLocked && !_isClosed;

  /// Whether a model can be selected or deleted now.
  bool get canChangeModel => !_isLocked;

  /// Probes the runtime and finds installed models.
  ///
  /// The first probe in a process can take seconds while the GPU backend
  /// compiles its shaders; it runs off the UI isolate, and
  /// [isInitialized] stays false until it finishes.
  ///
  /// Does nothing once the provider is disposed or shut down: a check
  /// started then would still be running when the app exits.
  Future<void> initialize() async {
    if (_isClosed) {
      return;
    }
    await (_initializing = _initialize());
  }

  Future<void> _initialize() async {
    ImageGenerationCapabilities capabilities;
    try {
      capabilities = await _generationService.checkRuntime();
    } catch (error) {
      capabilities = ImageGenerationCapabilities(
        isSupported: false,
        unsupportedReason: _describe(error),
      );
    }
    if (_disposed) {
      return;
    }
    if (capabilities.isSupported && _modelService.isSupported) {
      try {
        for (final profile in profiles) {
          final installed = await _modelService.resolve(profile);
          if (installed != null) {
            _installed[profile.id] = installed;
          }
        }
      } catch (error) {
        _error = 'Could not read installed image models: ${_describe(error)}';
      }
      if (_disposed) {
        return;
      }
      if (!isSelectedInstalled) {
        final firstInstalled = profiles.where(isInstalled).firstOrNull;
        if (firstInstalled != null) {
          _select(firstInstalled);
        }
      }
    }
    _capabilities = capabilities;
    _notify();
  }

  /// Selects [profile], freeing the engine of the previous model.
  Future<void> selectModel(ImageModelProfile profile) async {
    if (profile.id == _selected.id || _isLocked) {
      return;
    }
    _select(profile);
    _error = null;
    _status = null;
    _notify();
    await releaseEngine();
  }

  void _select(ImageModelProfile profile) {
    _selected = profile;
    _steps = profile.defaults.steps;
  }

  /// Sets the output size.
  void setSize(int value) {
    if (!sizes.contains(value) || value == _size) {
      return;
    }
    _size = value;
    _notify();
  }

  /// Sets the sampling steps.
  void setSteps(int value) {
    final clamped = value.clamp(1, maxSteps);
    if (clamped == _steps) {
      return;
    }
    _steps = clamped;
    _notify();
  }

  /// Downloads [profile], resuming a partial download.
  Future<void> installModel(ImageModelProfile profile) async {
    if (_installingId != null || !isSupported || isInstalled(profile)) {
      return;
    }
    final cancelToken = CancelToken();
    _installToken = cancelToken;
    _installingId = profile.id;
    _installProgress = 0;
    _isVerifyingInstall = false;
    _error = null;
    _notify();
    try {
      final installed = await _modelService.install(
        profile,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (!identical(_installToken, cancelToken)) {
            return;
          }
          _isVerifyingInstall = false;
          _installProgress = progress;
          _notify();
        },
        onVerifying: () {
          if (!identical(_installToken, cancelToken)) {
            return;
          }
          _isVerifyingInstall = true;
          _notify();
        },
      );
      _installed[profile.id] = installed;
      if (!isBusy && !isSelectedInstalled) {
        _select(profile);
      }
    } catch (error) {
      if (!cancelToken.isCancelled) {
        _error = 'Could not download ${profile.name}: ${_describe(error)}';
      }
    } finally {
      if (identical(_installToken, cancelToken)) {
        _installToken = null;
        _installingId = null;
        _installProgress = 0;
        _isVerifyingInstall = false;
      }
      _notify();
    }
  }

  /// Cancels the running download; its partial file resumes next time.
  void cancelInstall() {
    _installToken?.cancel('Image model download cancelled by the user.');
  }

  /// Deletes the files of [profile], freeing its engine first.
  Future<void> deleteModel(ImageModelProfile profile) async {
    if (_isLocked || _installingId == profile.id) {
      return;
    }
    _deletingId = profile.id;
    _notify();
    try {
      if (_generatorModelId == profile.id) {
        await releaseEngine();
      }
      await _modelService.delete(profile);
      _installed.remove(profile.id);
      if (profile.id == _selected.id) {
        _output = null;
      }
    } catch (error) {
      _error = 'Could not delete ${profile.name}: ${_describe(error)}';
    } finally {
      _deletingId = null;
      _notify();
    }
  }

  /// Generates one image with the selected model, loading it first when
  /// needed. A `null` [seed] picks a random one.
  Future<void> generate({
    required String prompt,
    String negativePrompt = '',
    int? seed,
  }) async {
    final installed = _installed[_selected.id];
    if (installed == null || _isLocked || _isClosed || !isSupported) {
      return;
    }
    _error = null;
    _status = null;
    _canUnloadChatModel = false;
    _cancelRequested = false;
    _progress = null;
    _stage = _generatorModelId == installed.profile.id
        ? ImageGenerationStage.generating
        : ImageGenerationStage.loadingModel;
    _notify();

    StreamSubscription<ImageGenerationEvent>? subscription;
    try {
      final generator = await _ensureGenerator(installed);
      if (_disposed) {
        return;
      }
      if (generator == null || _cancelRequested) {
        _status = 'Generation cancelled.';
        return;
      }
      _stage = ImageGenerationStage.generating;
      _notify();

      final run = generator.generate(
        ImageGenerationRequest(
          prompt: prompt,
          negativePrompt: negativePrompt,
          width: _size,
          height: _size,
          steps: _steps,
          seed: seed,
        ),
      );
      _run = run;
      subscription = run.events.listen((event) {
        if (event is ImageGenerationProgressEvent) {
          _progress = event;
          _notify();
        }
      }, onError: (Object _, StackTrace _) {});
      final completion = await run.done;
      switch (completion.state) {
        case ImageGenerationCompletionState.completed:
          final result = completion.result!;
          final image = result.images.first;
          final png = await _encode(image);
          _output = GeneratedImageOutput(
            png: png,
            seed: result.seed,
            width: image.width,
            height: image.height,
            elapsed: result.elapsed,
            profile: installed.profile,
          );
        case ImageGenerationCompletionState.cancelled:
          _status = 'Generation cancelled.';
        case ImageGenerationCompletionState.failed:
          _error = _describe(completion.error!);
      }
    } catch (error) {
      _error = _describe(error);
      _canUnloadChatModel = isImageMemoryRefusal(error) && _isChatModelLoaded();
    } finally {
      // The run closes its events before `done` completes, so this only
      // detaches the listener.
      unawaited(subscription?.cancel());
      _run = null;
      _progress = null;
      _stage = ImageGenerationStage.idle;
      _notify();
    }
  }

  /// The loaded engine for [installed], or `null` when the provider closed
  /// before it loaded.
  Future<ImageGenerator?> _ensureGenerator(
    InstalledImageModel installed,
  ) async {
    final current = _generator;
    if (current != null && _generatorModelId == installed.profile.id) {
      return current;
    }
    await releaseEngine();
    final loading = _loadGenerator(installed);
    _loading = loading;
    try {
      return await loading;
    } finally {
      if (identical(_loading, loading)) {
        _loading = null;
      }
    }
  }

  Future<ImageGenerator?> _loadGenerator(InstalledImageModel installed) async {
    final generator = await _generationService.load(
      installed.toGenerationModel(),
      options: installed.profile.options,
    );
    if (_isClosed) {
      await _trackDisposal(generator.dispose());
      return null;
    }
    _generator = generator;
    _generatorModelId = installed.profile.id;
    return generator;
  }

  /// Cancels the running generation. A model that is still loading finishes
  /// loading, then no generation starts.
  void cancelGeneration() {
    if (!isBusy) {
      return;
    }
    _cancelRequested = true;
    _run?.cancel();
  }

  /// Unloads the chat model after a memory refusal, so the next generation
  /// has its memory. A failure is reported in [error], not thrown.
  Future<void> unloadChatModel() async {
    final unload = _unloadChatModel;
    if (unload == null) {
      return;
    }
    try {
      await unload();
    } catch (error) {
      _canUnloadChatModel = false;
      _error = 'Could not unload the chat model: ${_describe(error)}';
      _notify();
      return;
    }
    _canUnloadChatModel = false;
    _error = null;
    _status = 'Chat model unloaded. Generate again to retry.';
    _notify();
  }

  /// Frees the loaded model, cancelling a running generation.
  Future<void> releaseEngine() async {
    final generator = _generator;
    _generator = null;
    _generatorModelId = null;
    if (generator != null) {
      await _trackDisposal(generator.dispose());
    }
  }

  // [shutdown] must also wait for a disposal that [releaseEngine] started
  // earlier, such as during a model switch, because the engine is no longer
  // in [_generator] while it is being freed.
  Future<void> _trackDisposal(Future<void> disposal) {
    _disposals.add(disposal);
    return disposal.whenComplete(() => _disposals.remove(disposal));
  }

  /// Frees every model before the app exits: waits for a runtime check or a
  /// load in flight and for a release already running, then frees the
  /// loaded model. No model loads afterwards; the app exit that calls this
  /// is never cancelled. Repeated calls share one release.
  Future<void> shutdown() => _shutdown ??= _releaseForShutdown();

  Future<void> _releaseForShutdown() async {
    _notify();
    cancelGeneration();
    // The runtime check runs in its own isolate and initializes the GPU
    // backend, so the app must not exit in the middle of it.
    await _initializing;
    try {
      await _loading;
    } catch (_) {
      // A failed load left nothing to free.
    }
    try {
      await releaseEngine();
    } catch (error) {
      _logReleaseError(error);
    }
    await Future.wait([
      for (final disposal in _disposals) disposal.catchError(_logReleaseError),
    ]);
  }

  void _logReleaseError(Object error) =>
      debugPrint('Could not free an image model before exit: $error');

  String _describe(Object error) =>
      error is LlamaException ? error.message : error.toString();

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _installToken?.cancel('Image model download cancelled on screen exit.');
    _removeExitRelease?.call();
    final release = shutdown();
    final exitCoordinator = _exitCoordinator;
    if (exitCoordinator != null) {
      exitCoordinator.track(release);
    } else {
      unawaited(release);
    }
    super.dispose();
  }
}
