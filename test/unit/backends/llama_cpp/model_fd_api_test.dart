@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/model_fd_api.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

const _symbols = [
  'llama_dart_model_fd_api_version',
  'llama_dart_model_load_from_fd',
  'llama_dart_owner_model_load_from_fd',
];

final _model = Pointer<llama_model>.fromAddress(0x1000);

Matcher _unsupportedNaming(List<String> parts) =>
    isA<LlamaUnsupportedException>().having(
      (error) => error.message,
      'message',
      allOf(parts.map(contains).toList()),
    );

// Stands for a runtime whose version function returns [version] and whose
// other exports exist; only the version is ever called by the probe.
Pointer<NativeType> Function(String) _exports(
  NativeCallable<Uint32 Function()> version, {
  Set<String> missing = const {},
  List<String>? requested,
}) {
  return (name) {
    requested?.add(name);
    if (missing.contains(name)) throw ArgumentError('Missing $name');
    return version.nativeFunction;
  };
}

NativeCallable<Uint32 Function()> _version(int value) {
  final version = NativeCallable<Uint32 Function()>.isolateLocal(
    () => value,
    exceptionalReturn: 0,
  );
  addTearDown(version.close);
  return version;
}

void main() {
  group('tryResolve', () {
    test('resolves a runtime that exports the loader at version 1', () {
      expect(ModelFdApi.tryResolve(symbol: _exports(_version(1))), isNotNull);
    });

    test('accepts a later version', () {
      expect(ModelFdApi.tryResolve(symbol: _exports(_version(2))), isNotNull);
    });

    test('a runtime without the version export, as a v1.1.0 override that '
        'predates the loader, resolves to nothing', () {
      final requested = <String>[];
      expect(
        ModelFdApi.tryResolve(
          symbol: _exports(
            _version(1),
            missing: {..._symbols},
            requested: requested,
          ),
        ),
        isNull,
      );
      expect(requested, ['llama_dart_model_fd_api_version']);
    });

    for (final missing in _symbols) {
      test('a runtime missing $missing is a partial runtime and resolves to '
          'nothing', () {
        expect(
          ModelFdApi.tryResolve(
            symbol: _exports(_version(1), missing: {missing}),
          ),
          isNull,
        );
      });
    }

    test('version 0, which Windows reports, resolves to nothing', () {
      expect(ModelFdApi.tryResolve(symbol: _exports(_version(0))), isNull);
    });

    test('Windows resolves to nothing without looking anything up', () {
      final requested = <String>[];
      expect(
        ModelFdApi.tryResolve(
          isWindows: true,
          symbol: _exports(_version(1), requested: requested),
        ),
        isNull,
      );
      expect(requested, isEmpty);
    });

    test('a failure that is not a missing symbol is not hidden', () {
      expect(
        () => ModelFdApi.tryResolve(symbol: (_) => throw StateError('broken')),
        throwsStateError,
      );
    });

    test('resolves from the loaded pinned runtime off Windows', () {
      if (Platform.isWindows) return;
      final api = ModelFdApi.tryResolve();
      expect(api, isNotNull);
    });
  });

  group('modelFdUnsupported', () {
    test('names the capability, the native release and the fallback', () {
      expect(
        modelFdUnsupported(isWindows: false),
        _unsupportedNaming([
          'Loading a model from a caller-owned file descriptor',
          ModelFdApi.minimumNativeRelease,
          'llama_dart_model_fd_api_version',
          'v1.1.0 runtime override',
          'Load the model by path',
        ]),
      );
      expect(ModelFdApi.minimumNativeRelease, 'v1.1.0-1');
    });

    test('names Windows instead of a release there', () {
      expect(
        modelFdUnsupported(isWindows: true),
        _unsupportedNaming(['not supported on Windows', 'by path']),
      );
    });

    test('names the missing exit-teardown functions when they are the '
        'reason', () {
      expect(
        modelFdUnsupported(isWindows: false, hasExitTeardown: false),
        _unsupportedNaming(['predates the exit-teardown functions']),
      );
    });
  });

  group('modelFdFailure', () {
    final expected = <ModelFdStatus, Matcher>{
      ModelFdStatus.invalidArgument: isA<LlamaArgumentException>(),
      ModelFdStatus.unsupported: isA<LlamaUnsupportedException>(),
      ModelFdStatus.invalidDescriptor: isA<LlamaArgumentException>().having(
        (error) => error.name,
        'name',
        'fileDescriptor',
      ),
      ModelFdStatus.sizeMismatch: isA<LlamaArgumentException>()
          .having((error) => error.name, 'name', 'size')
          .having((error) => error.invalidValue, 'invalidValue', 42),
      ModelFdStatus.loadFailed: isA<LlamaModelException>(),
      ModelFdStatus.error: isA<LlamaModelException>(),
    };

    for (final entry in expected.entries) {
      test('${entry.key.name} maps to its typed exception without a path or '
          'native text', () {
        final error = modelFdFailure(entry.key.value, size: 42);
        expect(error, entry.value);
        expect(error.message, isNot(contains('/')));
        expect(error.message, isNot(contains(r'\')));
        expect(error.details, isNull);
      });
    }

    test('an unknown status is a model failure that names it', () {
      expect(
        modelFdFailure(99, size: -1),
        isA<LlamaModelException>().having(
          (error) => error.message,
          'message',
          contains('99'),
        ),
      );
    });

    test('success has no failure to map', () {
      expect(
        () => modelFdFailure(ModelFdStatus.success.value, size: -1),
        throwsStateError,
      );
    });

    test('status values are the wire values of the wrapper', () {
      expect(
        [for (final status in ModelFdStatus.values) status.value],
        [0, 1, 2, 3, 4, 5, 6],
      );
      expect(ModelFdStatus.fromValue(5), ModelFdStatus.loadFailed);
      expect(ModelFdStatus.fromValue(7), isNull);
    });
  });

  group('LlamaCppObjectCalls.loadModelFromDescriptor', () {
    LlamaCppObjectCalls calls({
      required ModelFdApi? api,
      bool isWindows = false,
    }) => LlamaCppObjectCalls.tracked(
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!,
      isWindows: isWindows,
      modelFdResolver: () => api,
    );

    test('returns the model the loader wrote and passes fd, size and '
        'params', () {
      final seen = <Object?>[];
      final subject = calls(
        api: ModelFdApi(
          load: (fd, size, params, out) {
            seen.addAll([fd, size, params.n_gpu_layers]);
            out.value = _model;
            return ModelFdStatus.success.value;
          },
          ownerLoad: (_, _, _, _, _) => fail('the owner loader is not used'),
        ),
      );

      final params = llama_model_default_params()..n_gpu_layers = 3;
      expect(subject.loadModelFromDescriptor(7, 123, params), _model);
      expect(seen, [7, 123, 3]);
    });

    test('loads inside the owner when it is given', () {
      final owner = Pointer<Void>.fromAddress(0x2000);
      Pointer<Void>? seenOwner;
      final subject = calls(
        api: ModelFdApi(
          load: (_, _, _, _) => fail('the plain loader is not used'),
          ownerLoad: (token, fd, size, params, out) {
            seenOwner = token;
            out.value = _model;
            return ModelFdStatus.success.value;
          },
        ),
      );

      final model = subject.loadModelFromDescriptor(
        7,
        -1,
        llama_model_default_params(),
        owner: owner,
      );

      expect(model, _model);
      expect(seenOwner, owner);
    });

    for (final status in ModelFdStatus.values.skip(1)) {
      test('${status.name} throws what modelFdFailure maps it to', () {
        final subject = calls(
          api: ModelFdApi(
            load: (_, _, _, out) {
              out.value = nullptr;
              return status.value;
            },
            ownerLoad: (_, _, _, _, _) => status.value,
          ),
        );

        expect(
          () => subject.loadModelFromDescriptor(
            7,
            9,
            llama_model_default_params(),
          ),
          throwsA(
            isA<LlamaException>().having(
              (error) => error.runtimeType,
              'type',
              modelFdFailure(status.value, size: 9).runtimeType,
            ),
          ),
        );
      });
    }

    test('a success without a model is a failure, not a null model', () {
      final subject = calls(
        api: ModelFdApi(
          load: (_, _, _, out) {
            out.value = nullptr;
            return ModelFdStatus.success.value;
          },
          ownerLoad: (_, _, _, _, _) => 0,
        ),
      );

      expect(
        () => subject.loadModelFromDescriptor(
          7,
          -1,
          llama_model_default_params(),
        ),
        throwsA(isA<LlamaModelException>()),
      );
    });

    test('a runtime without the loader throws unsupported, never a '
        'success', () {
      var called = false;
      final subject = calls(api: null);
      expect(subject.modelFd, isNull);
      expect(
        () {
          called = true;
          return subject.loadModelFromDescriptor(
            7,
            -1,
            llama_model_default_params(),
          );
        },
        _throwsUnsupportedNaming([
          'v1.1.0-1',
          'llama_dart_model_fd_api_version',
        ]),
      );
      expect(called, isTrue);
    });

    test('Windows throws unsupported by platform', () {
      final subject = LlamaCppObjectCalls.tracked(
        ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!,
        isWindows: true,
      );

      expect(subject.modelFd, isNull);
      expect(
        () => subject.requireModelFd(),
        _throwsUnsupportedNaming(['Windows']),
      );
    });

    test('a runtime without exit teardown has no loader', () {
      final subject = LlamaCppObjectCalls.upstream;

      expect(subject.modelFd, isNull);
      expect(
        () => subject.requireModelFd(),
        _throwsUnsupportedNaming(['exit-teardown']),
      );
    });

    test('resolve admits the loader of a runtime that exports it', () {
      final subject = LlamaCppObjectCalls.resolve(
        isWindows: false,
        symbol: _exports(_version(1)),
      );

      expect(subject.exit, isNotNull);
      expect(subject.modelFd, isNotNull);
    });

    test('a runtime with exit teardown but not the loader, as a v1.1.0 '
        'override, keeps loading by path and refuses a descriptor', () {
      final subject = LlamaCppObjectCalls.resolve(
        isWindows: false,
        symbol: _exports(_version(1), missing: {..._symbols}),
      );

      expect(subject.exit, isNotNull);
      expect(subject.modelFd, isNull);
      expect(
        () => subject.requireModelFd(),
        _throwsUnsupportedNaming(['v1.1.0-1', 'v1.1.0 runtime override']),
      );
    });
  });
}

Matcher _throwsUnsupportedNaming(List<String> parts) =>
    throwsA(_unsupportedNaming(parts));
