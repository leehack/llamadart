@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _modelParams = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 1024,
);

const _params = GenerationParams(
  maxTokens: 12,
  penalty: 1,
  temp: 1,
  topK: 0,
  topP: 1,
  seed: 11,
  reusePromptPrefix: false,
  grammar: 'root ::= [a-z]+',
  topLogprobs: 2,
);

List<int> _bytesOf(Iterable<LlamaGeneratedTokenLogprobs> entries) => [
  for (final entry in entries) ...entry.sampled.bytes,
];

List<String> _shape(Iterable<LlamaGeneratedTokenLogprobs> entries) => [
  for (final entry in entries)
    '${entry.sampled.token} ${entry.sampled.logprob} ${entry.sampled.bytes} '
        '${entry.top.map((t) => '${t.token}:${t.logprob}')}',
];

void main() {
  late String modelPath;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('llamadart_logprobs_e2e_');
    addTearDown(() => dir.deleteSync(recursive: true));
    modelPath = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
  });

  group('backend', () {
    late LlamaBackend backend;
    late int context;

    setUp(() async {
      backend = LlamaBackend();
      addTearDown(backend.dispose);
      final model = await backend.modelLoad(modelPath, _modelParams);
      context = await backend.contextCreate(model, _modelParams);
    });

    for (final threshold in [1, 8]) {
      for (final delay in [Duration.zero, const Duration(milliseconds: 15)]) {
        test('entries never trail their bytes (batch $threshold, '
            'consumer delay ${delay.inMilliseconds} ms)', () async {
          final reporter = backend as BackendTokenLogprobsReporting;
          final stream = backend.generate(
            context,
            'ab',
            _params.copyWith(streamBatchTokenThreshold: threshold),
          );
          final bytes = <int>[];
          final taken = <LlamaGeneratedTokenLogprobs>[];
          await for (final event in stream) {
            bytes.addAll(event);
            taken.addAll(reporter.takeTokenLogprobs(stream));
            final entryBytes = _bytesOf(taken);
            expect(entryBytes.take(bytes.length), bytes);
            await Future<void>.delayed(delay);
          }
          taken.addAll(reporter.takeTokenLogprobs(stream));

          expect(bytes, hasLength(12));
          expect(_bytesOf(taken), bytes);
          expect(reporter.takeTokenLogprobs(stream), isEmpty);
        });
      }
    }

    test('a request without topLogprobs sends no entries', () async {
      final stream = backend.generate(
        context,
        'ab',
        _params.copyWith(clearTopLogprobs: true),
      );
      final bytes = await stream.expand((event) => event).toList();
      expect(bytes, hasLength(12));
      expect(
        (backend as BackendTokenLogprobsReporting).takeTokenLogprobs(stream),
        isEmpty,
      );
    });
  });

  group('engine', () {
    late LlamaEngine engine;

    setUp(() async {
      engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(modelPath, modelParams: _modelParams);
    });

    test('reports the capability', () async {
      expect((await engine.capabilities).supportsTokenLogprobs, isTrue);
    });

    test(
      'generate lists entries that match the stream, per batch size',
      () async {
        final shapes = <List<String>>[];
        for (final threshold in [1, 8]) {
          final stream = engine.generate(
            'ab',
            params: _params.copyWith(streamBatchTokenThreshold: threshold),
          );
          final list = rawTokenLogprobs(stream)!;
          expect(list, isEmpty);
          final text = StringBuffer();
          await for (final piece in stream) {
            text.write(piece);
            expect(utf8.decode(_bytesOf(list)), text.toString());
          }
          expect(utf8.decode(_bytesOf(list)), text.toString());
          expect(list, hasLength(12));
          shapes.add(_shape(list));
        }
        expect(shapes[0], shapes[1]);
      },
    );

    test('generate without topLogprobs has no list', () async {
      final stream = engine.generate(
        'ab',
        params: _params.copyWith(clearTopLogprobs: true),
      );
      expect(rawTokenLogprobs(stream), isNull);
      expect(await stream.join(), hasLength(12));
    });

    test('a split multi-byte character reaches the list whole', () async {
      final stream = engine.generate(
        'ab',
        params: _params.copyWith(
          grammar: 'root ::= "ééé"',
          maxTokens: 6,
          streamBatchTokenThreshold: 1,
        ),
      );
      final text = await stream.join();
      final entries = rawTokenLogprobs(stream)!;
      expect(text, 'ééé');
      expect(
        [for (final entry in entries) entry.sampled.bytes],
        [
          for (var i = 0; i < 3; i++) ...[
            [0xC3],
            [0xA9],
          ],
        ],
      );
      expect(utf8.encode(text), _bytesOf(entries));
    });

    test('create puts entries on the chunks they arrived with', () async {
      final chunks = await engine.create([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ], params: _params.copyWith(streamBatchTokenThreshold: 1)).toList();
      final entries = [
        for (final chunk in chunks) ...?chunk.choices.first.logprobs,
      ];
      final content = [
        for (final chunk in chunks) chunk.choices.first.delta.content ?? '',
      ].join();

      expect(entries, hasLength(12));
      expect(utf8.decode(_bytesOf(entries)), content);
      final seenText = StringBuffer();
      final seenEntries = <LlamaGeneratedTokenLogprobs>[];
      for (final chunk in chunks) {
        seenText.write(chunk.choices.first.delta.content ?? '');
        seenEntries.addAll(chunk.choices.first.logprobs ?? const []);
        expect(
          utf8.decode(_bytesOf(seenEntries)).length,
          greaterThanOrEqualTo(seenText.length),
          reason: 'a chunk never shows text before the entries of its tokens',
        );
      }
      for (final chunk in chunks) {
        final logprobs = chunk.choices.first.logprobs;
        if (logprobs == null) continue;
        expect(logprobs.every((entry) => entry.top.length == 2), isTrue);
        expect(
          LlamaCompletionChunkChoice.fromJson(
            chunk.choices.first.toJson(),
          ).logprobs!.map((e) => e.sampled.logprob),
          logprobs.map((e) => e.sampled.logprob),
        );
      }
    });

    test('create aggregates entries into the completion', () async {
      final completion = await engine.create([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ], params: _params).collect();
      expect(completion.logprobs, hasLength(12));
      expect(utf8.decode(_bytesOf(completion.logprobs!)), completion.text);
    });

    test('create without topLogprobs carries none', () async {
      final completion = await engine.create([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
      ], params: _params.copyWith(clearTopLogprobs: true)).collect();
      expect(completion.logprobs, isNull);
    });

    test('rejects values outside the range before decoding', () async {
      for (final top in [-1, 21]) {
        await expectLater(
          engine.generate('ab', params: _params.copyWith(topLogprobs: top)),
          emitsError(isA<LlamaArgumentException>()),
        );
      }
    });

    test(
      'cancelling mid-stream ends the list and the engine recovers',
      () async {
        final stream = engine.generate(
          'ab',
          params: _params.copyWith(
            maxTokens: 400,
            streamBatchTokenThreshold: 1,
          ),
        );
        final list = rawTokenLogprobs(stream)!;
        var seen = 0;
        await for (final _ in stream) {
          if (++seen == 3) engine.cancelGeneration();
        }
        expect(list.length, lessThan(400));
        expect(list, isNotEmpty);
        expect(utf8.decode(_bytesOf(list)), isNotEmpty);

        final next = engine.generate('ab', params: _params);
        expect(await next.join(), hasLength(12));
        expect(rawTokenLogprobs(next), hasLength(12));
      },
    );
  });
}
