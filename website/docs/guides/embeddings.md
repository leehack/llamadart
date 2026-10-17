---
title: On-device text embeddings
sidebar_label: Embeddings
description: Generate local embeddings with llamadart, understand backend support, and build retrieval-style workflows.
---

`llamadart` supports local embedding generation through `LlamaEngine` on
native and web runtimes.

## Basic usage

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path('path/to/embedding-model.gguf')),
  );

  try {
    if (!(await engine.capabilities).supportsEmbeddings) {
      print('This backend cannot embed.');
      return;
    }

    final List<double> vector = await engine.embed('hello world');
    final List<List<double>> batch = await engine.embedBatch([
      'semantic search',
      'document retrieval',
    ]);

    print('single dims=${vector.length}');
    print('batch count=${batch.length}');
  } finally {
    await engine.dispose();
  }
}
```

## Ordered content inputs

`embed(String)` and `embedBatch(List<String>)` are unchanged. The additive
`LlamaEmbeddingInput` accepts a nonempty ordered list of `LlamaTextContent`,
`LlamaImageContent` and `LlamaAudioContent` parts. Use `embedContent(input)`
or `embedContentBatch(inputs)` for one vector per input. Adjacent text parts
form one verbatim-concatenated text segment on every backend, including within mixed inputs; no separator or task prefix is added. An empty
batch returns no vectors; an empty parts list throws `LlamaArgumentException`.

```dart
Future<List<double>> embedContentExample(LlamaEngine engine) async {
  final capabilities = await engine.embeddingCapabilities;
  if (!capabilities.text) {
    throw LlamaUnsupportedException('This loaded runtime cannot embed text.');
  }
  return engine.embedContent(
    LlamaEmbeddingInput([const LlamaTextContent('hello world')]),
  );
}
```

After loading a model and any projector, `await engine.embeddingCapabilities`
reports `text`, `image` and `audio`. Packaged llama.cpp backends currently
report text only (with existing model restrictions). LiteRT-LM embedding engines
probe text/image/audio processors on native CPU. Chat vision/audio
support does not imply embedding support. Custom backends may implement the
optional `BackendMultimodalEmbeddings` SPI from `package:llamadart/backend.dart`
and positively probe each loaded model/runtime modality.

The modality enum may gain values such as video; include a default case in
switches. Video and chat-only parts throw `LlamaUnsupportedException`; a portable
video frame/timestamp sampling contract has not been defined. No media is
silently flattened into text. Source/codec support is runtime-specific;
embedding PCM uses mono 16 kHz Float32 samples. Keep media buffers unchanged
until the future settles. `normalize` and cancellation through
`cancelGeneration()` follow the existing embedding semantics. Content-call
observers receive only ordered part kinds/counts, with no text, paths, URLs
or media payloads; old string calls retain their existing text observations.

GGUF embeddings reuse the existing model and its `LlamaModel.projector` or
`loadMultimodalProjector` loading path. `ModelParams(liteRtLmEmbeddingEngine: true)`
selects the separate LiteRT-LM embedding engine. Use `ComputeDevice.cpu` on
native. Native GPU and all Web paths throw `LlamaUnsupportedException`. This flag
is LiteRT-LM-only: llama.cpp GGUF loaders reject true; the default false preserves
existing loading. The qualified bundle is EmbeddingGemma-2 740M; probe it rather
than inferring modality support from its name. Follow
[the multimodal tracker](https://github.com/leehack/llamadart/issues/1072);
[task-prefix and Matryoshka helpers](https://github.com/leehack/llamadart/issues/1126)
remain separate.

### LiteRT-LM embedding engine

```dart
Future<List<double>> embedLiteRtImage(LlamaEngine engine, Uint8List png) async {
  await engine.setModel(
    LlamaModel(ModelSource.path('embeddinggemma-2-740m.litertlm')),
    params: const ModelParams(
      liteRtLmEmbeddingEngine: true,
      device: ComputeDevice.cpu,
      contextSize: 1024,
    ),
  );
  return engine.embedContent(LlamaEmbeddingInput([LlamaImageContent(bytes: png)]));
}
```

Web embeddings remain unsupported: Web CPU cannot load external text-encoder
weights, and pinned WebGPU vectors missed the native CPU parity gate. Media inputs accept encoded PNG/JPEG bytes,
mono 16 kHz PCM16/Float32 WAV bytes, or mono 16 kHz Float32 samples. Paths,
image URLs, video and multiple sources per part are unsupported. All parts are
decoded before inference.
No task prefix is inserted. Embedding mode rejects generation and tokenizer APIs.

LiteRT-LM selects overflow-error behavior. It has no expanded-token count API,
so overflow may be discovered after earlier batch items consumed compute; the
whole call throws `LlamaInferenceException` and returns no vectors. It never
truncates or returns partial results. llama.cpp still validates actual expanded
context/batch/micro-batch capacity before inference.

## Backend support and compatibility

- Embeddings are an optional backend capability. After loading a model,
  `(await engine.capabilities).supportsEmbeddings`, like the synchronous
  `engine.supportsEmbeddings`, reports whether the active backend supports
  them; when it is false, `LlamaEngine.embed(...)` and
  `embedBatch(...)` throw `LlamaUnsupportedException`. It does not inspect the
  model, so the model limits below still apply.
- Native llama.cpp/GGUF backends support embeddings, including batched
  embeddings, when the loaded model was built for embedding output.
- On native, rank-pooled reranker GGUFs (such as Qwen3-Reranker) return
  classifier scores rather than embeddings, so `embed(...)` and
  `embedBatch(...)` throw `LlamaUnsupportedException` for them. Reranking is
  tracked in [#323](https://github.com/leehack/llamadart/issues/323).
- On native, encoder-decoder GGUFs (such as T5) throw
  `LlamaUnsupportedException`; use an encoder-only or decoder-only embedding
  model.
- On native, an input with more tokens than the context holds per sequence
  throws `LlamaInferenceException`; shorten it or raise `contextSize`. With
  `kvUnified: false`, the context is split across `maxParallelSequences`.
- On native, encoder-only models, models without a KV cache, non-causal
  models and MEAN/CLS-pooled models embed each input in one pass. This also
  applies when the model has a KV cache. An input longer than the context's
  actual micro-batch capacity throws `LlamaInferenceException` before decoding;
  shorten the input or raise `microBatchSize` and `batchSize` together.
  Causal models with a KV cache retain chunked LAST or unpooled embedding
  support. Batched one-pass inputs are grouped only within the micro-batch
  capacity, and every input is validated before any group is decoded.
- Native causal-attention detection follows the pinned llama.cpp `v0.7.0`
  contract: the runtime's diffusion-model probe and EmbeddingGemma's forced
  non-causal attention take precedence over metadata. Other loaded models
  use their boolean `<architecture>.attention.causal` value, defaulting to
  causal attention when that optional key is absent. Missing architecture,
  invalid attention metadata or an unavailable required runtime probe throws
  `LlamaUnsupportedException` before decoding. Use the pinned native runtime
  or a compatible runtime that exposes the required model information.
- Web backend supports embeddings when bridge assets expose embedding APIs
  (`v0.1.7` or newer).
- If web bridge assets are older than `v0.1.7`, embedding calls can fail with
  an unsupported/runtime error. Update bridge assets to a newer tag.
- `LlamaEngine.embedBatch(...)` uses true backend batching when available and
  otherwise falls back to repeated `embed(...)` calls.

## EmbeddingGemma-2 on native

Native v0.7.0 loads the official EmbeddingGemma-2 BF16 GGUF through the existing
`embed` and `embedBatch` APIs. Its projected text output has 768 components;
its 512-wide hidden representation is not the returned vector size. The
local model-backed test covers normalization, distinct inputs, sequential/batch
parity and reuse on macOS CPU and Metal. Image/audio embedding inputs still
require a public API tracked in
[#1072](https://github.com/leehack/llamadart/issues/1072).

For document embeddings, pass the model's task prefix as part of the text:

```dart
final vector = await engine.embed(
  'task: search result | text: Paris is the capital of France.',
);
```

Like other non-causal encoders, every input must fit in one micro-batch. Raise
`microBatchSize` and `batchSize` together for longer inputs. The runtime does
not automatically prepend task instructions.

## Retrieval-style flow (query + candidate ranking)

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path('path/to/embedding-model.gguf')),
  );

  try {
    const query = 'How do I improve embedding throughput?';
    final candidates = <String>[
      'Increase maxParallelSequences for wider embedding batches.',
      'Tune batchSize and microBatchSize together.',
      'Use CPU fallback on constrained devices.',
    ];

    final queryVector = await engine.embed(query, normalize: true);
    final candidateVectors = await engine.embedBatch(
      candidates,
      normalize: true,
    );

    final scored = <MapEntry<String, double>>[];
    for (var i = 0; i < candidates.length; i++) {
      final score = dotProduct(queryVector, candidateVectors[i]);
      scored.add(MapEntry(candidates[i], score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    for (final result in scored.take(3)) {
      print('${result.value.toStringAsFixed(4)}  ${result.key}');
    }
  } finally {
    await engine.dispose();
  }
}

double dotProduct(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}
```

With `normalize: true`, dot-product scores correspond to cosine similarity,
which is usually the simplest ranking baseline for local retrieval.

## Throughput tuning for `embedBatch(...)`

`ModelParams` controls batching behavior at context creation time:

```dart
const params = ModelParams(
  contextSize: 4096,
  batchSize: 2048,
  microBatchSize: 2048,
  maxParallelSequences: 8,
);
```

These `2048` / `2048` values are explicit encoder-throughput settings, not the
decoder/generative defaults. Start with a smaller `microBatchSize` such as
`512` on memory-constrained devices and increase it only after measuring.
Web retains full-context automatic batching on CPU and WebGPU because model
architecture is not available before bridge context creation. Known decoder
presets can use smaller batches; see [Performance tuning](./performance-tuning).
An embedding input must fit its model's context and, for encoder-only,
no-memory, non-causal or MEAN/CLS-pooled models, one micro-batch. Set both
batch values explicitly only when tuning a known workload; selecting memory64 does not remove this micro-batch requirement.

- `batchSize` (`n_batch`): max logical tokens per forward pass.
- `microBatchSize` (`n_ubatch`): scheduler micro-batch size.
- `maxParallelSequences` (`n_seq_max`): parallel sequence slots for true
  multi-sequence embedding batches.

Start with `maxParallelSequences` matching expected concurrent batch width (for
example `4` or `8`), then tune based on memory and latency/throughput tradeoffs.

To measure sequential vs batch throughput, see
[Backend benchmarks](./backend-benchmarks#embedding-throughput).

### LiteRT-LM embedding lifecycle and options

Concurrent embedding calls queue. Whole-batch media decoding runs off the caller
isolate; native inference checks cancellation between items. Cancel, unload and
timeout discard all vectors after the current item settles. A timeout throws
`LlamaInferenceException` and requests worker cancellation.

`contextSize` selects the model's encoder signature without truncating inputs.
Embedding mode applies `numberOfThreads`, `liteRtLmCacheDir` and CPU selection;
LoRA, chat templates, activation type, prefill, parallel loading, dispatch paths,
program cache limits, MTP/rollback and Web memory hints throw
`LlamaUnsupportedException` before model I/O. Native CPU qualification is limited
to macOS arm64; GPU/NPU and Web embeddings remain unavailable.
