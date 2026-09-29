import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import '../../core/image/generated_image.dart';
import '../../core/image/image_generation_driver.dart';
import 'stable_diffusion_bindings.dart' as sd;

typedef _ProgressCallback = NativeCallable<sd.sd_progress_cb_tFunction>;

/// One stable-diffusion.cpp context running in a dedicated worker isolate.
///
/// Loading and `generate_image` block, so both run in the worker. Progress
/// comes back through a [NativeCallable.listener] owned by the calling
/// isolate, which is safe to invoke from any runtime thread. Cancellation
/// calls `sd_cancel_generation` from the calling isolate, since the worker is
/// blocked inside `generate_image`; the runtime flag is atomic.
final class StableDiffusionImageWorker implements ImageGenerationSession {
  final Isolate _isolate;
  final ReceivePort _replies;
  final StreamIterator<Object?> _replyIterator;
  final SendPort _commands;
  final _ProgressCallback _progress;
  final Pointer<sd.sd_ctx_t> _context;
  void Function(int step, int steps)? _onProgress;
  bool _disposed = false;

  @override
  final String modelVersion;

  StableDiffusionImageWorker._(
    this._isolate,
    this._replies,
    this._replyIterator,
    this._commands,
    this._progress,
    this._context,
    this.modelVersion,
  );

  /// Spawns a worker and loads [config] in it.
  ///
  /// Throws [LlamaModelException] when the runtime cannot load the files as
  /// an image model.
  static Future<StableDiffusionImageWorker> start(
    ImageGenerationSessionConfig config,
  ) async {
    void Function(int step, int steps)? route;
    final progress = _ProgressCallback.listener(
      (int step, int steps, double _, Pointer<Void> _) =>
          route?.call(step, steps),
    );
    final replies = ReceivePort('llamadart-image-generation-replies');
    final iterator = StreamIterator<Object?>(replies);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        (replies.sendPort, config, progress.nativeFunction.address),
        debugName: 'llamadart-image-generation',
        onExit: replies.sendPort,
        onError: replies.sendPort,
      );
      final loaded = _unwrap(await _next(iterator)) as _Loaded;
      final worker = StableDiffusionImageWorker._(
        isolate,
        replies,
        iterator,
        loaded.commands,
        progress,
        Pointer.fromAddress(loaded.context),
        loaded.modelVersion,
      );
      route = (step, steps) => worker._onProgress?.call(step, steps);
      return worker;
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      await iterator.cancel();
      progress.close();
      rethrow;
    }
  }

  @override
  Future<List<GeneratedImage>?> generate(
    ImageGenerationSessionRequest request,
    void Function(int step, int steps) onProgress,
  ) async {
    _onProgress = onProgress;
    try {
      _commands.send(request);
      final reply = _unwrap(await _next(_replyIterator)) as _Generated;
      return reply.images == null
          ? null
          : [
              for (final image in reply.images!)
                GeneratedImage(
                  width: image.width,
                  height: image.height,
                  channels: image.channels,
                  pixels: image.pixels.materialize().asUint8List(),
                ),
            ];
    } finally {
      _onProgress = null;
    }
  }

  @override
  void cancel() {
    if (!_disposed) {
      sd.sd_cancel_generation(_context, sd.sd_cancel_mode_t.SD_CANCEL_ALL);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      _commands.send(const _Dispose());
      _unwrap(await _next(_replyIterator));
    } finally {
      _isolate.kill(priority: Isolate.immediate);
      await _replyIterator.cancel();
      _replies.close();
      // The worker cleared the callback before replying, so nothing calls it.
      _progress.close();
    }
  }

  static Future<Object?> _next(StreamIterator<Object?> replies) async {
    if (!await replies.moveNext()) {
      throw LlamaStateException('The image-generation worker stopped.');
    }
    return replies.current;
  }

  static Object? _unwrap(Object? reply) => switch (reply) {
    _LoadFailure(:final message) => throw LlamaModelException(message),
    null => throw LlamaStateException(
      'The image-generation worker exited unexpectedly.',
    ),
    [final error, _] => throw LlamaStateException(
      'The image-generation worker failed.',
      error,
    ),
    _ => reply,
  };
}

final class _Loaded {
  final SendPort commands;
  final int context;
  final String modelVersion;

  const _Loaded(this.commands, this.context, this.modelVersion);
}

final class _LoadFailure {
  final String message;

  const _LoadFailure(this.message);
}

final class _Dispose {
  const _Dispose();
}

final class _Disposed {
  const _Disposed();
}

final class _ImagePayload {
  final int width;
  final int height;
  final int channels;
  final TransferableTypedData pixels;

  const _ImagePayload(this.width, this.height, this.channels, this.pixels);
}

final class _Generated {
  final List<_ImagePayload>? images;

  const _Generated(this.images);
}

void _workerMain((SendPort, ImageGenerationSessionConfig, int) arguments) {
  final (replies, config, progressAddress) = arguments;
  final progress =
      Pointer<NativeFunction<sd.sd_progress_cb_tFunction>>.fromAddress(
        progressAddress,
      );

  final context = _withProgress(progress, () => _newContext(config));
  if (context == nullptr) {
    replies.send(
      const _LoadFailure(
        'stable-diffusion.cpp could not load the image model files; check '
        'that they form a supported checkpoint and that the device has '
        'enough memory.',
      ),
    );
    return;
  }
  if (!sd.sd_ctx_supports_image_generation(context)) {
    sd.free_sd_ctx(context);
    replies.send(
      const _LoadFailure('The loaded model does not support image generation.'),
    );
    return;
  }

  final commands = ReceivePort('llamadart-image-generation-commands');
  final version = sd.sd_get_model_version_name(context);
  replies.send(
    _Loaded(
      commands.sendPort,
      context.address,
      version == nullptr ? '' : version.cast<Utf8>().toDartString(),
    ),
  );
  commands.listen((command) {
    switch (command) {
      case ImageGenerationSessionRequest():
        replies.send(
          _withProgress(progress, () => _generate(context, command)),
        );
      case _Dispose():
        sd.free_sd_ctx(context);
        commands.close();
        replies.send(const _Disposed());
    }
  });
}

/// Runs [body] with the process-wide progress callback set, so the runtime
/// never prints progress bars to stdout, and clears it before returning.
T _withProgress<T>(
  Pointer<NativeFunction<sd.sd_progress_cb_tFunction>> progress,
  T Function() body,
) {
  sd.sd_set_progress_callback(progress, nullptr);
  try {
    return body();
  } finally {
    sd.sd_set_progress_callback(nullptr, nullptr);
  }
}

Pointer<sd.sd_ctx_t> _newContext(ImageGenerationSessionConfig config) {
  return using((arena) {
    Pointer<Char> text(String? value) =>
        value == null ? nullptr : value.toNativeUtf8(allocator: arena).cast();

    final params = arena<sd.sd_ctx_params_t>();
    sd.sd_ctx_params_init(params);
    final files = config.files;
    params.ref
      ..model_path = text(files['model'])
      ..diffusion_model_path = text(files['diffusionModel'])
      ..vae_path = text(files['vae'])
      ..taesd_path = text(files['taesd'])
      ..clip_l_path = text(files['clipL'])
      ..clip_g_path = text(files['clipG'])
      ..t5xxl_path = text(files['t5xxl'])
      ..backend = text(config.backend)
      // Load every weight now, so a model that does not fit fails the load
      // and progress during generation is only sampling.
      ..eager_load = true;
    if (config.threads > 0) {
      params.ref.n_threads = config.threads;
    }
    return sd.new_sd_ctx(params);
  });
}

_Generated _generate(
  Pointer<sd.sd_ctx_t> context,
  ImageGenerationSessionRequest request,
) {
  return using((arena) {
    final params = arena<sd.sd_img_gen_params_t>();
    sd.sd_img_gen_params_init(params);
    params.ref
      ..prompt = request.prompt.toNativeUtf8(allocator: arena).cast()
      ..negative_prompt = request.negativePrompt
          .toNativeUtf8(allocator: arena)
          .cast()
      ..width = request.width
      ..height = request.height
      ..seed = request.seed
      ..batch_count = request.count;
    params.ref.sample_params
      ..sample_steps = request.steps
      ..guidance.txt_cfg = request.guidanceScale;

    final imagesOut = arena<Pointer<sd.sd_image_t>>();
    final countOut = arena<Int>();
    final ok = sd.generate_image(context, params, imagesOut, countOut);
    final images = imagesOut.value;
    final count = countOut.value;
    try {
      if (!ok || images == nullptr) {
        return const _Generated(null);
      }
      return _Generated([
        for (var i = 0; i < count; i++)
          if (images[i].data != nullptr) _copy(images[i]),
      ]);
    } finally {
      if (images != nullptr) {
        sd.free_sd_images(images, count);
      }
    }
  });
}

_ImagePayload _copy(sd.sd_image_t image) {
  final length = image.width * image.height * image.channel;
  return _ImagePayload(
    image.width,
    image.height,
    image.channel,
    TransferableTypedData.fromList([image.data.asTypedList(length)]),
  );
}
