// Entrypoint of the app test/macos_quit_e2e_test.dart builds and launches:
// loads the models named by the environment, disposes nothing, registers no
// `onExitRequested` listener, and quits through the AppKit path named by
// `MACOS_QUIT_PATH`. `apple-event` waits for the test to send the Quit event.
//
// `MACOS_QUIT_CONTROL` set loads the chat model through the upstream loader
// instead: no isolate holds it and the runtime's exit teardown does not track
// it, so ggml-metal has to abort the quit. It is the test's proof that a model
// left alive is detected.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart' as llama_cpp;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;

const _tag = 'MACOS_QUIT_PROBE';

final List<Object> _loaded = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('llamadart macOS quit probe'))),
    ),
  );
  final environment = Platform.environment;
  try {
    final chatModel = environment['MACOS_QUIT_CHAT_MODEL']!;
    final imageModel = environment['MACOS_QUIT_IMAGE_MODEL'];
    final decisionModel = environment['MACOS_QUIT_DECISION_MODEL'];
    final control = environment.containsKey('MACOS_QUIT_CONTROL');
    if (control) {
      _loadUntracked(chatModel);
    } else {
      await _loadChat(chatModel);
      if (imageModel != null) await _loadImage(imageModel);
      if (decisionModel != null) {
        await _loadDecision(
          decisionModel,
          environment['MACOS_QUIT_DECISION_HEAD']!,
        );
      }
    }
    // What the runtimes would free at C exit if no isolate freed it first.
    stdout.writeln(
      '${_tag}_TRACKED llama_cpp=${llama_cpp.llama_dart_exit_tracked_count()} '
      'stable_diffusion='
      '${imageModel == null || control ? 0 : sd.sd_dart_exit_tracked_count()}',
    );
    stdout.writeln('${_tag}_READY $pid');
    await stdout.flush();
    await _quit(environment['MACOS_QUIT_PATH']!);
  } on Object catch (error) {
    stdout.writeln('${_tag}_ERROR $error');
  }
}

Future<void> _loadChat(String path) async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(path)),
    params: const ModelParams(contextSize: 2048),
  );
  await engine
      .generate(
        'Once upon a time',
        params: const GenerationParams(maxTokens: 4),
      )
      .drain<void>();
  stdout.writeln('${_tag}_CHAT_BACKEND ${await engine.getBackendName()}');
  _loaded.add(engine);
}

Future<void> _loadImage(String path) async {
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(path)),
  );
  await engine.generateImage(
    const ImageGenerationRequest(
      prompt: 'a red fox in autumn leaves',
      width: 256,
      height: 256,
      steps: 1,
      guidanceScale: 1,
      seed: 42,
    ),
  );
  stdout.writeln(
    '${_tag}_IMAGE_BACKEND ${(await engine.capabilities).backendName}',
  );
  _loaded.add(engine);
}

Future<void> _loadDecision(String encoder, String head) async {
  final engine = await DecisionEngine.load(
    DecisionModel(
      encoder: ModelSource.path(encoder),
      head: ModelSource.path(head),
    ),
  );
  stdout.writeln('${_tag}_DECISION_BACKEND ${engine.info.deviceName}');
  _loaded.add(engine);
}

void _loadUntracked(String path) {
  llama_cpp.llama_backend_init();
  final model = using(
    (arena) => llama_cpp.llama_model_load_from_file(
      path.toNativeUtf8(allocator: arena).cast(),
      llama_cpp.llama_model_default_params(),
    ),
  );
  if (model == nullptr) throw StateError('The upstream loader returned null.');
  _loaded.add(model);
}

Future<void> _quit(String path) async {
  switch (path) {
    case 'apple-event':
      break;
    case 'terminate':
      // The action of the application menu's Quit item, which Cmd-Q sends.
      _onMainThread(_sharedApplication, 'terminate:');
    case 'close-window':
      final windows = _send(_sharedApplication, _selector('windows'));
      final count = _sendCount(windows, _selector('count'));
      for (var index = 0; index < count; index++) {
        _onMainThread(
          _sendIndex(windows, _selector('objectAtIndex:'), index),
          'performClose:',
        );
      }
    case 'exit-required':
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    case 'exit-cancelable':
      await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
    default:
      throw ArgumentError.value(path, 'MACOS_QUIT_PATH');
  }
}

final DynamicLibrary _process = DynamicLibrary.process();

final Pointer<Void> Function(Pointer<Utf8>) _class = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('objc_getClass');

final Pointer<Void> Function(Pointer<Utf8>) _registerSelector = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('sel_registerName');

final Pointer<Void> Function(Pointer<Void>, Pointer<Void>) _send = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
    >('objc_msgSend');

final int Function(Pointer<Void>, Pointer<Void>) _sendCount = _process
    .lookupFunction<
      UnsignedLong Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('objc_msgSend');

final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int) _sendIndex =
    _process.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, UnsignedLong),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int)
    >('objc_msgSend');

final void Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  bool,
)
_sendOnMainThread = _process
    .lookupFunction<
      Void Function(
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Bool,
      ),
      void Function(
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        bool,
      )
    >('objc_msgSend');

Pointer<Void> _selector(String name) =>
    using((arena) => _registerSelector(name.toNativeUtf8(allocator: arena)));

Pointer<Void> get _sharedApplication => _send(
  using((arena) => _class('NSApplication'.toNativeUtf8(allocator: arena))),
  _selector('sharedApplication'),
);

// AppKit accepts these only on the main thread, whichever thread runs Dart.
void _onMainThread(Pointer<Void> receiver, String action) => _sendOnMainThread(
  receiver,
  _selector('performSelectorOnMainThread:withObject:waitUntilDone:'),
  _selector(action),
  nullptr,
  false,
);
