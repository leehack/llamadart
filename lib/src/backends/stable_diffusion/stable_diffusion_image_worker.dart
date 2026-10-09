import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import '../../core/image/generated_image.dart';
import '../../core/image/image_generation_driver.dart';
import '../../core/llama_logger.dart';
import '../../core/models/config/log_level.dart';
import '../isolate_shutdown_releases.dart';
import '../worker_log_message.dart';
import 'stable_diffusion_bindings.dart' as sd;
import 'stable_diffusion_calls.dart';
import 'stable_diffusion_log.dart';
import 'stable_diffusion_params.dart';

/// Resolves the native calls of a worker; `null` when the runtime lacks them.
typedef StableDiffusionCallsResolver = StableDiffusionCalls? Function();

/// Starts the timer that polls progress during a generation.
typedef StableDiffusionProgressTimer =
    Timer Function(Duration interval, void Function(Timer timer) poll);

/// One stable-diffusion.cpp context running in a dedicated worker isolate.
///
/// Loading and `generate_image` block, so both run in the worker. The runtime
/// records its progress reports and the calling isolate reads them on a
/// timer: Dart gives stable-diffusion.cpp no callback, because a callback
/// from the generating thread into a VM that is shutting down aborts the
/// process. Cancellation calls `sd_dart_cancel_generation` from the calling
/// isolate, since the worker is blocked inside the generation.
///
/// The runtime's log is read without a callback too, but by the worker: a
/// read can wait 100 ms, which the calling isolate must not. The worker reads
/// what the runtime recorded after its load, after each generation and when
/// it is disposed, and sends it to the calling isolate, which logs it through
/// [LlamaLogger]. On a runtime without [StableDiffusionCalls.log] nothing is
/// read.
///
/// Only a pending reply keeps the calling isolate alive, so a program that
/// ends with a model loaded exits; the worker then frees the model as it shuts
/// down.
final class StableDiffusionImageWorker implements ImageGenerationSession {
  /// How often a running [generate] reads the recorded progress. A cancel
  /// that arrived before the runtime started generating is applied again at
  /// the same rate.
  static const Duration progressPollInterval = Duration(milliseconds: 50);

  /// Reports one read asks for.
  static const int _reportsPerRead = 64;

  /// Reads one poll makes at most, so a runtime that reports faster than the
  /// calling isolate reads cannot keep it in the poll. Together with
  /// [_reportsPerRead] it covers the reports the runtime keeps.
  static const int _readsPerPoll = 64;

  /// Where the workers of this isolate have read the runtime's log to. The
  /// log is the process's, so each read continues where the last one ended.
  static StableDiffusionLogPosition _logPosition = (after: 0, dropped: 0);

  /// Starts reading the log from its beginning again, for a test that
  /// replaces the runtime.
  static void debugResetLogPositionForTesting() =>
      _logPosition = (after: 0, dropped: 0);

  final Isolate _isolate;
  final _Replies _replies;
  final SendPort _commands;
  final StableDiffusionCalls _calls;
  final StableDiffusionProgressTimer _progressTimer;
  final Pointer<sd.sd_ctx_t> _context;
  bool _cancelRequested = false;
  bool _disposed = false;
  bool _stopped = false;

  @override
  final String modelVersion;

  StableDiffusionImageWorker._(
    this._isolate,
    this._replies,
    this._commands,
    this._calls,
    this._progressTimer,
    this._context,
    this.modelVersion,
  );

  /// Spawns a worker and loads [config] in it.
  ///
  /// [resolveCalls] runs once in the calling isolate and once in the worker;
  /// [progressTimer] starts the progress poll of each [generate]. Tests
  /// replace both.
  ///
  /// The runtime records its messages from [logLevel] up, and the worker
  /// forwards them to this isolate's [LlamaLogger]; at [LlamaLogLevel.none]
  /// nothing is recorded or read. The level is the process's: the worker
  /// started last sets it.
  ///
  /// Throws [LlamaModelException] when the runtime cannot load the files as
  /// an image model, with the runtime's reason when it gives one, and
  /// [LlamaUnsupportedException] when the runtime does not export the
  /// functions of [StableDiffusionCalls].
  static Future<StableDiffusionImageWorker> start(
    ImageGenerationSessionConfig config, {
    StableDiffusionCallsResolver resolveCalls = StableDiffusionCalls.tryResolve,
    StableDiffusionProgressTimer progressTimer = Timer.periodic,
    LlamaLogLevel logLevel = LlamaLogLevel.none,
  }) async {
    final calls = resolveCalls();
    if (calls == null) {
      throw stableDiffusionWrapperUnsupported();
    }
    // Registers the runtime's recorders, which is not synchronized with a
    // load: they have to be in place before the worker starts one. The log
    // recorder is registered at every level, because the reason of a failed
    // load comes from it.
    final log = calls.log;
    if (log != null) {
      recordStableDiffusionLog(log, logLevel);
    }
    calls.progressEnable();
    final replies = _Replies();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        (replies.sendPort, config, resolveCalls, logLevel, _logPosition),
        debugName: 'llamadart-image-generation',
        onExit: replies.sendPort,
        onError: replies.sendPort,
      );
      final loaded = _unwrap(await replies.next()) as _Loaded;
      return StableDiffusionImageWorker._(
        isolate,
        replies,
        loaded.commands,
        calls,
        progressTimer,
        Pointer.fromAddress(loaded.context),
        loaded.modelVersion,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      await replies.close();
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
    final reports = calloc<sd.sd_dart_progress_t>(_reportsPerRead);
    final latest = calloc<Uint64>();
    // Reports are process-wide and numbered: everything after the newest one
    // recorded so far belongs to this generation.
    _calls.progressRead(0, nullptr, 0, latest);
    var after = latest.value;
    var dropped = 0;
    void readProgress() {
      for (var reads = 0; reads < _readsPerPoll; reads++) {
        final count = _calls.progressRead(
          after,
          reports,
          _reportsPerRead,
          latest,
        );
        if (count == 0) {
          return;
        }
        // The runtime dropped its oldest reports when the first one it
        // returns does not follow the last one read.
        dropped += reports[0].sequence - after - 1;
        for (var i = 0; i < count; i++) {
          final report = reports[i];
          after = report.sequence;
          onProgress(report.step, report.steps);
        }
        if (after >= latest.value) {
          return;
        }
      }
    }

    _cancelRequested = false;
    final timer = _progressTimer(progressPollInterval, (_) {
      if (_cancelRequested) {
        // stable-diffusion.cpp clears a cancel request when a generation
        // starts, so one that arrived before then is applied again.
        _calls.cancelGeneration(_context);
      }
      readProgress();
    });
    try {
      _commands.send(_Generate(request, _logPosition));
      final reply = await _reply() as _Generated;
      // The runtime recorded the last reports before the reply was sent.
      readProgress();
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
      timer.cancel();
      calloc.free(reports);
      calloc.free(latest);
      if (dropped > 0) {
        LlamaLogger.instance.warning(
          'The stable_diffusion runtime dropped $dropped image-generation '
          'progress reports: it keeps the '
          '${StableDiffusionCalls.progressHistory} most recent ones, and more '
          'than that were recorded between two reads. Progress events of '
          'this generation can be missing or mislabelled.',
        );
      }
    }
  }

  @override
  void cancel() {
    // A stopped worker's shutdown already freed the context.
    if (_disposed || _stopped) {
      return;
    }
    _cancelRequested = true;
    _calls.cancelGeneration(_context);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      if (!_stopped) {
        _commands.send(_Dispose(_logPosition));
        await _reply();
      }
    } finally {
      _isolate.kill(priority: Isolate.immediate);
      await _replies.close();
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
/// role as in `ImageGenerationSessionConfig.files`. Its message and details
/// name the files by their `ImageModelRole`, never by path.
///
/// [reason] is what the runtime logged as errors during the load, already
/// free of paths (`stableDiffusionFailureReason`); `null` when it logged
/// none, or when the runtime cannot report it, which [runtimeReportsReason]
/// tells apart. The runtime's reason for a file in the wrong role says
/// little, so the message also names the file roles a split checkpoint is
/// missing, with or without a reason.
LlamaModelException stableDiffusionModelLoadFailure(
  Map<String, String> files, {
  String? reason,
  bool runtimeReportsReason = false,
}) {
  final hints = <String>[
    if (!files.containsKey('model')) ...[
      if (!files.containsKey('vae') && !files.containsKey('taesd'))
        'Standalone diffusion weights (ImageModelRole.diffusionModel) need a '
            'vae or taesd file; a single file that includes its VAE, such as '
            'an SD 3.5 Medium GGUF, is an ImageModelRole.checkpoint.',
      if (!_textEncoderRoles.any(files.containsKey))
        'Standalone diffusion weights need their text encoders: clipL, '
            'clipG and t5xxl for SD 3.5, clipL and t5xxl for FLUX, and llm '
            'for Z-Image and Qwen-Image.',
    ],
  ];
  final message = [
    'stable-diffusion.cpp could not load the image model files.',
    if (reason != null) 'The runtime reported: "$reason".',
    ...hints,
    if (reason == null && hints.isEmpty)
      'Check that they form a model the runtime supports, that each file has '
          'its role (ImageModelRole.checkpoint for a single file with '
          'diffusion weights, ImageModelRole.diffusionModel for standalone '
          'ones; set one with ImageModelComponent(source, role: ...)), and '
          'that the device has enough memory.',
    if (reason == null)
      runtimeReportsReason
          ? 'The runtime logged no reason.'
          : 'This stable_diffusion runtime does not report its reason: that '
                'needs stable-diffusion-native '
                '${StableDiffusionCalls.optionalNativeRelease} or later.',
  ].join(' ');
  final roles = [
    for (final role in files.keys) role == 'model' ? 'checkpoint' : role,
  ];
  return LlamaModelException(message, 'files: ${roles.join(', ')}');
}

const List<String> _textEncoderRoles = ['clipL', 'clipG', 't5xxl', 'llm'];

/// The worker's replies, which keep the calling isolate alive only while one
/// is awaited.
final class _Replies {
  _Replies() {
    _port = RawReceivePort((Object? message) {
      // The worker sends what it read of the log before the reply of the
      // operation that recorded it.
      if (message is _LogBatch) {
        message.deliver();
      } else {
        _messages.add(message);
      }
    }, 'llamadart-image-generation-replies')..keepIsolateAlive = false;
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
  final LlamaException error;

  const _LoadFailure(this.error);
}

final class _Generate {
  final ImageGenerationSessionRequest request;
  final StableDiffusionLogPosition logPosition;

  const _Generate(this.request, this.logPosition);
}

final class _Dispose {
  final StableDiffusionLogPosition logPosition;

  const _Dispose(this.logPosition);
}

/// Messages the worker read from the runtime's log, for the calling isolate.
final class _LogBatch {
  final List<WorkerLogMessage> records;
  final StableDiffusionLogPosition position;
  final int dropped;

  const _LogBatch(this.records, this.position, this.dropped);

  void deliver() {
    final known = StableDiffusionImageWorker._logPosition;
    // Two workers that read at once can finish out of order, and the
    // dropped count can rise with no new message to read.
    StableDiffusionImageWorker._logPosition = (
      after: max(position.after, known.after),
      dropped: max(position.dropped, known.dropped),
    );
    // No caller awaits these records, so `emit` prints an error of the log
    // handler instead of throwing it into the port.
    for (final record in records) {
      record.emit();
    }
    if (dropped > 0) {
      WorkerLogMessage(
        LlamaLogLevel.warn,
        'The stable_diffusion runtime dropped $dropped log messages: it '
        'keeps the most recent 256 KiB of them, and more than that were '
        'recorded during one load or generation. Raise '
        'LlamaLogging.nativeLevel to record fewer.',
      ).emit();
    }
  }
}

/// The runtime's log in the worker isolate: nothing on a runtime that has no
/// recorder.
final class _WorkerLog {
  _WorkerLog(this._log, this._level, this._replies, Map<String, String> files)
    : _redact = stableDiffusionPathRedactor(files);

  final StableDiffusionLogCalls? _log;
  final LlamaLogLevel _level;
  final SendPort _replies;
  final String Function(String text) _redact;

  /// Why the load this thread just made failed, or `null`.
  String? failureReason() {
    final log = _log;
    return log == null
        ? null
        : stableDiffusionFailureReason(
            readStableDiffusionLastError(log),
            _redact,
          );
  }

  /// Sends what the runtime recorded after [position] to the calling
  /// isolate. The reads touch no context, so they are safe whenever the
  /// process exits; calls on a context come before them, inside the time
  /// exit teardown gives a thread after a load.
  void forward(StableDiffusionLogPosition position) {
    final log = _log;
    if (log == null || _level == LlamaLogLevel.none) {
      return;
    }
    final drain = drainStableDiffusionLog(log, position);
    _replies.send(
      _LogBatch(
        [
          for (final (level, text) in drain.messages)
            WorkerLogMessage(level, 'stable_diffusion: ${_redact(text)}'),
        ],
        drain.position,
        drain.dropped,
      ),
    );
  }
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

void _workerMain(
  (
    SendPort,
    ImageGenerationSessionConfig,
    StableDiffusionCallsResolver,
    LlamaLogLevel,
    StableDiffusionLogPosition,
  )
  arguments,
) {
  final (replies, config, resolveCalls, logLevel, logPosition) = arguments;
  final calls = resolveCalls();
  if (calls == null) {
    replies.send(_LoadFailure(stableDiffusionWrapperUnsupported()));
    return;
  }
  final log = _WorkerLog(calls.log, logLevel, replies, config.files);

  final context = _newContext(calls, config);
  if (context == nullptr) {
    // The errors of the load belong to this thread until its next load.
    final reason = log.failureReason();
    log.forward(logPosition);
    replies.send(
      _LoadFailure(
        stableDiffusionModelLoadFailure(
          config.files,
          reason: reason,
          runtimeReportsReason: calls.log != null,
        ),
      ),
    );
    return;
  }
  if (!calls.supportsImageGeneration(context)) {
    IsolateShutdownReleases.current.release(context);
    calls.exitFree(context.cast());
    log.forward(logPosition);
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
  final version = calls.modelVersionName(context);
  log.forward(logPosition);
  replies.send(
    _Loaded(
      commands.sendPort,
      context.address,
      version == nullptr ? '' : version.cast<Utf8>().toDartString(),
    ),
  );
  commands.listen((command) {
    switch (command) {
      case _Generate(:final request, :final logPosition):
        // An error here ends this isolate with the context still held, so
        // its shutdown frees it; a later cancel from the calling isolate
        // does nothing for a freed context.
        final generated = _generate(calls, context, request);
        log.forward(logPosition);
        replies.send(generated);
      case _Dispose(:final logPosition):
        IsolateShutdownReleases.current.release(context);
        calls.exitFree(context.cast());
        commands.close();
        log.forward(logPosition);
        replies.send(const _Disposed());
    }
  });
}

Pointer<sd.sd_ctx_t> _newContext(
  StableDiffusionCalls calls,
  ImageGenerationSessionConfig config,
) {
  return using((arena) {
    final params = arena<sd.sd_ctx_params_t>();
    calls.contextParamsInit(params);
    applyStableDiffusionContextParams(params, config, arena);
    final context = calls.newContext(params);
    IsolateShutdownReleases.current.hold(
      ShutdownStage.model,
      calls.exitFreeAddress,
      context,
    );
    return context;
  });
}

_Generated _generate(
  StableDiffusionCalls calls,
  Pointer<sd.sd_ctx_t> context,
  ImageGenerationSessionRequest request,
) {
  return using((arena) {
    final params = arena<sd.sd_img_gen_params_t>();
    calls.imageGenerationParamsInit(params);
    applyStableDiffusionGenerationParams(params, request, arena);

    final imagesOut = arena<Pointer<sd.sd_image_t>>();
    final countOut = arena<Int>();
    final ok = calls.generateImage(context, params, imagesOut, countOut);
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
        calls.freeImages(images, count);
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
