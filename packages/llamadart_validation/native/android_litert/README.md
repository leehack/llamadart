# S24 LiteRT native/public qualifier

This private, prospective harness targets one `SC-51E`, API 36, SM8650 run. It
changes no production selector, owner guard, runtime pin or public API. Source
and model-free checks authorize no APK build or device/cloud execution.

The corrected CPU profile is unchanged `chat-litert-cpu`: Qwen3 SHA-256
`c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108`,
613,722,264 bytes, revision `e6687177`. The separate GPU profile retains
`555579ff2f4fd13379abe69c1c3ab5200f7338bc92471557f1d6614a6e5ab0b4`,
614,236,160 bytes, revision `8414150f`. Their URLs, metadata, prompts and
oracles cannot be interchanged.

Both use the maintained C04 fixtures: “Reply with one short sentence saying
hello.” with `\bhello\b`, and “What is 3 + 4? Reply with only the number.” with
`^(?:3 \+ 4 = )?7[.!]?$`. Controls retain context 1024, four threads, temperature
0, effective top-k 1, top-p .9, seed 1, output 32 and thinking off. The native
control uses the exact exported Qwen template; the public route keeps its
normal bundle/template selection. Speculation is off; the legacy default
repetition penalty remains unapplied, matching the default service.

## Fixed case graph

| Stage | Maximum seconds | Required result and dependent behavior |
| --- | ---: | --- |
| Staging and identity | 120 | Exact device, two model hashes, complete installed native inventory, final owner archive and compiled source/binding match. |
| Native launch and legacy GPU guard | 120 | Installed PIE launch probe loads no runtime/model. Separate native child requests GPU for `555…` and must refuse before generation. Guard failure stops dependent public GPU work. |
| Public legacy explicit GPU | 60 | Default service must expose the same native restriction as `LlamaUnsupportedException`; no backend override. |
| Native corrected CPU | 120 | Owned child runs both fixed C04 requests; raw native JSON, positive counters, mapped core and both semantic oracles must pass. |
| Public corrected CPU | 150 | Default service, two complete engine lifetimes, both C04 oracles each lifetime, cancellation and reload. |
| Public legacy auto | 150 | Real GPU failure warning, CPU selection, positive counters, process-wide CPU initialization plus fresh per-lifetime compilation, UTF-8 transport, cancellation and reload. Every legacy semantic result is recorded separately; transport success never qualifies legacy accuracy. |
| Native corrected GPU | 120 | Runs only after the native corrected CPU control passes. Owned child attempts the same two C04 requests once; exact raw JSON, positive counters, both semantic oracles and correlated Adreno/Vulkan delegate initialization must pass. Failure/crash/timeout/malformed evidence is FAIL. |
| Public corrected auto | 150 | Runs only after the corrected native GPU control passes. Same corrected C04/cancel/reload obligations; observes the actual selected route and correlated native initialization. A CPU result needs a real GPU-failure warning; a GPU result needs initialization evidence. Neither is forced in advance. |
| Cleanup and export | 60 | Persist final statuses, failed cases, legacy semantic failures and every unexecuted required case. |

Caps sum to 1,050 seconds. A Java watchdog independent of Dart enforces stage
bounds and a 19-minute app-process ceiling; Test Lab remains capped at 20
minutes, one execution, no retry. Native children also have an independent
115-second alarm and the shared owned-process helper's 120-second deadline,
2 MiB stdout and 8 MiB stderr limits. They cannot hang or crash a public engine
in the same process. Missing or exceeded captures fail; changing prompts or
models after a failed control is not part of this graph.

The owner guard presently recognizes only `555…`. The corrected model's GPU
attempt is therefore isolated in the owned native child. A failed corrected
GPU control leaves public corrected auto NOT_RUN, requires diagnosis/safe
restriction before qualification, and never authorizes an unguarded public
attempt. This harness does not extend the production guard.

## Evidence boundaries

The public route is the same uninjected default `LiteRtLmService` boundary as
the accepted macOS public qualifier. It has no explicit library path, runtime
factory, speech driver or backend override. Its default discovery probe and
each lifetime check exact mapped payload bytes. C API 1.0 plus frozen default
source and the mapped-library binding establish the selected route; no runtime
selection counter is exposed or claimed measured.

Public chunks are exact default-service UTF-8 bytes. Finish is always labelled
`not_exposed_by_default_service`; settlement and positive token counters remain
separate observations. XNNPACK's delegate-created message is process-wide:
its first captured bytes/hash are retained once, while every lifetime needs a
new empty-at-load capture containing fresh native model compilation plus CPU
selection/layers zero. Reusing an earlier lifetime's compilation capture fails.
The retained prior S24 captures had 42/66 cumulative lines across two CPU
lifetimes but only one delegate-created line; no repeat initialization is invented. Native raw JSON comes only from the separate C API
control and is never attributed to the public route. Synchronous native finish
is likewise labelled unexposed. GPU delegate initialization is not per-request
accelerator execution proof, general GPU support or a throughput measurement.

The journal copies bytes with their size, SHA-256 and base64 before parsing or
grading. Child capture first validates owned PID, exit, deadline, byte limits
and file hashes, then its own strict S24 protocol. The shared helper's GGUF
`protocol_complete` field is not S24 acceptance. Invalid UTF-8 remains preserved
in raw capture and fails wire parsing. Mapped libraries must have the admitted
installed paths and hashes. Earlier failed/transport-only JNI runs are unchanged
and receive no public-path or corrected-model credit.

## Source and APK admission still required

Freeze clean source and independent review before preparing an APK. The final
binding must contain exact source commit/tree/inventory, the final rebuilt
0.19 owner commit, runtime archive and manifest hashes, complete owner archive
libraries, complete installed APK libraries, child executable and canonical
Qwen template hashes, both unchanged profiles, run id and the existing shared
budget receipt hash. Owner `7ea10d0` is explicitly rejected as the aborted
candidate. No final owner payload is selected by these source files.

Future native preparation compiles `main.cpp` as an Android arm64 PIE executable
with NDK 28.2.13676358, links `-ldl`, and packages it as
`libllamadart_litert_child.so` in the installed native directory. Preserve an
executable ELF interpreter and verify the final APK's complete native inventory;
a host build is not Android launch proof. The root owns the model-free installed
PIE launch check on the API 34 arm64 emulator before paid-device admission.

The separate instrumentation target is exactly
`com.example.llamadart_chat_example.S24LiteRtPublicTest`. The frozen submission
must select only that class. It requires explicit
`qualificationMode=s24-litert-public-v1` and `qualificationBindingSha256`, and
copies only the fixed staged Test Lab inputs:

- `/data/local/tmp/s24-litert-public-binding.json`
- `/data/local/tmp/s24-litert-public-cpu.litertlm`
- `/data/local/tmp/s24-litert-public-gpu.litertlm`
- `/data/local/tmp/s24-litert-public-template.jinja`

There is no HTTP fallback. Stale directories/configuration fail. Build the Dart
entrypoint `integration_test/litert_lm_s24_public_qualification_test.dart` with
`S24_LITERT_SOURCE_COMMIT`, `S24_LITERT_SOURCE_INVENTORY_SHA256` and
`S24_LITERT_BINDING_SHA256` from the admitted binding. Bind the produced APK/test
APK and compiled target/defines in a separate build receipt, then independently
verify them; no self-declared binding substitutes for that review. Pull the app's
external-files run directory and require its journal/hash/captures, not just a
provider SUCCESS result.

Use the maintained shared budget/admission procedure in
[the validation runbook](../../../../doc/cross_platform_validation.md#firebase-setup-submission-and-collection).
This lane keeps the existing third reservation at **USD 2.50**, the unchanged
**USD 22.50** shared cap and a single 20-minute execution. Its binding is not a
new reservation or dispatch permission. Fresh source/APK/device/budget admission
and an exact class-targeted command are still required; these files contain no
cloud submission command.

## Model-free source checks

From `packages/llamadart_validation`, using the pinned SDK:

```sh
dart analyze
TMPDIR="$(mktemp -d)" dart test -p vm test/android_litert_qualification_test.dart
python3 -m unittest discover -s native/android_litert -p 'test_*.py'
```

The C++ host fixture executes the actual child against a synthetic C API and
checks exact settings/prompts, raw response copying, counters, refusal, missing
JSON and wrong ABI. It loads no model and establishes no device result.
