# Cross-platform validation runbook

The first implementation supplies the quick core, shared reports, portable
builds, and explicit Firebase/GCE orchestration. It uses the current checkout's
runtime pins. It does not replace the release matrix, qualify unrun platforms,
or schedule paid work. The broader [validation plan](cross_platform_validation_plan.md)
retains the later feature and device milestones.

## Source and generated artifacts

- `packages/llamadart_validation/`: private Dart suite, locked profiles, desktop
  runner/reporter, JSONL validation and JSON/JUnit/CSV/HTML rendering.
- `example/chat_app/lib/validation_main.dart`: interactive QA app. Run with
  `flutter run -t lib/validation_main.dart` from `example/chat_app`.
- `example/chat_app/integration_test/validation_test.dart`: unattended entrypoint;
  Android instrumentation and iOS XCTest invoke the same controller.
- `tool/testing/validation.dart`: build, local, report, plan, run, status, collect,
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

Prompts, regex expectations, exact output/thinking, ordered terminal case IDs,
configuration hashes, model hashes, source/runtime pins and environment all appear
in the journal. The raw tiny fixture does not claim chat capability.

Thinking, tool calls, stop-marker fixtures, batching, expanded unsupported guards,
multimodal/speech/embedding packs, NPU, and full browser/device rotation remain
subsequent qualification work. Selecting `release` today keeps those additional
obligations visible as NOT_RUN and cannot pass as a release qualification.

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
iOS execution and attachment retrieval still need a separately approved device
run. Web builds use the maintained bridge-staging script. Serve with isolation
headers, for example:

```sh
python3 tool/testing/serve_static_with_headers.py --directory .dart_tool/validation/bundles/web --port 7367
```

## Firebase setup, submission and collection

Use an explicitly selected **unbilled Spark project** and account. Preflight checks
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
The CLI uses explicit `--project` and `--account`, one 20-minute execution, no
flaky retries and no video. It records the matrix ID, polls terminal state, copies
the default Test Lab results, then verifies completion or cancellation. It does
not enable billing or create a custom result bucket.

Android pulls external app result files with complete console JSONL as fallback.
iOS attaches bounded result files to XCTest; collection exports `.xcresult`
attachments on macOS. Missing, truncated or conflicting evidence remains incomplete.
Physical device export/crash behavior is an explicit live-qualification step;
a build and fake-provider tests alone do not prove it.

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
GPU layers alone does not qualify execution. LiteRT GPU/NPU and browser accelerator
proof still require their own qualified evidence adapters; they remain incomplete.

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
