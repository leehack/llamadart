import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';

void main(List<String> arguments) {
  final [mode, expected, libraryPath] = arguments;
  final library = DynamicLibrary.open(libraryPath);
  final spy = library.lookupFunction<Int32 Function(), int Function()>(
    'fixture_by_value_calls',
  );
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  Symbol member(String name) => MirrorSystem.getSymbol(name, owner);
  ClassMirror type(String name) =>
      owner.declarations[member(name)]! as ClassMirror;

  Object? attempt() {
    switch (mode) {
      case 'load':
        final directory = Directory.systemTemp.createTempSync('admission-');
        final model = File('${directory.path}/model.gguf')
          ..writeAsBytesSync([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]);
        try {
          return LlamaCppService().loadModel(model.path, const ModelParams());
        } finally {
          directory.deleteSync(recursive: true);
        }
      case 'direct' || 'windows':
        return reflect(LlamaCppService(isWindows: mode == 'windows')).invoke(
          member('_resolveSpeculativeApi'),
          [],
          {#candidates: <String>[]},
        );
      case 'dynamic':
        return type('_SpeculativeApi').invoke(#tryLoad, [library]).reflectee;
      case 'mtmd':
        return type('_MtmdApi').invoke(#tryLoad, [library]).reflectee;
      case 'mtmd-default':
        return reflect(
          LlamaCppService(),
        ).invoke(member('_mtmdContextParamsDefault'), []).reflectee;
    }
    throw ArgumentError(mode);
  }

  Object? error;
  Object? result;
  try {
    result = attempt();
  } catch (caught) {
    error = caught;
  }

  if (expected == 'refused') {
    if (error is! LlamaUnsupportedException ||
        !error.message.contains('llama.cpp v1.1.0')) {
      throw StateError('$mode was not refused: $error');
    }
    if (spy() != 0) {
      throw StateError(
        '$mode made ${spy()} by-value calls on a refused runtime',
      );
    }
  } else {
    if (error is LlamaUnsupportedException &&
        error.message.contains('llama.cpp v1.1.0')) {
      throw StateError('$mode refused an admitted runtime: $error');
    }
    // The spy has no mtmd exports and `load` stops at the first missing
    // backend symbol: both only need to get past admission.
    final mustProceed = switch (mode) {
      'dynamic' => result == null,
      'direct' || 'windows' || 'mtmd-default' => spy() < 1,
      _ => false,
    };
    if (mustProceed) {
      throw StateError('$mode did not proceed: $error');
    }
  }
}
