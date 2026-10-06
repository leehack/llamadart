// Subprocess fixture: ends the process in one way while llama.cpp objects are
// alive. Arguments: the scenario and a GGUF chat model; `quit-projector` also
// takes that model's projector, and `quit-decision` takes an encoder GGUF and
// its decision head instead.
//
// The `quit-` scenarios call C `exit` through FFI from the main isolate while
// the isolate that owns the objects is alive: what a native host that skips
// the Dart shutdown does. They do not model a Flutter macOS quit, which shuts
// the isolates down first, and `dart:io`'s `exit` does not run the static
// destructors that make ggml-metal abort. Each one exits while the owning
// isolate is idle or inside a guarded call; an exit during an unguarded call
// is not covered (doc/llama_cpp_exit_teardown.md).
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';

const _messages = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Count from 1 to 1000, writing each number on a new line.',
  ),
];

Future<void> main(List<String> args) async {
  final [scenario, modelPath, ...extra] = args;
  switch (scenario) {
    case 'quit-projector':
      final engine = await LlamaEngine.load(
        LlamaModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(extra.single),
        ),
        params: const ModelParams(contextSize: 2048),
      );
      _reportBackend(await engine.getBackendName());
      _quit(scenario);
    case 'quit-decision':
      final decisions = await DecisionEngine.load(
        DecisionModel(
          encoder: ModelSource.path(modelPath),
          head: ModelSource.path(extra.single),
        ),
      );
      _reportBackend(decisions.info.deviceName);
      _quit(scenario);
    case 'quit-loaded':
      final engine = await _load(modelPath);
      await engine.create(_messages, params: _tokens(4)).drain<void>();
      _quit(scenario);
    case 'quit-generating':
      await _firstToken(await _load(modelPath));
      _quit(scenario);
    case 'throw-generating':
      await _firstToken(await _load(modelPath));
      _reached(scenario);
      throw StateError('unhandled error with a generation running');
    case 'quit-loading':
      await _insideNativeLoad(modelPath);
      _quit(scenario);
    case 'throw-loading':
      await _insideNativeLoad(modelPath);
      _reached(scenario);
      throw StateError('unhandled error with a model load running');
    case 'kill-loading':
      // The kill lands when the native load returns, before the isolate holds
      // the model for its own shutdown.
      (await _insideNativeLoad(modelPath)).kill(priority: Isolate.immediate);
      _reached(scenario);
    case 'return-loaded':
      await Isolate.run(() => _loadInThisIsolate(modelPath));
      _reached(scenario);
    default:
      throw ArgumentError.value(scenario, 'scenario');
  }
}

void _reportBackend(String name) => stdout.writeln('EXIT_PROBE_BACKEND $name');

void _reached(String scenario) =>
    stdout.writeln('EXIT_PROBE_REACHED $scenario');

Never _quit(String scenario) {
  _reached(scenario);
  DynamicLibrary.process()
      .lookupFunction<Void Function(Int32), void Function(int)>('exit')(0);
  throw StateError('C exit returned');
}

GenerationParams _tokens(int count) => GenerationParams(
  maxTokens: count,
  streamBatchTokenThreshold: 1,
  streamBatchByteThreshold: 1,
);

Future<LlamaEngine> _load(String modelPath) async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(modelPath)),
    params: const ModelParams(contextSize: 2048),
  );
  _reportBackend(await engine.getBackendName());
  return engine;
}

// Leaves the generation running: cancelling the subscription would stop it.
Future<void> _firstToken(LlamaEngine engine) {
  final first = Completer<void>();
  engine.create(_messages, params: _tokens(512)).listen((_) {
    if (!first.isCompleted) first.complete();
  });
  return first.future;
}

/// Returns an isolate that is halfway through the native call loading
/// [modelPath], going by how long one load of it just took.
Future<Isolate> _insideNativeLoad(String modelPath) async {
  final loadTime = await Isolate.run(() {
    final service = LlamaCppService()..initializeBackend();
    final load = Stopwatch()..start();
    final model = service.loadModel(modelPath, const ModelParams());
    load.stop();
    service.freeModel(model);
    return load.elapsed;
  });
  stdout.writeln('EXIT_PROBE_LOAD_MS ${loadTime.inMilliseconds}');
  final loading = ReceivePort();
  final isolate = await Isolate.spawn(_loadAfterNotice, (
    loading.sendPort,
    modelPath,
  ));
  await loading.first;
  await Future<void>.delayed(loadTime ~/ 2);
  return isolate;
}

void _loadAfterNotice((SendPort, String) message) {
  final (loading, modelPath) = message;
  final service = LlamaCppService()..initializeBackend();
  loading.send(null);
  service.loadModel(modelPath, const ModelParams());
}

void _loadInThisIsolate(String modelPath) {
  const params = ModelParams(contextSize: 2048);
  final service = LlamaCppService()..initializeBackend();
  service.createContext(service.loadModel(modelPath, params), params);
}
