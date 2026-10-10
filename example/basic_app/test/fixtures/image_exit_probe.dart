// Subprocess fixture: ends the process in one way while an image model is
// alive, or prints the progress events of a batch. Arguments: the scenario
// and an image checkpoint; `quit-both-loaded` also takes a GGUF chat model.
// A scenario whose name ends in `-logging` runs with the runtime's log
// forwarded at debug level, so the worker reads the log around the exit.
//
// The `host-shutdown-` scenarios dispose engines in a separate owning isolate
// and await its actual exit notification before C exit. The loading scenario
// requests shutdown while a load is pending and awaits that load before disposal.
// The remaining main isolate is a host-control stand-in, not a Flutter engine.
//
// The `quit-` scenarios call C `exit` through FFI from the main isolate while
// the worker isolate that owns the context is alive: what a native host that
// skips the Dart shutdown does. `dart:io`'s `exit` does not run the static
// destructors that make ggml-metal abort. Each one exits while the worker is
// idle, loading or generating, which is what the runtime's exit teardown
// waits for (doc/llama_cpp_exit_teardown.md).
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_image_worker.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_params.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';

import '../../../../test/support/cooperative_exit_probe.dart';

Future<void> main(List<String> args) async {
  final [requested, modelPath, ...extra] = args;
  final logging = requested.endsWith(_loggingSuffix);
  final scenario = logging
      ? requested.substring(0, requested.length - _loggingSuffix.length)
      : requested;
  if (logging) {
    await LlamaLogging.configure(
      level: LlamaLogLevel.debug,
      handler: (_) => _logRecords++,
    );
  }
  if (scenario.startsWith('host-shutdown-')) {
    await runCooperativeExitProbe(_cooperativeShutdown, [
      scenario,
      modelPath,
      ...extra,
      if (logging) _loggingSuffix,
    ], completedMarker: 'IMAGE_PROBE_HOST_SHUTDOWN_COMPLETE');
    _reportTracked();
    _quit(scenario);
  }
  switch (scenario) {
    case 'symbols':
      await ImageGenerationEngine.checkRuntime();
      for (final name in [
        ...StableDiffusionCalls.wrapperSymbols,
        ...StableDiffusionCalls.logSymbols,
        ...StableDiffusionCalls.deviceMemorySymbols,
      ]) {
        if (StableDiffusionCalls.symbolAddress(name) !=
            DynamicLibrary.process().lookup(name)) {
          throw StateError('$name does not resolve to the export of its name');
        }
      }
      final calls = StableDiffusionCalls.tryResolve()!;
      if (calls.log == null || calls.gpu == null) {
        throw StateError('The pinned runtime lacks the log or the GPU queries');
      }
      _reached(scenario);
    case 'quiet':
      // At the default log levels the runtime prints nothing: the test reads
      // this process's stderr.
      final engine = await _load(modelPath);
      await engine.generateImage(_request(steps: 1));
      await engine.dispose();
      _reached(scenario);
    case 'events':
      final engine = await _load(modelPath);
      final events = <String, List<String>>{};
      for (final (count, steps) in [(2, 1), (3, 4), (2, 4)]) {
        final task = await engine.generate(
          _request(steps: steps, count: count),
        );
        events['${count}x$steps'] = [
          await for (final event in task.events)
            if (event is ImageGenerationProgressEvent)
              '${event.phase.name} ${event.step}/${event.steps} '
                  'image ${event.imageIndex}/${event.imageCount}',
        ];
      }
      stdout.writeln('IMAGE_PROBE_EVENTS ${jsonEncode(events)}');
      await engine.dispose();
      _reached(scenario);
    case 'quit-loaded':
      final engine = await _load(modelPath);
      await engine.generateImage(_request(steps: 1));
      _reportTracked();
      _quit(scenario);
    case 'quit-generating':
      await _firstStep(await _load(modelPath));
      _quit(scenario);
    case 'throw-generating':
      await _firstStep(await _load(modelPath));
      _reached(scenario);
      throw StateError('unhandled error with a generation running');
    case 'quit-loading':
      await _insideLoad(modelPath);
      _quit(scenario);
    case 'throw-loading':
      await _insideLoad(modelPath);
      _reached(scenario);
      throw StateError('unhandled error with a model load running');
    case 'kill-loading':
      // The kill lands when the native load returns, before the isolate
      // holds the context for its own shutdown.
      final loadTime = await _loadTime(modelPath);
      final loading = ReceivePort();
      final isolate = await Isolate.spawn(_loadAfterNotice, (
        loading.sendPort,
        modelPath,
      ));
      await loading.first;
      await Future<void>.delayed(loadTime ~/ 2);
      isolate.kill(priority: Isolate.immediate);
      _reached(scenario);
    case 'dispose-quit':
      final engine = await _load(modelPath);
      await engine.generateImage(_request(steps: 1));
      await engine.dispose();
      _reportTracked();
      _quit(scenario);
    case 'quit-both-loaded':
      final chat = await LlamaEngine.load(
        LlamaModel(ModelSource.path(extra.single)),
        params: const ModelParams(contextSize: 2048),
      );
      stdout.writeln('IMAGE_PROBE_CHAT_BACKEND ${await chat.getBackendName()}');
      final engine = await _load(modelPath);
      await engine.generateImage(_request(steps: 1));
      _quit(scenario);
    default:
      throw ArgumentError.value(scenario, 'scenario');
  }
}

Future<void> _cooperativeShutdown((SendPort, List<String>) message) async {
  final (completed, arguments) = message;
  final logging = arguments.last == _loggingSuffix;
  final [scenario, modelPath, ...extra] = logging
      ? arguments.sublist(0, arguments.length - 1)
      : arguments;
  if (logging) {
    await LlamaLogging.configure(
      level: LlamaLogLevel.debug,
      handler: (_) => _logRecords++,
    );
  }
  LlamaEngine? chat;
  ImageGenerationEngine? engine;
  try {
    if (scenario == 'host-shutdown-both-loaded') {
      chat = await LlamaEngine.load(
        LlamaModel(ModelSource.path(extra.single)),
        params: ModelParams(
          contextSize: 2048,
          preferredBackend: GpuBackend.values.byName(
            (Platform.environment['IMAGE_EXIT_CHAT_BACKEND'] ?? 'cpu')
                .toLowerCase(),
          ),
          device:
              (Platform.environment['IMAGE_EXIT_CHAT_BACKEND'] ?? 'cpu')
                      .toLowerCase() ==
                  'cpu'
              ? ComputeDevice.cpu
              : ComputeDevice.gpu,
        ),
      );
      stdout.writeln('IMAGE_PROBE_CHAT_BACKEND ${await chat.getBackendName()}');
    }
    final loading = _load(modelPath);
    if (scenario == 'host-shutdown-loading') {
      stdout.writeln('IMAGE_PROBE_HOST_SHUTDOWN_REQUESTED loading');
    }
    engine = await loading;
    switch (scenario) {
      case 'host-shutdown-loaded':
      case 'host-shutdown-both-loaded':
        await engine.generateImage(_request(steps: 1));
      case 'host-shutdown-generating':
        final generation = await _firstStep(engine, bounded: true);
        try {
          await engine.dispose();
          final completion = await generation.task.done;
          if (completion.state == ImageGenerationCompletionState.failed) {
            throw completion.error!;
          }
        } finally {
          await generation.subscription.cancel();
        }
      case 'host-shutdown-loading':
        break;
      default:
        throw ArgumentError.value(scenario, 'scenario');
    }
  } finally {
    // Join both independent native workers even if one disposal fails.
    await Future.wait([
      if (engine != null) engine.dispose(),
      if (chat != null) chat.dispose(),
    ]);
  }
  if (_logRecords > 0) stdout.writeln('IMAGE_PROBE_LOG_RECORDS $_logRecords');
  completed.send(true);
}

const _loggingSuffix = '-logging';

int _logRecords = 0;

void _reached(String scenario) {
  if (_logRecords > 0) {
    stdout.writeln('IMAGE_PROBE_LOG_RECORDS $_logRecords');
  }
  stdout.writeln('IMAGE_PROBE_REACHED $scenario');
}

void _reportTracked() =>
    stdout.writeln('IMAGE_PROBE_TRACKED ${sd.sd_dart_exit_tracked_count()}');

Never _quit(String scenario) {
  _reached(scenario);
  DynamicLibrary.process()
      .lookupFunction<Void Function(Int32), void Function(int)>('exit')(0);
  throw StateError('C exit returned');
}

ImageGenerationRequest _request({required int steps, int count = 1}) =>
    ImageGenerationRequest(
      prompt: 'a red fox in autumn leaves',
      width: 256,
      height: 256,
      steps: steps,
      guidanceScale: 1,
      seed: 42,
      count: count,
    );

Future<ImageGenerationEngine> _load(String modelPath) async {
  final requested =
      Platform.environment['IMAGE_EXIT_BACKEND'] ??
      (Platform.isLinux ? 'cpu' : null);
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(modelPath)),
    params: ImageModelParams(
      device: requested == null
          ? ComputeDevice.auto
          : requested.toLowerCase() == 'cpu'
          ? ComputeDevice.cpu
          : ComputeDevice.gpu,
    ),
  );
  stdout.writeln(
    'IMAGE_PROBE_BACKEND ${(await engine.capabilities).backendName}',
  );
  return engine;
}

// Leaves the generation running: the steps left take longer than the exit.
Future<
  ({
    StreamSubscription<ImageGenerationEvent> subscription,
    ImageGenerationTask task,
  })
>
_firstStep(ImageGenerationEngine engine, {bool bounded = false}) async {
  final task = await engine.generate(
    bounded
        ? _request(steps: 2)
        : const ImageGenerationRequest(
            prompt: 'a red fox in autumn leaves',
            steps: 40,
            guidanceScale: 1,
            seed: 42,
          ),
  );
  final sampling = Completer<void>();
  final subscription = task.events.listen(
    (event) {
      if (event case ImageGenerationProgressEvent(
        phase: ImageGenerationPhase.sampling,
        step: >= 1,
      ) when !sampling.isCompleted) {
        sampling.complete();
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!sampling.isCompleted) sampling.completeError(error, stack);
    },
    onDone: () {
      if (!sampling.isCompleted) {
        sampling.completeError(
          StateError('Generation produced no sampling step.'),
        );
      }
    },
  );
  try {
    await sampling.future;
    return (subscription: subscription, task: task);
  } catch (_) {
    await subscription.cancel();
    rethrow;
  }
}

ImageGenerationSessionConfig _config(String modelPath) =>
    ImageGenerationSessionConfig(
      files: {'model': modelPath},
      backend: null,
      threads: 0,
    );

// Times the worker's load alone: an engine load also probes the runtime and
// reads the file headers first. The first load of a process also sets up
// Metal, so the second one is the measure of the next.
Future<Duration> _loadTime(String modelPath) async {
  final load = Stopwatch();
  for (var i = 0; i < 2; i++) {
    load
      ..reset()
      ..start();
    final worker = await StableDiffusionImageWorker.start(
      _config(modelPath),
      logLevel: LlamaLogging.level,
    );
    load.stop();
    await worker.dispose();
  }
  stdout.writeln('IMAGE_PROBE_LOAD_MS ${load.elapsedMilliseconds}');
  return load.elapsed;
}

/// Leaves a worker halfway through the native call loading [modelPath],
/// going by how long one load of it just took.
Future<void> _insideLoad(String modelPath) async {
  final loadTime = await _loadTime(modelPath);
  unawaited(
    StableDiffusionImageWorker.start(
      _config(modelPath),
      logLevel: LlamaLogging.level,
    ),
  );
  await Future<void>.delayed(loadTime ~/ 2);
}

void _loadAfterNotice((SendPort, String) message) {
  final (loading, modelPath) = message;
  final calls = StableDiffusionCalls.tryResolve()!;
  using((arena) {
    final params = arena<sd.sd_ctx_params_t>();
    calls.contextParamsInit(params);
    applyStableDiffusionContextParams(params, _config(modelPath), arena);
    loading.send(null);
    calls.newContext(params);
  });
}
