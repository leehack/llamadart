// Local-only real image startup and sampling, with cooperative host disposal.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart' as native;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;

import 'macos_quit_probe.dart' as macos;

Future<ImageGenerationEngine>? _loading;
ImageGenerationTask? _task;
bool _loadReturned = false;
bool _generationReturned = false;
final List<Object> _alive = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Text('Image shutdown probe'))));
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
    throw StateError('Host observer did not initialize.');
  }
  observer.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('flutter_shutdown_image_init')(
    Native.addressOf<NativeFunction<Int32 Function()>>(
      sd.sd_dart_exit_tracked_count,
    ).cast(),
  );
  final work = env['FLUTTER_SHUTDOWN_WORK']!;
  _loading = ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(env['MACOS_QUIT_CHAT_MODEL']!)),
    params: ImageModelParams(
      device: Platform.isLinux ? ComputeDevice.cpu : ComputeDevice.gpu,
      threads: 4,
    ),
  );
  _alive.add(_loading!);
  unawaited(
    _loading!.then((engine) {
      _loadReturned = true;
      stdout.writeln('FLUTTER_SHUTDOWN_IMAGE_LOAD_RETURNED');
    }),
  );
  if (work == 'image-loading') {
    // Read the maintained native recorder while the production worker loads.
    // This installs no callback and does not consume the worker's cursor.
    final reports = calloc<sd.sd_dart_progress_t>(1);
    final latest = calloc<Uint64>();
    var seen = false;
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final count = sd.sd_dart_progress_read(0, reports, 1, latest);
      if (!seen && count > 0 && !_loadReturned) {
        seen = true;
        stdout.writeln(
          'FLUTTER_SHUTDOWN_IMAGE_LOAD_PROGRESS sequence=${reports[0].sequence} step=${reports[0].step}/${reports[0].steps}',
        );
      }
    });
    _alive.add(timer);
    unawaited(
      _loading!.whenComplete(() {
        timer.cancel();
        calloc.free(reports);
        calloc.free(latest);
      }),
    );
  } else if (work == 'image-generating') {
    final engine = await _loading!;
    stdout.writeln(
      'FLUTTER_SHUTDOWN_IMAGE_BACKEND ${(await engine.capabilities).backendName}',
    );
    _task = await engine.generate(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        width: 256,
        height: 256,
        steps: 40,
        guidanceScale: 1,
        seed: 42,
      ),
    );
    final first = Completer<void>();
    final subscription = _task!.events.listen((event) {
      if (event is ImageGenerationProgressEvent &&
          event.phase == ImageGenerationPhase.sampling &&
          event.step > 0 &&
          event.step < event.steps &&
          !first.isCompleted) {
        first.complete();
      }
    });
    _alive.add(subscription);
    unawaited(
      _task!.done.then((_) {
        _generationReturned = true;
        stdout.writeln('FLUTTER_SHUTDOWN_IMAGE_GENERATION_DONE');
      }),
    );
    await first.future;
    stdout.writeln('FLUTTER_SHUTDOWN_READY image-generating');
  } else {
    throw ArgumentError.value(work, 'work');
  }
  stdin.transform(const SystemEncoding().decoder).listen((command) async {
    final path = command.trim();
    stderr.writeln(
      'FLUTTER_SHUTDOWN_IMAGE_QUIT_REQUEST loading=${!_loadReturned} generating=${_task != null && !_generationReturned}',
    );
    if (work == 'image-loading' && _loadReturned) {
      throw StateError('Image load finished before shutdown request.');
    }
    if (work == 'image-generating' && _generationReturned) {
      throw StateError('Image generation finished before shutdown request.');
    }
    final engine = await _loading!;
    if (work == 'image-loading') {
      stdout.writeln(
        'FLUTTER_SHUTDOWN_IMAGE_BACKEND ${(await engine.capabilities).backendName}',
      );
    }
    final disposal = engine.dispose();
    await engine.dispose();
    await disposal;
    if (_task != null) {
      final completion = await _task!.done;
      if (completion.state == ImageGenerationCompletionState.failed) {
        throw completion.error!;
      }
      stdout.writeln(
        'FLUTTER_SHUTDOWN_IMAGE_COMPLETION ${completion.state.name}',
      );
    }
    if (sd.sd_dart_exit_tracked_count() != 0) {
      throw StateError('Image objects remain after disposal.');
    }
    stdout.writeln('FLUTTER_SHUTDOWN_IMAGE_DISPOSED');
    await stdout.flush();
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
