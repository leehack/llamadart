# Prospective Pixel Qwen3.5 restriction check

`integration_test/pixel_qwen35_guard_test.dart` in the chat app is a separate
private entrypoint for `core018-pixel-supported-cases-20261104`: Pixel 9 Pro
(`caiman`), API35, Mali-G715, native `v0.8.0-2`. It never sets `qualified=true`.
Freeze clean source and obtain fresh independent review before APK preparation;
root owns exact artifact/APK/operator/budget admission and the eventual run.
The ceiling is one execution, USD2.50, 20 minutes and zero retries. This source
does not reserve budget, authorize dispatch or qualify any GPU.

The original [#948](https://github.com/leehack/llamadart/issues/948) describes
Qwen3.5-0.8B Q4_0 on caiman/Android15, a 59-token C06 history prompt repeating
`8`, and a 276-token grammar/tool abort. Its body names source `41be54c60` and
native `v0.5.0-2`, the raw `v0.5.0` runtime and published core `v0.10.0` controls.
The body and all three comments inspected during preparation contain no raw
run/operator links. They are historical assertions, not reconstructed raw
provenance. The later case-sensitive CPU reference in
`doc/cross_platform_validation.md` returns `Cedar17` for `cedar17`; that remains
FAIL. The issue body's older CPU-success wording is not evidence that this
later CPU reference passed. No historical record is regraded by this pack.

Use the unchanged `chat-gguf-{cpu,vulkan}` profiles: Qwen3.5-0.8B Q4_0,
revision `8fea620810c4afa23dd6443f999a48574c1611a3`, 563036064 bytes,
SHA256 `57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf`.
Both profiles' raw asset hashes are bound. Original C06 uses the unchanged four
messages, context1024, four decode/batch threads, maxTokens32, temp0, seed1,
topK40/topP0.9/minP0, repetition penalty1.1, presence penalty0, thinking off and
prefix reuse off. `trim() == 'cedar17'` is the original case-sensitive oracle.
No lowercase, punctuation normalization or multi-secret replacement is allowed.
The final renderer/runtime differs intentionally from the historical source;
messages, settings, actual usage counts and full output are retained. Missing
historical prompt bytes/token IDs are not invented from the stated 59-token
count. This is a prospective exact-current-C06 check, not an authenticated
historical byte replay.

The public backend is `LlamaEngine(LlamaBackend())`, with no service factory,
worker entrypoint, library override, custom projector or model substitution.
Vulkan cells explicitly request GPU plus Vulkan and require positive layers;
Ordinary CPU cells explicitly request CPU plus CPU/zero layers; the separate
zero-layer control keeps its Vulkan/GPU preference while requesting zero layers. The example hook family
is `llama_cpp` only for this isolated build, retaining normal native hook
selection and the final pin while excluding unrelated runtime bundles.

Order: CPU/unset runs the existing C04.arithmetic fixture first: unchanged
`What is 2 + 2? Reply with only the number.`, strict `^4[.!]?$` on trimmed
content, with the original profile sampler/limits above. A wrong/empty answer,
thinking, unordered/incomplete stream, missing positive native counts or a
non-stop finish fails the reference. Dependent C04 rows become NOT_RUN; no
prompt, oracle, weights or settings may be tuned after observing a failure.
Strict original CPU/unset and Vulkan/unset C06 remain separate diagnostics,
including the known CPU Cedar17 failure.

Vulkan/unset and each fresh explicit size1..8 lifetime run the identical
single-user public C04 chat request. Each must independently pass semantics
and exactly match the CPU reference's raw visible UTF-8 bytes, public rendered
prompt bytes and IDs, visible-output retokenization IDs, native usage counts
and finish reason. The public rendered input must exceed8 tokens. Output
retokenization uses addSpecial=false; rendered input uses addSpecial=true.
These are public-output/count/finish comparisons, NEVER sampled native token
IDs, EOG or hidden stop-token parity. Timing fields are not token counts.
Observed native n_ubatch values are retained where emitted; requested sizes
alone do not establish geometry or GPU execution.

Vulkan/unset retains the unchanged loaded capability, media, speculation and
embedding refusal matrix, then repeats C04 with prefix reuse disabled and the
same CPU parity oracle for post-refusal recovery. Explicit sizes9/32/33/64/512
retain typed load-refusal/no-native-context controls. CPU size32 and the
separate Vulkan-preference/gpuLayers0/size32 lifetime run the same C04 parity
control and require actual CPU/zero layers; neither receives GPU credit or
claims CPU media/speculation support. Every lifetime awaits disposal. This
is representative >8 coverage, not exhaustive integer or model qualification.

The default Vulkan cell must observe the production eight-token cap decision
from actual unsafe/unproven facts. No seam injects architecture, placement or
subgroup facts. A safe subgroup, missing cap evidence, CPU fallback or software
renderer cannot satisfy the restricted route. Every admitted Vulkan lifetime
requires its own fresh native stderr with positive tensor offload, Mali-G715
device selection and positive matching Vulkan compute allocation. This is
actual model/context placement evidence; it does not trace each shader or
prove that every operation executes exclusively on the GPU.

Image/audio and native-generation refusals require typed `Android/Vulkan`/#948
diagnostics. Video is already unavailable through the public API; external
draft and content embeddings can refuse through loaded capability admission.
Those typed results are labelled separately and do not by themselves prove
the service's pre-evaluation barrier. The unchanged production recording suite
and its independent audit provide that causal boundary evidence. Loaded
vision/audio/embedding modalities must be false and speculative strategies
empty before these probes start. A CPU size32 text lifetime establishes the
CPU route is outside the batch restriction; it does not claim CPU media or
speculative-model support.

Java's explicit `qwen35GuardMode` branch in `MainActivityTest` verifies
caiman/API35 and `stageModel=true`, copies the bound asset into a fresh output
directory, captures Build/SoC/fingerprint, CPUinfo/getprop/Vulkan properties
and installed APK SHA, and starts an independent watchdog. It preserves all
existing scenario guards and their 20-minute watchdog limit. This lane has a
19-minute app ceiling, 30/60/90/120-second operation deadlines, 8MiB per native
stderr and journal limits; Dart starts no new operation after18 minutes.
Cleanup is still armed. Timeout/process death/unfinished work leaves the run
incomplete; a Dart timeout is never used to cancel live native work. There is
no C signal handler, native helper, native source/binary patch or diagnostic
replacement for the public route.

Stage a preverified model at `/data/local/tmp/llamadart-smoke.gguf`; there is no
HTTP fallback. Existing Java staging copies it to app cache, and Dart hashes
it again before load. The stage's only asset is
`assets/pixel_qwen35_guard/binding.json`; it adds no native libraries. Bind
clean commit/tree/tracked inventory, hook/selector hashes, exact runtime archive
and selected libraries, complete installed native inventory, both profile
hashes and the actual root-owned budget receipt. The runtime archive must be
the maintained final `v0.8.0-2` archive SHA256
`a40669ffb3ab20a62028fbe65c0d217e5a36f71e4beef36447a6a630d5953a76`.
Compile its binding SHA in `PIXEL_QWEN35_GUARD_BINDING_SHA256` and require the
same instrumentation `qwen35GuardBindingSha256`. Bootstrap inventories remain
provisional until the final APK's actual entries exactly match the binding.
Independent source/APK/provenance review is mandatory; a self-declared hash is
not artifact authentication.

Collect the exact external-files run directory, raw instrumentation and
attributable full logcat/crash logs even when the test fails. The JSONL retains
source/model/runtime binding, complete required-case inventory, each result,
raw output, counters, capability/device-fact records, actual maps with hashes,
per-lifetime raw native log files/hashes and disposal observations. The complete
marker separates restriction failures from correctness failures. A CPU
`Cedar17` or GPU repeated-8 answer remains FAIL even if every restriction passes;
the final Flutter assertion still fails. Missing required cases/placement,
watchdog death or absent terminal remain incomplete. Neither instrumentation
success nor successful typed refusals closes #948, lifts the cap, reproduces
the old C07 abort, proves general Mali support or authorizes publication.

New source/APK bindings use schema `pixel-qwen35-supported-cases.v2`; the old
344f1cb source, APKs, admission and historical C06 records remain immutable.
Required-case accounting separately retains NOT_RUN dependent rows, completed
FAIL rows and missing rows. A passing bounded C04 range cannot erase C06 FAIL,
close #948 or make strict overall correctness true. Model-free unit checks
cover semantic failure gating, byte/ID/count/finish/config/input mismatches,
missing geometry/stream evidence and required recovery/control completeness.
