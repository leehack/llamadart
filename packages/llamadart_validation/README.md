# llamadart validation

Private maintainer package (`publish_to: none`). It exercises the exported
llamadart API through the same core on desktop, Flutter mobile, and Web.
It is independent of the public package's implementation and exports.

Start from the repository root:

```sh
dart run tool/testing/run_local_e2e.dart --scenario validation-harness
dart run tool/testing/validation.dart local --profile tiny-gguf-cpu
dart run tool/testing/validation.dart local --profile tiny-gguf-lifecycle
dart run tool/testing/validation.dart build --target desktop --out .dart_tool/validation/bundles/desktop
```

See [the runbook](../../doc/cross_platform_validation.md) for models, bundles,
Firebase/GCE setup, run/recovery commands, evidence and cost boundaries.
See [the full plan](../../doc/cross_platform_validation_plan.md) for subsequent
platform and feature qualification. A quick run does not qualify a release.

`assets/profiles/` locks each model URL/revision/SHA256/size and inference
configuration. `lib/llamadart_validation.dart` is the platform-neutral suite; conditional native
adapters and `lib/io.dart` handle filesystem/runtime checks. `bin/run.dart` and `bin/report.dart` are the
CLI entrypoints. Flutter uses the package's profile assets and shared runner.
Native wrappers persist JSONL per event; reports always derive from that journal.
`assets/image_profiles/` holds the Firebase image-generation device checks, which
run the chat app's image test (or, for `image-settings-*`, its image settings
comparison) and are graded by its image evidence verifier
([image-generation profiles](../../doc/cross_platform_validation.md#image-generation-profiles)).

The two `npu-*` profiles are locked candidates. Inspect their local prerequisites
with `validation.dart npu-preflight`; the opt-in Android builder packages verified
local model/vendor inputs and the installed app checks its SoC and captures
per-generation execution proof. S24 NPU execution is verified but semantic
qualification still fails; Pixel 10 hardware execution remains NOT_RUN.

Exit 0 means this selected run qualified, 1 means failed/incomplete.
Unknown/dirty source provenance, missing counters, unknown backend placement, skipped mandatory cases and missing
records remain incomplete. Imported model preparation must prove the locked
SHA256 and byte size. Desktop qualification additionally requires the portable
CLI's verified runtime inventory and bundle manifest hash; JIT remains diagnostic.
The CLI rejects runtime overrides, validates its environment and runtime payload,
and anchors native discovery to the bundle. Older desktop journals without this
proof preserve assertions but no longer qualify when reimported. `release` selection deliberately records unimplemented
feature packs as NOT_RUN until their fixtures and wrappers are qualified.
The reporter derives mandatory cases, effective settings and accelerator-proof
requirements from the validated profile. Self-declared inventory, rehashed
conflicting settings and per-record unsupported exemptions cannot waive them.

Reports expose independent `summary.qualification_gaps`: assertion failures,
execution errors, unexecuted cases, missing accelerator evidence, incomplete
provenance, and journal/lifecycle problems. Multiple gaps can coexist. An
unverified accelerator does not establish model or platform incompatibility;
successful inference also does not prove GPU/NPU execution. Execution errors
require diagnosis against the retained native logs and host setup. The HTML
report shows these distinctions and the placement verifier's reason. These
diagnostics do not relax qualification requirements or replace case results.

`C01.load` measures public load/readiness, which can precede native engine
initialization. In LiteRT, the first `C02.unicode` tokenization call can include
deferred engine creation. Its `tokenize_call_ms` is therefore not isolated
tokenizer latency. The runner records this timing scope, separate detokenization
latency, and the active public operation on errors/timeouts. A first-use timeout
does not establish a tokenizer defect. Case deadlines remain 60s unless the embedding pack locks its 300s deadline or a LiteRT
GPU profile sets `engine_create_case_timeout_ms` for engine-create cases; provider
process deadlines can additionally include model preparation and host startup.

Profiles select `quick`, `focused` or `release`. Focused profiles require a
nonempty, unique `focus_features` list; `tiny-gguf-lifecycle` adds the second
dispose/load/generate cycle to the quick CPU run. Core feature IDs are `text`,
`unicode`, `thinking`, `history`, `tools`, `streaming`, `batching`, `lifecycle`, `guards` and
`performance`. Unimplemented selected cases stay NOT_RUN.

Journal schema 2 includes the versioned case/feature catalog, resolved synthetic
fixtures, explicit omissions and a catalog hash. Each terminal case carries its
case version and fixture hash. Defaults live in `lib/src/case_catalog.dart` and
compile into every host; model overrides remain in the locked JSON profiles.
The reporter validates metadata against the executable catalog and still imports
schema-1 journals with their original inventory. It does not invent missing
catalog provenance for those older runs.

`tiny-gguf-batching` adds C11 text/thinking parity across default, 1-piece/1-byte,
and recovered default worker settings. Trial outputs/configuration/finish order
and metrics are retained; chunk counts may differ. LiteRT Web checks each native
option's typed rejection instead. NPU deterministic parity, GGUF Web controls and
tool-bearing fixtures remain unqualified. Catalog version 2 preserves imports of
version-1 journals against their original case/fixture definitions.

Catalog 4 adds executable C02 Unicode generation (exact output, no trimming),
C05 thinking enabled/disabled (512 output-token bound, separated nonempty thinking
when enabled and none when disabled), and C07 tool choice (`auto`, `required`,
`none`, 128 output-token bound). C07 checks one weather call with exact city
arguments, public completion semantics, synthetic tool-result consumption and
default recovery. The actual tools, choices, prompts, messages and per-call
settings are logged; tool schemas are produced by the public ToolDefinition API.
Failures are strict model/runtime observations, not automatic diagnoses.
Thinking-budget controls and tool-bearing batching remain separate planned work.
Native C API controls do not execute these public feature cases. Catalogs 1–3
retain their original fixtures and unimplemented obligations on import. No
existing device/model run is upgraded by this implementation.

For portable GGUF GPU runs, pass `--native-log <captured-stderr-path>` to the
validation launcher and redirect stderr to that path before starting it. The
launcher uses those bytes for the same placement checks as the standalone
reporter. Missing or invalid UTF-8 captures fail; supplying a log never waives
failed cases, missing records or runtime identity requirements.

For Firebase Android LiteRT GPU runs, remote collection binds the device
`logcat` to the journal and the reporter verifies N GPU delegate
initializations on one hardware Vulkan adapter for the N expected load cases.
The placement is reported as
`gpu_delegate_initialized_per_load_execution_unobserved`: it is not
per-request execution proof, its delegate-kernel count is a consistency check
on top of the upstream compile rule, and its failure-marker list is not
exhaustive. `--native-log` for such a journal must name logcat `threadtime`
records; evidence counts only under the `native` and `litert` tags.

It does not observe CPU engines created elsewhere in the process, the
accelerator mask (inferred from the requested backend and the self-reported
LiteRT-LM tag), subgraphs LiteRT lets delegation skip, the closed ML Drift
delegate internals, or the identity of the shipped binary, and the embedding
and other side models run on the XNNPACK CPU delegate, not the GPU. The
predicate and its limits are in `doc/cross_platform_validation.md`.

## Multimodal embeddings

`embedding-gguf-cpu` (native desktop/Android/iOS) and `embedding-gguf-metal`
(macOS/iOS) lock EmbeddingGemma-2 BF16 plus its matching projector. They select
load plus ten embedding cases: capabilities, text/image/audio, image→audio and
audio→image across the mixed and batch cases, repeated/reordered batch items,
audio normalization, typed unsupported/marker
errors, cancellation before/after backend SPI dispatch and text/media reuse.
They produce no token-throughput samples.

```sh
dart run tool/testing/validation.dart local --profile embedding-gguf-cpu \
  --model /path/to/embeddinggemma-2-BF16.gguf \
  --projector /path/to/mmproj-embeddinggemma-2-BF16.gguf \
  --out .dart_tool/validation/runs/embedding-cpu
```

The [fixture README](assets/embeddings/README.md) records deterministic PNG/WAV
regeneration, upstream-only native CPU reference generation and measured
CPU/Metal kernel spread and negative controls. Separate CPU and Metal entries
both require cosine ≥ 0.999 and max-abs ≤ 0.01, allowing about 10x/6x headroom
over the measured errors while rejecting wrong pooling, missing normalization
and swapped media order. Wrong-projector cohort hashes fail before inference.
CPU one/four-thread vectors reproduced the reference exactly; Metal default and
concurrency-disabled audio had cosine 0.999900635/max-abs 0.001568219, while
fusion-disabled and both-disabled had 0.999906460/0.001644426.
The published archive and contained dylib hashes identify the reference runtime;
a hook-processed local dylib hash does not.

Metal placement requires one full positive tensor-offload record and one
`llama_context` per expected load, plus exactly two MTL0 projector contexts
(`gemma4v`, then `gemma4a`). Each complete llama graph reservation and each
projector reservation must contain exactly one positive MTL0 compute allocation;
CPU scratch allocations may accompany it. Every compute record must belong to
one of those reservations. Pooled embedding toggles can reserve the same llama
context repeatedly, so reservation count has no fixed ceiling; context count
stays exact. CPU-only, partial/zero/missing offload, wrong-device, zero-size,
unattributed or incomplete records remain unverified. Other profiles retain
their existing placement rule and effective-config hashes.

Both profiles lock `embedding.case_timeout_ms: 300000`, included in their
effective-config hashes. E05/E06 each encode one image, and E07 uses audio;
both mixed orders and the batch's repeated item remain checked. The 224×224
fixture encodes at 432×432; the logged 768×768 is projector warmup allocation.
CPU peak footprint is about 1.4 GB (max RSS about 1.9 GB); the projector is not
mmapped. Use ≥6 GB devices for Firebase runs.
Every case verifies all fixture hashes; a missing or changed reference errors
rather than skips. The journal binds `feature_id: embeddings`, case/fixture and
catalog hashes; report import rechecks successful numerical and contract
metrics and projector SHA256/size evidence. Existing catalogs are preserved.

The [runbook](../../doc/cross_platform_validation.md#multimodal-embedding-pack)
has the mobile/Firebase commands and qualification limits. Web and LiteRT-LM
pack coverage remains NOT_RUN until locked inputs and adapters are qualified;
the Web builder rejects these native profiles before downloading. Local JIT
runs cannot supply portable runtime evidence. This private pack changes no
public core API or release changelog.
