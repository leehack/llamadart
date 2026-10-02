import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import '../../core/image/generated_image.dart';
import '../../core/image/image_generation_driver.dart';
import '../isolate_shutdown_releases.dart';
import 'stable_diffusion_bindings.dart' as sd;
import 'stable_diffusion_params.dart';

typedef _ProgressCallback = NativeCallable<sd.sd_progress_cb_tFunction>;

/// One stable-diffusion.cpp context running in a dedicated worker isolate.
///
/// Loading and `generate_image` block, so both run in the worker. Progress
/// comes back through a [NativeCallable.listener] owned by the calling
/// isolate, which is safe to invoke from any runtime thread. Cancellation
/// calls `sd_cancel_generation` from the calling isolate, since the worker is
/// blocked inside `generate_image`; the runtime flag is atomic.
///
/// Only a pending reply keeps the calling isolate alive, so a program that
/// ends with a model loaded exits; the worker then frees the model as it shuts
/// down.
final class StableDiffusionImageWorker implements ImageGenerationSession {
  final Isolate _isolate;
  final _Replies _replies;
  final SendPort _commands;
  final _ProgressCallback _progress;
  final Pointer<sd.sd_ctx_t> _context;
  void Function(int step, int steps)? _onProgress;
  bool _disposed = false;
  bool _stopped = false;

  @override
  final String modelVersion;

  StableDiffusionImageWorker._(
    this._isolate,
    this._replies,
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
    )..keepIsolateAlive = false;
    final replies = _Replies();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        (replies.sendPort, config, progress.nativeFunction.address),
        debugName: 'llamadart-image-generation',
        onExit: replies.sendPort,
        onError: replies.sendPort,
      );
      final loaded = _unwrap(await replies.next()) as _Loaded;
      final worker = StableDiffusionImageWorker._(
        isolate,
        replies,
        loaded.commands,
        progress,
        Pointer.fromAddress(loaded.context),
        loaded.modelVersion,
      );
      route = (step, steps) => worker._onProgress?.call(step, steps);
      return worker;
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      await replies.close();
      progress.close();
      rethrow;
    }
  }

  @override
  Future<List<GeneratedImage>?> generate(
    ImageGenerationSessionRequest request,
    void Function(int step, int steps) onProgress,
  ) async {
    if (_stopped) {
      throw LlamaStateException(
        'The image-generation worker stopped; load the model again.',
      );
    }
    _onProgress = onProgress;
    try {
      _commands.send(request);
      final reply = await _reply() as _Generated;
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
      if (!_stopped) {
        _commands.send(const _Dispose());
        await _reply();
      }
    } finally {
      _isolate.kill(priority: Isolate.immediate);
      await _replies.close();
      // The worker cleared the callback before replying, so nothing calls it.
      _progress.close();
    }
  }

  /// The next worker reply, unwrapped. Marks the worker stopped when it has
  /// exited, so later calls fail at once instead of waiting for a reply.
  Future<Object?> _reply() async {
    try {
      return _unwrap(await _replies.next());
    } on LlamaStateException {
      _stopped = true;
      rethrow;
    }
  }

  static Object? _unwrap(Object? reply) => switch (reply) {
    _LoadFailure(:final error) => throw error,
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

/// The error for stable-diffusion.cpp rejecting [files], keyed by runtime
/// role as in `ImageGenerationSessionConfig.files`. Its details list the
/// roles, never the paths.
///
/// The runtime logs its reason only through a callback whose text is gone by
/// the time Dart can read it (stable-diffusion-native#3), so the message
/// names the file roles a split checkpoint is missing.
LlamaModelException stableDiffusionModelLoadFailure(Map<String, String> files) {
  final hints = <String>[
    if (!files.containsKey('model')) ...[
      if (!files.containsKey('vae') && !files.containsKey('taesd'))
        'A split checkpoint (diffusionModel) needs a vae or taesd file; a '
            'single-file checkpoint that includes its VAE, such as an '
            'SD 3.5 Medium GGUF, goes in model instead.',
      if (!_textEncoderRoles.any(files.containsKey))
        'A split checkpoint needs its text encoders: clipL, clipG and t5xxl '
            'for SD 3.5, clipL and t5xxl for FLUX, and llm for Z-Image and '
            'Qwen-Image.',
    ],
  ];
  final message = [
    'stable-diffusion.cpp could not load the image model files.',
    if (hints.isEmpty)
      'Check that they form a checkpoint the runtime supports, that each '
          'file is in its role (a single-file checkpoint goes in model, '
          'standalone diffusion weights in diffusionModel), and that the '
          'device has enough memory.'
    else
      ...hints,
    'The runtime does not report its reason to llamadart yet.',
  ].join(' ');
  return LlamaModelException(message, 'files: ${files.keys.join(', ')}');
}

const List<String> _textEncoderRoles = ['clipL', 'clipG', 't5xxl', 'llm'];

/// The worker's replies, which keep the calling isolate alive only while one
/// is awaited.
final class _Replies {
  _Replies() {
    _port = RawReceivePort(_messages.add, 'llamadart-image-generation-replies')
      ..keepIsolateAlive = false;
  }

  final StreamController<Object?> _messages = StreamController();
  late final StreamIterator<Object?> _iterator = StreamIterator(
    _messages.stream,
  );
  late final RawReceivePort _port;
  int _waiting = 0;

  SendPort get sendPort => _port.sendPort;

  Future<Object?> next() async {
    _waiting++;
    _port.keepIsolateAlive = true;
    try {
      if (!await _iterator.moveNext()) {
        throw LlamaStateException('The image-generation worker stopped.');
      }
      return _iterator.current;
    } finally {
      if (--_waiting == 0) {
        _port.keepIsolateAlive = false;
      }
    }
  }

  Future<void> close() async {
    _port.close();
    await _iterator.cancel();
  }
}

final class _Loaded {
  final SendPort commands;
  final int context;
  final String modelVersion;

  const _Loaded(this.commands, this.context, this.modelVersion);
}

final class _LoadFailure {
  final LlamaModelException error;

  const _LoadFailure(this.error);
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
    replies.send(_LoadFailure(stableDiffusionModelLoadFailure(config.files)));
    return;
  }
  if (!sd.sd_ctx_supports_image_generation(context)) {
    IsolateShutdownReleases.current.release(context);
    sd.free_sd_ctx(context);
    replies.send(
      _LoadFailure(
        LlamaModelException(
          'The loaded model does not support image generation.',
        ),
      ),
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
        final _Generated generated;
        try {
          generated = _withProgress(
            progress,
            () => _generate(context, command),
          );
        } catch (_) {
          // The error ends this isolate, and the calling isolate may still
          // call `sd_cancel_generation` on the context: leak it rather than
          // free it at shutdown.
          IsolateShutdownReleases.current.release(context);
          rethrow;
        }
        replies.send(generated);
      case _Dispose():
        IsolateShutdownReleases.current.release(context);
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
    final params = arena<sd.sd_ctx_params_t>();
    sd.sd_ctx_params_init(params);
    applyStableDiffusionContextParams(params, config, arena);
    final context = sd.new_sd_ctx(params);
    IsolateShutdownReleases.current.hold(
      ShutdownStage.model,
      Native.addressOf<NativeFunction<Void Function(Pointer<sd.sd_ctx_t>)>>(
        sd.free_sd_ctx,
      ).cast(),
      context,
    );
    return context;
  });
}

_Generated _generate(
  Pointer<sd.sd_ctx_t> context,
  ImageGenerationSessionRequest request,
) {
  return using((arena) {
    final params = arena<sd.sd_img_gen_params_t>();
    sd.sd_img_gen_params_init(params);
    applyStableDiffusionGenerationParams(params, request, arena);

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
