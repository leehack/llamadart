# LiteRT-LM C API 1 adoption

The public lazy facade, default service probes and speech worker now share
ABI-aware discovery. Production selection still rejects C API 1 because
`_liteRtLmV1ProductionSelection` remains false. The internal
`createLiteRtLmSelectedRuntimeClient(allowV1: true)` entry point exercises that
same facade with admitted C API 1.0.x fixtures, retaining selected core and
companion handles and paths. `LiteRtLmV1RuntimeClient` also remains injectable. Its fixtures prove ABI,
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
| Packaged Apple platform floor | Exact owner `5129cd0` candidate declares macOS 14.0 and iOS 15.0 | Staged owned discovery refuses macOS below 14 or unknown versions before any core/companion load, including custom paths; direct v1 operations also check the floor. Public activation and artifact qualification remain pending. macOS 13 is unsupported by this artifact; static iOS minima are not device qualification. |
| Engine initialization and backend options | Status/out settings; responsive owned background creation with scalar function/configuration addresses, immediate same-thread canonical error copy, partial-owner cleanup and typed service retry classification. Pending/uncertain creation retains its library/model/cache family. | Qualify each selected backend and exact artifact; missing completion requires process restart. |
| `tokenize` / `detokenize` / start tokens | Status/out, `size_t`, copied results, legacy BOS semantics | Matching artifact/model qualification. |
| Bundle capabilities | Owned model-file snapshot; null optional client probe on native read failure | Declarations do not prove executor or channel enforcement. |
| System, text/tool/media history and tool descriptors | Validated snapshots; encoded local image/audio paths and base64 payloads retain roles/order through the existing service serializer. Loaded-core modality and processor admission precede native history/send. | Real media-family artifact qualification; additional tool schema shapes remain separate. |
| `generate` / `generateMessageJson` / chat | Active text/tool/encoded-media messages and snapshotted per-send context; native response/tool-call assembly. Explicit visual budgets require declared Gemma4 image processing plus the native setter and use status/out ownership. | Real media/processor quality and platform qualification. |
| Output cap and generated-token penalties | Owned per-turn options; missing exports refuse before send | Preserve the tested refusal of unqualified penalties with speculation. |
| Reasoning output and budgets | Named reasoning chunks retain configured markers. Positive C-int per-send budgets use status/out thinking options after first-channel boundary and native-tokenizer admission. | Actual matched thinking-family enforcement, cancellation/reuse and final public routing still require qualification; symbols or metadata alone do not prove a model obeys the bound. |
| Native JSON Schema chat | Complete optional C API 1.0 group, by-value provider enum, status-checked configuration and per-turn constraints with thinking disabled; compiled ABI and service-client fixtures | Exact candidate/model regression and final public routing remain required. Missing exports refuse before conversation replacement; automatic tool constraints remain disabled. |
| LoRA session path | Explicit typed refusal preserves the current conversation; upstream advanced engines reject initial text adapters | Runtime support remains tracked in [litert-lm-native#99](https://github.com/leehack/litert-lm-native/issues/99); setter availability alone does not provide support. |
| Image/audio chat | Internal encoded-file transport; configured encoder, native modality declarations and a supported processor route are all required. Unknown/missing proof is refused. Service image-history counts prepare dynamic inputs without claiming enforced capacity. Direct legacy-only `maxNumImages` capacity remains unsupported. | Public factory remains disabled. Remote URLs, raw RGB/PCM and video retain their existing refusal; compiled fixtures do not qualify media quality or GPU execution. |
| Embedding sessions | Dedicated v1 engine/options/input/response APIs, `size_t` counts and copied vectors; the public extension preserves its concrete session return type through a forwarding session | Matching artifact/model qualification with existing backend restrictions. |
| Dedicated ASR | Loaded-library ABI1/layout/full-symbol admission; v1 client and injected actual speech probe/worker use the independent bridge. Compiled fixture covers partial owners, copied text/errors, size_t backpressure, cancel/reset/finalization and worker startup/disposal. | Matching artifact/model/audio qualification through the injected worker; staged selector probe/worker fixture passes; production selection remains legacy. |
| Logging | Canonical v1 status checked for declared severity values | Matching artifact qualification. |
| Cancellation, errors and disposal | Final plus successful drain required; cancellation awaits adapter terminal bookkeeping; failed drain/missing final retain native owners in isolated fixtures | Worker/timeout and actual artifact/model qualification must preserve the same retention boundary. |
| Benchmark metrics / `run` | Legacy metrics value types and aggregation; owned native snapshots | Benchmark loops and actual artifact/model qualification. |

Production selection remains legacy and the Web stub remains unchanged. Independent ASR library helpers reuse its bridge bindings without constructing legacy text bindings; malformed success-with-null owners are refused, and a partial engine returned with an error is released. Adding an operation to
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

## Internal media admission

Image/audio JSON accepts one existing local file path or nonempty standard base64
blob per encoded part, in user/assistant messages. History is snapshotted before
native allocation. The service serializer retains every image/audio part across
history expansion and conversation recreation; system/tool media, mixed media
with thinking/tool calls, URLs, raw pixels/samples and video are refused. Local
files must remain available until native processing settles.

Native `loaded_file_supports_input_modality` declarations are necessary but do
not by themselves prove that a conversation processor consumes media. Admission
also checks configured encoders and the bounded model-type metadata. Generic
processors require explicit image/audio switches. Missing type declarations may
use the exact upstream Gemma3/Gemma3n tokenizer fingerprint; filenames never
admit a processor. Unknown model types or unavailable native probes stay
unsupported. A processor omitted from a custom native build still fails native
conversation creation rather than becoming a text-only success.

The service's automatic visual preprocessing hint is distinct from an explicit
per-send budget. V1 requests the automatic hint only for a declared Gemma4 image
processor with its setter export. An explicit budget for another/unknown
processor is refused: the canonical C wrapper otherwise returns success while
ignoring it. The status-checked budget and output/penalty options share one owned
optional-args scope. The service's image-history count is routing/preparation
information, not a public capacity request; v1 passes all actual images without
calling the legacy-only count setter. Direct settings that request an enforced
legacy capacity still fail explicitly.

These source/fixture checks do not activate the public factory, select new
runtime assets, establish image/audio semantics or qualify hardware.

## Internal thinking-budget admission

The runtime capability requires the complete thinking-config, optional-args and
native-tokenizer export groups without allocating an engine. Each requested
budget separately checks the loaded model's first declared channel: it must be
reasoning (an explicit flag or the existing legacy reasoning-name fallback),
with distinct nonempty UTF-8 start/end strings. The loaded native tokenizer must
produce nonnegative, nonempty, distinct token sequences and decode each whole
marker exactly with special tokens retained. A later reasoning channel cannot
replace the first one used by upstream. Unknown or malformed proof is refused.
The legacy two-field first-channel reader keeps its existing signature and
behavior; stricter boundary decoding belongs to the detailed admission reader.

Budgets are positive signed C ints. Every send creates a thinking config, checks
its returned status, explicitly enables thinking, sets the budget, and attaches
its copied value to owned optional args. Temporary owners are released on both
success and failure, after copying native errors. No-budget sends attach no
thinking override, including after a bounded or cancelled turn. Failed drains
and missing final callbacks retain the same native family; temporary decode
options do not release that ownership early.

Conversation context is snapshotted as JSON. Per-send context overrides its keys
for that send, matching native merge order; an effective false or unknown
`enable_thinking` refuses a directly requested budget. Schema conversations and
speculative decoding also refuse it. The existing service behavior remains:
`enableThinking: false` forwards no budget, and zero budgets or forced messages
are rejected. The native already-open-channel branch remains responsible for
using empty start IDs when the rendered prompt has opened the first channel.

Compiled fixtures check ABI values, export/version skew, first-channel and
native tokenization negatives, status/partial-owner cleanup, schema interplay,
per-turn isolation, cancellation and unsettled retention. They do not prove
reasoning enforcement. Before public adoption, run a scheduled, hash-bound
thinking-family model check with unbounded reasoning above the bound, bounded
reasoning within the declared tokenized tolerance, nonempty final content and
cancel/reuse isolation. Keep runtime/model/host identity and all failed outcomes.

## Final public-path qualification

The `litert-lm-v1-public-direct`, `litert-lm-v1-public-service` and
`litert-lm-v1-public-speech` local-only rows exercise the public
`LiteRtLmRuntimeClient`, default `LiteRtLmService` and default
`SpeechToTextEngine` paths. They provide no runtime-client factory or speech
driver override. Production selection remains disabled, so these rows must
refuse until the final activation and artifact gates are admitted.

Supply `LITERT_LM_V1_LIBRARY`, its `LITERT_LM_V1_LIBRARY_SHA256`,
`LITERT_LM_V1_MODEL_SHA256`, `LITERT_LM_V1_RUNTIME_MANIFEST` and its
`_SHA256`, plus `LITERT_LM_V1_PUBLIC_CONFIG` and its `_SHA256`. The runtime
manifest is the existing list of adjacent payload `name`, `bytes` and `sha256`
records; every library must match. Chat config is the tracked
`chat-litert-cpu.json` profile. Speech config binds `tokenizer` and `audio`
objects (`path`/`sha256`), `preset` and `expected_transcript`.

Run `run_local_e2e.dart --scenario litert-lm-v1-public-<route> --model-path
<model> --backend cpu --dry-run` first. The scheduled execution compiles a
child from clean committed source, hashes its executable, preserves stdout and
native stderr before aggregate assertions, and owns its four-minute deadline.
It records all observed loaded runtime payload identities, two chat engine
lifetimes, cancellation and reuse. The direct client reports native finish;
the default service exposes settlement and limit classification but no exact
cancelled native-finish getter, so its receipt says that explicitly.

Model-free tests separately prove the current uninjected flag-off refusal with
zero fixture engine attempts. Clearly labeled staging-seam tests exercise the
status-9 engine error mapping: explicit GPU requests surface typed unsupported
with the CPU remedy, while automatic GPU preference retains CPU fallback.
These are consumer mapping controls, not execution of the Android native guard
or GPU/physical-device qualification. The fixture-only `--expect-disabled`
control can never produce a successful public-v1 qualification receipt.

Complete default discovery is a separate activation gate: legacy inventories
include TopK sampler libraries absent from the prepared v0.19 manifest. Do not
add dummy libraries or weaken completeness to make an actual candidate pass.
The default service must resolve the admitted version-specific inventory; the
qualifier rejects a loaded core or companion whose bytes differ from its
manifest. Other platform and owner-artifact gates remain independent.

## Internal JSON Schema qualification

The maintained `litert-lm-v1-json-schema` local-only scenario binds the published
CPU Qwen profile, exact candidate library and source/child bytes. It checks a
fixed conflicting plain control, Unicode/typed constrained output with thinking
disabled, ordinary followup, real cancellation, reuse and reload. This prepares
actual candidate qualification; adding the scenario alone does not satisfy that
gate or enable public v1 routing. See `doc/testing_matrix.md`.


## Actual thinking qualification

`litert-lm-v1-thinking-budget` is a separate local-only preparation scenario for
the maintained `gemma4-litert-cpu` bundle (SHA256 `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`).
It preserves the existing generation-controls train prompt, deterministic
sampler and reasoning oracle: unbounded reasoning exceeds 24 tokens, budget 12
allows at most 14 tokenized reasoning tokens and requires nonempty final content.
Every send uses one fixed total output cap of 1536 tokens. This is a separately
reviewed prospective run: the earlier candidate and legacy 768-token baseline
failures remain failed evidence. There is no automatic cap escalation.
Completed generations must report a native stop and settled work. Unbounded
bytes must match before and after the bounded turn, cancellation and reload.
Cancellation requires actual output and a native cancelled cause. A separate
client refuses an explicit budget under false context, then proves bounded reuse.
Before direct client initialization, the qualifier creates and write-probes a
private cache under its existing scratch directory. The outer scratch owner
retains that cache until the owned child exits, including unsettled cleanup.

Native finish and settlement observations belong to the exact client/engine
epoch recorded by successful native creation. A harmless tokenizer call forces
lazy initialization before capturing each turn's owner; capability probes never
select it. Unknown finish evidence from a new owner cannot borrow a disposed
client's earlier stop result. Engine replacement during a turn is refused.

The scenario requires core and manifest SHA256 inputs. The manifest is a JSON
array of every adjacent runtime dylib, each with basename `name`, positive
`bytes` and lowercase `sha256`; optional metadata is ignored. All files must
remain within the core directory. The child verifies each payload before loading
and records dependency graphs, actual dyld-loaded runtime paths, effective
status-checked sampler values, marker token IDs, emitted assembled UTF-8 bytes,
native metrics/finish causes and native stderr before checking the oracles.
Before every service send, a delegating observer captures the actual native
rendering, UTF-8 bytes, hash and native token IDs with and without start tokens,
plus conversation settings after successful production status checks. The first
baseline must match the preserved legacy native render byte-for-byte and by hash
before generation; this prospective gate does not assert parity of the old failed
candidate run. Later stages retain their prescribed inputs. Per-send
settings remain labelled requested until the turn succeeds; no native sampler
readback is claimed. Input metrics sum all prefill work, including native KV-cache
refills after reasoning removal, so they are not the initial prompt-token count.
Assembled output bytes are not represented as raw native response JSON.

Run the dry-run below first. Execute only after the model-job owner admits the
clean frozen source, exact runtime payload manifest and fixture identity. The
outer test compiles and hashes an owned child, captures logs in a unique run
directory and kills only that child at 600 seconds. No automatic retry or prompt
selection is performed. This qualifies CPU budget enforcement and lifecycle,
not train-answer accuracy, other models/backends or public v1 activation.

```bash
LITERT_LM_V1_LIBRARY=<candidate-libLiteRtLm.dylib> \
LITERT_LM_V1_LIBRARY_SHA256=<sha256> \
LITERT_LM_V1_RUNTIME_MANIFEST=<runtime-payloads.json> \
LITERT_LM_V1_RUNTIME_MANIFEST_SHA256=<sha256> \
LITERT_LM_V1_MODEL_SHA256=181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c \
dart run tool/testing/run_local_e2e.dart --scenario litert-lm-v1-thinking-budget \
  --model-path <gemma-4-E2B-it.litertlm> --backend cpu --dry-run
```
