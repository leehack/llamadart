@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/model_fd_api.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/posix_file_descriptors.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 64,
);
const _greedy = GenerationParams(maxTokens: 4, temp: 0, topK: 1, seed: 1);

// Runs the real llama.cpp runtime on the CPU through a real descriptor.
void main() {
  if (Platform.isWindows) {
    test(
      'descriptors are POSIX only; Windows is covered by the unsupported '
      'tests',
      () {},
      skip: 'no descriptor loader on Windows',
    );
    return;
  }

  late Directory dir;
  late File model;
  late LlamaCppService service;
  final open = <int>[];

  int track(int fd) {
    open.add(fd);
    return fd;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_model_fd_');
    model = writeSyntheticLlamaGguf('${dir.path}/model.gguf');
    service = LlamaCppService(isMacosX64: false)..initializeBackend();
  });

  tearDown(() {
    service.dispose();
    open.forEach(closeDescriptor);
    open.clear();
    dir.deleteSync(recursive: true);
  });

  Future<void> generate(int context) async {
    final cancel = calloc<Int8>();
    try {
      await service
          .generate(context, 'ab', _greedy, cancel.address)
          .drain<void>();
    } finally {
      calloc.free(cancel);
    }
  }

  test('loads a model from a descriptor that is then closed, and decodes '
      'from the mapped file', () async {
    final fd = openReadOnlyDescriptor(model.path);
    final handle = service.loadModelFromDescriptor(
      fd,
      _params,
      size: model.lengthSync(),
    );
    closeDescriptor(fd);
    // The mapping holds the file; the path is not needed either.
    model.deleteSync();

    final tokens = service.tokenize(handle, 'ab', true);
    expect(tokens, isNotEmpty);
    await generate(service.createContext(handle, _params));
  });

  test('loads with the weights read into memory when mmap is off', () async {
    final fd = openReadOnlyDescriptor(model.path);
    final handle = service.loadModelFromDescriptor(
      fd,
      _params.copyWith(useMmap: false),
    );
    closeDescriptor(fd);

    await generate(service.createContext(handle, _params));
  });

  test('keeps the caller descriptor open at its offset, on success and on '
      'failure', () {
    final fd = track(openReadOnlyDescriptor(model.path));
    seekDescriptor(fd, 5);

    service.loadModelFromDescriptor(fd, _params, size: model.lengthSync());
    expect(descriptorOffset(fd), 5);

    expect(
      () => service.loadModelFromDescriptor(fd, _params, size: 1),
      throwsA(isA<LlamaArgumentException>()),
    );
    expect(descriptorOffset(fd), 5);
  });

  test('holds the model for isolate shutdown until it is freed, like a '
      'path-loaded one', () {
    List<ShutdownStage> held() => [
      for (final entry in IsolateShutdownReleases.current.debugHeldForTesting)
        entry.stage,
    ];
    final before = held().length;
    final fd = openReadOnlyDescriptor(model.path);

    final handle = service.loadModelFromDescriptor(fd, _params);
    closeDescriptor(fd);

    expect(held().length, before + 1);
    expect(held().last, ShutdownStage.model);
    service.freeModel(handle);
    expect(held().length, before);
  });

  test('a model loaded from a descriptor is freed like a path-loaded one and '
      'leaves the service able to load a path', () {
    final fd = openReadOnlyDescriptor(model.path);
    final handle = service.loadModelFromDescriptor(fd, _params);
    closeDescriptor(fd);

    service.freeModel(handle);

    expect(service.loadModel(model.path, _params), isNot(handle));
  });

  group('refusals map to typed exceptions and load nothing', () {
    void expectRefused(int Function() load, Matcher exception) {
      Object? caught;
      try {
        load();
      } catch (error) {
        caught = error;
      }
      expect(caught, exception);
      final message = (caught! as LlamaException).message;
      expect(message, isNot(contains(dir.path)));
      expect(message, isNot(contains('model.gguf')));
      expect(service.loadModel(model.path, _params), isNonNegative);
    }

    test('a closed descriptor is an argument error naming it', () {
      final fd = openReadOnlyDescriptor(model.path);
      closeDescriptor(fd);

      expectRefused(
        () => service.loadModelFromDescriptor(fd, _params),
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'fileDescriptor',
        ),
      );
    });

    test('a negative descriptor is an argument error', () {
      expectRefused(
        () => service.loadModelFromDescriptor(-1, _params),
        isA<LlamaArgumentException>(),
      );
    });

    test('a directory is not a regular file', () {
      final fd = track(openReadOnlyDescriptor(dir.path));

      expectRefused(
        () => service.loadModelFromDescriptor(fd, _params),
        isA<LlamaArgumentException>(),
      );
    });

    test(
      'a pipe, as a streaming content provider returns, is not seekable',
      () {
        final (read, write) = openPipeDescriptors();
        track(read);
        track(write);

        expectRefused(
          () => service.loadModelFromDescriptor(read, _params),
          isA<LlamaArgumentException>(),
        );
      },
    );

    test('a write-only descriptor is not readable', () {
      final fd = track(openWriteOnlyDescriptor(model.path));

      expectRefused(
        () => service.loadModelFromDescriptor(fd, _params),
        isA<LlamaArgumentException>(),
      );
    });

    test('a size that differs from the file is an argument error', () {
      final fd = track(openReadOnlyDescriptor(model.path));

      expectRefused(
        () => service.loadModelFromDescriptor(
          fd,
          _params,
          size: model.lengthSync() + 1,
        ),
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'size',
        ),
      );
    });

    test('a file that is not a GGUF is a model failure', () {
      final text = File('${dir.path}/notes.txt')
        ..writeAsStringSync('not a model');
      final fd = track(openReadOnlyDescriptor(text.path));

      expectRefused(
        () => service.loadModelFromDescriptor(fd, _params),
        isA<LlamaModelException>(),
      );
    });

    test('a truncated GGUF is a model failure', () {
      final truncated = File('${dir.path}/truncated.gguf')
        ..writeAsBytesSync(model.readAsBytesSync().sublist(0, 64));
      final fd = track(openReadOnlyDescriptor(truncated.path));

      expectRefused(
        () => service.loadModelFromDescriptor(fd, _params),
        isA<LlamaModelException>(),
      );
    });
  });

  group('without the loader nothing loads and nothing succeeds', () {
    LlamaCppService withoutLoader({bool isWindows = false}) => LlamaCppService(
      isMacosX64: false,
      isWindows: isWindows,
      objectCalls: LlamaCppObjectCalls.tracked(
        ExitTeardownApi.tryResolve(isWindows: false)!,
        isWindows: isWindows,
        modelFdResolver: () => null,
      ),
    )..initializeBackend();

    test('a runtime that lacks it, as a v1.1.0 override, throws unsupported '
        'naming v1.1.0-1 and still loads by path', () {
      final skewed = withoutLoader();
      addTearDown(skewed.dispose);
      final fd = track(openReadOnlyDescriptor(model.path));

      expect(
        () => skewed.loadModelFromDescriptor(fd, _params),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('v1.1.0-1'),
              contains('v1.1.0 runtime override'),
              contains('file descriptor'),
            ),
          ),
        ),
      );
      expect(skewed.loadModel(model.path, _params), isNonNegative);
    });

    test('a refusal does not wait for runtime admission, which a runtime '
        'without the loader may also fail', () {
      final unadmitted = LlamaCppService(
        isMacosX64: false,
        buildIdentity: () => null,
        objectCalls: LlamaCppObjectCalls.tracked(
          ExitTeardownApi.tryResolve(isWindows: false)!,
          modelFdResolver: () => null,
        ),
      )..initializeBackend();
      addTearDown(unadmitted.dispose);

      expect(
        () => unadmitted.loadModelFromDescriptor(3, _params),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('file descriptor'),
          ),
        ),
      );
    });

    test('Windows throws unsupported naming the platform', () {
      final windows = withoutLoader(isWindows: true);
      addTearDown(windows.dispose);

      expect(
        () => windows.loadModelFromDescriptor(3, _params),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('Windows'),
          ),
        ),
      );
    });
  });

  test('a GPU memory fit, which measures a path, is unsupported', () {
    final fd = track(openReadOnlyDescriptor(model.path));

    expect(
      () => service.loadModelFromDescriptor(
        fd,
        const ModelParams(
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
          contextSize: 64,
          gpuMemoryFit: GpuMemoryFit(),
        ),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('gpuMemoryFit'),
        ),
      ),
    );
  });

  test('loads inside the worker owner when one is installed', () async {
    // A worker isolate owns its models: the owner variant is the one called,
    // with the token the parent created. The installed owner is global to an
    // isolate, so this runs in its own.
    final calls = await Isolate.run(() {
      final bootstrap = LlamaCppService.createOwnerBootstrap();
      if (bootstrap == null) return ['no owner API'];
      final calls = <String>[];
      final service = LlamaCppService(
        isMacosX64: false,
        objectCalls: LlamaCppObjectCalls.tracked(
          ExitTeardownApi.tryResolve(isWindows: false)!,
          modelFdResolver: () => ModelFdApi(
            load: (_, _, _, _) {
              calls.add('plain');
              return ModelFdStatus.loadFailed.value;
            },
            ownerLoad: (owner, _, _, _, _) {
              calls.add(
                owner.address == bootstrap.token.address ? 'owner' : 'other',
              );
              return ModelFdStatus.loadFailed.value;
            },
          ),
        ),
      )..initializeBackend();
      service.installWorkerOwner(bootstrap.token.address);
      try {
        service.loadModelFromDescriptor(3, _params);
      } on LlamaModelException {
        calls.add('refused');
      }
      return calls;
    });

    expect(calls, ['owner', 'refused']);
  });
}
