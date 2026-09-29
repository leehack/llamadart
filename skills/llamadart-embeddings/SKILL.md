---
name: llamadart-embeddings
description: >-
  Use when generating text embeddings with llamadart (engine.embed,
  engine.embedBatch), ranking documents by cosine similarity, building a local
  retrieval-augmented generation (RAG) loop, storing vectors, or tuning
  ModelParams batch sizes and input length limits for embedding models.
---

# Embeddings and retrieval with llamadart

## Guidelines

- Use `engine.embed(text)` for one vector and `engine.embedBatch(texts)` for
  many; both return `List<double>` vectors (one per input, in input order) and
  take `normalize` (default `true`, L2-normalized). With normalized vectors,
  cosine similarity is the dot product. Pass `normalize: false` only when you
  need raw vectors, and then compute full cosine similarity.
- Load a dedicated embedding GGUF (for example
  `hf://ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf`). No
  special `ModelParams` flag is needed: the engine switches the context into
  embedding mode per call. Loading and disposal work as in the
  llamadart-getting-started skill.
- Give the embedding model and the chat model separate `LlamaEngine`s. An
  engine holds one model, and switching models per query reloads weights.
- Embeddings are llama.cpp-only. LiteRT-LM (`.litertlm`) engines, native or
  web, throw `LlamaUnsupportedException`. After loading, check
  `engine.supportsEmbeddings` (false on LiteRT-LM) before offering the
  feature. It reports the backend only, so still treat
  `LlamaUnsupportedException` from `embed` as a configuration error, not
  something to retry or swallow.
- Rank-pooled reranker GGUFs (such as Qwen3-Reranker) produce classifier
  scores, not embeddings; `embed`/`embedBatch` throw
  `LlamaUnsupportedException` for them, as do encoder-decoder models such as
  T5.
- Web embeddings need llama.cpp bridge assets `v0.1.7` or newer. When
  older assets lack the embedding API, calls throw `LlamaUnsupportedException`
  naming that floor; other web embedding failures surface as
  `LlamaInferenceException`.
- Nothing is truncated for you. Encoder-only and non-causal models (BERT,
  ModernBERT, EmbeddingGemma) embed each input in one micro-batch: an input
  longer than `microBatchSize` (512 tokens by default on native) throws
  `LlamaInferenceException`. Chunk documents into passages (a few hundred
  tokens), measure with `engine.getTokenCount(text)`, or raise
  `microBatchSize` and `batchSize` together (and `contextSize` past its value).
- `embedBatch` runs true multi-sequence batches only when
  `ModelParams.maxParallelSequences` is greater than 1 (default `1`, which
  embeds inputs one at a time). Set it to the expected batch width (for
  example 4 or 8); llama.cpp keeps the full per-sequence context, and inputs
  that do not fit a batch fall back to single passes automatically.
- For throughput on a known workload, set `batchSize` and `microBatchSize`
  explicitly (for example 2048/2048 with `maxParallelSequences: 8`), starting
  with `microBatchSize: 512` on memory-constrained devices and measuring.
- Embed documents once and persist the vectors with the text and the model
  identity; vectors from different embedding models are not comparable, so
  re-index when the model changes. `embedBatch([])` returns an empty list.
- Keep retrieval results visible to users and bound the prompt: take the top
  few chunks, and budget them with `engine.getTokenCount` against the chat
  model's context. Generation itself (`engine.create`, streaming) is covered
  in the llamadart-chat-streaming skill.
- For larger corpora, store vectors in a database with a vector index instead
  of scanning a Dart list. The `example/basic_app` sqlite-vector demo stores
  `embed` output in SQLite via the `sqlite_vector` package and runs
  nearest-neighbour search there.

## Examples

Index documents and rank them for a query:

```dart
import 'package:llamadart/llamadart.dart';

double dot(List<double> a, List<double> b) {
  double sum = 0;
  for (int i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

Future<List<({String text, double score})>> search(
  LlamaEngine embedder,
  List<String> documents,
  String query, {
  int topK = 3,
}) async {
  final List<List<double>> index = await embedder.embedBatch(documents);
  final List<double> queryVector = await embedder.embed(query);
  final List<({String text, double score})> ranked =
      <({String text, double score})>[
        for (int i = 0; i < documents.length; i++)
          (text: documents[i], score: dot(queryVector, index[i])),
      ]..sort((a, b) => b.score.compareTo(a.score));
  return ranked.take(topK).toList();
}

Future<void> main() async {
  final LlamaEngine embedder = LlamaEngine(LlamaBackend());
  try {
    await embedder.loadModelSource(
      ModelSource.parse(
        'hf://ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf',
      ),
      modelParams: const ModelParams(
        contextSize: 2048,
        maxParallelSequences: 8,
      ),
    );
    final List<({String text, double score})> hits = await search(
      embedder,
      <String>[
        'Increase maxParallelSequences for wider embedding batches.',
        'Tune batchSize and microBatchSize together.',
        'Use CPU fallback on constrained devices.',
      ],
      'How do I improve embedding throughput?',
    );
    for (final ({String text, double score}) hit in hits) {
      print('${hit.score.toStringAsFixed(3)}  ${hit.text}');
    }
  } on LlamaUnsupportedException catch (error) {
    print('This model or runtime cannot embed: ${error.message}');
  } finally {
    await embedder.dispose();
  }
}
```

Answer a question grounded in retrieved chunks (two engines):

```dart
import 'package:llamadart/llamadart.dart';

Future<String> answer({
  required LlamaEngine embedder,
  required LlamaEngine generator,
  required List<String> chunks,
  required List<List<double>> chunkVectors,
  required String question,
}) async {
  final List<double> query = await embedder.embed(question);
  final List<int> order = List<int>.generate(chunks.length, (int i) => i)
    ..sort((int a, int b) {
      double scoreA = 0;
      double scoreB = 0;
      for (int d = 0; d < query.length; d++) {
        scoreA += query[d] * chunkVectors[a][d];
        scoreB += query[d] * chunkVectors[b][d];
      }
      return scoreB.compareTo(scoreA);
    });
  final String context = order.take(2).map((int i) => '- ${chunks[i]}').join(
    '\n',
  );

  final List<LlamaChatMessage> messages = <LlamaChatMessage>[
    const LlamaChatMessage.fromText(
      role: LlamaChatRole.system,
      text:
          'Answer using only the context. '
          'If the context does not contain the answer, say you do not know.',
    ),
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'Context:\n$context\n\nQuestion: $question',
    ),
  ];

  final StringBuffer reply = StringBuffer();
  await for (final LlamaCompletionChunk chunk in generator.create(
    messages,
    params: const GenerationParams(maxTokens: 128, temp: 0.2),
    enableThinking: false,
  )) {
    reply.write(chunk.choices.first.delta.content ?? '');
  }
  return reply.toString();
}
```

Split long text into passages that fit one embedding pass:

```dart
import 'package:llamadart/llamadart.dart';

Future<List<String>> chunkByTokens(
  LlamaEngine embedder,
  String text, {
  int maxTokens = 400,
}) async {
  final List<String> chunks = <String>[];
  final StringBuffer current = StringBuffer();
  for (final String paragraph in text.split(RegExp(r'\n\s*\n'))) {
    final String candidate = current.isEmpty
        ? paragraph
        : '$current\n\n$paragraph';
    if (current.isNotEmpty &&
        await embedder.getTokenCount(candidate) > maxTokens) {
      chunks.add(current.toString());
      current
        ..clear()
        ..write(paragraph);
    } else {
      current
        ..clear()
        ..write(candidate);
    }
  }
  if (current.isNotEmpty) chunks.add(current.toString());
  return chunks;
}
```

A single paragraph longer than `maxTokens` still needs splitting (for example
by sentence) before `embed`, or it throws `LlamaInferenceException` on
non-causal models.

## More

- Embeddings: https://llamadart.leehack.com/docs/guides/embeddings
- Retrieval (RAG) tutorial: https://llamadart.leehack.com/docs/tutorials/rag
- Basic app example (sqlite-vector search): https://llamadart.leehack.com/docs/examples/basic-app
- Performance tuning: https://llamadart.leehack.com/docs/guides/performance-tuning
