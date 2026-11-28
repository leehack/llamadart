@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import 'engine_test.dart' show MockLlamaBackend;

final class _DescriptorBackend extends MockLlamaBackend
    implements BackendFileDescriptorModelLoad {
  _DescriptorBackend({super.failContextCreate});

  final List<({int fd, int? size, ModelParams params})> loads = [];
  Object? failure;

  @override
  Future<int> modelLoadFromFileDescriptor(
    int fileDescriptor,
    ModelParams params, {
    int? size,
  }) async {
    loads.add((fd: fileDescriptor, size: size, params: params));
    if (failure case final error?) throw error;
    return 7;
  }
}

void main() {
  late _DescriptorBackend backend;
  late LlamaEngine engine;
  late LlamaModel pathModel;

  setUp(() {
    backend = _DescriptorBackend();
    engine = LlamaEngine(backend);
    final dir = Directory.systemTemp.createTempSync('llamadart_fd_engine_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/old.gguf')..writeAsBytesSync([1, 2, 3]);
    pathModel = LlamaModel(ModelSource.path(file.path));
  });

  tearDown(() => engine.dispose());

  test('loads a model from a descriptor and makes it ready', () async {
    const params = ModelParams(contextSize: 512);

    await engine.setModelFromFileDescriptor(5, size: 1234, params: params);

    expect(engine.isReady, isTrue);
    expect(backend.loads.single.fd, 5);
    expect(backend.loads.single.size, 1234);
    expect(backend.loads.single.params.contextSize, 512);
    expect(backend.modelLoadCalls, 0, reason: 'no path load is involved');
    expect(
      await engine.create([
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ]).text(),
      'response',
    );
  });

  test('accepts the largest 32-bit descriptor', () async {
    await engine.setModelFromFileDescriptor(0x7fffffff);

    expect(backend.loads.single.fd, 0x7fffffff);
  });

  test('passes a null size, which skips the size check', () async {
    await engine.setModelFromFileDescriptor(5);

    expect(backend.loads.single.size, isNull);
  });

  test('replaces the loaded model, unloading it first', () async {
    await engine.setModel(pathModel);

    await engine.setModelFromFileDescriptor(5);

    expect(backend.modelFreeCalls, 1);
    expect(backend.loads, hasLength(1));
    expect(engine.isReady, isTrue);
  });

  group('arguments are checked before the loaded model is touched', () {
    setUp(() async {
      await engine.setModel(pathModel);
    });

    Future<void> expectKept(
      Future<void> Function() load,
      Matcher exception,
    ) async {
      await expectLater(load(), throwsA(exception));
      expect(engine.isReady, isTrue);
      expect(backend.modelFreeCalls, 0);
      expect(backend.loads, isEmpty);
    }

    test('a negative descriptor', () {
      return expectKept(
        () => engine.setModelFromFileDescriptor(-1),
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'fileDescriptor',
        ),
      );
    });

    for (final fd in [0x80000000, (1 << 32) + 8]) {
      test('a descriptor of $fd, which the runtime would truncate to '
          'another one', () {
        return expectKept(
          () => engine.setModelFromFileDescriptor(fd),
          isA<LlamaArgumentException>().having(
            (error) => error.name,
            'name',
            'fileDescriptor',
          ),
        );
      });
    }

    test('a negative size', () {
      return expectKept(
        () => engine.setModelFromFileDescriptor(5, size: -1),
        isA<LlamaArgumentException>().having(
          (error) => error.name,
          'name',
          'size',
        ),
      );
    });

    test('invalid model params', () {
      return expectKept(
        () => engine.setModelFromFileDescriptor(
          5,
          params: const ModelParams(gpuLayers: 0, gpuMemoryFit: GpuMemoryFit()),
        ),
        isA<LlamaArgumentException>(),
      );
    });

    test('a LoRA adapter that is a source rather than a local path', () {
      return expectKept(
        () => engine.setModelFromFileDescriptor(
          5,
          params: ModelParams(
            loras: [
              LoraAdapterConfig.source(
                ModelSource.url(Uri.parse('https://example.com/a.gguf')),
              ),
            ],
          ),
        ),
        isA<LlamaUnsupportedException>(),
      );
    });

    test('a backend that cannot load from a descriptor', () async {
      final plain = MockLlamaBackend();
      final plainEngine = LlamaEngine(plain);
      addTearDown(plainEngine.dispose);
      await plainEngine.setModel(pathModel);

      await expectLater(
        plainEngine.setModelFromFileDescriptor(5),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('file descriptor'),
          ),
        ),
      );
      expect(plainEngine.isReady, isTrue);
      expect(plain.modelFreeCalls, 0);
    });
  });

  group('a failed load leaves nothing loaded and keeps the typed error', () {
    for (final (name, error, matcher) in <(String, Object, Matcher)>[
      (
        'unsupported, as a runtime without the loader',
        LlamaUnsupportedException('needs llamadart-native v1.1.0-1'),
        isA<LlamaUnsupportedException>(),
      ),
      (
        'an argument error, as a descriptor the runtime refuses',
        LlamaArgumentException('not a regular file', name: 'fileDescriptor'),
        isA<LlamaArgumentException>(),
      ),
      (
        'a model error, as llama.cpp refusing the file',
        LlamaModelException('llama.cpp could not load the model'),
        isA<LlamaModelException>(),
      ),
    ]) {
      test(name, () async {
        await engine.setModel(pathModel);
        backend.failure = error;

        await expectLater(
          engine.setModelFromFileDescriptor(5),
          throwsA(matcher),
        );

        expect(engine.isReady, isFalse);
        expect(backend.modelFreeCalls, 1, reason: 'the old model was replaced');
      });
    }

    test('an untyped failure becomes a model failure without leaking the '
        'descriptor source', () async {
      backend.failure = Exception('boom');

      await expectLater(
        engine.setModelFromFileDescriptor(5),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            'Failed to load a model from a file descriptor',
          ),
        ),
      );
      expect(engine.isReady, isFalse);
    });

    test('a context that cannot be created frees the loaded model and leaves '
        'nothing loaded', () async {
      final failing = _DescriptorBackend(failContextCreate: true);
      final failingEngine = LlamaEngine(failing);
      addTearDown(failingEngine.dispose);

      await expectLater(
        failingEngine.setModelFromFileDescriptor(5),
        throwsA(isA<LlamaModelException>()),
      );

      expect(failing.loads, hasLength(1));
      expect(failing.modelFreeCalls, 1);
      expect(failingEngine.isReady, isFalse);
    });

    test('an engine whose load failed can load again', () async {
      backend.failure = LlamaModelException('refused');
      await expectLater(
        engine.setModelFromFileDescriptor(5),
        throwsA(isA<LlamaModelException>()),
      );
      backend.failure = null;

      await engine.setModelFromFileDescriptor(6);

      expect(engine.isReady, isTrue);
    });
  });

  test('throws after dispose', () async {
    await engine.dispose();

    await expectLater(
      engine.setModelFromFileDescriptor(5),
      throwsA(isA<LlamaStateException>()),
    );
  });
}
