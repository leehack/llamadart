@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _modelParams = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 1024,
);

const _sampled = GenerationParams(
  maxTokens: 6,
  penalty: 1,
  temp: 1,
  topK: 0,
  topP: 1,
  seed: 11,
  reusePromptPrefix: false,
  grammar: 'root ::= [a-z]+',
  topLogprobs: 3,
);

const _ungrammared = GenerationParams(
  maxTokens: 6,
  penalty: 1,
  temp: 1,
  topK: 0,
  topP: 1,
  seed: 11,
  reusePromptPrefix: false,
  topLogprobs: 3,
);

const _vocabSize = 259;
const _prompt = 'ab';

typedef _Event = ({List<int> bytes, List<LlamaGeneratedTokenLogprobs> entries});

void main() {
  late LlamaCppService service;
  late int context;
  late int model;
  late String modelPath;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('llamadart_logprobs_');
    addTearDown(() => dir.deleteSync(recursive: true));
    service = LlamaCppService()..initializeBackend();
    addTearDown(service.dispose);
    modelPath = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
    model = service.loadModel(modelPath, _modelParams);
    context = service.createContext(model, _modelParams);
  });

  Future<List<_Event>> run(
    GenerationParams params, {
    String prompt = _prompt,
    bool callback = true,
  }) async {
    final cancel = calloc<Int8>();
    try {
      final pending = <LlamaGeneratedTokenLogprobs>[];
      final events = <_Event>[];
      await for (final bytes in service.generate(
        context,
        prompt,
        params,
        cancel.address,
        onTokenLogprobs: callback ? pending.addAll : null,
      )) {
        events.add((bytes: bytes, entries: List.of(pending)));
        pending.clear();
      }
      if (pending.isNotEmpty) events.add((bytes: const [], entries: pending));
      return events;
    } finally {
      calloc.free(cancel);
    }
  }

  List<int> streamBytes(List<_Event> events) => [
    for (final event in events) ...event.bytes,
  ];

  List<LlamaGeneratedTokenLogprobs> entriesOf(List<_Event> events) => [
    for (final event in events) ...event.entries,
  ];

  test('loaded llama.cpp reports token log-probabilities', () {
    expect(service.generationCapabilities(model).tokenLogprobs, isTrue);
  });

  test('every streamed token has an entry released with its bytes', () async {
    final events = await run(_sampled);
    final entries = entriesOf(events);

    expect(entries, hasLength(6));
    for (final event in events) {
      expect(
        [for (final entry in event.entries) ...entry.sampled.bytes],
        event.bytes,
        reason: 'entries arrive with exactly the bytes they added',
      );
    }
    expect(streamBytes(events), [
      for (final entry in entries) ...entry.sampled.bytes,
    ]);
    for (final entry in entries) {
      expect(entry.top, hasLength(3));
      expect(
        entry.top.map((token) => token.logprob),
        orderedEquals(
          entry.top.map((token) => token.logprob).toList()
            ..sort((a, b) => b.compareTo(a)),
        ),
      );
      expect(entry.sampled.logprob, lessThan(0));
    }
  });

  test('values are the raw distribution scoreNextToken reports', () async {
    final entries = entriesOf(await run(_sampled));
    final generated = StringBuffer();
    for (final entry in entries) {
      final scores = service.scoreNextToken(
        context,
        '$_prompt$generated',
        candidates: [entry.sampled.token],
        topK: 3,
        reusePromptPrefix: false,
      );
      expect(
        entry.sampled.logprob,
        closeTo(scores.candidates.single.logprob, 1e-3),
      );
      expect(
        [for (final token in entry.top) token.token],
        [for (final token in scores.top) token.token],
      );
      for (final (i, token) in entry.top.indexed) {
        expect(token.logprob, closeTo(scores.top[i].logprob, 1e-3));
        expect(token.bytes, scores.top[i].bytes);
      }
      generated.write(utf8.decode(entry.sampled.bytes));
    }
  });

  test('zero alternatives reports the sampled token only', () async {
    final entries = entriesOf(await run(_sampled.copyWith(topLogprobs: 0)));
    expect(entries, hasLength(6));
    expect(entries.every((entry) => entry.top.isEmpty), isTrue);
  });

  test('grammar steers the sample, not the reported distribution', () async {
    final entries = entriesOf(await run(_sampled));
    final allowed = {for (var byte = 0x61; byte <= 0x7a; byte++) byte + 3};
    expect(entries.every((e) => allowed.contains(e.sampled.token)), isTrue);
    expect(
      entries.any((e) => e.top.any((t) => !allowed.contains(t.token))),
      isTrue,
      reason: 'the model prefers tokens the grammar forbids',
    );
  });

  test('a split multi-byte character keeps its bytes whole', () async {
    final events = await run(
      _sampled.copyWith(grammar: 'root ::= "ééé"', maxTokens: 6),
    );
    final entries = entriesOf(events);

    expect(streamBytes(events), [0xC3, 0xA9, 0xC3, 0xA9, 0xC3, 0xA9]);
    expect(
      [for (final entry in entries) entry.sampled.bytes],
      [
        for (var i = 0; i < 3; i++) ...[
          [0xC3],
          [0xA9],
        ],
      ],
    );
    expect(utf8.decode(streamBytes(events)), 'ééé');
    expect(entries.first.sampled.text, '�');
  });

  test('the first token matches scoreNextToken under a grammar', () async {
    final entry = entriesOf(
      await run(_sampled.copyWith(grammar: 'root ::= "ééé"', maxTokens: 1)),
    ).single;
    final scores = service.scoreNextToken(
      context,
      _prompt,
      candidates: [entry.sampled.token],
      topK: 3,
      reusePromptPrefix: false,
    );
    expect(
      entry.sampled.logprob,
      closeTo(scores.candidates.single.logprob, 1e-9),
    );
  });

  test('tokens a stop sequence removes entirely are not reported', () async {
    final full = entriesOf(await run(_sampled));
    final text = utf8.decode(full.expand((e) => e.sampled.bytes).toList());
    final stop = text.substring(3, 5);
    final trimmed = await run(_sampled.copyWith(stopSequences: [stop]));

    expect(utf8.decode(streamBytes(trimmed)), text.substring(0, 3));
    final entries = entriesOf(trimmed);
    expect(entries, hasLength(3));
    for (final (i, entry) in entries.indexed) {
      expect(entry.sampled.token, full[i].sampled.token);
      expect(entry.sampled.logprob, full[i].sampled.logprob);
    }
  });

  test('a withheld stop prefix releases its entries with its bytes', () async {
    final full = entriesOf(await run(_sampled));
    final text = utf8.decode(full.expand((e) => e.sampled.bytes).toList());
    final stop = '${text.substring(3, 4)}\u0000';
    final events = await run(_sampled.copyWith(stopSequences: [stop]));

    expect(utf8.decode(streamBytes(events)), text);
    expect(entriesOf(events), hasLength(6));
    for (final event in events) {
      expect([
        for (final entry in event.entries) ...entry.sampled.bytes,
      ], event.bytes);
    }
  });

  test('a null callback or topLogprobs reads no logits', () async {
    final noCallback = await run(_sampled, callback: false);
    expect(streamBytes(noCallback), hasLength(6));
    expect(entriesOf(noCallback), isEmpty);

    final off = await run(_sampled.copyWith(clearTopLogprobs: true));
    expect(entriesOf(off), isEmpty);
    expect(streamBytes(off), streamBytes(noCallback));
  });

  test('values outside the range fail before decoding', () async {
    for (final top in [-1, GenerationParams.maxTopLogprobs + 1]) {
      await expectLater(
        run(_sampled.copyWith(topLogprobs: top)),
        throwsA(
          isA<LlamaArgumentException>().having(
            (e) => e.name,
            'name',
            'topLogprobs',
          ),
        ),
      );
    }
    final top = _sampled.copyWith(topLogprobs: GenerationParams.maxTopLogprobs);
    expect(
      entriesOf(await run(top)).first.top,
      hasLength(GenerationParams.maxTopLogprobs),
    );
    expect(
      GenerationParams.maxTopLogprobs,
      lessThan(_vocabSize),
      reason: 'the synthetic vocabulary is larger than the largest request',
    );
  });

  test('speculative decoding is rejected before decoding', () async {
    await expectLater(
      run(
        _ungrammared.copyWith(
          speculativeDecodingConfig: const SpeculativeDecodingConfig(
            strategy: SpeculativeDecodingStrategy.ngramSimple,
          ),
        ),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('topLogprobs'), contains('speculative')),
        ),
      ),
    );
  });
}
