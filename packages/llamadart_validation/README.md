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
does not establish a tokenizer defect. Case deadlines remain 60s unless a LiteRT
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
