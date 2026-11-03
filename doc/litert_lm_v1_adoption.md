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
| Engine initialization and backend options | Status/out settings and ownership; injected CPU service fixture | Preserve responsive asynchronous creation and precise native-creation error classification for existing retry policies. Qualify each selected backend. |
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
| Dedicated ASR | Independent owner ABI 1 exists; explicit v1 refusal | Library admission and actual speech probe/worker dispatch must use the independent bridge safely, without legacy core ABI calls. |
| Logging | Canonical v1 status checked for declared severity values | Matching artifact qualification. |
| Cancellation, errors and disposal | Final plus successful drain required; cancellation awaits adapter terminal bookkeeping; failed drain/missing final retain native owners in isolated fixtures | Worker/timeout and actual artifact/model qualification must preserve the same retention boundary. |
| Benchmark metrics / `run` | Legacy metrics value types and aggregation; owned native snapshots | Benchmark loops and actual artifact/model qualification. |

The public legacy runtime and Web stub remain unchanged. Adding an operation to
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
