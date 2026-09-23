# Decision Engine Design

`DecisionEngine` runs Laya-style decision models: a bidirectional encoder
(ModernBERT GGUF, run by llama.cpp) plus a small decision head (safetensors),
answering typed questions about a state in one non-autoregressive pass. The
request and response shapes follow Laya's `system_one` and TypeSafe's Jev API,
so prompts written for either carry over unchanged.

Reference implementation: `laya` 0.3.5 on PyPI, checkpoint
`convaiinnovations/laya` at `1c5edc17a7acd8701df6fc341c0d179f1c62c982`
(Apache-2.0). Parity with it is the acceptance bar.

## Model assets

| File | Source | Notes |
| --- | --- | --- |
| Backbone GGUF | `fr0stbit3/laya-gguf@ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c`, `laya-Q8_0.gguf` (421 MB) or `laya-F16.gguf` | `modern-bert` architecture, 1024 hidden |
| Head | same repo, `laya-head.safetensors` (106 MB, F32) | 36 tensors under the PyTorch names; `__metadata__["laya.config"]` holds `rl_agent_config.json` |
| Official checkpoint | `convaiinnovations/laya/model.safetensors` + `rl_agent_config.json` | also accepted as a head file: `encoder.*` tensors are ignored, config comes from `configPath` |

Measured error of the whole pipeline against the PyTorch reference over the 24
fixture rows: worst marker-logit difference 0.012-0.014 with a locally
converted F32 GGUF, 0.164 with the community Q8_0. Q4_0 was both slower and less
accurate on every device tried.

## Public API

```dart
final engine = LlamaEngine(LlamaBackend());
await engine.loadModel(
  'laya-Q8_0.gguf',
  modelParams: const ModelParams(contextSize: 512),
);
final decisions = await DecisionEngine.load(
  engine,
  headPath: 'laya-head.safetensors',
);

final result = await decisions.systemOne(
  state: {'from': 'user@acme.com', 'body': 'Billed twice for March.'},
  questions: {
    'department': DecisionQuestion.choice(
      'Which department should handle this?',
      criteria: {'billing': 'invoices, refunds', 'technical': 'bugs', 'other': null},
    ),
    'urgency': DecisionQuestion.score(
      'How urgent is this?',
      levels: ['not urgent', 'soon', 'critical'],
    ),
    'refund': DecisionQuestion.noul('Does the user request a refund?'),
  },
);

result.choices['department']!.choice; // 'billing'
result.scores['urgency']!.score; // expected level, 0..2
result.nouls['refund']!.noul; // P(true)
result.toJson(); // {model, answers, usage}, the Laya/Jev response shape

await decisions.dispose(); // frees the head; the LlamaEngine stays loaded
```

Types, all in `lib/src/core/decision/` and pure Dart:

- `sealed class DecisionQuestion` with `ChoiceQuestion` (`Map<String, Object?>
  criteria`; a null or empty value means "no description"), `ScoreQuestion`
  (`List<Object?> levels`, sent as `criteria`) and `NoulQuestion` (optional
  `whenTrue`/`whenFalse`, sent as `criteria: {"true", "false"}`). Factory
  constructors `DecisionQuestion.choice/score/noul`, plus `fromJson`/`toJson` in
  the wire format. `fromJson` accepts a list-valued choice `criteria` (Laya turns
  it into `{label: null}`, dropping duplicates) and non-string `instructions`
  (serialized as `json.dumps` with `ensure_ascii=True`). It is stricter than
  Laya elsewhere: score `criteria` must be a list and noul `criteria` null or a
  map, so a map of score levels or an empty noul list is rejected.
- `DecisionRequest(state:, questions:)` for `systemOneBatch`.
- `sealed class DecisionAnswer` with `ChoiceAnswer` (`choice`, `probabilities`),
  `ScoreAnswer` (`score`, `legend`, `probabilities` keyed `'0'..`) and
  `NoulAnswer` (`noul`). Every answer has `confidence` and `actProbability`
  (Laya's `action.act_probability`).
- `DecisionResult`: `model`, `answers`, typed views `choices`/`scores`/`nouls`,
  `usage` (`inputTokens`, `outputTokens` = 0) and `toJson()`.
- `DecisionEngine`: `load`, `capabilitiesFor(engine)`, `info` (limits and the
  head's device), `systemOne`, `systemOneBatch`, `dispose`.
- `LlamaDecisionException` for invalid questions and model-dependent failures
  such as an option list that does not fit the head budget.

Values are unrounded doubles; upstream rounds to 4 decimals in its JSON.

## Architecture

```text
DecisionEngine (core, pure Dart)
  question -> texts -> engine.tokenize -> sequence ids + marker positions
  LlamaEngine hooks: loadDecisionHeadBackend / runDecisionBackend / freeDecisionHeadBackend
    BackendDecision (backend.dart, web-safe value types)
      NativeAutoBackend -> NativeLlamaBackend -> worker isolate -> LlamaCppService
        private encoder llama_context + safetensors head + ggml head graph
  raw marker logits + raw act logits -> decoder (core) -> DecisionResult
```

Why the split: sequence building and decoding stay in shared Dart, so the web
path only has to provide "token ids in, raw logits out". The worker never sends
hidden states across the isolate boundary; only logits cross it.

### Core (`lib/src/core/decision/`)

| File | Contents |
| --- | --- |
| `python_json.dart` | `json.dumps` byte parity: `, `/`: ` separators, Python float `repr`, `NaN`/`Infinity`, `ensure_ascii` |
| `decision_question.dart` | question types, `DecisionRequest`, JSON conversion, validation |
| `decision_result.dart` | answer types, `DecisionUsage`, `DecisionResult` |
| `decision_sequence.dart` | option rendering, tokenizer input texts, sequence assembly |
| `decision_decoder.dart` | temperature selection and clamping, softmax, confidence, act features, answer decoding |
| `decision_engine.dart` | facade and `DecisionCapabilities` |

The core must not import `dart:io`/`dart:ffi`, directly or transitively.

### Backend contract (`lib/src/backends/backend.dart`)

```dart
abstract class BackendDecision {
  Future<BackendDecisionCapabilities> decisionCapabilities(int modelHandle);
  Future<BackendDecisionHeadInfo> decisionHeadLoad(
    int modelHandle, String headPath, {String? configPath});
  Future<List<BackendDecisionOutput>> decisionRun(
    int headHandle, List<BackendDecisionSequence> sequences);
  Future<void> decisionHeadFree(int headHandle);
}
```

- `BackendDecisionHeadInfo`: `handle`, `hiddenSize`, `clsToken`, `sepToken`,
  `maskToken`, `maskText`, `configJson` (the Laya config text; the core reads
  `max_len`, `head_max_len` and temperatures from it) and `deviceName`.
- `BackendDecisionSequence`: `tokens`, `markers` (`Int32List`) and
  `questionType` (0 choice, 1 score, 2 noul), one per question.
- `BackendDecisionOutput`: per sequence, raw marker `logits` and raw
  `actLogits` (`Float32List`).

`NativeAutoBackend` implements and forwards it; the LiteRT-LM delegate reports
unsupported. `WebAutoBackend` does not implement it until the bridge ships the
module, so the engine hook reports unsupported and `DecisionEngine.load` throws
`LlamaUnsupportedException`.

### Engine hooks (`lib/src/core/engine/engine.dart`)

Plain public methods documented as low-level integration hooks, like the TTS
trio. The capabilities hook checks `is! BackendDecision` before readiness, so
Web reports a stable reason without a model. The engine records live head
handles and forgets them in `_unloadModel`; a run or free with a forgotten
handle throws `LlamaStateException` ("load the DecisionEngine again") instead of
reaching a possibly reused native handle. No engine lease: the head uses its own
llama context, and the worker serializes native work.

### Native (`lib/src/backends/llama_cpp/`)

- Worker messages `DecisionCapabilitiesRequest`, `DecisionHeadLoadRequest`,
  `DecisionRunRequest`, `DecisionHeadFreeRequest`, handled synchronously. Every
  request gets a reply. Errors reuse the existing `WorkerErrorKind`s: bad head
  file or model mismatch is `model`, unknown handle is `state`, compute failure
  is `inference`, missing symbols are `unsupported`.
- `safetensors.dart`: header parse with bounds checks; reads only the needed
  byte ranges through `RandomAccessFile`; F32, F16 and BF16 convert to F32.
- `decision_head.dart`: weights in one backend buffer, the head graph through
  `ggml_backend_sched`, and the act MLP in Dart.
- Service state: `Map<int, _DecisionHead>` keyed by `_getHandle()`, holding the
  model handle, a private `llama_context` (n_ctx = n_batch = n_ubatch =
  `max_len`, `n_seq_max` 1, `embeddings` true, pooling NONE, threads and offload
  knobs from the model's load params), backends, sched, weights. Kept out of
  `_contexts` so generate, embed and state persistence cannot reach it.
  `freeModel` frees the model's heads before `llama_model_free`; `dispose` frees
  all heads first.
- Teardown order per head: sched synchronize, sched free, weights buffer free,
  `ggml_free`, backends free, then `llama_free` on the private context. A live
  Metal buffer at process exit trips `ggml_metal_rsets_free`'s assert.

Head device: CPU when the model runs on CPU (`_modelBackendNames` is CPU or
resolved GPU layers <= 0), with `op_offload` false. Otherwise the model's GPU
device, with the CPU backend last in the sched (required by
`ggml_backend_sched_new`). Never `ggml_backend_init_best`, which would start a
GPU backend in explicit CPU mode. CPU threads come from the private context
(`llama_n_threads`) through the CPU registry's `ggml_backend_set_n_threads`.

Load-time checks, each failing with a typed exception: architecture reported by
`general.architecture` is `modern-bert`; `llama_vocab_cls`/`sep`/`mask` exist;
`n_embd` equals the head width; `n_ctx_train >= max_len`; every tensor is
present with the exact shape implied by `hidden`, `head_layers` and the act
rows; `nhead = max(1, hidden ~/ 64)` divides `hidden`. The run path rejects a
sequence longer than `llama_n_ubatch` before `llama_encode`, whose
`GGML_ASSERT` would abort the process.

Windows: `llama.dll` exports no `ggml_*` graph symbols; they live in
`ggml-base.dll` (ops, graph, sched, buffers) and `ggml.dll` (registry). The head
calls ggml through a small function table that uses the generated bindings on
other platforms and `@Native` twins with `assetId:
'package:llamadart/ggml-base'`/`'package:llamadart/ggml'` on Windows (precedent:
`test/unit/backends/llama_cpp/native_precision_bindings_test.dart`). Generated
bindings are not edited.

## Parity rules

Sequence (`build_sequence`, `max_len` 512, `head_max_len` 192):

```text
[CLS] "<type> question: <instructions>" [SEP] [MASK] " opt0" [MASK] " opt1" ... [SEP] state [SEP]
```

- Every piece has the mask token's text replaced by one space first.
- Option ids are truncated to 48 after the marker. If fewer than 16 tokens
  remain of `head_max_len`, each option is cut to `max(4, (head_max_len - 16)
  ~/ K)`. The head text keeps `max(8, remaining)` tokens.
- State fills `max(0, max_len - len - 1)` tokens, then `[SEP]`; the result is cut
  to `max_len` and markers past it are dropped. If fewer markers than options
  survive, the question fails with `LlamaDecisionException`.
- Tokenization is `engine.tokenize(text, addSpecial: false)` (llama.cpp parses
  special tokens, matching Hugging Face added-token splitting). Each distinct
  text is tokenized once per call.
- Options: choice `label` or `label: <criterion>`; score `level i: <criterion>`;
  noul `false: <criterion or "no, the statement does not hold">`, `true:
  <criterion or "yes, the statement holds">`. Non-string criteria render as
  compact JSON (`ensure_ascii=False`). State is a string as-is or
  `json.dumps(state, ensure_ascii=False)`.

Decoding, per question with K markers and question type q:

- `t` = `temperature_by_options["<type>:<2|3-5|6-10|11+>"]` if present, else
  `temperature[q]`; clamped to [0.5, 5.0]; non-numeric, NaN or infinite becomes
  1.0. Temperatures come from the config, not the `temperature` tensor.
- `p = softmax(logits / t)`. Choice: first argmax, `confidence = clamp(1 -
  H(p) / ln K, 0, 1)` with `p` clipped to 1e-12 inside the log, and 1.0 when K <
  2. Score: `score = sum(i * p_i)`, same confidence. Noul: `noul = p[1]`,
  `confidence = max(p[1], 1 - p[1])`.
- Act head input: CLS row after the head layers, concatenated with `[top1, top1
  - top2, H(p_raw) / ln(max(K, 2)), max(K, 2) / 255]` from the untempered
  softmax (log clip 1e-9; top2 is 0 when K = 1). `Linear -> GELU(erf) ->
  Linear`; `actProbability = softmax(act)[0]`.
- `usage.inputTokens` is the sum of sequence lengths; `model` is
  `laya-rl-agent`.

Validation before any native call: at least one question; non-empty ids; at
least one option (K = 1 is valid); score levels non-empty; criteria values are
JSON-like (null, bool, num, String, List, Map with String keys).

## Platform matrix

| Platform | Path | Status |
| --- | --- | --- |
| macOS, iOS | Metal or CPU | supported |
| Android | CPU (recommended, 6 threads on Pixel 9 Pro) or Vulkan | supported; Mali Vulkan was slower than CPU |
| Linux | CPU, Vulkan, CUDA | supported |
| Windows | CPU, Vulkan, CUDA | supported through the `ggml-base` twins |
| Native LiteRT-LM | - | `LlamaUnsupportedException` |
| Web (WebGPU bridge) | - | `LlamaUnsupportedException` until the bridge module ships |

Measured per question (512-token window, Q8_0): about 12 ms on an M4 Max with
Metal; about 2.1 s on a Pixel 9 Pro with 6 CPU threads.

## Known limits

- Input is not Unicode-normalized. The Hugging Face tokenizer applies NFC, so
  NFD text (for example a decomposed "é") can tokenize differently. Pass NFC
  text.
- One encoder pass per question; the state is re-encoded for every question.
- No cancellation: a batch runs to completion in the worker.
- Only the English checkpoint is validated. Other ModernBERT-family checkpoints
  load if the checks pass but have no parity evidence.
- `contextSize: 512` is recommended for the engine's own context, which the
  decision path does not use.

## Testing

- Unit (VM and Chrome unless noted): `python_json` against Python output
  (float formatting is VM-only because Web numbers lose the int/double
  distinction); sequence assembly, decoding, and question JSON round trips and
  validation on synthetic inputs.
- Unit (VM, the fixture is read with `dart:io`): sequence ids and markers for
  all 24 fixture rows using the fixture's recorded tokenizations; decoding from
  recorded raw logits to the recorded answers within 6e-5 (Laya rounds to 4
  decimals and decodes in float32; worst measured deviation 4.96e-5).
- Unit (VM): safetensors parsing and malformed-file errors on synthetic files;
  the ggml head on a tiny synthetic head against a pure-Dart reference; worker,
  backend-client and router routing with fakes; engine hooks and facade with a
  fake backend; Web unsupported path under `@TestOn('browser')`.
- Local-only E2E `test/e2e/backends/decision_engine_e2e_test.dart`: real GGUF
  and head, the 24 fixture rows, exact token ids, logits within tolerance.
  Runner scenario `decision-model-smoke` (`--model-path`, `--head-path`) and
  test-matrix row of the same id.

Fixture: `test/fixtures/decision/laya_0_3_5_reference.json`, produced by the
scripts beside it from the pinned official checkpoint on CPU in FP32.

## Delivery

Stacked PRs, each merged only with maintainer approval:

1. Design doc and the pure-Dart core with the parity fixture (standard risk).
2. Native backend, engine hooks, facade, export, E2E, docs (high risk: backend
   routing and a new export; needs the independent audit and readiness
   evidence).
3. `example/basic_app` decision example.
4. `example/laya_tetris` Flutter example: real-time Tetris played through
   `DecisionEngine`, with the base and a Tetris-tuned head.
5. Head fine-tuning notebook and dataset tool.
6. Web: a decision module in `llama-web-bridge` (C++ next to its TTS module,
   same graph on WebGPU), asset publication, then `WebGpuLlamaBackend`
   implementing `BackendDecision` in this repo.

Model hosting for the Tetris-tuned head, and publishing new bridge assets, need
maintainer approval before they happen.
