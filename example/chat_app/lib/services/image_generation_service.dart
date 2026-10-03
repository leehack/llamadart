import 'package:llamadart/llamadart.dart';

/// App-level seam over [ImageGenerationEngine], so the image screen can be
/// tested without the native stable_diffusion runtime.
abstract interface class ImageGenerationService {
  /// Creates the service backed by [ImageGenerationEngine].
  factory ImageGenerationService() = _EngineImageGenerationService;

  /// Probes the bundled runtime without loading a model or blocking the UI
  /// isolate.
  Future<ImageGenerationCapabilities> checkRuntime();

  /// Loads [model]; throws what [ImageGenerationEngine.load] throws.
  Future<ImageGenerator> load(ImageGenerationModel model);
}

/// A loaded image model.
abstract interface class ImageGenerator {
  /// Support of the loaded engine, including the device it runs on.
  ImageGenerationCapabilities get capabilities;

  /// Starts one generation; throws what [ImageGenerationEngine.generate]
  /// throws.
  Future<ImageGenerationRun> generate(ImageGenerationRequest request);

  /// Cancels a running generation and frees the model.
  Future<void> dispose();
}

/// One running generation, mirroring [ImageGenerationTask].
abstract interface class ImageGenerationRun {
  /// Progress events followed by one final event; never an error.
  Stream<ImageGenerationEvent> get events;

  /// Completes once the generation succeeds, is cancelled, or fails; never
  /// with an error.
  Future<ImageGenerationCompletion> get done;

  /// Requests cancellation.
  void cancel();
}

class _EngineImageGenerationService implements ImageGenerationService {
  @override
  Future<ImageGenerationCapabilities> checkRuntime() =>
      ImageGenerationEngine.checkRuntime();

  @override
  Future<ImageGenerator> load(ImageGenerationModel model) async =>
      _EngineImageGenerator(await ImageGenerationEngine.load(model));
}

class _EngineImageGenerator implements ImageGenerator {
  final ImageGenerationEngine _engine;

  _EngineImageGenerator(this._engine);

  @override
  ImageGenerationCapabilities get capabilities => _engine.capabilities;

  @override
  Future<ImageGenerationRun> generate(ImageGenerationRequest request) async =>
      _TaskImageGenerationRun(await _engine.generate(request));

  @override
  Future<void> dispose() => _engine.dispose();
}

class _TaskImageGenerationRun implements ImageGenerationRun {
  final ImageGenerationTask _task;

  _TaskImageGenerationRun(this._task);

  @override
  Stream<ImageGenerationEvent> get events => _task.events;

  @override
  Future<ImageGenerationCompletion> get done => _task.done;

  @override
  void cancel() => _task.cancel();
}
