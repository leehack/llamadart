# Cross-platform validation runbook

The first implementation supplies the quick core, shared reports, portable
builds, and explicit Firebase/GCE orchestration. It uses the current checkout's
runtime pins. It does not replace the release matrix, qualify unrun platforms,
or schedule paid work. The broader [validation plan](cross_platform_validation_plan.md)
retains the later feature and device milestones.

Firebase is the primary physical Android/iOS qualification route. The personal
Pixel and iPad are optional debugging devices; the Mac remains the local build,
iOS signing and desktop/browser test host. The next milestone includes Firebase
NPU qualification on Galaxy S24 (Qualcomm SM8650) and Pixel 10 (Tensor G5).
The two SoC-specific model locks and offline input preflight are implemented.
The Android builder now embeds verified model/vendor inputs, and the installed
app checks its SoC before loading. Public-Dart and direct-native control paths
capture per-generation dispatch evidence. Neither path has run on an NPU device
yet; hardware qualification remains NOT_RUN.

## Source and generated artifacts

- `packages/llamadart_validation/`: private Dart suite, locked profiles, desktop
  runner/reporter, JSONL validation and JSON/JUnit/CSV/HTML rendering.
- `example/chat_app/lib/validation_main.dart`: interactive QA app. Run with
  `flutter run -t lib/validation_main.dart` from `example/chat_app`.
- `example/chat_app/integration_test/validation_test.dart`: unattended entrypoint;
  Android instrumentation and iOS XCTest invoke the same controller.
- `tool/testing/validation.dart`: build, local, report, npu-preflight, plan, run, status, collect,
  reconcile, cleanup. Provider helpers live beside it under `tool/testing/validation/`.
- `.github/workflows/validation_bundles.yml`: manual build-only workflow. No cloud
  credentials, model runs, VM creation or Firebase submission in CI.
- `.dart_tool/validation/`: ignored local models, bundles and journals. Do not
  commit weights, signing files, account configs, results or credentials.

Use Flutter **3.47.1**, its Dart executable, and Python 3.10+ (Windows: `python`,
other hosts: `python3`). Android uses the installed Android SDK/JDK; XCTest needs
Xcode, configured local signing and the owned Mac. gcloud is needed only for
provider operations. Normal chat-app behavior is unchanged.
The `local` command records source/runtime provenance automatically. Plain
`flutter run` is useful for diagnostics, but an app without the builder's identity
defines cannot qualify. Dirty builds retain all assertion results and metrics;
qualification requires a clean committed source and known runtime identities.

## Quick model profiles and cases

| Profiles | Locked fixture | Use |
| --- | --- | --- |
| `tiny-gguf-{cpu,metal,vulkan,cuda}` | stories15M, 98,357,920 bytes | Packaging, native loading, lifecycle; throughput is a tiny-model diagnostic |
| `chat-gguf-{cpu,metal,vulkan,cuda}` | Qwen3.5 0.8B Q4_0, 563,036,064 bytes | GGUF chat, history and instruction checks |
| `chat-litert-{cpu,gpu}` | Qwen3 0.6B LiteRT-LM, 614,236,160 bytes | Native LiteRT public path; explicit GPU proof remains incomplete |

Full revisions and SHA256 values live in profile JSON. The instruction GGUF is
[ggml-org's Q4_0 artifact](https://huggingface.co/ggml-org/Qwen3.5-0.8B-GGUF/blob/8fea620810c4afa23dd6443f999a48574c1611a3/Qwen3.5-0.8B-Q4_0.gguf),
so its results are a distinct cohort from the Q4_K_M candidate in the original plan.
Native LiteRT files cannot qualify LiteRT Web; that requires a Web model bundle.
The app reports this explicitly before downloading a native LiteRT fixture in Web.

The quick inventory is C01 load/diagnostics, C02 Unicode tokenize/detokenize,
C03 raw generation, C04 hello/arithmetic and C06 multi-turn history for chat
fixtures, C08 cancellation/control/recovery, C09 dispose/new engine/reload,
C10 one-token limit, C12 missing-model rejection/recovery, and B01 one warmup
plus three measured generations. Independent assertion failures do not suppress
later metrics; load failure or timeout prevents unsafe later inference.

Sampling is temperature 0, seed 1, top-k 40, top-p .9, repeat penalty 1.1,
context 1024, four threads, 32 generated tokens, thinking disabled, prompt reuse
disabled. Case overrides (one-token limit and 256-token cancellation) are recorded.
C08 compares the same prompt against an uncancelled control; the pinned WASM
delegate's explicit cancellation AbortError is also recorded as interruption evidence. Merely calling cancel
is not a pass; missing interruption evidence is NOT_RUN. Case timeouts are 60s;
disposal has a 10s bound and unresolved work cannot report successful cleanup.
Native Flutter model acquisition has a ten-minute deadline within the
18-minute integration test and 20-minute Test Lab execution limits. CLI downloads
retain their five-minute default. Download deadline failures report received and
expected bytes, remove partial weights and never become inference/TPS samples.

Prompts, regex expectations, exact output/thinking, ordered terminal case IDs,
configuration hashes, model hashes, source/runtime pins and environment all appear
in the journal. The raw tiny fixture does not claim chat capability.

Thinking, tool calls, stop-marker fixtures, batching, expanded unsupported guards,
multimodal/speech/embedding packs and full browser/device rotation remain
subsequent qualification work. NPU requires the verified Android packaging
described below; selecting `npu` alone cannot supply vendor libraries or evidence.
Selecting `release` today
keeps those additional obligations visible as NOT_RUN and cannot pass as a
release qualification.

## NPU input preparation

`npu-qualcomm-sm8650` and `npu-tensor-g5` are **unqualified candidate locks**
with opt-in Android build support. Each records Gemma 3 1B IT revision
`a6306a4e292016480083b73b8dc6f3f939ae04c3`, the SoC-specific file/hash/size,
context 1280, max output 32 and required library architectures. The Qualcomm
file is 690,094,080 bytes; Tensor G5 is 1,678,542,365 bytes. Model access is gated:
stage an authorized copy locally without embedding tokens or signed URLs in
the APK, kit manifest or report. The preflight never downloads a model.

```sh
dart run tool/testing/validation.dart npu-preflight \
  --profile npu-qualcomm-sm8650 \
  --model /path/to/Gemma3-1B-IT_q4_ekv1280_sm8650.litertlm \
  --kit /path/to/qualcomm-kit \
  --out .dart_tool/validation/npu-preflight.json
```

Omit `--model` or `--kit` to obtain the missing-input inventory. `--out` must be
a new file. The command writes hashes, sizes, SoC/runtime identities and checks;
it does not export supplied local paths. Exit 1 and `status: NOT_RUN` remain
intentional even when `inputs_verified: true`: file integrity is not native
execution or qualification. It creates no remote resources and uses no quota.

The kit contains flat regular library files and `npu-kit.json` with schema 1,
`target`, `runtime_tag`, `litert_revision`, `dispatch_header_sha256`, and a
`libraries` map from basename to `sha256`/`bytes`. Host libraries must be
AArch64 ELF64; the Qualcomm V75 skeleton is Hexagon ELF32. The lock includes
QAIRT 2.47.0.260601 host/DSP hashes, audited vendor dispatch hashes and the
matching diagnostic proxy hashes. Rebuilding a proxy requires reviewing and
updating its lock; a caller-supplied manifest cannot bless a different probe.
An older prebuilt, different SoC, tampered file, missing file or symlink fails
the input check. Dynamic dependency resolution still needs final-APK/device
verification; this inventory check does not execute or resolve a shared library.
The inspected S24 stub needs device `libcdsprpc.so`; its DSP skeleton needs
Hexagon `libc++.so.1` and `libc++abi.so.1`. Their availability and namespace access
inside the installed Firebase app remain unverified. Android host libraries
cannot substitute for DSP libraries with the same basename.

For runtime `0.17.0-3`, the actual LiteRT dependency is
`9fe5be45564c868408e6514c8aabb83e211a0911`. Its dispatch header adds `get_hooks`
to the nested interface relative to LiteRT v2.2.0 while retaining the same API
version. The version string alone cannot establish table-layout compatibility.
The native owner repository's diagnostic proxy is built against the exact
headers and accepts only the audited same-source vendor binaries. It preserves
vendor calls and exports lifetime counters for synchronous completions/failures,
async submissions/failures and synchronous calls in flight. Async submission is
not completion; positive counts establish some NPU work, never all-NPU placement.

The builder stages the model as an uncompressed APK asset and the verified kit
as extracted native libraries. The final APK checker streams every model/library
entry and rechecks sizes/hashes; remote upload repeats this check. The Android
host checks `Build.SOC_MODEL`, API and ABI before loading, checks installed library
hashes, copies the model to the app's private cache, and verifies its hash again.
It declares the required device library (`libcdsprpc.so` or
`libedgetpu_litert.so`) and configures the app-local DSP search directory. These
checks cannot prove that the Firebase sandbox grants access to its device driver.

Build separate bundles from clean committed source; each contains interactive
`qa-app.apk`, unattended `app.apk` and instrumentation `test.apk`:

```sh
dart run tool/testing/validation.dart build --target android \
  --profile npu-qualcomm-sm8650 \
  --kit /path/to/qualcomm-kit \
  --model /path/to/Gemma3-1B-IT_q4_ekv1280_sm8650.litertlm \
  --execution-path native_c_api \
  --out .dart_tool/validation/bundles/s24-npu-native
# Repeat with --execution-path public_api and a separate output directory.
```

These locally staged bundles contain authorized model weights and licensed vendor
libraries. Keep them private; the public CI bundle workflow does not accept NPU
kit/model inputs. No Hugging Face token, signed download URL or SDK credential is
packaged. Kit `license-*` files are retained in the APK.

The direct native control bypasses `LlamaEngine` and its backend/worker bindings,
calling the pinned C API on a dedicated isolate. It runs eight cases: load,
hello, arithmetic, reload, warmup and three throughput repetitions. It uses the
same Gemma artifact, dispatch kit, context 1280, four threads and per-request
output cap 32 as the public LiteRT service. The public NPU runtime skips session
sampler overrides, so both paths retain compiled model/runtime defaults. Requested
seed/temperature/top-k/top-p remain recorded, but effective NPU sampling is
explicitly unknown; these runs cannot claim seeded deterministic sampling.
Gemma keeps the native conversation default for thinking; the Qwen pilot's
explicit thinking-disable setting is not reused. The public NPU path runs the
14-case quick chat inventory, including Unicode tokenization, raw/history,
cancel/control/recovery, one-token limit and missing-model recovery.

Every generation records before/after probe counters. The reporter recomputes
deltas and rejects absent, reset, failed, in-flight or async-only proof. Positive
proof means **NPU participation; CPU partition coverage unknown**, never all-NPU.
Native controls are labelled separately and do not qualify the public Dart path.
Native decode TPS/token counts and native TTFT are separate from wall throughput;
the blocking native control cannot observe visible-answer TTFA, so that field
is null. Warmup is retained but excluded from the three-sample charts.

Use the normal Firebase `plan`/`run`/`collect`/`cleanup` flow below with the exact
S24 or Pixel 10 profile/device pairing. Run the native control first and stop if
it cannot initialize. Do not automatically submit both bundles or bypass the
selected Spark quota or Blaze budget guard. The compatible CPU Gemma semantic control, separate Unicode
generation fixture and aggregate paired-control qualification remain future
work; the existing Qwen CPU retry is not a matched Gemma control. A per-run green
report is not completion of the full NPU pack. The `validation-harness` row covers
the model-free identity/proof/input checks and APK tampering tests.

## Build and run

```sh
# Model-free safety and report regression tests.
dart run tool/testing/run_local_e2e.dart --scenario validation-harness

# Uses a shared verified model cache; creates a fresh output directory.
dart run tool/testing/validation.dart local --profile chat-litert-cpu

# Build on each native OS/architecture; weights are downloaded when running.
dart run tool/testing/validation.dart build --target desktop --profile tiny-gguf-cpu --out .dart_tool/validation/bundles/desktop
dart run tool/testing/validation.dart build --target android --profile tiny-gguf-vulkan --out .dart_tool/validation/bundles/android
dart run tool/testing/validation.dart build --target web --out .dart_tool/validation/bundles/web
dart run tool/testing/validation.dart build --target ios-inputs --out .dart_tool/validation/bundles/ios-inputs
# On the owned Mac with existing local Xcode signing configured:
dart run tool/testing/validation.dart build --target ios --profile tiny-gguf-cpu --out .dart_tool/validation/bundles/ios
```

Desktop bundles include `bin/llamadart-validate`, `bin/llamadart-report`, native
code assets, profiles and remote wrappers.
The hidden `.dart_tool/llamadart/litert_lm/` directory inside desktop bundles
contains the pinned LiteRT runtime, re-extracted from its SHA256-verified archive.
Preserve it when copying or extracting a bundle; the public runtime discovers it
relative to the executable. This avoids depending on the build machine's cache.
Windows arm64 bundles retain GGUF only; the manifest records LiteRT unavailable,
and an explicitly selected LiteRT build profile is rejected on that ABI.
Run outside the repository:

```sh
bin/llamadart-validate --profile tiny-gguf-cpu --environment-file environment.json --out results
bin/llamadart-report results
# Explicit GGUF accelerator evidence can be derived from that run's native log:
bin/llamadart-report results --native-log results/stderr.log
```

Windows executables have `.exe`. Keep the complete bundle layout. GitHub artifacts
contain `bundle.tar.gz` so executable permissions survive download; extract it
before use. Bundle manifests enumerate every shipped byte and record build OS/ABI,
SDKs, source commit/dirty state, native pins and the compiled mobile profile.
Resolved suite/app dependency locks are included as provenance too.
Remote dispatch rejects changed, dirty, wrong-OS or wrong-profile bundles.

Android produces `qa-app.apk` for interactive installation and a matched
`app.apk`/`test.apk` instrumentation pair. These are Debug builds, explicitly
labelled; do not compare their TPS to Release builds. Both native runtimes are
bundled, making APKs larger than a single-runtime deployment.

`ios-inputs` contains committed source, no signing credentials. `ios` invokes
`build-for-testing` and packages `tests.zip`; signing must already be configured. The unique existing project team is applied
to the test target too; use `--team TEAMID` when selecting another configured team.
Building the iOS bundle does not submit a test; use the explicit Firebase
`plan`/`run` steps below. Web builds use the maintained bridge-staging script. Serve with isolation
headers, for example:

```sh
python3 tool/testing/serve_static_with_headers.py --directory .dart_tool/validation/bundles/web --port 7367
```

## Firebase setup, submission and collection

The [device rotation and NPU cases](cross_platform_validation_plan.md#8-firebase-device-selection-and-free-rotation)
include S24, Tab P12, iPhone 16 Pro, iPhone SE 3, Pixel 10 and iPad 10. The planned
initial selection is 16 CPU/GPU core executions, six NPU reference/public-Dart/CPU
control executions and two targeted iPad GPU/lifecycle executions: **24 across
at least seven Spark quota days**, with at most four planned physical executions/day.
NPU submissions require the verified APK packaging and preflight first. iOS cases
cover CPU/Metal/LiteRT GPU; Apple NPU is not exposed by the current backend.
Native XCTest coverage does not qualify Safari/iPadOS browser execution.

By default, use an explicitly selected **unbilled Spark project** and account. Preflight checks
billing is disabled and the selected physical model/OS exists in the live catalog.
Pick one row per submission; never use an implicit device matrix. Check available
physical quota in Firebase before creating a receipt. Receipt evidence expires
after 15 minutes. The local journal permits at most four physical submissions in
a rolling 24 hours; other clients still share the provider's quota.

Copy `tool/testing/validation/firebase.example.json` to an ignored local path and
fill account, project, exact device/OS and a freshly checked quota receipt.

```sh
dart run tool/testing/validation.dart plan --target firebase-android --config .dart_tool/validation/firebase.json --bundle .dart_tool/validation/bundles/android --out .dart_tool/validation/plan.json
dart run tool/testing/validation.dart run --plan .dart_tool/validation/plan.json
```

Use `firebase-ios` with the signed `ios` bundle. Plan creation is local/read-only;
`run` rechecks identity, budget evidence and live provider state before submission.
The CLI uses explicit `--project` and `--account`, one execution capped at 20 minutes, no
flaky retries and no video. It records the matrix ID, polls terminal state, copies
the default Test Lab results, then verifies completion or cancellation. It does
not enable billing or create a custom result bucket.

### Explicit Blaze runs

Blaze is an opt-in mode for separately authorized runs. Copy
`tool/testing/validation/firebase_blaze.example.json` to an ignored local path.
The operator links billing separately; the runner never upgrades a project.
Preflight requires `billing_mode: "blaze"`, an enabled billing link to the exact
`billing_account`, and current physical execution quota. Spark plans still reject
billed projects. A quota receipt proves execution capacity, not free minutes.

Supply a fresh `budget` receipt with an authorization/pricing evidence reference,
fixed `window_start`, `expires_at` no more than 24 hours later, and positive
`maximum_run_usd` and `maximum_total_usd`. At least one hour must remain before
dispatch. Refresh `verified_at` within 15 minutes of each run, without moving
the authorized window or increasing its cap. All amounts are USD: record any
conservative conversion, tax and auxiliary-cost allowance in the evidence.
Do not copy a CAD credit balance into `available_usd`.

`funding: "credit"` also requires a fresh credit receipt that verifies Test Lab
eligibility, at least twice the entire batch budget available, and two hours
before credit expiry. A balance alone or a scope of "certain usage" does not
establish eligibility. `funding: "approved_charges"` is only for an explicit
user authorization covering out-of-pocket charges; it is not implied by having
a payment method or requesting a credit-funded upgrade.

For free execution on Blaze, select `funding: "free_allowance"` and supply a fresh
`free_allowance` receipt (`verified_at`, `evidence`, `remaining_physical_minutes`).
Verify the full project inventory, including other clients and pre-upgrade use;
round each physical test's **test-process duration** up to whole minutes. Queue,
installation and result-collection durations are not the billable test duration.
Subtract this usage from the published 30-minute daily physical allowance. Unknown
or active executions prevent relying on that calculation. The receipt must be
within the budget window. This mode needs no assumed credit eligibility or paid
authorization; gross USD reservations remain for traceability.

Set `test_timeout_minutes` to an integer from 1 to 20 (default 20). Verified free
minutes must cover that timeout plus a one-minute rounding reserve. The journal
also reserves minutes for submissions made after the receipt was checked, so
reusing a receipt cannot spend those minutes twice. Refresh the full project
inventory after each completed execution before reclaiming unused reserved time;
do not simply update its timestamp. These controls cannot exclude submissions
from another client after the check, so keep this dedicated project serialized.

The journal reserves the full per-run estimate before any submission, rounding
up to cents, and rejects runs exceeding the batch cap. Earlier Blaze submissions
for the same project within that window consume the cap even when failed or
cancelled; preflight failures do not. An uncertain submission still blocks all
new remote work until reconciled. Keep one shared run journal for the batch;
do not delete it or move the window to reset the allowance.

Each run remains one physical device, at most a 20-minute provider timeout and zero
flaky retries. The estimate must cover at least the full timeout at the current
[$5/device-hour rate](https://firebase.google.com/docs/test-lab/usage-quotas-pricing),
before deducting any free minutes or credits. For example, a $2/run reservation
and $6 batch cap permit three runs. Check current prices and add other costs
where applicable. This is a local submission guard, not a Cloud Billing hard
cap: it cannot control other clients, determine promotional eligibility, or
reconcile the provider invoice. Actual usage, applied credits and charged cost
remain separate evidence. Budget alerts also do not cap charges.

The gcloud asynchronous response contains a console URL, not a matrix object.
The adapter reads the matrix creation receipt and verifies its project and unique
run label through the Testing API before using it. If submission is interrupted,
recover the existing matrix with `reconcile`; never repeat `run` to find out
whether a submission succeeded. An unverified candidate ID is diagnostic only.

Android pulls external app result files. The first live S24 run recovered a
complete journal through this path, but its collected console log contained no
validation JSONL; console-only recovery is not yet qualified on Flutter devices.
iOS attaches bounded result files to XCTest; collection exports `.xcresult`
attachments on macOS. Missing, truncated or conflicting evidence remains incomplete.
Physical device export/crash behavior is an explicit live-qualification step;
a build and fake-provider tests alone do not prove it.

A model-preparation error can occur before the suite manifest exists. The current
collector retains those raw device files under `remote-results`, but cannot
produce a validated suite report from them. Record preparation as ERROR and
inference as NOT_RUN, with TPS unavailable. Zero cases and successful artifact
collection are not a passing run; a structured preparation-error envelope remains
a follow-up. Do not insert requested bundle metadata as observed runtime evidence.

## GCE setup and teardown

Run the GCE controller from the owned Mac or Linux. Windows is supported as the
CUDA test guest; Windows-hosted GCE orchestration is not yet qualified.

Copy `tool/testing/validation/gce.example.json` to an ignored path. Configure an
immutable **GPU-ready image**, exact expected driver, compatible machine/accelerator,
zone, an existing network and a targeted IAP TCP/22 firewall tag. Linux needs
Python, `timeout` and `sha256sum`; Windows needs Google-supported SSH and PowerShell.
This initial adapter consumes an already qualified image; it does not install GPU
drivers or change project networking. Check quotas and image/machine compatibility
before the first approved run. Instance readiness rechecks the actual driver.

The GCE profile must explicitly select GGUF CUDA and the uploaded desktop bundle
must be built for the destination x64 OS. Each run requires fresh evidence that
promotional credit applies to **all** expected costs, has at least twice the
estimated run cost available, and expires at least two hours after dispatch.
The receipt is an operator-verified billing-console record, not an automatic
credit API lookup. A budget alert is not a guarantee against charges.

```sh
dart run tool/testing/validation.dart plan --target gce-linux-cuda --profile tiny-gguf-cuda --config .dart_tool/validation/gce.json --bundle .dart_tool/validation/bundles/linux --out .dart_tool/validation/plan.json
dart run tool/testing/validation.dart run --plan .dart_tool/validation/plan.json
```

Use `gce-windows-cuda` with a Windows x64 bundle and Windows-ready image. The
adapter records intent before creating one VM, requires provider-confirmed deletion
after 60 minutes, persists instance/disk IDs before setup, verifies the driver,
uploads/checks the bundle over IAP, runs under a 20-minute watchdog, collects
results, deletes the owned VM/boot disk, and reads the inventories back.
It creates no reusable volumes, static IPs or service accounts. An ephemeral
public IP provides outbound model download access and belongs in the cost estimate.

Deletion is the default cleanup. **Stopped VMs can retain charged disks**; stopping
also clears the runtime deadline. Provider deletion deadlines and local finally
cleanup are complementary, not a zero-cost guarantee. If identity is uncertain,
cleanup refuses to delete a potentially unrelated resource, records UNKNOWN and
blocks another run. No cloud run is permitted under the $0-out-of-pocket policy
when applicable credit cannot be verified.

## Recovery and evidence

```sh
dart run tool/testing/validation.dart status --run-id qa-EXACT-ID
dart run tool/testing/validation.dart collect --run-id qa-EXACT-ID
dart run tool/testing/validation.dart cleanup --run-id qa-EXACT-ID
# Only after finding the exact ID in the provider console:
dart run tool/testing/validation.dart reconcile --run-id qa-EXACT-ID --remote-id EXACT-PROVIDER-ID
```

Use the ID printed in the saved plan (the placeholder above is not a valid ID).
OS locks serialize provider operations and release if the controlling process dies.
SIGINT requests cancellation; cleanup still runs after the current bounded provider
operation. Reusing a run ID cannot submit twice. A missing creation/submission
response is UNKNOWN, never permission to retry. If no remote ID was received,
inspect the provider console using the exact project/run label, preserve the
journal, and use `reconcile` before recovery; do not delete the journal to bypass
the blocker. Reconciliation checks the Firebase project/matrix/run label, or the
GCE numeric instance ID, zone, label and owned automatic boot disk. It cannot
replace an established identity and does not erase the original failure. Then
run `status`, `collect` and `cleanup`. Recovery commands never submit a replacement.

`orchestration.json` stores phase, exact IDs, provider state and collection state;
`cleanup.json` stores verified/unknown cleanup. `remote-summary.json` is the
combined verdict: provider success **and** validated Dart assertions/provenance
**and** complete retrieval **and** verified cleanup. Test-only report success
cannot override provider failure or unresolved infrastructure.

Each run exports `events.jsonl`, `manifest.json`, `results.json`, `junit.xml`,
`samples.csv`, and `summary.html`. HTML has case status/output, native decode TPS,
estimated visible-output TPS, TTFA, and median/min/max for three measured samples.
Warmup is retained but excluded from these comparisons. Missing counters are null;
chunks are never called tokens. Backend-native decode timing and retokenized
wall-time estimates stay in separate series. Three samples are informational,
not a performance regression gate or a cross-device ranking.

Explicit CPU rows reject contradictory GPU diagnostics. GGUF accelerator reports
require matching backend diagnostics plus positive native tensor offload and
compute allocations for all three successful loads. Device presence or requested
GPU layers alone does not qualify execution. LiteRT NPU uses the checked per-generation dispatch adapter described above.
LiteRT GPU and browser accelerator proof still require qualified evidence
adapters; they remain incomplete.

Normal model runs are opt-in. Model-free suite/provider tests run in CI. Before
claiming another platform qualified, attach the exact commit, model/backend,
command, provider/device identity, combined verdict, cleanup and native evidence.

## Initial owned-machine observations (2026-09-17)

The portable macOS arm64 bundle ran outside the repository. Tiny GGUF CPU/Metal
completed inference/lifecycle/TPS, while native Unicode corruption remains tracked
in [#511](https://github.com/leehack/llamadart/issues/511). The tiny model's expected
SentencePiece leading space is an explicit fixture normalization; corrupted
Unicode is still a failure. A Web/WASM UI run preserved Unicode and proved
cancellation through the pinned delegate's explicit AbortError and successful
recovery. The CPU identity check recognizes the pinned WASM name only with zero
GPU layers and its CPU core metadata.
Web native-token counters were unavailable, so C10 stayed NOT_RUN.

Qwen3.5 GGUF also exposed native Unicode corruption and returned `Cedar17` for the
case-sensitive `cedar17` history oracle. LiteRT CPU ran 13/14 cases successfully
but answered `2` for `2 + 2`; retain the semantic failure and relate it to
[#509](https://github.com/leehack/llamadart/issues/509), without inferring the same
cause before a native reference comparison. These runs are diagnostics, not
release qualification or stable performance baselines.

## Maintained Firebase CPU pilot (2026-09-17)

Four physical executions used the unbilled Spark project. All reached terminal
provider states, artifacts were collected, and completion was verified. No GCE
VM was created. Android file pulls and iOS XCTest attachment export both recovered
complete quick-core journals when model preparation succeeded.

| Device / profile | Outcome | Median native decode TPS |
| --- | --- | ---: |
| Galaxy S24 / tiny GGUF CPU | 10 PASS, 1 FAIL: C02 Unicode corruption | 538.5 |
| iPhone 16 Pro / tiny GGUF CPU | 10 PASS, 1 FAIL: C02 Unicode corruption | 708.3 |
| Galaxy S24 / Qwen3 LiteRT CPU | Preparation ERROR; inference NOT_RUN | Unavailable |
| iPhone 16 Pro / Qwen3 LiteRT CPU | 13 PASS, 1 FAIL: C04 arithmetic returned `2` | 8.9 |

GGUF used native `v0.4.0`; LiteRT used `0.17.0-3`. Unicode matches
[#511](https://github.com/leehack/llamadart/issues/511); the arithmetic observation
matches [#509](https://github.com/leehack/llamadart/issues/509) and does not by
itself establish a Dart-layer defect. The three benchmark samples after warmup
remain available despite those independent assertion failures. Android is Debug
and iOS is Release; the tiny GGUF model is a packaging fixture, so these numbers
are not a device ranking or a comparison of backend performance.

The Android LiteRT attempt ended after 302 seconds during model download, before
any suite manifest or inference. Its old diagnostic recorded a closed connection
without partial byte progress. The corrected mobile host now has a ten-minute
download deadline and reports byte counts on timeout. The final iOS bundle used
that host, downloaded and verified the 614 MB fixture in about 65 seconds, then
ran the suite. This does not prove Android download recovery: the corrected APK
was built locally but no fifth execution was submitted. Retain the failed attempt
and use a fresh quota receipt for an explicitly selected later retry.

The remaining mobile milestones are reliable preparation-error envelopes,
Android LiteRT inference with the corrected host, and the planned GPU/NPU
packaging and execution-evidence adapters. These CPU observations do not qualify
those accelerator paths or a release.
