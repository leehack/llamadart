import 'dart:async';
import 'dart:math';

import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import '../exceptions.dart';
import 'generated_image.dart';
import 'image_generation_driver.dart';
import 'image_generation_driver_stub.dart'
    if (dart.library.io) 'image_generation_driver_io.dart';
import 'image_generation_events.dart';
import 'image_generation_model.dart';
import 'image_generation_progress.dart';
import 'image_generation_request.dart';

/// Image-generation support of the runtime, and of a loaded engine.
class ImageGenerationCapabilities {
  /// Whether images can be generated.
  final bool isSupported;

  /// Actionable reason when [isSupported] is false.
  final String? unsupportedReason;

  /// Device the engine runs on, such as `MTL0`, `Vulkan0` or `CPU`. For
  /// `ImageGenerationEngine.runtimeCapabilities`, the device
  /// `ImageGenerationDevice.auto` would pick.
  final String? backendName;

  /// Every device the runtime reports, such as `MTL0`, `BLAS` and `CPU`.
  final List<String> deviceNames;

  /// stable-diffusion.cpp version of the bundled runtime.
  final String? runtimeVersion;

  /// Model family the runtime detected, such as `SD 2.x`; `null` before a
  /// model is loaded.
  final String? modelVersion;

  /// Whether a running generation can be cancelled.
  final bool supportsCancellation;

  /// Maximum concurrent generations: one per process.
  final int maxConcurrentTasks;

  /// Creates a capability snapshot.
  const ImageGenerationCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.backendName,
    this.deviceNames = const <String>[],
    this.runtimeVersion,
    this.modelVersion,
    this.supportsCancellation = false,
    this.maxConcurrentTasks = 0,
  });
}

/// A cancellable image generation.
class ImageGenerationTask {
  final StreamController<ImageGenerationEvent> _events =
      StreamController<ImageGenerationEvent>();
  final Completer<ImageGenerationCompletion> _done =
      Completer<ImageGenerationCompletion>();
  final void Function() _onCancel;
  bool _cancelled = false;

  ImageGenerationTask._(this._onCancel);

  /// Progress events followed by one [ImageGenerationFinalEvent].
  ///
  /// Single-subscription. A failure is emitted as a stream error and also
  /// reported by [done]; a cancelled task closes the stream without a final
  /// event.
  Stream<ImageGenerationEvent> get events => _events.stream;

  /// Completes once the task succeeds, is cancelled, or fails.
  Future<ImageGenerationCompletion> get done => _done.future;

  /// Whether cancellation has been requested.
  bool get isCancellationRequested => _cancelled;

  /// Requests cancellation. Calling this more than once, or after the task
  /// finished, is safe.
  ///
  /// The runtime stops before its next sampling step or before decoding, so
  /// the task can take up to one step to report
  /// [ImageGenerationCompletionState.cancelled].
  void cancel() {
    if (_cancelled || _done.isCompleted) {
      return;
    }
    _cancelled = true;
    _onCancel();
  }

  void _add(ImageGenerationEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _finish(ImageGenerationCompletion completion) {
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
    if (!_done.isCompleted) {
      _done.complete(completion);
    }
  }
}

/// Experimental on-device text-to-image generation through the opt-in
/// stable_diffusion runtime (stable-diffusion.cpp).
///
/// The app must bundle the runtime by adding `stable_diffusion` to
/// `hooks.user_defines.llamadart.llamadart_native_runtimes`. It runs on
/// Android arm64 (CPU), iOS and macOS (Metal), and Linux and Windows (CPU or
/// Vulkan). On the web and other platforms [load] throws
/// [LlamaUnsupportedException].
///
/// The model runs in a worker isolate, so the calling isolate stays
/// responsive. stable-diffusion.cpp reports progress through one
/// process-wide callback, so only one generation or model load can run at a
/// time; a second one throws [LlamaStateException]. The guard covers engines
/// in the same isolate; do not generate from engines in different isolates
/// at the same time.
///
/// Runtime logs are not forwarded to `LlamaLogger` yet: stable-diffusion.cpp
/// passes log text that is only valid during a call made from its own
/// threads.
///
/// ```dart
/// final engine = await ImageGenerationEngine.load(
///   ImageGenerationModel.sdxs('sdxs-512-tinySDdistilled_Q8_0.gguf'),
/// );
/// final result = await engine.generateImage(
///   const ImageGenerationRequest(prompt: 'a red fox in autumn leaves'),
/// );
/// final png = result.images.first.toPng();
/// await engine.dispose();
/// ```
class ImageGenerationEngine {
  static Object? _activeOperation;
  static final Random _seedRandom = Random();

  /// The loaded model.
  final ImageGenerationModel model;

  /// The runtime settings the model was loaded with.
  final ImageGenerationOptions options;

  final ImageGenerationSession _session;
  final StableDiffusionRuntimeStatus _runtime;
  final String _backendName;
  ImageGenerationTask? _activeTask;
  Future<void>? _disposal;

  ImageGenerationEngine._(
    this.model,
    this.options,
    this._session,
    this._runtime,
    this._backendName,
  );

  /// Probes the bundled runtime without loading a model.
  ///
  /// Reports unsupported when the runtime is not bundled, the platform or CPU
  /// is not supported, or on the web.
  ///
  /// The first probe in a process, here or in [load], initializes the GPU
  /// backend on the calling isolate. With an empty Metal shader cache that
  /// compiles ggml's Metal library: about 16 s on an M4 Max. macOS keeps the
  /// result in its shader cache, so later launches take under 0.5 s. To keep
  /// a UI isolate responsive, make the first call from another isolate, such
  /// as with `Isolate.run`; later calls then return at once.
  static ImageGenerationCapabilities runtimeCapabilities() {
    final status = _driver.probe();
    final reason = status.unavailableReason;
    if (reason != null) {
      return ImageGenerationCapabilities(
        isSupported: false,
        unsupportedReason: reason.message,
      );
    }
    return ImageGenerationCapabilities(
      isSupported: true,
      backendName: _backendNameFor(ImageGenerationDevice.auto, status.devices),
      deviceNames: [for (final device in status.devices) device.name],
      runtimeVersion: status.version,
      supportsCancellation: true,
      maxConcurrentTasks: 1,
    );
  }

  /// Loads [model] and returns a ready engine.
  ///
  /// Weights load eagerly, so the first [generate] does not pay for them. The
  /// first GPU generation in a process still compiles GPU pipelines; see
  /// [warmUp].
  ///
  /// Before loading, when [ImageGenerationOptions.checkMemory] is set and the
  /// platform reports it, the model's estimated memory
  /// (a quarter more than its file sizes, plus 256 MiB) is compared
  /// with the memory available: `MemAvailable` on Android and Linux, the
  /// app's remaining memory limit on iOS, and physical memory on macOS.
  /// Windows reports nothing and is not checked. A model that does not fit
  /// throws [LlamaModelException] naming both figures, instead of letting the
  /// system kill the app.
  ///
  /// Throws:
  /// - [LlamaUnsupportedException] when the runtime is unavailable (see
  ///   [runtimeCapabilities]), or when [ImageGenerationDevice.gpu] is
  ///   requested and the runtime reports no GPU.
  /// - [LlamaModelException] when a file is missing, the model does not fit,
  ///   or the runtime cannot load it as an image model.
  /// - [LlamaStateException] while another generation or load is running.
  static Future<ImageGenerationEngine> load(
    ImageGenerationModel model, {
    ImageGenerationOptions options = const ImageGenerationOptions(),
  }) async {
    final driver = _driver;
    final runtime = driver.probe()..throwIfUnavailable();
    final backendName = _backendNameFor(options.device, runtime.devices);
    if (options.threads < 0) {
      throw LlamaImageGenerationException(
        'ImageGenerationOptions.threads must be 0 or greater.',
        options.threads,
      );
    }
    final files = model.files.paths;
    if (files['model'] == null && files['diffusionModel'] == null) {
      throw LlamaModelException(
        'An image-generation model needs a model or diffusionModel file.',
      );
    }
    var weightBytes = 0;
    for (final MapEntry(key: role, value: path) in files.entries) {
      final size = path.trim().isEmpty ? null : driver.fileSize(path);
      if (size == null) {
        throw LlamaModelException(
          'Image-generation $role file not found: "$path".',
        );
      }
      weightBytes += size;
    }
    if (options.checkMemory) {
      _checkMemory(weightBytes, driver.memoryBudget());
    }

    final operation = _acquireOperation();
    try {
      final session = await driver.start(
        ImageGenerationSessionConfig(
          files: files,
          backend: switch (options.device) {
            ImageGenerationDevice.auto => null,
            ImageGenerationDevice.cpu => 'cpu',
            ImageGenerationDevice.gpu => 'gpu',
          },
          threads: options.threads,
        ),
      );
      return ImageGenerationEngine._(
        model,
        options,
        session,
        runtime,
        backendName,
      );
    } finally {
      _releaseOperation(operation);
    }
  }

  /// Support of this engine; unsupported once disposed.
  ImageGenerationCapabilities get capabilities {
    if (_disposal != null) {
      return const ImageGenerationCapabilities(
        isSupported: false,
        unsupportedReason: 'The ImageGenerationEngine is disposed.',
      );
    }
    return ImageGenerationCapabilities(
      isSupported: true,
      backendName: _backendName,
      deviceNames: [for (final device in _runtime.devices) device.name],
      runtimeVersion: _runtime.version,
      modelVersion: _session.modelVersion,
      supportsCancellation: true,
      maxConcurrentTasks: 1,
    );
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposal != null;

  /// Starts generating the images [request] describes.
  ///
  /// Unset steps and guidance come from [ImageGenerationModel.defaults], and
  /// an unset seed is picked at random and reported in the result.
  ///
  /// Throws [LlamaImageGenerationException] for an invalid request, including
  /// invalid steps or guidance from [ImageGenerationModel.defaults], and
  /// [LlamaStateException] after [dispose] or while another generation or
  /// load is running. A runtime failure after the task starts, such as an
  /// aborted GPU command buffer, fails the task with
  /// [LlamaInferenceException]; the engine stays usable.
  ImageGenerationTask generate(ImageGenerationRequest request) {
    final effective = _resolve(request);
    final operation = _acquireOperation();
    final resolved = ImageGenerationSessionRequest(
      prompt: effective.prompt,
      negativePrompt: effective.negativePrompt,
      width: effective.width,
      height: effective.height,
      steps: effective.steps!,
      guidanceScale: effective.guidanceScale!,
      seed: effective.seed ?? _seedRandom.nextInt(0x7FFFFFFF),
      count: effective.count,
    );
    final task = ImageGenerationTask._(_session.cancel);
    _activeTask = task;
    unawaited(_run(task, resolved, operation));
    return task;
  }

  /// Generates the images [request] describes and returns them.
  ///
  /// Throws what [generate] throws, the failure of the task, or
  /// [LlamaStateException] when [dispose] cancels it.
  Future<ImageGenerationResult> generateImage(
    ImageGenerationRequest request,
  ) async {
    final completion = await generate(request).done;
    return switch (completion.state) {
      ImageGenerationCompletionState.completed => completion.result!,
      ImageGenerationCompletionState.failed => throw completion.error!,
      ImageGenerationCompletionState.cancelled => throw LlamaStateException(
        'Image generation was cancelled because the engine was disposed.',
      ),
    };
  }

  /// Compiles the GPU pipelines a [width] by [height] generation needs, by
  /// running one single-step generation and discarding its image, so the
  /// first real image does not pay for them.
  ///
  /// ggml compiles each GPU pipeline the first time a process uses it. That
  /// made the first image take 12 s on Linux Vulkan and 45 s on Windows
  /// Vulkan (NVIDIA L4) instead of under 0.6 s, and added about 0.5 s on an
  /// M4 Max with an empty Metal shader cache. GPU drivers and macOS cache
  /// compiled shaders on disk, so later launches are faster.
  ///
  /// Use the size the app will generate: ggml picks some pipelines by tensor
  /// size, so another size can still compile more.
  ///
  /// On the CPU there is nothing to compile, so this returns at once.
  ///
  /// The warm-up holds the one-operation slot like [generate]: await it
  /// before the next [generate] or [load]. [dispose] cancels a running
  /// warm-up, which then completes normally.
  ///
  /// Throws [LlamaImageGenerationException] for an invalid size or invalid
  /// model defaults, [LlamaStateException] after [dispose] or while another
  /// generation or load is running, and [LlamaInferenceException] when the
  /// runtime fails the generation.
  Future<void> warmUp({int width = 512, int height = 512}) async {
    final request = ImageGenerationRequest(
      prompt: 'warm-up',
      width: width,
      height: height,
      steps: 1,
      seed: 0,
    );
    if (!_isGpu(_backendName)) {
      // Fail where a GPU warm-up would, so callers behave the same on both.
      _resolve(request);
      _releaseOperation(_acquireOperation());
      return;
    }
    final completion = await generate(request).done;
    if (completion.state == ImageGenerationCompletionState.failed) {
      throw completion.error!;
    }
  }

  /// Cancels a running generation, waits for it to stop, and frees the
  /// model. Calling this more than once is safe.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    final task = _activeTask;
    if (task != null) {
      task.cancel();
      await task.done;
    }
    await _session.dispose();
  }

  /// [request] with the model defaults applied, after checking that it can
  /// run.
  ImageGenerationRequest _resolve(ImageGenerationRequest request) {
    if (_disposal != null) {
      throw LlamaStateException('The ImageGenerationEngine is disposed.');
    }
    // Validate after applying the model defaults: custom defaults are not
    // checked when the model is built, and the runtime crashes on 0 steps.
    final effective = ImageGenerationRequest(
      prompt: request.prompt,
      negativePrompt: request.negativePrompt,
      width: request.width,
      height: request.height,
      steps: request.steps ?? model.defaults.steps,
      guidanceScale: request.guidanceScale ?? model.defaults.guidanceScale,
      seed: request.seed,
      count: request.count,
    );
    validateImageGenerationRequest(effective);
    return effective;
  }

  Future<void> _run(
    ImageGenerationTask task,
    ImageGenerationSessionRequest request,
    Object operation,
  ) async {
    late final ImageGenerationCompletion completion;
    try {
      final tracker = ImageGenerationProgressTracker(
        steps: request.steps,
        imageCount: request.count,
      );
      task._add(tracker.start());
      final stopwatch = Stopwatch()..start();
      final images = await _session.generate(request, (step, steps) {
        if (task.isCancellationRequested) {
          // stable-diffusion.cpp clears the cancel flag when a generation
          // starts, so a cancel that arrived before then is re-applied here.
          _session.cancel();
          return;
        }
        tracker.onNativeProgress(step, steps).forEach(task._add);
      });
      stopwatch.stop();
      if (task.isCancellationRequested) {
        completion = const ImageGenerationCompletion.cancelled();
        return;
      }
      if (images == null || images.isEmpty) {
        throw LlamaInferenceException(
          'stable-diffusion.cpp could not generate the image. It reports no '
          'reason; causes include running out of memory and an aborted GPU '
          'command buffer. The engine can run the next request.',
        );
      }
      final result = ImageGenerationResult(
        images: images,
        seed: request.seed,
        elapsed: stopwatch.elapsed,
      );
      task._add(ImageGenerationFinalEvent(result));
      completion = ImageGenerationCompletion.completed(result);
    } catch (error, stackTrace) {
      if (task.isCancellationRequested) {
        completion = const ImageGenerationCompletion.cancelled();
        return;
      }
      final failure = error is LlamaException
          ? error
          : LlamaInferenceException('Image generation failed.', error);
      task._events.addError(failure, stackTrace);
      completion = ImageGenerationCompletion.failed(failure);
    } finally {
      // Release before `done` completes so a caller awaiting it can start
      // the next generation.
      _releaseOperation(operation);
      if (identical(_activeTask, task)) {
        _activeTask = null;
      }
      task._finish(completion);
    }
  }

  static ImageGenerationDriver get _driver =>
      debugImageGenerationDriverOverride ?? createImageGenerationDriver();

  static Object _acquireOperation() {
    if (_activeOperation != null) {
      throw LlamaStateException(
        'Another image generation or image model load is running. '
        'stable-diffusion.cpp reports progress through one process-wide '
        'callback, so only one can run at a time.',
      );
    }
    return _activeOperation = Object();
  }

  static void _releaseOperation(Object operation) {
    if (identical(_activeOperation, operation)) {
      _activeOperation = null;
    }
  }

  static void _checkMemory(
    int weightBytes,
    ImageGenerationMemoryBudget? budget,
  ) {
    if (budget == null) {
      return;
    }
    final required = estimateImageGenerationMemoryBytes(weightBytes);
    if (required <= budget.bytes) {
      return;
    }
    throw LlamaModelException(
      'The image model needs about ${_gib(required)} GiB '
      '(${_gib(weightBytes)} GiB of weights plus working memory), but only '
      '${_gib(budget.bytes)} GiB is available (${budget.source}). Use a '
      'smaller or more quantized model, free memory, or set '
      'ImageGenerationOptions.checkMemory to false to try anyway.',
    );
  }

  static String _gib(int bytes) {
    final gib = bytes / (1 << 30);
    return gib.toStringAsFixed(gib < 10 ? 2 : 1);
  }

  static String _backendNameFor(
    ImageGenerationDevice device,
    List<StableDiffusionDevice> devices,
  ) {
    final gpu = devices.map((d) => d.name).where(_isGpu).firstOrNull;
    final cpu = devices
        .where((d) => d.name.toUpperCase() == 'CPU')
        .firstOrNull
        ?.name;
    return switch (device) {
      ImageGenerationDevice.auto => gpu ?? cpu ?? 'CPU',
      ImageGenerationDevice.cpu => cpu ?? 'CPU',
      ImageGenerationDevice.gpu =>
        gpu ??
            (throw LlamaUnsupportedException(
              'ImageGenerationDevice.gpu needs a GPU, and the stable_diffusion '
              'runtime reports only ${devices.map((d) => d.name).join(', ')}. '
              'Android runs on the CPU; on Linux and Windows set '
              'hooks.user_defines.llamadart.'
              'llamadart_stable_diffusion_backends to [vulkan]. Use '
              'ImageGenerationDevice.auto or cpu otherwise.',
            )),
    };
  }

  static bool _isGpu(String deviceName) {
    final name = deviceName.toLowerCase();
    return _gpuDevicePrefixes.any(name.startsWith);
  }

  /// ggml registry names of GPU devices. The published runtimes use Metal
  /// (`MTL0`) and Vulkan (`Vulkan0`).
  static const List<String> _gpuDevicePrefixes = [
    'mtl',
    'metal',
    'vulkan',
    'cuda',
    'rocm',
    'gpuopencl',
    'opencl',
    'sycl',
  ];
}

/// Estimated peak memory, in bytes, of an image model whose files total
/// [weightBytes]: the weights plus a quarter for compute buffers, plus
/// 256 MiB for the text encoder, VAE decode and runtime.
///
/// Measured peaks at 512x512 fit it: SDXS Q8 (651 MB of weights) used 1.06
/// to 1.55 GB of process memory, including the app, on iPhone, Mac and
/// Android.
int estimateImageGenerationMemoryBytes(int weightBytes) =>
    weightBytes + weightBytes ~/ 4 + (256 << 20);
