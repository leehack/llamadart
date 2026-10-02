import 'dart:async';
import 'dart:math';

import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import '../exceptions.dart';
import '../models/download/model_download_manager.dart';
import '../models/model_load_options.dart';
import '../models/model_resolver.dart';
import '../models/model_source.dart';
import '../models/model_target_file.dart';
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
///   ImageGenerationModel(
///     files: ImageGenerationModelFiles(
///       model: ModelSource.path('sdxs-512-tinySDdistilled_Q8_0.gguf'),
///     ),
///     defaults: const ImageGenerationDefaults(steps: 1, guidanceScale: 1),
///   ),
/// );
/// final result = await engine.generateImage(
///   const ImageGenerationRequest(prompt: 'a red fox in autumn leaves'),
/// );
/// final png = result.images.first.toPng();
/// await engine.dispose();
/// ```
class ImageGenerationEngine {
  static Object? _activeOperation;
  static Future<StableDiffusionRuntimeStatus>? _runningProbe;
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

  /// Probes the bundled runtime without loading a model, on the calling
  /// isolate.
  ///
  /// Reports unsupported when the runtime is not bundled, the platform or CPU
  /// is not supported, or on the web.
  ///
  /// The first probe in a process initializes the GPU backend. With an empty
  /// Metal shader cache that compiles ggml's Metal library: about 16 s on an
  /// M4 Max, during which this call blocks the calling isolate. macOS keeps
  /// the result in its shader cache, so later launches take under 0.5 s, and
  /// later probes in the process return at once. A call made while
  /// [checkRuntime] or [load] is still probing blocks until that probe
  /// finishes. From a UI isolate, use [checkRuntime] instead.
  static ImageGenerationCapabilities runtimeCapabilities() =>
      _capabilitiesOf(_driver.probe());

  /// Probes the bundled runtime like [runtimeCapabilities], without blocking
  /// the calling isolate.
  ///
  /// On native platforms the probe runs in a short-lived isolate, so the
  /// first probe's GPU backend initialization (see [runtimeCapabilities])
  /// does not freeze a UI isolate; the calling isolate can still pause once
  /// for up to about 0.5 s while the probe isolate loads the runtime library.
  /// Calls on this isolate, including [load], share a probe that is still
  /// running, and all of them get its result or its error. On the web it
  /// completes with the same unsupported result as [runtimeCapabilities].
  static Future<ImageGenerationCapabilities> checkRuntime() async =>
      _capabilitiesOf(await _probeRuntime(_driver));

  static ImageGenerationCapabilities _capabilitiesOf(
    StableDiffusionRuntimeStatus status,
  ) {
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

  static Future<StableDiffusionRuntimeStatus> _probeRuntime(
    ImageGenerationDriver driver,
  ) {
    final running = _runningProbe;
    if (running != null) {
      return running;
    }
    late final Future<StableDiffusionRuntimeStatus> probe;
    probe = driver.probeInBackground().whenComplete(() {
      if (identical(_runningProbe, probe)) {
        _runningProbe = null;
      }
    });
    return _runningProbe = probe;
  }

  /// Loads [model] and returns a ready engine.
  ///
  /// Each file of [model] comes from its `ModelSource`, resolved like
  /// `LlamaEngine.loadModelSource`: [modelResolver] (by default
  /// [DefaultModelResolver]) resolves it, and [modelDownloadManager] (by
  /// default [DefaultModelDownloadManager]) checks a local file, or
  /// downloads a remote one into the model cache, resuming an interrupted
  /// download and reusing a cached file. Files resolve one at a time, in
  /// role order. [loadOptions] applies to every remote file: cache policy
  /// and directory, authentication, resume, retries and the cancel token.
  /// Local files take only the cancel token.
  ///
  /// [onProgress] reports the files together: `receivedBytes` counts every
  /// file resolved so far, including cached and local ones, plus the bytes
  /// of the current download; `totalBytes` is the combined size of all files
  /// once every size is known (from the start for local files, otherwise
  /// when each download starts), and `null` before.
  ///
  /// Weights load eagerly, so the first [generate] does not pay for them. The
  /// first GPU generation in a process still compiles GPU pipelines; see
  /// [warmUp].
  ///
  /// The runtime probe that comes first runs off the calling isolate, as in
  /// [checkRuntime]. It, the [options] checks and a check that every local
  /// file exists run before anything downloads.
  ///
  /// Before loading, when [ImageGenerationOptions.checkMemory] is set and the
  /// device's memory is known, the model's estimated memory (a quarter more
  /// than its file sizes, plus 512 MiB) is compared with the memory
  /// available: on Android the larger of `MemAvailable` and half of physical
  /// memory less what the app already holds, `MemAvailable` on Linux, the
  /// app's remaining memory limit on iOS, and physical memory on macOS,
  /// capped on Metal by the GPU's recommended working set. Windows, and GPUs
  /// other than Metal (whose device memory the runtime does not report), are
  /// not checked. A model that does not fit throws [LlamaModelException]
  /// naming both figures, instead of letting the system kill the app.
  ///
  /// Throws:
  /// - [LlamaUnsupportedException] when the runtime is unavailable (see
  ///   [runtimeCapabilities]), including on the web; when
  ///   [ImageGenerationDevice.gpu] is requested and the runtime reports no
  ///   GPU; and when [loadOptions] sets [ModelLoadOptions.sha256], which
  ///   cannot apply to several files.
  /// - [LlamaModelException] when a file is missing, the model does not fit,
  ///   or the runtime cannot load it as an image model; and what
  ///   [modelDownloadManager] throws for a failed download.
  /// - [LlamaStateException] when [loadOptions]' cancel token cancels the
  ///   load, and while another generation or load is running.
  static Future<ImageGenerationEngine> load(
    ImageGenerationModel model, {
    ImageGenerationOptions options = const ImageGenerationOptions(),
    ModelLoadOptions loadOptions = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
    ModelResolver? modelResolver,
    ModelDownloadManager? modelDownloadManager,
  }) async {
    final driver = _driver;
    final runtime = await _probeRuntime(driver)
      ..throwIfUnavailable();
    final backendName = _backendNameFor(options.device, runtime.devices);
    if (options.threads < 0) {
      throw LlamaImageGenerationException(
        'ImageGenerationOptions.threads must be 0 or greater.',
        options.threads,
      );
    }
    if (loadOptions.sha256 != null) {
      throw LlamaUnsupportedException(
        'ImageGenerationEngine.load loads several files, so '
        'ModelLoadOptions.sha256 cannot apply to them. Leave it unset.',
      );
    }
    final sources = model.files.sources;
    if (sources['model'] == null && sources['diffusionModel'] == null) {
      throw LlamaModelException(
        'An image-generation model needs a model or diffusionModel file.',
      );
    }
    final knownSizes = <String, int>{};
    for (final MapEntry(key: role, value: source) in sources.entries) {
      if (source.isLocal) {
        knownSizes[role] = _fileSize(driver, role, source.path!);
      }
    }

    final files = await _resolveFiles(
      sources,
      knownSizes,
      loadOptions,
      onProgress,
      modelResolver ?? const DefaultModelResolver(),
      modelDownloadManager ?? DefaultModelDownloadManager(),
    );
    if (loadOptions.cancelToken?.isCancelled ?? false) {
      throw LlamaStateException('Image model loading was cancelled.');
    }
    var weightBytes = 0;
    for (final MapEntry(key: role, value: path) in files.entries) {
      weightBytes += _fileSize(driver, role, path);
    }
    if (options.checkMemory) {
      _checkMemory(
        weightBytes,
        driver.memoryBudget(switch (backendName) {
          _ when _isMetal(backendName) => ImageGenerationComputeDevice.metal,
          _ when _isGpu(backendName) => ImageGenerationComputeDevice.otherGpu,
          _ => ImageGenerationComputeDevice.cpu,
        }),
      );
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
          flashAttention:
              options.flashAttention ?? _flashAttentionByDefault(backendName),
          vaeDirectConvolution:
              options.vaeDirectConvolution ??
              _vaeDirectConvolutionByDefault(
                backendName,
                hasTaesd: files.containsKey('taesd'),
              ),
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
  /// Unset width, height, steps, guidance, sampler, scheduler and flow shift
  /// come from [ImageGenerationModel.defaults], and an unset seed is picked
  /// at random and reported in the result.
  ///
  /// Throws [LlamaImageGenerationException] for an invalid request, including
  /// an invalid size, steps, guidance or flow shift from
  /// [ImageGenerationModel.defaults], and
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
      width: effective.width!,
      height: effective.height!,
      steps: effective.steps!,
      guidanceScale: effective.guidanceScale!,
      seed: effective.seed ?? _seedRandom.nextInt(0x7FFFFFFF),
      count: effective.count,
      sampler: effective.sampler,
      scheduler: effective.scheduler,
      flowShift: effective.flowShift,
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
  /// size, so another size can still compile more. An unset [width] or
  /// [height] uses the model's (`ImageGenerationDefaults.width` and
  /// `height`), like an unset request size in [generate]. For a model
  /// trained at 1024x1024 the warm-up costs one sampling step and a decode
  /// at that size: 3.0 to 3.8 s for SDXL-Lightning with TAESDXL on an
  /// M4 Max, and the same peak memory as an image, which the memory
  /// check in [load] covers.
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
  Future<void> warmUp({int? width, int? height}) async {
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
      width: request.width ?? model.defaults.width,
      height: request.height ?? model.defaults.height,
      steps: request.steps ?? model.defaults.steps,
      guidanceScale: request.guidanceScale ?? model.defaults.guidanceScale,
      seed: request.seed,
      count: request.count,
      sampler: request.sampler ?? model.defaults.sampler,
      scheduler: request.scheduler ?? model.defaults.scheduler,
      flowShift: request.flowShift ?? model.defaults.flowShift,
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

  static int _fileSize(ImageGenerationDriver driver, String role, String path) {
    final size = path.trim().isEmpty ? null : driver.fileSize(path);
    if (size == null) {
      throw LlamaModelException(
        'Image-generation $role file not found: "$path".',
      );
    }
    return size;
  }

  /// Local paths of [sources], keyed by role, resolved one at a time.
  static Future<Map<String, String>> _resolveFiles(
    Map<String, ModelSource> sources,
    Map<String, int> knownSizes,
    ModelLoadOptions loadOptions,
    ModelDownloadProgressCallback? onProgress,
    ModelResolver resolver,
    ModelDownloadManager manager,
  ) async {
    final sizes = Map<String, int>.of(knownSizes);
    var resolvedBytes = 0;
    void report(int currentBytes) {
      if (onProgress == null) {
        return;
      }
      final total = sizes.length == sources.length
          ? sizes.values.fold<int>(0, (sum, size) => sum + size)
          : null;
      onProgress(
        ModelDownloadProgress(
          receivedBytes: resolvedBytes + currentBytes,
          totalBytes: total,
        ),
      );
    }

    final localOptions = ModelLoadOptions(cancelToken: loadOptions.cancelToken);
    final files = <String, String>{};
    for (final MapEntry(key: role, value: source) in sources.entries) {
      final fileOptions = source.isLocal ? localOptions : loadOptions;
      final fileProgress = onProgress == null
          ? null
          : (ModelDownloadProgress progress) {
              if (progress.totalBytes case final total?) {
                sizes.putIfAbsent(role, () => total);
              }
              report(progress.receivedBytes);
            };
      final target = await resolver.resolve(
        source,
        ModelResolveRequest(options: fileOptions, onProgress: fileProgress),
      );
      final entry = await ensureModelTargetFile(
        manager,
        source,
        target,
        options: fileOptions,
        onProgress: fileProgress,
        assetType: 'image model',
      );
      files[role] = entry.filePath;
      final bytes = entry.bytes ?? sizes[role];
      if (bytes != null) {
        sizes[role] = bytes;
      }
      resolvedBytes += bytes ?? 0;
      report(0);
    }
    return files;
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

  static bool _isMetal(String deviceName) {
    final name = deviceName.toLowerCase();
    return name.startsWith('mtl') || name.startsWith('metal');
  }

  /// Flash attention was measured faster or neutral on the CPU and Metal;
  /// other GPU backends keep the runtime default until measured.
  static bool _flashAttentionByDefault(String backendName) =>
      !_isGpu(backendName) || _isMetal(backendName);

  /// Direct VAE convolutions are much slower on Metal, and gain little with
  /// a tiny autoencoder.
  static bool _vaeDirectConvolutionByDefault(
    String backendName, {
    required bool hasTaesd,
  }) => !_isMetal(backendName) && !hasTaesd;

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
/// 512 MiB for the VAE decode and the runtime.
///
/// Measured process peaks at each model's native size, with the automatic
/// attention and VAE settings, stay under it: SDXS Q8 (0.64 GiB of weights)
/// used 1.30 GiB on Metal and SD-Turbo Q8 (1.88 GiB) 2.66 GiB on the CPU,
/// both on an M4 Max; 1024x1024 SDXL, SD 3.5 Large Turbo, FLUX and Z-Image
/// on Metal stayed 0.5 to 1.6 GiB under it, while SD 3.5 Medium with its
/// full VAE peaked 0.3 GiB above. On five Android phones, loading and
/// generating at 512x512 added at most 1.16 GiB to the app for SDXS, 2.26 GiB
/// for SD-Turbo Q8 with TAESD and 2.64 GiB for SD-Turbo Q8 with its full VAE,
/// against estimates of 1.30, 2.87 and 2.86 GiB. Larger sizes than a model's
/// native one need more, especially on the CPU.
int estimateImageGenerationMemoryBytes(int weightBytes) =>
    weightBytes + weightBytes ~/ 4 + (512 << 20);
