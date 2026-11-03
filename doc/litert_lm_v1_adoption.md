# LiteRT-LM C API 1 adoption

The public runtime factory still rejects C API 1. `LiteRtLmV1RuntimeClient` is
an internal, explicitly injected service client. Its fixtures prove ABI,
dispatch and lifetime behavior; they do not qualify a model, device or owner
artifact. Keep the factory disabled and pins unchanged until the required gaps
below and artifact review are complete.

`LiteRtLmService.runtimeClientFactory` selects this preparation path and probes
metadata/finish capabilities from that same factory. It is exclusive with the
existing `clientFactory`. The existing factory retains its creation counts and
public client behavior through `LiteRtLmLegacyServiceClient`; its statically
dispatched embedding extension stays on the legacy implementation. The internal
client/session contracts make v1 embedding dispatch independent of that extension.

## Required coverage

| Public call path | Preparation and evidence | Remaining admission work |
| --- | --- | --- |
| Packaged Apple platform floor | Exact owner `5129cd0` candidate declares macOS 14.0 and iOS 15.0 | macOS 14 deployment/runtime refusal, docs and companion SwiftPM must agree before adoption. macOS 13 is unsupported by this artifact; static iOS minima are not device qualification. |
| Engine initialization and backend options | Status/out settings; responsive owned background creation with scalar function/configuration addresses, immediate same-thread canonical error copy, partial-owner cleanup and typed service retry classification. Pending/uncertain creation retains its library/model/cache family. | Qualify each selected backend and exact artifact; missing completion requires process restart. |
| `tokenize` / `detokenize` / start tokens | Status/out, `size_t`, copied results, legacy BOS semantics | Matching artifact/model qualification. |
| Bundle capabilities | Owned model-file snapshot; null optional client probe on native read failure | Declarations do not prove executor or channel enforcement. |
| System, text/tool history and tool descriptors | Validated snapshots; actual service chat fixture with history/tools | Media history and additional supported schema shapes require migration. |
| `generate` / `generateMessageJson` / chat | Active text/tool messages and snapshotted per-send context; native response/tool-call assembly | Media payloads, visual budgets and their processor contracts. |
| Output cap and generated-token penalties | Owned per-turn options; missing exports refuse before send | Preserve the tested refusal of unqualified penalties with speculation. |
| Reasoning output | v1 `reasoning_content` identifies a named reasoning channel; duplicate channel text is surfaced once within configured markers | Thinking budgets remain explicitly refused. A metadata boolean alone cannot prove channel end-token enforcement. |
| Native JSON Schema chat | Explicit typed refusal | Provider/configuration and per-turn constraint status APIs, including the existing thinking-disable contract. |
| LoRA session path | Explicit typed refusal | Setter status, copied path ownership and supported engine/backend behavior. |
| Image/audio chat | Explicit typed refusal | Media message validation, processor admission and visual-budget transport. `maxNumImages` is documented legacy-engine-only and must not be silently dropped. Video retains its existing public refusal. |
| Embedding sessions | Independent session contract; explicit v1 refusal | Dedicated v1 engine/options/input/response APIs, `size_t` counts and copied vectors, with existing backend restrictions. |
| Dedicated ASR | Loaded-library ABI1/layout/full-symbol admission; v1 client and injected actual speech probe/worker use the independent bridge. Compiled fixture covers partial owners, copied text/errors, size_t backpressure, cancel/reset/finalization and worker startup/disposal. | Matching artifact/model/audio qualification through the injected worker; public default selection remains legacy. |
| Logging | Canonical v1 status checked for declared severity values | Matching artifact qualification. |
| Cancellation, errors and disposal | Final plus successful drain required; cancellation awaits adapter terminal bookkeeping; failed drain/missing final retain native owners in isolated fixtures | Worker/timeout and actual artifact/model qualification must preserve the same retention boundary. |
| Benchmark metrics / `run` | Legacy metrics value types and aggregation; owned native snapshots | Benchmark loops and actual artifact/model qualification. |

The public legacy selection and Web stub remain unchanged. Independent ASR library helpers reuse its bridge bindings without constructing legacy text bindings; malformed success-with-null owners are refused, and a partial engine returned with an error is released. Adding an operation to
the internal contract requires both ABI implementations to supply it explicitly;
v1 never inherits a legacy FFI method as a fallback. Unsupported preparations
throw `LlamaUnsupportedException` before native generation rather than reporting
success with an ignored option.

## Primary contracts

Consumer preparation is checked against upstream
`83ce6067f2e2a3fb697556928f93936693ded971`:

- `c/engine.h`, `c/conversation.h`, `c/model_info.h` define status/out signatures,
  owned results and borrowed strings.
- `runtime/conversation/internal_callback_util.cc` emits a reasoning chunk with
  one named channel and the same text in `reasoning_content`.
- `runtime/conversation/conversation.cc` derives thinking delimiter tokens from
  channel metadata; `runtime/core/tasks.cc` can ignore a budget without end IDs.
- Owner ASR ABI/layout admission is a separate contract from the core C API
  version. Its model and audio-quality qualification remains independent.

## Actual service qualification

The `litert-lm-v1-service` local-only scenario accepts an explicit library path,
model path and both expected SHA256 digests. Run its `--dry-run` first, then the
same command without that flag only when the model-job owner schedules it:

```bash
LITERT_LM_V1_LIBRARY=<qualified-libLiteRtLm> \
LITERT_LM_V1_LIBRARY_SHA256=<64-hex-digest> \
LITERT_LM_V1_MODEL_SHA256=<64-hex-digest> \
dart run tool/testing/run_local_e2e.dart --scenario litert-lm-v1-service \
  --model-path <Qwen3-0.6B.litertlm> --backend cpu --dry-run
```

It compiles an owned child from a clean checkout, binds its executable and source
revision/tree to the receipt, verifies input bytes, and requests CPU with two
threads and an isolated cache. Chat must return exactly `4`; cancellation must
begin after actual output and finish with the native cancelled cause; reloading
the same service must return `4` again. A process deadline bounds unsafe retained
work. Logs and the receipt go under `.dart_tool/litert_lm_v1_service/`, or the
external `LITERT_LM_V1_LOG_DIR`. This is a qualification tool, not public v1
selection, and does not claim the remaining feature families or other devices.

## Independent ASR dispatch

`createLiteRtLmSpeechToTextDriverWithRuntime` in the IO implementation is an
internal qualification/integration boundary. Pass an isolate-sendable factory
that constructs the selected ABI client from the provided library path inside
the receiving isolate. Both the support probe and the streaming worker use it.
The default speech factory still uses the legacy client; this does not enable
public C API1 selection or change runtime pins.

The selected text C API does not determine ASR support. The loaded library must
report ASR ABI1, exact configuration/result sizes and every required bridge
symbol. A session retains its own bridge/library and model resources after its
creation engine is deleted; it can settle and dispose independently of a text
client. Calls remain synchronous inside the existing worker and cancellation is
cooperative between windows, as in the owner contract.

For a scheduled real ASR check, use `litert-lm-v1-asr-smoke` from the local E2E
runner with explicit library/model/tokenizer/audio SHA256 values. Its dry-run
prints the exact command. The wrapper requires a clean committed checkout,
compiles an owned AOT child, verifies all four input digests before native
loading, requests CPU/two threads, and injects the v1 driver into the existing
public streaming/task/cancellation smoke. It captures source/executable identity,
stdout/native stderr and a receipt in a unique temporary evidence directory.
Only its owned child is killed at the four-minute deadline. A successful fixture
or owner C++ smoke does not replace this actual Dart worker/model qualification.

## Asynchronous engine ownership

The v1 service client awaits `loadConfiguredAsync`; the explicit synchronous
internal `loadConfigured` helper keeps its existing behavior. Short settings
construction stays on the owner isolate. The blocking constructor runs through
`runLiteRtLmBlockingCall` with scalar addresses and plain diagnostic strings,
while the client retains the original library, settings and borrowed strings.
The completed scope copies canonical v1 message/clear error state on that thread
using the returned status, then releases a failing partial engine. It never
queries the removed legacy error-code getter.

Only an explicit returned scope permits settings cleanup and engine adoption.
Lost transport quarantines the family and refuses reuse/disposal. The service
exposes pending initialization, retains its client/model-link/cache lease before
the await, and forbids cache/audio/automatic-backend retry after uncertain
completion. Settled failures retain the existing typed engine-creation retry and
fallback behavior. Model-free barriers/TLS fixtures and killed subprocesses test
these boundaries; they do not substitute actual artifact/model qualification.
