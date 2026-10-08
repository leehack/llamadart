import 'dart:ffi';

import '../../core/exceptions.dart';
import '../../hook/native_release_pins.dart';
import 'stable_diffusion_bindings.dart' as sd;

const _stableDiffusionAsset = 'package:llamadart/stable_diffusion';

typedef _ProgressEnableNative = Void Function();
typedef _ProgressReadNative =
    Size Function(
      Uint64,
      Pointer<sd.sd_dart_progress_t>,
      Size,
      Pointer<Uint64>,
    );
typedef _NewContextNative =
    Pointer<sd.sd_ctx_t> Function(Pointer<sd.sd_ctx_params_t>);
typedef _GenerateImageNative =
    Bool Function(
      Pointer<sd.sd_ctx_t>,
      Pointer<sd.sd_img_gen_params_t>,
      Pointer<Pointer<sd.sd_image_t>>,
      Pointer<Int>,
    );
typedef _CancelGenerationNative =
    Void Function(Pointer<sd.sd_ctx_t>, UnsignedInt);
typedef _ExitFreeNative = Void Function(Pointer<Void>);
typedef _GpuDeviceMemoryNative =
    Int32 Function(Int32, Pointer<sd.sd_dart_gpu_device_memory_t>);
typedef _LogEnableNative = Void Function();
typedef _LogSetLevelNative = Void Function(Int32);
typedef _LogReadNative =
    Uint64 Function(Uint64, Pointer<Char>, Size, Pointer<Int32>, Pointer<Size>);
typedef _LogDroppedNative = Uint64 Function();
typedef _LastErrorNative = Size Function(Pointer<Char>, Size);

/// Every native call an image worker makes.
///
/// The `sd_dart_` members are stable-diffusion-native's wrapper functions
/// (`src/sd_dart_wrapper.h` there), which exist from
/// [minimumNativeRelease] on:
///
/// - The library records progress reports itself and [progressRead] copies
///   them out, so Dart gives stable-diffusion.cpp no callback. A callback
///   into the VM from the generating thread aborts the process when the VM
///   is already shutting down.
/// - [newContext] tracks the context in a registry inside the creating call,
///   [generateImage] is a call that registry waits for, and on Apple
///   platforms the library frees what is still tracked during C `exit`,
///   before ggml-metal's static destructor, which aborts while a Metal buffer
///   is allocated. The registry waits only for those two calls and
///   [exitFree]: any other native call on a context that is in flight when
///   the process exits is freed under (`doc/llama_cpp_exit_teardown.md`).
///
/// [tryResolve] binds the six of them through the addresses it resolves, so
/// the calls exist only when the runtime exports all six. An older runtime
/// has no way to report progress without a Dart callback, so image
/// generation is unsupported on it rather than falling back.
///
/// [log] and [gpuDeviceMemory] are the functions [optionalNativeRelease]
/// added. Each group is bound only when the runtime exports all of it, and is
/// `null` otherwise: a runtime between the two releases still generates
/// images, without the runtime's log and its reason for a failed load, and
/// without the memory check of a Vulkan GPU.
///
/// `sd_dart_exit_teardown`, `sd_dart_exit_call_begin`,
/// `sd_dart_exit_call_end`, `sd_dart_exit_track` and `sd_dart_exit_untrack`
/// are left unbound: an isolate killed after a native call never reaches the
/// call that would follow it, and a Dart program that returns from `main`
/// after teardown waits forever for its blocked isolates.
///
/// The remaining members are upstream functions that return at once. A new
/// call on a context that can run for longer than the registry's 250 ms
/// settle time needs an `sd_dart_` wrapper in stable-diffusion-native first.
final class StableDiffusionCalls {
  /// Creates the calls from functions.
  const StableDiffusionCalls({
    required this.progressEnable,
    required this.progressRead,
    required this.newContext,
    required this.generateImage,
    required this.cancelGeneration,
    required this.exitFree,
    required this.exitFreeAddress,
    required this.contextParamsInit,
    required this.supportsImageGeneration,
    required this.modelVersionName,
    required this.imageGenerationParamsInit,
    required this.freeImages,
    this.log,
    this.gpuDeviceMemory,
  });

  /// The oldest `stable-diffusion-native` release that exports the `sd_dart_`
  /// functions.
  static const String minimumNativeRelease = 'v0.2.0-1';

  /// The `sd_dart_` functions [tryResolve] needs the runtime to export.
  static const List<String> wrapperSymbols = [
    'sd_dart_progress_enable',
    'sd_dart_progress_read',
    'sd_dart_new_sd_ctx',
    'sd_dart_generate_image',
    'sd_dart_cancel_generation',
    'sd_dart_exit_free',
  ];

  /// The `stable-diffusion-native` release that added [logSymbols] and
  /// [deviceMemorySymbols].
  static const String optionalNativeRelease = 'v0.2.0-2';

  /// The `sd_dart_` functions of [log].
  static const List<String> logSymbols = [
    'sd_dart_log_enable',
    'sd_dart_log_set_level',
    'sd_dart_log_read',
    'sd_dart_log_dropped',
    'sd_dart_last_error',
  ];

  /// The `sd_dart_` function of [gpuDeviceMemory].
  static const List<String> deviceMemorySymbols = ['sd_dart_gpu_device_memory'];

  /// Resolves the calls from the bundled runtime, or returns `null` when it
  /// does not export every one of [wrapperSymbols]. [log] and
  /// [gpuDeviceMemory] are `null` when it does not export theirs.
  ///
  /// [symbol] replaces the lookup: it returns the address of the function
  /// exported under a name, and throws [ArgumentError] when there is none.
  static StableDiffusionCalls? tryResolve({
    Pointer<NativeType> Function(String name)? symbol,
  }) {
    try {
      return StableDiffusionCalls._fromSymbols(symbol ?? symbolAddress);
    } on ArgumentError {
      return null;
    }
  }

  /// The address of the function the bundled runtime exports as [name], one
  /// of [wrapperSymbols], [logSymbols] or [deviceMemorySymbols]; throws
  /// [ArgumentError] when it exports none.
  static Pointer<NativeType> symbolAddress(String name) => switch (name) {
    'sd_dart_progress_enable' =>
      Native.addressOf<NativeFunction<_ProgressEnableNative>>(
        sd.sd_dart_progress_enable,
      ),
    'sd_dart_progress_read' =>
      Native.addressOf<NativeFunction<_ProgressReadNative>>(
        sd.sd_dart_progress_read,
      ),
    'sd_dart_new_sd_ctx' => Native.addressOf<NativeFunction<_NewContextNative>>(
      sd.sd_dart_new_sd_ctx,
    ),
    'sd_dart_generate_image' =>
      Native.addressOf<NativeFunction<_GenerateImageNative>>(
        sd.sd_dart_generate_image,
      ),
    'sd_dart_cancel_generation' =>
      Native.addressOf<NativeFunction<_CancelGenerationNative>>(
        _cancelGeneration,
      ),
    'sd_dart_exit_free' => Native.addressOf<NativeFunction<_ExitFreeNative>>(
      sd.sd_dart_exit_free,
    ),
    'sd_dart_log_enable' => Native.addressOf<NativeFunction<_LogEnableNative>>(
      sd.sd_dart_log_enable,
    ),
    'sd_dart_log_set_level' =>
      Native.addressOf<NativeFunction<_LogSetLevelNative>>(
        sd.sd_dart_log_set_level,
      ),
    'sd_dart_log_read' => Native.addressOf<NativeFunction<_LogReadNative>>(
      sd.sd_dart_log_read,
    ),
    'sd_dart_log_dropped' =>
      Native.addressOf<NativeFunction<_LogDroppedNative>>(
        sd.sd_dart_log_dropped,
      ),
    'sd_dart_last_error' => Native.addressOf<NativeFunction<_LastErrorNative>>(
      sd.sd_dart_last_error,
    ),
    'sd_dart_gpu_device_memory' =>
      Native.addressOf<NativeFunction<_GpuDeviceMemoryNative>>(
        sd.sd_dart_gpu_device_memory,
      ),
    _ => throw ArgumentError.value(name, 'name', 'not bound'),
  };

  // Every wrapper is called through the address resolved here, so none can be
  // bound without being part of the probe.
  factory StableDiffusionCalls._fromSymbols(
    Pointer<NativeType> Function(String name) symbol,
  ) {
    Pointer<NativeFunction<T>> function<T extends Function>(String name) =>
        symbol(name).cast();
    // A group whose functions the runtime does not all export.
    T? optional<T>(T Function() bind) {
      try {
        return bind();
      } on ArgumentError {
        return null;
      }
    }

    final exitFree = function<_ExitFreeNative>('sd_dart_exit_free');
    final void Function(Pointer<sd.sd_ctx_t>, int) cancelGeneration =
        function<_CancelGenerationNative>(
          'sd_dart_cancel_generation',
        ).asFunction();
    return StableDiffusionCalls(
      progressEnable: function<_ProgressEnableNative>(
        'sd_dart_progress_enable',
      ).asFunction(),
      progressRead: function<_ProgressReadNative>(
        'sd_dart_progress_read',
      ).asFunction(isLeaf: true),
      newContext: function<_NewContextNative>(
        'sd_dart_new_sd_ctx',
      ).asFunction(),
      generateImage: function<_GenerateImageNative>(
        'sd_dart_generate_image',
      ).asFunction(),
      cancelGeneration: (context) =>
          cancelGeneration(context, sd.sd_cancel_mode_t.SD_CANCEL_ALL.value),
      exitFree: exitFree.asFunction(),
      exitFreeAddress: exitFree.cast(),
      contextParamsInit: sd.sd_ctx_params_init,
      supportsImageGeneration: sd.sd_ctx_supports_image_generation,
      modelVersionName: sd.sd_get_model_version_name,
      imageGenerationParamsInit: sd.sd_img_gen_params_init,
      freeImages: sd.free_sd_images,
      log: optional(
        () => StableDiffusionLogCalls(
          enable: function<_LogEnableNative>('sd_dart_log_enable').asFunction(),
          setLevel: function<_LogSetLevelNative>(
            'sd_dart_log_set_level',
          ).asFunction(),
          read: function<_LogReadNative>('sd_dart_log_read').asFunction(),
          dropped: function<_LogDroppedNative>(
            'sd_dart_log_dropped',
          ).asFunction(),
          lastError: function<_LastErrorNative>(
            'sd_dart_last_error',
          ).asFunction(),
        ),
      ),
      gpuDeviceMemory: optional(
        () => function<_GpuDeviceMemoryNative>(
          'sd_dart_gpu_device_memory',
        ).asFunction(),
      ),
    );
  }

  /// `sd_dart_progress_enable`: from then on the library records every
  /// progress report in the process, loads included, and prints no progress
  /// bars. Its first call is not synchronized with a load or generation on
  /// another thread.
  final void Function() progressEnable;

  /// `sd_dart_progress_read`: copies up to `capacity` reports whose sequence
  /// is greater than `after` into `reports`, oldest first, returns how many,
  /// and writes the newest recorded sequence to `latest`. The library keeps
  /// the [progressHistory] most recent reports; when older ones are gone the
  /// first report returned is not `after + 1`. A leaf call: it takes no lock
  /// and never waits.
  final int Function(
    int after,
    Pointer<sd.sd_dart_progress_t> reports,
    int capacity,
    Pointer<Uint64> latest,
  )
  progressRead;

  /// The number of reports [progressRead] keeps.
  static const int progressHistory = 4095;

  /// `sd_dart_new_sd_ctx`: `new_sd_ctx` that tracks the context before it
  /// returns; `nullptr` on failure.
  final Pointer<sd.sd_ctx_t> Function(Pointer<sd.sd_ctx_params_t> params)
  newContext;

  /// `sd_dart_generate_image`: `generate_image` as a call exit teardown
  /// cancels and waits for.
  final bool Function(
    Pointer<sd.sd_ctx_t> context,
    Pointer<sd.sd_img_gen_params_t> params,
    Pointer<Pointer<sd.sd_image_t>> imagesOut,
    Pointer<Int> countOut,
  )
  generateImage;

  /// `sd_dart_cancel_generation` with `SD_CANCEL_ALL`: callable from any
  /// thread while another generates, and does nothing for a context that was
  /// already freed.
  final void Function(Pointer<sd.sd_ctx_t> context) cancelGeneration;

  /// `sd_dart_exit_free`: frees a context [newContext] returned, once; does
  /// nothing for one that exit teardown already freed.
  final void Function(Pointer<Void> context) exitFree;

  /// The address of [exitFree], for `IsolateShutdownReleases`.
  final Pointer<NativeFinalizerFunction> exitFreeAddress;

  /// `sd_ctx_params_init`.
  final void Function(Pointer<sd.sd_ctx_params_t> params) contextParamsInit;

  /// `sd_ctx_supports_image_generation`.
  final bool Function(Pointer<sd.sd_ctx_t> context) supportsImageGeneration;

  /// `sd_get_model_version_name`: a static string, or `nullptr`.
  final Pointer<Char> Function(Pointer<sd.sd_ctx_t> context) modelVersionName;

  /// `sd_img_gen_params_init`.
  final void Function(Pointer<sd.sd_img_gen_params_t> params)
  imageGenerationParamsInit;

  /// `free_sd_images`.
  final void Function(Pointer<sd.sd_image_t> images, int count) freeImages;

  /// The runtime's log recorder, or `null` on a runtime older than
  /// [optionalNativeRelease].
  final StableDiffusionLogCalls? log;

  /// `sd_dart_gpu_device_memory`, or `null` on a runtime older than
  /// [optionalNativeRelease]: writes the memory of GPU `deviceIndex`, or of
  /// the device a context with no backend uses for
  /// `SD_DART_GPU_DEFAULT_DEVICE`, to `out` and returns an
  /// `sd_dart_gpu_status`.
  ///
  /// The first query in a process initializes the GPU backend, which on Metal
  /// with an empty shader cache takes many seconds, so it never runs on a UI
  /// isolate. It is a call exit teardown waits for, with the bound of a load.
  final int Function(
    int deviceIndex,
    Pointer<sd.sd_dart_gpu_device_memory_t> out,
  )?
  gpuDeviceMemory;
}

/// The log recorder of the stable_diffusion runtime: the library copies each
/// message of stable-diffusion.cpp and ggml into a buffer of its own and Dart
/// reads them, so Dart gives the runtime no log callback either.
///
/// [read] and [lastError] wait up to 100 ms for a thread that is copying a
/// message, so they are not leaf calls and run in the worker isolate. All of
/// them stay valid during and after exit teardown.
final class StableDiffusionLogCalls {
  /// Creates the calls from functions.
  const StableDiffusionLogCalls({
    required this.enable,
    required this.setLevel,
    required this.read,
    required this.dropped,
    required this.lastError,
  });

  /// `sd_dart_log_enable`: from then on the library records the messages of
  /// every call in the process, and ggml's no longer go to stderr. Its first
  /// call is not synchronized with a load, a generation or a device query on
  /// another thread.
  final void Function() enable;

  /// `sd_dart_log_set_level`: the lowest `sd_log_level_t` recorded;
  /// `SD_LOG_ERROR + 1` records nothing.
  final void Function(int level) setLevel;

  /// `sd_dart_log_read`: copies the oldest message whose sequence is greater
  /// than `after` to `text` and returns its sequence, or 0 when there is
  /// none. A sequence other than `after + 1` means the messages in between
  /// left the buffer.
  final int Function(
    int after,
    Pointer<Char> text,
    int capacity,
    Pointer<Int32> level,
    Pointer<Size> length,
  )
  read;

  /// `sd_dart_log_dropped`: messages that left the buffer unread, or could
  /// not be recorded.
  final int Function() dropped;

  /// `sd_dart_last_error`: the error messages recorded while the calling
  /// thread's most recent [StableDiffusionCalls.newContext] or
  /// [StableDiffusionCalls.generateImage] ran, joined by line breaks; returns
  /// the bytes of the whole text. Empty unless [enable] was called before
  /// that call.
  final int Function(Pointer<Char> text, int capacity) lastError;
}

/// The error for a stable_diffusion runtime that does not export every
/// function of [StableDiffusionCalls].
LlamaUnsupportedException stableDiffusionWrapperUnsupported() =>
    LlamaUnsupportedException(
      'The stable_diffusion runtime does not export the sd_dart_ functions '
      'image generation needs for progress without a Dart callback and for '
      'freeing its contexts at process exit '
      '(${StableDiffusionCalls.wrapperSymbols.join(', ')}): '
      'stable-diffusion-native ${StableDiffusionCalls.minimumNativeRelease} '
      'or later is required. Bundle the package-pinned release '
      '$stableDiffusionReleaseTag.',
    );

// The generated binding takes the enum, so it has no address of its own.
@Native<_CancelGenerationNative>(
  symbol: 'sd_dart_cancel_generation',
  assetId: _stableDiffusionAsset,
)
external void _cancelGeneration(Pointer<sd.sd_ctx_t> context, int mode);
