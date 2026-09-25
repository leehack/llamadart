import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart'
    show BackendEmbeddings, BackendGenerationLimit, BackendRuntimeIdentity;
import 'package:test/test.dart';

import 'engine_test.dart' show LimitReportingMockBackend, MockLlamaBackend;

class _ObservedBackend extends LimitReportingMockBackend
    implements BackendEmbeddings, BackendRuntimeIdentity {
  Map<String, String>? metadata;
  Object? generateError;

  @override
  LlamaRuntime? get runtime => LlamaRuntime.llamaCpp;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final base = await super.modelMetadata(modelHandle);
    return {...base, ...?metadata};
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    final error = generateError;
    if (error != null) return Stream<List<int>>.error(error);
    return super.generate(contextHandle, prompt, params, parts: parts);
  }

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) async => <double>[text.length.toDouble()];
}

class _Recorder extends LlamaEngineObserver {
  final List<LlamaOperation> operations = <LlamaOperation>[];
  final List<Object?> startZoneValues = <Object?>[];
  final List<Object> events = <Object>[];
  final List<LlamaOperationResult> results = <LlamaOperationResult>[];
  final List<Object?> endZoneValues = <Object?>[];

  void clear() {
    operations.clear();
    startZoneValues.clear();
    events.clear();
    results.clear();
    endZoneValues.clear();
  }

  @override
  LlamaOperationObserver? onStart(LlamaOperation operation) {
    operations.add(operation);
    startZoneValues.add(Zone.current[#trace]);
    return _OperationRecorder(this);
  }
}

class _OperationRecorder extends LlamaOperationObserver {
  final _Recorder recorder;

  _OperationRecorder(this.recorder);

  @override
  void onChunk(LlamaCompletionChunk chunk) => recorder.events.add(chunk);

  @override
  void onText(String text) => recorder.events.add(text);

  @override
  void onEnd(LlamaOperationResult result) {
    recorder.results.add(result);
    recorder.endZoneValues.add(Zone.current[#trace]);
  }
}

class _ThrowingObserver extends LlamaEngineObserver {
  final bool throwOnStart;

  _ThrowingObserver({required this.throwOnStart});

  @override
  LlamaOperationObserver? onStart(LlamaOperation operation) {
    if (throwOnStart) throw StateError('start');
    return _ThrowingOperationObserver();
  }
}

class _ThrowingOperationObserver extends LlamaOperationObserver {
  @override
  void onChunk(LlamaCompletionChunk chunk) => throw StateError('chunk');

  @override
  void onText(String text) => throw StateError('text');

  @override
  void onEnd(LlamaOperationResult result) => throw StateError('end');
}

const _user = LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi');
const _usage = LlamaGenerationUsage(
  promptTokens: 7,
  completionTokens: 2,
  duration: Duration(milliseconds: 9),
);

void main() {
  late _ObservedBackend backend;
  late _Recorder recorder;
  late LlamaEngine engine;

  setUp(() async {
    backend = _ObservedBackend()..metadata = {'general.name': 'Tiny Llama'};
    recorder = _Recorder();
    engine = LlamaEngine(backend, observers: [recorder]);
    await engine.loadModel('/private/models/tiny.gguf');
    recorder.clear();
  });

  tearDown(() => engine.dispose());

  group('model load', () {
    test('reports the file name, never the directory', () async {
      final loads = _Recorder();
      final observed = LlamaEngine(_ObservedBackend(), observers: [loads]);
      addTearDown(observed.dispose);

      await observed.loadModel(
        '/private/models/tiny.gguf',
        modelParams: const ModelParams(contextSize: 128),
      );

      final load = loads.operations.single as LlamaModelLoadOperation;
      expect(load.model, 'tiny.gguf');
      expect(load.runtime, isNull);
      expect(load.modelParams.contextSize, 128);
      expect(loads.results.single.error, isNull);
    });

    test('reports a URL load by its last path segment', () async {
      final loads = _Recorder();
      final observed = LlamaEngine(
        MockLlamaBackend(urlLoadingSupported: true),
        observers: [loads],
      );
      addTearDown(observed.dispose);

      await observed.loadModelFromUrl(
        'https://example.com/org/tiny.gguf?token=secret',
      );

      expect(loads.operations.single.model, 'tiny.gguf');
    });

    test('reports a failed load with its error', () async {
      final loads = _Recorder();
      final observed = LlamaEngine(
        MockLlamaBackend(failModelLoad: true),
        observers: [loads],
      );
      addTearDown(observed.dispose);

      await expectLater(
        observed.loadModel('/models/broken.gguf'),
        throwsA(isA<LlamaModelException>()),
      );

      expect(loads.results.single.error, isA<LlamaModelException>());
    });

    test('names later operations by the file name without general.name, '
        'and forgets the name on unload', () async {
      await engine.unloadModel();
      backend.metadata = {'general.name': '  '};
      await engine.loadModel('/models/other.gguf');
      await engine.generate('p').drain<void>();

      expect(recorder.operations.last.model, 'other.gguf');
    });
  });

  group('create', () {
    test('reports the request, each chunk and the final usage', () async {
      backend.nextUsage = _usage;
      backend.generationChunks = ['Hel', 'lo'];
      final tool = ToolDefinition(
        name: 'ping',
        description: 'Ping.',
        parameters: const [],
        handler: (_) async => null,
      );
      const params = GenerationParams(maxTokens: 12, temp: 0.3);

      final chunks = await engine
          .create(
            const [_user],
            params: params,
            tools: [tool],
            toolChoice: ToolChoice.none,
          )
          .toList();

      final chat = recorder.operations.single as LlamaChatOperation;
      expect(chat.model, 'Tiny Llama');
      expect(chat.runtime, LlamaRuntime.llamaCpp);
      expect(chat.messages, const [_user]);
      expect(chat.params, same(params));
      expect(chat.tools, [tool]);
      expect(chat.toolChoice, ToolChoice.none);
      expect(recorder.events, chunks);
      final result = recorder.results.single;
      expect(result.finishReason, 'stop');
      expect(result.usage, same(_usage));
      expect(result.cancelled, isFalse);
      expect(result.error, isNull);
    });

    test('reports a length finish', () async {
      backend.nextLimit = BackendGenerationLimit.maxTokens;

      await engine.create(const [_user]).drain<void>();

      expect(recorder.results.single.finishReason, 'length');
    });

    test('starts when listened to, in the zone that called create', () async {
      final stream = runZoned(
        () => engine.create(const [_user]),
        zoneValues: {#trace: 'parent'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(recorder.operations, isEmpty);

      await stream.drain<void>();

      expect(recorder.startZoneValues, ['parent']);
      expect(recorder.endZoneValues, ['parent']);
    });

    test('reports a subscription cancel once', () async {
      backend.generationChunks = ['a', 'b', 'c'];
      final first = Completer<void>();
      late StreamSubscription<LlamaCompletionChunk> subscription;
      subscription = engine.create(const [_user]).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;

      await subscription.cancel();

      final result = recorder.results.single;
      expect(result.cancelled, isTrue);
      expect(result.finishReason, isNull);
    });

    test('reports cancelGeneration before the backend as cancelled', () async {
      final stream = engine.create(const [_user]);
      final done = stream.drain<void>();
      engine.cancelGeneration();
      await done;

      expect(recorder.results.single.cancelled, isTrue);
      expect(recorder.results.single.finishReason, isNull);
    });

    test('reports a backend failure with its error', () async {
      backend.generateError = StateError('boom');

      await expectLater(
        engine.create(const [_user]).drain<void>(),
        throwsA(isA<LlamaInferenceException>()),
      );

      expect(recorder.results.single.error, isA<LlamaInferenceException>());
    });
  });

  group('generate', () {
    test('reports the prompt, each piece, usage and finish', () async {
      backend
        ..generationChunks = ['one ', 'two']
        ..nextLimit = BackendGenerationLimit.maxTokens
        ..nextUsage = _usage;
      const params = GenerationParams(maxTokens: 2);

      final pieces = await engine.generate('raw', params: params).toList();

      final text = recorder.operations.single as LlamaTextCompletionOperation;
      expect(text.prompt, 'raw');
      expect(text.params, same(params));
      expect(text.model, 'Tiny Llama');
      expect(recorder.events, pieces);
      expect(recorder.results.single.finishReason, 'length');
      expect(recorder.results.single.usage, same(_usage));
    });

    test('reports a stop finish without a limit', () async {
      await engine.generate('raw').drain<void>();

      expect(recorder.results.single.finishReason, 'stop');
      expect(recorder.results.single.usage, isNull);
    });
  });

  group('embeddings', () {
    test('embed and embedBatch report their inputs', () async {
      await engine.embed('a', normalize: false);
      await engine.embedBatch(['bb', 'ccc']);

      final single = recorder.operations[0] as LlamaEmbeddingsOperation;
      final batch = recorder.operations[1] as LlamaEmbeddingsOperation;
      expect(single.inputs, ['a']);
      expect(single.normalize, isFalse);
      expect(batch.inputs, ['bb', 'ccc']);
      expect(batch.model, 'Tiny Llama');
      expect(recorder.results.map((r) => r.error), [null, null]);
    });

    test('starts synchronously in the calling zone', () async {
      final result = runZoned(
        () => engine.embed('a'),
        zoneValues: {#trace: 'parent'},
      );
      expect(recorder.startZoneValues, ['parent']);
      await result;
    });

    test('reports an unsupported backend with its error', () async {
      final embeddings = _Recorder();
      final observed = LlamaEngine(MockLlamaBackend(), observers: [embeddings]);
      addTearDown(observed.dispose);
      await observed.loadModel('/models/tiny.gguf');

      await expectLater(
        observed.embed('a'),
        throwsA(isA<LlamaUnsupportedException>()),
      );

      expect(embeddings.results.last.error, isA<LlamaUnsupportedException>());
    });
  });

  test('a throwing observer does not change what the caller sees', () async {
    final plain = LlamaEngine(_ObservedBackend());
    addTearDown(plain.dispose);
    await plain.loadModel('/models/tiny.gguf');
    final observed = LlamaEngine(
      _ObservedBackend(),
      observers: [
        _ThrowingObserver(throwOnStart: true),
        _ThrowingObserver(throwOnStart: false),
        recorder,
      ],
    );
    addTearDown(observed.dispose);
    await observed.loadModel('/models/tiny.gguf');

    final expected = await plain.generate('p').toList();
    final pieces = await observed.generate('p').toList();

    expect(pieces, expected);
    expect(recorder.results.last.finishReason, 'stop');
  });

  test('an engine without observers reads no model metadata at load', () async {
    final unobserved = MockLlamaBackend();
    final plain = LlamaEngine(unobserved);
    addTearDown(plain.dispose);

    await plain.loadModel('/models/tiny.gguf');

    expect(unobserved.modelMetadataCalls, 0);
    expect(plain.observers, isEmpty);
  });
}
