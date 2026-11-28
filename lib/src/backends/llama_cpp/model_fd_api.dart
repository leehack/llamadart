import 'dart:ffi';

import '../../core/exceptions.dart';
import 'bindings.dart';

typedef _VersionNative = Uint32 Function();
typedef _LoadNative =
    Int32 Function(
      Int32,
      Int64,
      llama_model_params,
      Pointer<Pointer<llama_model>>,
    );
typedef _OwnerLoadNative =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int64,
      llama_model_params,
      Pointer<Pointer<llama_model>>,
    );

/// The result of `llama_dart_model_load_from_fd`, as documented by
/// llamadart-native's `docs/model_load_from_fd.md`.
enum ModelFdStatus {
  /// `*out_model` is a tracked model.
  success(0),

  /// `out_model` was null.
  invalidArgument(1),

  /// The platform has no descriptor loader (Windows). Never a success.
  unsupported(2),

  /// The descriptor is negative, closed, write-only, not a regular file or
  /// not seekable.
  invalidDescriptor(3),

  /// The expected size differs from the size of the file.
  sizeMismatch(4),

  /// llama.cpp refused the file, or teardown cancelled the load.
  loadFailed(5),

  /// A caught exception, an unknown or inactive owner or no free descriptor.
  error(6);

  const ModelFdStatus(this.value);

  /// The value the wrapper returns.
  final int value;

  /// The status the wrapper returned as [value], or `null` for a value this
  /// release does not know.
  static ModelFdStatus? fromValue(int value) {
    for (final status in values) {
      if (status.value == value) return status;
    }
    return null;
  }
}

/// The optional caller-owned file-descriptor model loader of
/// llamadart-native, resolved as one unit.
///
/// `llama_dart_model_load_from_fd` and `llama_dart_owner_model_load_from_fd`
/// are the descriptor twins of the path loaders: they share the exit-teardown
/// guard, progress callback, cancellation and owner semantics, and the model
/// they return is tracked, so it is freed with the same `llama_dart_exit_free`
/// as a path-loaded one. The wrapper duplicates the descriptor and closes
/// only its duplicate, so the caller keeps its own.
///
/// A runtime that exports none of them (llamadart-native before
/// [minimumNativeRelease], including a `v1.1.0` runtime override that the
/// build identity admits), exports only some, or reports a version below
/// [minimumVersion] resolves to `null`.
final class ModelFdApi {
  /// Creates an API from resolved functions.
  const ModelFdApi({required this.load, required this.ownerLoad});

  /// The oldest `llamadart-native` release that exports the loader.
  static const String minimumNativeRelease = 'v1.1.0-1';

  /// The version `llama_dart_model_fd_api_version` reports from
  /// [minimumNativeRelease] on every platform with a loader.
  static const int minimumVersion = 1;

  /// Resolves the loader from the loaded runtime, or returns `null` when the
  /// runtime lacks it.
  ///
  /// Windows never resolves: the wrapper reports version 0 there, and the
  /// descriptor of another C runtime cannot be duplicated safely.
  ///
  /// [symbol] replaces the lookup: it returns the address of the function
  /// exported under a name, and throws [ArgumentError] when there is none.
  static ModelFdApi? tryResolve({
    bool isWindows = false,
    Pointer<NativeType> Function(String name)? symbol,
  }) {
    if (isWindows) return null;
    final resolve = symbol ?? _bindingsSymbol;
    try {
      final version = resolve(
        'llama_dart_model_fd_api_version',
      ).cast<NativeFunction<_VersionNative>>().asFunction<int Function()>();
      final load = resolve(
        'llama_dart_model_load_from_fd',
      ).cast<NativeFunction<_LoadNative>>().asFunction<_Load>();
      final ownerLoad = resolve(
        'llama_dart_owner_model_load_from_fd',
      ).cast<NativeFunction<_OwnerLoadNative>>().asFunction<_OwnerLoad>();
      if (version() < minimumVersion) return null;
      return ModelFdApi(load: load, ownerLoad: ownerLoad);
    } on ArgumentError {
      return null;
    }
  }

  /// `llama_dart_model_load_from_fd`.
  final int Function(
    int fd,
    int size,
    llama_model_params params,
    Pointer<Pointer<llama_model>> out,
  )
  load;

  /// `llama_dart_owner_model_load_from_fd`.
  final int Function(
    Pointer<Void> owner,
    int fd,
    int size,
    llama_model_params params,
    Pointer<Pointer<llama_model>> out,
  )
  ownerLoad;
}

typedef _Load =
    int Function(int, int, llama_model_params, Pointer<Pointer<llama_model>>);
typedef _OwnerLoad =
    int Function(
      Pointer<Void>,
      int,
      int,
      llama_model_params,
      Pointer<Pointer<llama_model>>,
    );

/// The exception for a runtime without a descriptor loader.
///
/// Names the capability, the condition and [ModelFdApi.minimumNativeRelease];
/// loading from a descriptor never reports success without the loader.
LlamaUnsupportedException modelFdUnsupported({
  required bool isWindows,
  bool hasExitTeardown = true,
}) {
  const capability = 'Loading a model from a caller-owned file descriptor';
  const fallback =
      'Load the model by path instead, copying a file that has no '
      'local path into a local file first.';
  if (isWindows) {
    return LlamaUnsupportedException(
      '$capability is not supported on Windows: the llama.cpp runtime has no '
      'descriptor loader there. $fallback',
    );
  }
  final reason = hasExitTeardown
      ? 'the loaded llama.cpp runtime does not export '
            'llama_dart_model_fd_api_version, llama_dart_model_load_from_fd '
            'and llama_dart_owner_model_load_from_fd at version '
            '${ModelFdApi.minimumVersion} or later'
      : 'the loaded llama.cpp runtime predates the exit-teardown functions '
            'the loader builds on';
  return LlamaUnsupportedException(
    '$capability needs llamadart-native ${ModelFdApi.minimumNativeRelease} or '
    'later, but $reason. A v1.1.0 runtime override lacks them: use the '
    'package-pinned native runtime. $fallback',
  );
}

/// The exception for a non-success [status] of the descriptor loader.
///
/// The messages carry no path, descriptor content or native error text.
/// [size] is the size the caller expected, or negative when it passed none.
LlamaException modelFdFailure(int status, {required int size}) {
  const copyFallback = 'Copy the model to a local file and load it by path.';
  switch (ModelFdStatus.fromValue(status)) {
    case ModelFdStatus.success:
      throw StateError('A successful status has no failure.');
    case ModelFdStatus.invalidArgument:
      return LlamaArgumentException(
        'The native descriptor loader rejected its arguments.',
      );
    case ModelFdStatus.unsupported:
      return modelFdUnsupported(isWindows: true);
    case ModelFdStatus.invalidDescriptor:
      return LlamaArgumentException(
        'The file descriptor is not a readable, seekable regular file. A '
        'content provider that streams the document returns a pipe or a '
        'socket instead. $copyFallback',
        name: 'fileDescriptor',
      );
    case ModelFdStatus.sizeMismatch:
      return LlamaArgumentException(
        'The size of the file behind the descriptor is not the expected '
        '$size bytes. The file may be incomplete or have changed.',
        name: 'size',
        invalidValue: size,
      );
    case ModelFdStatus.loadFailed:
      return LlamaModelException(
        'llama.cpp could not load a model from the file descriptor: it is not '
        'a complete single-file GGUF at offset 0, cannot be memory-mapped '
        '(set ModelParams.useMmap to false to read it instead), or the load '
        'was cancelled.',
      );
    case ModelFdStatus.error:
      return LlamaModelException(
        'The native descriptor loader failed: it caught an exception, has no '
        'free descriptor or lost its owner.',
      );
    case null:
      return LlamaModelException(
        'The native descriptor loader returned the unknown status $status.',
      );
  }
}

Pointer<NativeType> _bindingsSymbol(String name) => switch (name) {
  'llama_dart_model_fd_api_version' =>
    Native.addressOf<NativeFunction<_VersionNative>>(
      llama_dart_model_fd_api_version,
    ),
  'llama_dart_model_load_from_fd' =>
    Native.addressOf<NativeFunction<_LoadNative>>(
      llama_dart_model_load_from_fd,
    ),
  'llama_dart_owner_model_load_from_fd' =>
    Native.addressOf<NativeFunction<_OwnerLoadNative>>(
      llama_dart_owner_model_load_from_fd,
    ),
  _ => throw ArgumentError.value(name, 'name', 'not bound'),
};
