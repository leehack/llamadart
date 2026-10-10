// Local-only entrypoint for Flutter quitting while native work is active.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart' as native;
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/worker.dart';

import 'macos_quit_probe.dart' as macos;

final List<Object> _alive = [];
Future<LlamaEngine>? _startup;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Flutter shutdown probe'))),
  );
  final env = Platform.environment;
  final observer = DynamicLibrary.open(env['FLUTTER_SHUTDOWN_OBSERVER']!);
  final initialize = observer
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Void>),
        int Function(Pointer<Utf8>, Pointer<Void>)
      >('flutter_shutdown_observer_init');
  final initialized = using(
    (arena) => initialize(
      env['FLUTTER_SHUTDOWN_OBSERVER']!.toNativeUtf8(allocator: arena),
      Native.addressOf<NativeFunction<Int32 Function()>>(
        native.llama_dart_exit_tracked_count,
      ).cast(),
    ),
  );
  if (initialized != 0) {
    throw StateError('Native host observer did not initialize.');
  }
  final model = env['MACOS_QUIT_CHAT_MODEL']!;
  final work = env['FLUTTER_SHUTDOWN_WORK']!;
  if (work == 'startup') {
    observer.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('flutter_shutdown_startup_init')(
      Native.addressOf<
            NativeFunction<
              Pointer<native.llama_model> Function(
                Pointer<Char>,
                native.llama_model_params,
              )
            >
          >(native.llama_dart_model_load_from_file)
          .cast(),
    );
    _startup = LlamaEngine.load(
      LlamaModel(ModelSource.path(model)),
      backend: NativeLlamaBackend(workerEntrypoint: _startupWorker),
      params: ModelParams(
        contextSize: 4096,
        preferredBackend: Platform.isLinux ? GpuBackend.cpu : GpuBackend.metal,
        device: Platform.isLinux ? ComputeDevice.cpu : ComputeDevice.gpu,
      ),
    );
    _alive.add(_startup!);
    stdout.writeln('FLUTTER_SHUTDOWN_READY startup');
  } else if (work == 'loading') {
    final load = _startNativeLoad(model, env['FLUTTER_SHUTDOWN_OBSERVER']!);
    _alive.add(load);
    // The test waits for the native progress marker, not this scheduling point.
    stdout.writeln('FLUTTER_SHUTDOWN_READY loading');
  } else if (work == 'generating') {
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(model)),
      params: ModelParams(
        contextSize: 4096,
        preferredBackend: Platform.isLinux ? GpuBackend.cpu : GpuBackend.metal,
        device: Platform.isLinux ? ComputeDevice.cpu : ComputeDevice.gpu,
      ),
    );
    _alive.add(engine);
    stdout.writeln('FLUTTER_SHUTDOWN_BACKEND ${await engine.getBackendName()}');
    final first = Completer<void>();
    final subscription = engine
        .generate(
          'Write every integer from 1 to 10000, with one integer on each line.\n1\n2\n3\n',
          params: const GenerationParams(
            maxTokens: 2048,
            seed: 42,
            streamBatchTokenThreshold: 1,
            streamBatchByteThreshold: 1,
          ),
        )
        .listen(
          (_) {
            if (!first.isCompleted) first.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!first.isCompleted) first.completeError(error, stack);
            stderr.writeln('FLUTTER_SHUTDOWN_ERROR $error');
          },
          onDone: () => stdout.writeln('FLUTTER_SHUTDOWN_GENERATION_DONE'),
        );
    _alive.add(subscription);
    await first.future;
    stdout.writeln('FLUTTER_SHUTDOWN_READY generating');
  } else {
    throw ArgumentError.value(work, 'FLUTTER_SHUTDOWN_WORK');
  }
  await stdout.flush();
  // The harness requests a quit only after it verifies actual native activity.
  final commands = ReceivePort();
  _alive.add(commands);
  stdin.transform(const SystemEncoding().decoder).listen((command) async {
    final path = command.trim();
    if (work == 'loading' || work == 'startup') {
      final active = observer.lookupFunction<Int32 Function(), int Function()>(
        'flutter_shutdown_quit_requested',
      )();
      if (active != 1) {
        throw StateError('Native load finished before the quit request.');
      }
    }
    if (work == 'startup') {
      final engine = await _startup!;
      stdout.writeln(
        'FLUTTER_SHUTDOWN_BACKEND ${await engine.getBackendName()}',
      );
      // A second caller must await the same already-started disposal.
      final disposal = engine.dispose();
      await engine.dispose();
      await disposal;
      stdout.writeln('FLUTTER_SHUTDOWN_STARTUP_DISPOSED');
      await stdout.flush();
    }
    if (path == 'exit-required' || path == 'exit-cancelable') {
      await ServicesBinding.instance.exitApplication(
        path == 'exit-required' ? AppExitType.required : AppExitType.cancelable,
      );
    } else if (Platform.isMacOS) {
      await macos.requestMacosProbeQuit(path);
    } else {
      throw ArgumentError.value(path, 'quit path');
    }
  });
}

Future<int> _startNativeLoad(String model, String observerPath) =>
    Isolate.run(() => _nativeLoad(model, observerPath));

int _nativeLoad(String model, String observerPath) {
  if (Platform.isLinux) {
    using(
      (arena) => native.ggml_backend_load_all_from_path(
        '${File(Platform.resolvedExecutable).parent.path}/lib'
            .toNativeUtf8(allocator: arena)
            .cast(),
      ),
    );
  }
  native.llama_backend_init();
  final params = native.llama_model_default_params();
  params.n_gpu_layers = Platform.isLinux ? 0 : 99;
  final load = DynamicLibrary.open(observerPath)
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Utf8>,
          native.llama_model_params,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Utf8>,
          native.llama_model_params,
        )
      >('flutter_shutdown_load');
  return using(
    (arena) => load(
      Native.addressOf<
            NativeFunction<
              Pointer<native.llama_model> Function(
                Pointer<Char>,
                native.llama_model_params,
              )
            >
          >(native.llama_dart_model_load_from_file)
          .cast(),
      Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
        native.llama_dart_exit_free,
      ).cast(),
      model.toNativeUtf8(allocator: arena),
      params,
    ),
  );
}

void _startupWorker(SendPort port) {
  final env = Platform.environment;
  final observer = DynamicLibrary.open(env['FLUTTER_SHUTDOWN_OBSERVER']!);
  final runtime = DynamicLibrary.open(env['FLUTTER_SHUTDOWN_RUNTIME']!);
  final calls = LlamaCppObjectCalls.resolve(
    isWindows: false,
    symbol: (name) => name == 'llama_dart_model_load_from_file'
        ? observer.lookup('flutter_shutdown_startup_load')
        : runtime.lookup(name),
  );
  runLlamaWorkerForTesting(port, LlamaCppService(objectCalls: calls));
}
