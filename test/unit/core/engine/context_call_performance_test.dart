import 'dart:async';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import 'engine_test.dart';

class _EmbeddingDispatchBackend extends PerformanceCounterBackend {
  _EmbeddingDispatchBackend() : super(nativeChat: false);

  bool fail = false;
  bool failAsynchronously = false;
  int dispatches = 0;
  Completer<void>? gate;

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) {
    dispatches++;
    if (fail) {
      final error = LlamaInferenceException('Dispatch rejected before worker');
      if (failAsynchronously) return Future.error(error);
      throw error;
    }
    return _completeEmbed(contextHandle, text, normalize);
  }

  Future<List<double>> _completeEmbed(
    int contextHandle,
    String text,
    bool normalize,
  ) async {
    await gate?.future;
    return super.embed(contextHandle, text, normalize: normalize);
  }
}

class _ContentDispatchBackend extends _EmbeddingDispatchBackend
    implements BackendMultimodalEmbeddings {
  @override
  Future<LlamaEmbeddingCapabilities> getEmbeddingCapabilities(
    int contextHandle,
  ) async => const LlamaEmbeddingCapabilities(text: true);

  @override
  Future<List<List<double>>> embedContentBatch(
    int contextHandle,
    List<LlamaEmbeddingInput> inputs, {
    bool normalize = true,
  }) async => [
    for (final input in inputs)
      await embed(
        contextHandle,
        input.parts.cast<LlamaTextContent>().map((part) => part.text).join(),
        normalize: normalize,
      ),
  ];
}

Future<void> _cancelEarly(LlamaEngine engine) async {
  final cancelled = engine.generate('cancelled').toList();
  engine.cancelGeneration();
  await cancelled;
  expect(await engine.getPerformanceContext(), isNull);
}

void main() {
  final paths = <String, Future<Object?> Function(LlamaEngine)>{
    'embed': (engine) => engine.embed('hello'),
    'embedBatch': (engine) => engine.embedBatch(['hello', 'world']),
    'content fallback': (engine) => engine.embedContent(
      LlamaEmbeddingInput([const LlamaTextContent('hello')]),
    ),
    'content dispatch': (engine) => engine.embedContentBatch([
      LlamaEmbeddingInput([const LlamaTextContent('hello')]),
    ]),
  };

  for (final MapEntry(key: path, value: dispatch) in paths.entries) {
    _EmbeddingDispatchBackend newBackend() => path == 'content dispatch'
        ? _ContentDispatchBackend()
        : _EmbeddingDispatchBackend();

    for (final stale in [true, false]) {
      for (final asynchronous in [false, true]) {
        test('$path failed dispatch preserves performance availability: '
            'stale=$stale async=$asynchronous', () async {
          final backend = newBackend();
          final engine = LlamaEngine(backend);
          addTearDown(engine.dispose);
          await engine.loadModel('fake.gguf');
          await engine.generate('first').drain<void>();
          expect((await engine.getPerformanceContext())?.evalTokens, 1);
          if (stale) await _cancelEarly(engine);
          backend
            ..fail = true
            ..failAsynchronously = asynchronous;

          await expectLater(
            dispatch(engine),
            throwsA(isA<LlamaInferenceException>()),
          );
          expect(backend.dispatches, 1);
          expect(
            (await engine.getPerformanceContext())?.evalTokens,
            stale ? null : 1,
          );

          backend.fail = false;
          await dispatch(engine);
          expect((await engine.getPerformanceContext())?.evalTokens, 0);
        });
      }
    }

    test('$path restores cancelled performance only after success', () async {
      final backend = newBackend();
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('fake.gguf');
      await engine.generate('first').drain<void>();
      await _cancelEarly(engine);
      final gate = backend.gate = Completer<void>();
      final pending = dispatch(engine);
      await pumpEventQueue();
      expect(backend.dispatches, 1);
      expect(await engine.getPerformanceContext(), isNull);
      gate.complete();
      await pending;
      expect((await engine.getPerformanceContext())?.evalTokens, 0);
    });

    test(
      '$path success after reload cannot revive cancelled counters',
      () async {
        final backend = newBackend();
        final engine = LlamaEngine(backend);
        addTearDown(engine.dispose);
        await engine.loadModel('fake.gguf');
        await engine.generate('first').drain<void>();
        final gate = backend.gate = Completer<void>();
        final pending = dispatch(engine);
        await pumpEventQueue();
        expect(backend.dispatches, 1);
        final oldHandle = engine.contextHandle;
        await engine.unloadModel();
        await engine.loadModel('fake.gguf');
        expect(engine.contextHandle, oldHandle);
        await engine.generate('new model').drain<void>();
        await _cancelEarly(engine);
        gate.complete();
        await pending;
        expect(await engine.getPerformanceContext(), isNull);
        await engine.generate('recovery').drain<void>();
        expect((await engine.getPerformanceContext())?.evalTokens, 1);
      },
    );
  }
}
