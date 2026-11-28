@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:llamadart/src/backends/native/native_backend.dart';
import 'package:test/test.dart';

import '../../core/engine/engine_test.dart' show MockLlamaBackend;

import '../../../support/posix_file_descriptors.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 64,
);

// Runs the real llama.cpp worker isolate on the CPU through a real descriptor.
void main() {
  if (Platform.isWindows) {
    test('descriptors are POSIX only', () {}, skip: 'no loader on Windows');
    return;
  }

  late Directory dir;
  late File model;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_backend_fd_');
    model = writeSyntheticLlamaGguf('${dir.path}/model.gguf');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  for (final (name, create) in <(String, LlamaBackend Function())>[
    ('the llama.cpp backend', NativeLlamaBackend.new),
    ('the default backend that routes by runtime', NativeAutoBackend.new),
  ]) {
    group(name, () {
      late LlamaEngine engine;

      setUp(() => engine = LlamaEngine(create()));
      tearDown(() => engine.dispose());

      test(
        'loads from a descriptor the app then closes, and generates',
        () async {
          final fd = openReadOnlyDescriptor(model.path);
          await engine.setModelFromFileDescriptor(
            fd,
            size: model.lengthSync(),
            params: _params,
          );
          closeDescriptor(fd);
          model.deleteSync();

          expect(engine.isReady, isTrue);
          final tokens = await engine.tokenize('ab');
          expect(tokens, isNotEmpty);
          final text = StringBuffer();
          await for (final token in engine.generate(
            'ab',
            params: const GenerationParams(maxTokens: 4, temp: 0, topK: 1),
          )) {
            text.write(token);
          }
          expect(engine.isReady, isTrue);
        },
      );

      test('a refused descriptor keeps its typed error across the worker '
          'isolate, and the engine loads by path afterwards', () async {
        final fd = openReadOnlyDescriptor(model.path);
        addTearDown(() => closeDescriptor(fd));

        await expectLater(
          engine.setModelFromFileDescriptor(fd, size: 1, params: _params),
          throwsA(
            isA<LlamaArgumentException>().having(
              (error) => error.message,
              'message',
              contains('expected 1 bytes'),
            ),
          ),
        );
        await expectLater(
          engine.setModelFromFileDescriptor(-1, params: _params),
          throwsA(isA<LlamaArgumentException>()),
        );
        expect(engine.isReady, isFalse);

        await engine.setModel(
          LlamaModel(ModelSource.path(model.path)),
          params: _params,
        );
        expect(engine.isReady, isTrue);
      });

      test('a file that is not a GGUF is a model failure', () async {
        final text = File('${dir.path}/notes.txt')
          ..writeAsStringSync('not a model');
        final fd = openReadOnlyDescriptor(text.path);
        addTearDown(() => closeDescriptor(fd));

        await expectLater(
          engine.setModelFromFileDescriptor(fd, params: _params),
          throwsA(
            isA<LlamaModelException>().having(
              (error) => error.message,
              'message',
              isNot(contains(dir.path)),
            ),
          ),
        );
        expect(engine.isReady, isFalse);
      });
    });
  }

  test('a router whose llama.cpp backend is custom and lacks the capability '
      'refuses with unsupported', () async {
    final router = NativeAutoBackend(llamaCppFactory: MockLlamaBackend.new);
    addTearDown(router.dispose);

    await expectLater(
      router.modelLoadFromFileDescriptor(3, _params),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          contains('custom llama.cpp backend factory'),
        ),
      ),
    );
  });
}
