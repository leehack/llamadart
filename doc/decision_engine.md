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

Measured error and speed per backbone, head file and device are under
[Measured](#measured). Q4_0 was both slower and less accurate on every device
tried.

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
  such as an option list that does not fit the head budget, and for text that
  contains U+0000 (see [Known limits](#known-limits)).

Values are unrounded doubles; upstream rounds to 4 decimals in its JSON.

## Architecture

```text
DecisionEngine (core, pure Dart)
  question -> texts -> engine.tokenize -> sequence ids + marker positions
  LlamaEngine hooks: loadDecisionHeadBackend / runDecisionBackend / freeDecisionHeadBackend
    BackendDecision (backend.dart, web-safe value types)
      NativeAutoBackend -> NativeLlamaBackend -> worker isolate -> LlamaCppService
        private encoder llama_context + safetensors head + ggml head graph
      WebAutoBackend -> WebGpuLlamaBackend -> WebGpuDecisionHeads -> llama-web-bridge
        bridge decision API 1: private encoder context + head in the WASM core
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
| `decision_engine.dart` | facade, `DecisionCapabilities` and `DecisionModelInfo` |

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

`NativeAutoBackend` and `WebAutoBackend` implement and forward it; their
LiteRT-LM delegates report unsupported.

### Engine hooks (`lib/src/core/engine/engine.dart`)

Plain public methods documented as low-level integration hooks, like the TTS
trio. The capabilities hook checks `is! BackendDecision` before readiness, so
a backend without the contract reports a stable reason without a model.

Backend handles are not unique over an engine's life: the worker numbers
handles from 1, and a new worker starts after `LlamaEngine.dispose` followed by
`loadModel`, or when a GGUF load follows a `.litertlm` load (which replaces the
llama.cpp delegate even if it fails), so the first head after a restart gets
the previous head's number. `loadDecisionHeadBackend` therefore returns the
head with an engine handle from a counter that never resets, mapped to the
backend handle. `_unloadModel` forgets every mapping. A
run with an unmapped engine handle throws `LlamaStateException` ("load the
DecisionEngine again") and a free does nothing, so a stale `DecisionEngine`
can reach neither a later head nor its backend handle. No engine lease: the
head uses its own llama context, and the worker serializes native work.

`DecisionEngine` also checks the engine's model handle before tokenizing. If
the model is unloaded while a call or `load` is in flight, the failure it
causes, such as `LlamaContextException` from tokenization, is rethrown as
`LlamaStateException`.

### Native (`lib/src/backends/llama_cpp/`)

- Worker messages `DecisionCapabilitiesRequest`, `DecisionHeadLoadRequest`,
  `DecisionRunRequest`, `DecisionHeadFreeRequest`, handled synchronously. Every
  request sent before `DisposeRequest` gets a reply; the worker drops requests
  that arrive after it, so the client's `decisionHeadFree` sends nothing once
  disposal has started. Errors reuse the existing `WorkerErrorKind`s: a model
  that `decisionModelUnsupportedReason` rejects, and missing ggml symbols, are
  `unsupported`; an unreadable or malformed head file or
  config, or a head that does not fit the encoder, is `model`; an encoder
  context that cannot be created or fails its checks is `context`; an invalid
  sequence or a failed encoder or head pass is `inference`; an unknown model or
  head handle is `state`.
- `safetensors.dart`: header parse with bounds checks; reads only the needed
  byte ranges through `RandomAccessFile`; F32, F16 and BF16 convert to F32.
- `decision_head.dart`: weights in one backend buffer, the head graph through
  `ggml_backend_sched`, and the act MLP in Dart.
- Service state: `Map<int, _DecisionHead>` keyed by `_getHandle()`, holding the
  model handle, a private `llama_context` (n_ctx = n_batch = n_ubatch =
  `max_len`, `n_seq_max` 1, `embeddings` true, pooling NONE, threads and offload
  knobs from the model's load params), backends, sched, weights, and the
  encoder call (`llama_encode` plus `llama_get_embeddings`; unit tests
  substitute it because the null test context would abort). Kept out of
  `_contexts` so generate, embed and state persistence cannot reach it.
  `freeModel` frees the model's heads before `llama_model_free`; `dispose` frees
  all heads first.
- Teardown order per head: sched synchronize, sched free, weights buffer free,
  `ggml_free`, backends free, then `llama_free` on the private context. A live
  Metal buffer at process exit trips `ggml_metal_rsets_free`'s assert.

Head device: CPU when the model runs on CPU (`_modelBackendNames` is CPU or
resolved GPU layers <= 0), with `op_offload` false. Otherwise a GPU or iGPU
device whose registry and device names match the model's backend (`mainGpu`
picks among several; none matching means CPU), with the CPU backend last in
the sched (required by `ggml_backend_sched_new`). Never
`ggml_backend_init_best`, which would start a GPU backend in explicit CPU mode.

CPU threads: `llama_encode` uses the private context's `n_threads_batch` for
every sequence of more than one token, and the head passes the same count
(`llama_n_threads_batch`) to the CPU registry's `ggml_backend_set_n_threads`.
So `ModelParams.numberOfThreadsBatch` sets the CPU threads of both, and
llama.cpp's default (4) applies when it is 0. `numberOfThreads` only reaches
one-token encoder passes, which `DecisionEngine` never builds.

Load-time checks, each failing with a typed exception and each decided by a
static helper that unit tests cover:

- `decisionModelUnsupportedReason` (also the capability probe):
  `general.architecture` is `modern-bert`; the CLS (`llama_vocab_bos`), SEP and
  MASK tokens are in the vocabulary; the MASK token has text; `n_embd_out` is 0
  or `n_embd`.
- `checkDecisionHeadFitsEncoder`: the head's `type_emb.weight` width equals
  `n_embd`; `n_ctx_train >= max_len`.
- `checkDecisionEncoderContext`: pooling is NONE; `n_ubatch >= max_len`.
- `DecisionHeadWeights.read`: every tensor is present with the exact shape
  implied by `hidden`, `head_layers` and the act rows; `nhead = max(1, hidden
  ~/ 64)` divides `hidden`.

The run path rejects a sequence longer than `llama_n_ubatch` before
`llama_encode`, whose `GGML_ASSERT` would abort the process.
`validateDecisionSequences` checks every sequence before the first encoder
pass: 1 to `n_ubatch` tokens inside the vocabulary, 1 to token-count markers
inside the sequence, and a question type from 0 to 2. The bridge core runs the
same checks with the same messages, so both runtimes reject the same input; the
marker-count bound comes from the bridge, whose head graph sizes its buffers by
marker count.

Windows: `llama.dll` exports no `ggml_*` graph symbols; they live in
`ggml-base.dll` (ops, graph, sched, buffers) and `ggml.dll` (registry). The head
calls ggml through a small function table that uses the generated bindings on
other platforms and `@Native` twins with `assetId:
'package:llamadart/ggml-base'`/`'package:llamadart/ggml'` on Windows (precedent:
`test/unit/backends/llama_cpp/native_precision_bindings_test.dart`). Generated
bindings are not edited.

### Web (`lib/src/backends/webgpu/`)

`WebGpuLlamaBackend` implements `BackendDecision` through `WebGpuDecisionHeads`
(`webgpu_decision.dart`), which calls the llama-web-bridge decision API:
`getDecisionCapabilities`, `loadDecisionHead`, `runDecision` and
`freeDecisionHead` (bridge `docs/api.md`, "Decision heads"). The bridge runs the
head on WebGPU when the model loaded with GPU layers and on the CPU otherwise,
and reports which as `deviceName`.

- Capability probe: a bridge object without all four methods reports
  unsupported with "Web decision models need llama-web-bridge assets with the
  decision API (apiVersion 1)", from the `webGpuDecisionBridgeRequirement`
  constant. A capability or head response with an `apiVersion` other than 1 is
  unsupported too, and such a head is freed first. The currently pinned assets
  predate the API, so Web reports unsupported until the asset pin moves to a
  tag that has it.
- Paths are URLs, resolved in Dart against `document.baseURI` before any
  fetch, so a page's `<base href>` applies to both in both bridge modes. The
  bridge fetches `headPath`. It takes the config only as text, so `configPath`
  is fetched in the page with `fetch`, before the head, and passed as
  `configJson`; with both a missing config and a bad head, Web reports the
  config where native reports the head. A failed fetch or an HTTP error is
  `LlamaModelException` "Cannot read the decision head config at <url>." with
  the status or error in `details`. URLs in error messages and details drop
  user info, query and fragment, including URLs that browser and bridge
  errors quote.
- Handles: the backend numbers heads itself, never reusing a number, and maps
  each to the bridge instance and bridge handle that loaded it. `modelFree` and
  `dispose` dispose the bridge, and a model load on the same bridge frees every
  bridge head, so the backend forgets all heads at each. A run with a forgotten
  head, or with a head whose bridge is no longer active, throws
  `LlamaStateException` without calling the bridge; a free does nothing.
- Errors: the bridge rejects with plain `Error`s that carry the core's message
  and no status code, so the mapping reads the message after stripping the
  bridge's `Failed to load decision head: ` or `Decision run failed: ` prefix.
  "Load the decision head again" (a freed head, or one lost to a worker
  failure, which also forgets the head), "No model loaded", "Bridge has been
  disposed", "was cancelled" and "during active generation" map to
  `LlamaStateException`, from the capability probe too; "decision encoder
  context" to `LlamaContextException`; anything else to unsupported for the
  probe, `LlamaModelException` for a load (head URL in `details`),
  `LlamaInferenceException` for a run and `LlamaStateException` for a free.
  Load errors that ask bridge callers to pass `configJson` name `configPath`
  or the config URL instead. Without an active bridge, the probe reports
  unsupported and a load throws `LlamaStateException`, as native does for an
  unloaded model. A malformed head description or output is
  `LlamaDecisionException`, like native's unexpected worker responses.
- Sequences: the bridge's JavaScript layer type-checks every sequence before
  the core validates any, and would reject a question type outside the int32
  range in its own words. The backend rejects that case first with native's
  message, so only the index can differ: with several invalid sequences, such a
  question type is reported before an earlier sequence's core error.
- The bridge serializes decision calls with its other operations and cannot
  cancel a run. When its worker fails during a run, it reloads the model on the
  main thread and rejects the run; the engine keeps its model, and the
  `DecisionEngine` must be loaded again.

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
| macOS | Metal or CPU | validated with a real model ([Measured](#measured)) |
| iOS | Metal or CPU | expected, untested |
| Android | CPU or Vulkan | expected, untested through `DecisionEngine` |
| Linux | CPU, Vulkan, CUDA | expected, untested |
| Windows | CPU, Vulkan, CUDA | expected through the `ggml-base` twins, untested |
| Native LiteRT-LM | - | `LlamaUnsupportedException` |
| Web (WebGPU bridge) | WebGPU or CPU (WASM) | needs bridge assets with the decision API (apiVersion 1), which no published asset tag has yet; the currently pinned assets report `LlamaUnsupportedException`. CI uses a fake bridge; checked locally with a real model ([Web check](#web-check)) |
| LiteRT-LM Web | - | `LlamaUnsupportedException` |

Real-model evidence is macOS only. The CPU head unit tests are meant to run in
the Linux, macOS and Windows CI jobs; until this PR's Linux and Windows jobs
pass, they have run on macOS only. iOS, Vulkan and CUDA have no run at all.
Android numbers come from the prototype that preceded this implementation, not
from `DecisionEngine`: about 2.1 s per question (512-token window, Q8_0) on a
Pixel 9 Pro with 6 CPU threads, and Mali Vulkan was slower than the CPU there.

### Measured

`decision-model-smoke` on an Apple M4 Max (16 cores, macOS), 24 fixture rows of
31 to 512 tokens (mean 90), `ModelParams(contextSize: 512)`, default threads
(llama.cpp's 4). Differences are the worst over all rows against the Laya 0.3.5
PyTorch reference; time is `systemOne` wall time per question.

| Backbone | Head file | Backend | Head device | Logit diff | Probability diff | Score diff | ms per question |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F32 (local conversion) | `laya-head.safetensors` | CPU | CPU | 0.0129 | 0.0029 | 0.0019 | 187 |
| F32 (local conversion) | `laya-head.safetensors` | Metal | MTL0 | 0.0118 | 0.0030 | 0.0031 | 15.4 |
| F16 (local conversion) | `laya-head.safetensors` | CPU | CPU | 0.0518 | 0.0115 | 0.0097 | 115 |
| F16 (local conversion) | `laya-head.safetensors` | Metal | MTL0 | 0.0118 | 0.0030 | 0.0031 | 14.0 |
| `laya-Q8_0.gguf` | `laya-head.safetensors` | CPU | CPU | 0.1422 | 0.0356 | 0.0609 | 85.6 |
| `laya-Q8_0.gguf` | `laya-head.safetensors` | Metal | MTL0 | 0.1642 | 0.0436 | 0.0253 | 14.4 |
| F32 (local conversion) | official `model.safetensors` + config | CPU | CPU | 0.0129 | 0.0029 | 0.0019 | 188 |
| `laya-Q8_0.gguf` | official `model.safetensors` + config | Metal | MTL0 | 0.1642 | 0.0436 | 0.0253 | 14.2 |

The official checkpoint's F16 head tensors give the same differences as the F32
head file. On these 24 fixture rows, in every configuration, no choice changed,
no noul crossed 0.5 and no score rounded to a different level.

The fixture's short sequences understate the error. A broader review set of
187 questions in 62 random requests (seed 20260922, mean 327 tokens, 73
sequences at the 512-token cap), compared with Laya 0.3.5 on CPU in FP32, gave
these worst differences:

| Backbone | Backend | Logit diff | Probability diff | Changed decisions |
| --- | --- | --- | --- | --- |
| F32 (local conversion) | CPU | 0.102 | 0.0065 | none |
| F32 (local conversion) | Metal | 0.100 | 0.0085 | none |
| F16 (local conversion) | CPU | 0.204 | 0.0189 | two choices with reference top-2 gaps of 0.00015 and 0.0003 |
| F16 (local conversion) | Metal | 0.100 | 0.0085 | none |
| `laya-Q8_0.gguf` | CPU | 1.905 | 0.237 | a noul from 0.694 to 0.457 (also with 1 and 4 threads); a choice with a reference top-2 gap of 0.00015; a noul from 0.4997 to 0.5004 |
| `laya-Q8_0.gguf` | Metal | 2.935 | 0.066 | two choices with reference top-2 gaps of 0.00015 and 0.0014; a noul from 0.4997 to 0.5010 |

On this set the median Q8_0 difference is about 6 times the F32 one for logits
and 8 times for probabilities; on the fixture the worst is 11 (CPU) to 14
(Metal) times. Q8_0 can change clear decisions. An F16 conversion matched F32
on Metal and flipped only near-ties on CPU. Use an F32 backbone, or F16 on
Metal, when answers must match Laya; the published `laya-F16.gguf` has not
been measured.

On Metal, disposing the engine with a head still loaded exits cleanly; skipping
the head frees in `freeModel` and `dispose` makes the same exit abort in
`ggml_metal_rsets_free`.

### Web check

Local only, not in CI: `DecisionEngine` through `LlamaEngine(LlamaBackend())`
in Playwright's headless Chromium on the same machine, with an unpublished
local build of the llama-web-bridge decision API, the 24 fixture rows,
`laya-head.safetensors` and the tolerances of `decision-model-smoke`. Token ids
and markers matched on every row.

| Backbone | Bridge runtime | Head device | Logit diff | Probability diff | Score diff |
| --- | --- | --- | --- | --- | --- |
| `laya-Q8_0.gguf` | WebGPU; worker and main thread on wasm64, worker on wasm32 | WebGPU | 0.1636 | 0.0436 | 0.0247 |
| F16 (local conversion) | WebGPU; worker and main thread | WebGPU | 0.0169 | 0.0046 | 0.0013 |
| F16 (local conversion) | WASM CPU; worker | CPU | 0.0149 | 0.0039 | 0.0028 |
| `laya-Q8_0.gguf` | WASM CPU; worker | CPU | 0.2326 | 0.0628 | 0.1224 |

Q8_0 on the WASM CPU misses the 0.05 probability tolerance on one row, with the
same top option. The bridge's own smoke, which calls the bridge directly, gets
the same worst logit difference, so the drift comes from the bridge's WASM CPU
Q8_0 path rather than llamadart. The currently pinned assets reported
unsupported with the actionable reason in both bridge modes. Sequence
validation messages, error mapping, URL redaction, `<base href>` resolution,
and heads freed or bridges disposed behind the engine's back were checked
against the same build.

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
- Text containing U+0000 is rejected with `LlamaDecisionException`: native
  tokenization passes the text's C-string length to `llama_tokenize`, so it
  would cut the text at the NUL while Laya tokenizes all of it. A non-string
  state is JSON-encoded, which escapes U+0000.
- Q8_0 backbones can change decisions; see [Measured](#measured).

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
  the ggml head on a tiny synthetic head against a pure-Dart reference, and
  through a recording ggml function table that checks every create has its
  free, the teardown order, the thread count and the scheduler's backend
  order; the service's load-time check helpers, sequence validation, and run
  order through a substituted encoder; worker, backend-client and router
  routing with fakes; engine hooks and facade with a fake backend.
- Unit (Chrome): `WebGpuDecisionHeads` against a fake bridge
  (`test/support/fake_webgpu_decision_bridge.dart`): the capability probe for
  old assets, API version skew, bridge reasons and state rejections; head
  loading with page-fetched configs, unreadable ones, URLs resolved against a
  `<base href>`, and credentials and queries kept out of errors; error mapping,
  including the `configJson` wording; handle scoping to the loading bridge;
  question types outside int32; malformed responses. `WebGpuLlamaBackend`
  without an active bridge, and forgetting heads on `modelFree`, a same-bridge
  model load and `dispose`; `WebAutoBackend` forwarding and LiteRT-LM Web
  reporting unsupported; the engine hook without a model.
- Integration (Chrome, fake bridge): `DecisionEngine` through `LlamaEngine`,
  `WebAutoBackend` and `WebGpuLlamaBackend`: answers, sequence layout,
  page-fetched config, old assets, API version skew, a cancelled capability
  probe, and a model unload.
- Integration (VM, CI's `stories15M.gguf`): a llama-architecture model is
  reported unsupported and `DecisionEngine.load` fails before reading the head.
- Local-only E2E `test/e2e/backends/decision_engine_e2e_test.dart`: real GGUF
  and head, the 24 fixture rows, exact token ids and markers from the engine
  tokenizer, raw logits and `systemOne` answers within tolerance (see
  `doc/testing_matrix.md` for the tolerance rules); the head on the CPU when
  the model offloads no layers; and an engine disposed with a head still
  loaded, whose process must then exit cleanly (on Metal a leaked buffer
  aborts the exit, which fails the runner). Runner scenario
  `decision-model-smoke` (`--model-path`, `--head-path`, optional
  `--config-path` and `--backend`) and test-matrix row of the same id.
- No test reaches the service's `llama_free` of the encoder context after a
  failed head load, its `op_offload` and `mainGpu` choices, or its order of
  head and context teardown; that needs fault injection or several GPUs. The
  PR's high-risk block records them as residual risk.

Fixture: `test/fixtures/decision/laya_0_3_5_reference.json`, produced by the
scripts beside it from the pinned official checkpoint on CPU in FP32.

## Delivery

Stacked PRs, each merged only with maintainer approval:

1. Design doc and the pure-Dart core with the parity fixture (standard risk).
2. Native backend, engine hooks, facade, export, E2E, docs. High risk:
   `classify_high_risk_changes.dart` reports `backendRuntime`,
   `regressionPolicy` (the test-matrix row and its docs) and `structuredOutput`
   (`lib/llamadart.dart` brings in all three structured-output v2 axes by
   default). The readiness evidence must justify excluding each
   structured-output axis from inspected production call sites, alongside the
   regression-policy evidence and the independent audit.
3. `example/basic_app` decision example.
4. `example/laya_tetris` Flutter example: real-time Tetris played through
   `DecisionEngine`, with the base and a Tetris-tuned head.
5. Head fine-tuning notebook and dataset tool.
6. Web: a decision module in `llama-web-bridge` (C++ next to its TTS module,
   same graph on WebGPU), `WebGpuLlamaBackend` implementing `BackendDecision`
   in this repo (reporting unsupported with the pinned assets), asset
   publication, then the asset pin bump.

Model hosting for the Tetris-tuned head, and publishing new bridge assets, need
maintainer approval before they happen.
