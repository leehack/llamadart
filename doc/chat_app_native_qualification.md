# Firebase Test Lab native qualification

Run Flutter and Android build commands from `example/chat_app`. Run the
`dart run tool/testing/...` commands from the repository root.

The Android instrumentation runner can execute `integration_test/smoke_test.dart`
on Firebase physical devices. Build the app with `flutter build apk --debug
--target integration_test/smoke_test.dart`, then build the test APK from `android/`
with `./gradlew app:assembleAndroidTest -Ptarget=../integration_test/smoke_test.dart`.
Submit the app and test APKs as an instrumentation test with an explicit device,
Android version, project, and timeout.

Use `--dart-define=LLAMADART_GGUF_MODEL_URL=<immutable-model-url>` and
`--dart-define=LLAMADART_GGUF_SHA256=<sha256>` to bind the model artifact.
`LLAMADART_GGUF_BACKEND` accepts `auto`, `cpu`, `metal`, or `vulkan`.
Set `LLAMADART_GGUF_SEMANTIC=true` for an instruction-tuned model to check math,
capital-city answers, cancellation, and reuse. Explicit GPU runs assert the
selected backend and positive GPU layer count. The default tiny-model test checks
loading and basic output only; it does not establish semantic or GPU qualification.
Preserve the Firebase matrix ID, test XML, device logs, model checksum, and actual
backend diagnostics with the PR's platform evidence.

For large models, the test runner supports pre-staging without granting production
storage permissions. Build the smoke APK with
`LLAMADART_GGUF_MODEL=/data/user/0/com.example.llamadart_chat_example/cache/firebase-model.gguf`
and the expected `LLAMADART_GGUF_SHA256`. Build the instrumentation APK from the
same checkout. Pass these additional options to `gcloud firebase test android run`:

```sh
--environment-variables=stageModel=true \
--other-files=/data/local/tmp/llamadart-smoke.gguf=gs://YOUR_BUCKET/model.gguf
```

The opt-in runner copies the shell-staged file into the target app's private cache
before launching Flutter. The Dart test still verifies the model checksum before
inference. Do not stage directly into `/sdcard/Android/data`: scoped storage can
prevent the app from reading files installed there by Test Lab. A staging or
checksum failure is a harness failure, not evidence that a runtime backend passed
or failed inference.

The runner stages the file as `firebase-model.gguf` unless
`--environment-variables=stageModel=true,stageModelName=<file-name>` names it.
Pass the model's real file name for a `.litertlm` bundle: the engine rejects a
`.litertlm` file declared as `.gguf`, and the LiteRT-LM tests read the model
family from the name. The name must match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`,
and the app's `LLAMADART_*_MODEL` path must end in the same name.

The staged file lives in the app cache, which Android purges when it exceeds
the app's cache quota (64 MiB on the emulator; `installd` logged the purge of
a 586 MiB staged model). A purged model fails the run before inference, so
treat it as a harness failure and restage.

To check that an accelerator is correctly refused, build
`integration_test/litert_lm_json_schema_e2e_test.dart` with
`--dart-define=LITERT_LM_EXPECT_UNQUALIFIED=true` and the accelerator in
`LITERT_LM_BACKEND`. The run passes only on the typed gate refusal and fails
with "The backend was admitted" if the backend is admitted.

## LiteRT-LM reload memory

`integration_test/litert_lm_reload_memory_e2e_test.dart` creates a LiteRT-LM
engine, generates, deletes it and repeats, recording process memory after every
step. It fails when the memory left after a delete keeps growing across reloads,
measured from the second of at least three iterations. Generation is checked
only for non-empty output; read the journal to judge the text.

Run it on a connected device or the macOS host (off Android the counter is
process RSS, which is not a graphics-memory counter):

```sh
dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-litert-reload-memory --device <device>
```

It downloads and hash-checks the locked `chat-litert-*` validation model
itself; `--model-path` names a copy that already exists on the target device.

For Test Lab, build both APKs from that target as above, then add:

```sh
--environment-variables=litertReloadVariants=cpu+gpu,litertReloadIterations=4,memorySnapshots=true \
--directories-to-pull=/sdcard/Android/data/com.example.llamadart_chat_example/files/litert_reload_memory
```

Variants run in order in one process: `cpu` or `gpu`, optionally suffixed
`-create-only`, `-reuse` or `-settle`. With `memorySnapshots=true` the runner
answers each step with `dumpsys meminfo` and `dumpsys gpu --gpumem`, the only
counters here that include driver-owned graphics memory per process; without it
the test falls back to device-wide `MemTotal - MemAvailable`. A variant whose
counter changes during the run, because `dumpsys` stopped answering, fails
instead of comparing unlike readings. The pulled
directory holds `journal.jsonl`, the raw `dumpsys` text of every step,
`vkjson.json` (`cmd gpu vkjson`, the Vulkan driver's limits) and
`app_apk.sha256` (the installed app APK), written as the run goes so they
survive a low-memory kill. The same records appear in logcat as
`LITERT_RELOAD_MEMORY` lines.

When the low-memory killer or a native crash ends the app, Test Lab reports
`Test failed to run` and no test case. It still pulls the directory, journal
included: the last `step_started` record without a matching `step` names the
step that was running.

On the Android emulator the `gpu` variants measure gfxstream, which keeps
memory and descriptors after a delete, so the check can fail there and says
nothing about a device.

Each `generate` step records the first 400 characters of the output, its length
and three signals of a broken decode (`printable_ascii`,
`replacement_characters`, `distinct_words` of `words`). To compare backends or
runtimes on one prompt, run `cpu` first as the reference and fix the request:
`litertReloadPrompts` (`|`-separated; the profile prompt by default),
`litertReloadChat=true` (chat template with thinking off instead of raw text),
`litertReloadTemperature` and `litertReloadSeed` (the profile samples greedily:
temperature 0, seed 1). The matching build-time defaults are
`--dart-define=LITERT_RELOAD_PROMPTS`, `LITERT_RELOAD_CHAT`,
`LITERT_RELOAD_TEMPERATURE` and `LITERT_RELOAD_SEED`. An argument passed as an
empty string keeps its default. Fewer than three iterations record the steps
without the memory check.

## LiteRT-LM bundle in a read-only directory

`integration_test/litert_lm_read_only_bundle_e2e_test.dart` hard-links the
locked `chat-litert-*` validation model into directories it sets to mode 555
and loads it through `LlamaEngine(LlamaBackend())` with
`LiteRtLmModelParams.cacheDir` unset, as an app that ships a model in its
bundle does. Four cases run in one process, in this order:

| Case | Bundle name | Backend |
| --- | --- | --- |
| `unsuffixed` | `Qwen3-0.6B` | `cpu`, then `gpu` |
| `litertlm` | `Qwen3-0.6B.litertlm` | `gpu`, then `cpu` |

Every case must generate
([#975](https://github.com/leehack/llamadart/pull/975),
[#976](https://github.com/leehack/llamadart/issues/976)). A case fails when the
directory is writable, when its mode or its entries change, on an empty reply
and on any error.
The run also fails when the entries beside the original model file change.
Each case logs a `started` line, a `dir` line with the directory as observed
before the load, its result with the reply or the error type and message on
the line before, and a `dir` line after the load. Two `origin` lines after the
last case list the original file's directory before the first case and after
the last:

```text
E2E read-only bundle: dir case=<id> backend=<cpu|gpu> when=<before|after> writable=<true|false> mode=<0555> entries=<json list>
E2E read-only bundle: case=<id> backend=<cpu|gpu> outcome=<ok|empty_reply|typed_error:<Type>> ms=<n>
E2E read-only bundle: origin when=<before|after> entries=<json list>
```

```sh
dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-litert-read-only-bundle --device <device>
```

macOS and Android default to a temp cache directory, so of the targets this
test runs on only iOS and Linux load the bundle uncached through the public
API (it needs POSIX `link` and `chmod`, so not Windows), while on macOS and Android
every case generates and the run checks the harness. To run the service with
that default off on such a host, instead of the public backend, call
`flutter test` as the scenario prints it and add
`--dart-define=LITERT_READ_ONLY_NO_TEMP_CACHE=true`.

For iOS Test Lab, build the XCTest bundle from that target and submit
`tests.zip` as an `xctest`; the result lines are in `xcodebuild_output.log`:

```sh
flutter build ios --config-only --release \
  --target integration_test/litert_lm_read_only_bundle_e2e_test.dart
(cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath <derived-data> build-for-testing DEVELOPMENT_TEAM=<team>)
(cd <derived-data>/Build/Products && zip -q -r <out>/tests.zip .)
```

## llama.cpp text and stable_diffusion images in one process

`integration_test/text_image_coexistence_e2e_test.dart` checks that a chat
model and an image model work side by side in one process
([#779](https://github.com/leehack/llamadart/issues/779)). It downloads and
hash-checks the locked `chat-gguf-cpu` validation model (563 MB) and SDXS-512
(683 MB), then runs through the public API, each engine staying loaded from
its load to the last step:

1. `solo`: a greedy, seeded chat reply, before anything of the image runtime
   is called.
2. `ImageGenerationEngine.load`, then a 512x512 image with seed 42.
3. `after_image`: the same chat request on the same `LlamaEngine`.
4. The same image request again.

It fails unless the second reply equals the first and both are at least 16
tokens long, the second PNG equals the first and is a 512x512 image that is
not blank, and both engines name their backend. A typed error fails the test
after its `error` line.

```text
E2E coexistence: text when=<solo|after_image> sha256=<hex> tokens=<n> ms=<n>
E2E coexistence: image n=<1|2> sha256=<hex> backend=<name> ms=<n>
E2E coexistence: memory after=<step> rss_mb=<n> peak_rss_mb=<n>
E2E coexistence: result text_equal=<bool> image_equal=<bool>
```

The `result` line and `coexistence.json` are written before the assertions,
so a run is graded by the test outcome, not by the receipt. A
`started step=<step>` line precedes each step, so a run that a native crash
ends names the step it died in. The `memory` lines hold the resident and peak
resident set size of the process, which leaves out Metal memory on Apple
devices.

```sh
dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-text-image-coexistence --device <device>
```

For Test Lab, build both APKs from that target as above, with
`--dart-define=VALIDATION_COMMIT=<exact-source-commit>` and
`--dart-define=VALIDATION_SOURCE_DIRTY=false` from a clean checkout so the
`config` line and the receipt name the source, then add:

```sh
--directories-to-pull=/sdcard/Android/data/com.example.llamadart_chat_example/files/coexistence
```

Each run directory holds the first image as `coexistence_image.png` and
`coexistence.json` with the replies, hashes, timings and memory figures. Give
the Test Lab timeout both downloads on top of the run.

## Automatic image attention and VAE settings

`integration_test/image_settings_comparison_e2e_test.dart` compares the
automatic `ImageModelParams.flashAttention` and `vaeDirectConvolution`
settings with explicit overrides
([#805](https://github.com/leehack/llamadart/issues/805)). In one process it
loads SDXS-512, SD-Turbo with TAESD and SD-Turbo with its full VAE once per
arm: `auto` (no overrides) and `both_off` (both `false`), plus
`vae_direct_off` for the full VAE, the only variant whose automatic settings
turn both on; it differs from `auto` in the VAE setting alone and from
`both_off` in flash attention alone. Each load runs
`ImageGenerationEngine.warmUp` (a one-step generation on a GPU, nothing on
the CPU) and then generates the same 512x512 image with seed 42: one timed
image per load on Android and two elsewhere (`IMAGE_SETTINGS_MEASURED`). Two rounds (`IMAGE_SETTINGS_ROUNDS`) load every
arm again in the reverse order. A load records wall time per image, split at
the first decoding event into sampling and decode, the image hash, the
backend and the peak memory from load to dispose: Apple `phys_footprint` peak reset through
`proc_reset_footprint_interval` (it includes Metal buffers), Android `VmHWM`
reset through `/proc/self/clear_refs` where the app may write it, each with a
20 ms sampled peak of the current figure beside it, which is the peak used
when the reset is refused. Test Lab refused it on all three phones (Galaxy
S24 and Galaxy A53 with Android 16, Pixel 9 Pro with Android 15), so their
peaks are the 20 ms sampled `VmRSS`. A model that the load-time memory check
refuses is recorded as refused for all its arms. A refusal verifies only when
it names `ImageModelParams.checkMemory` and the run lists the variant in
`IMAGE_SETTINGS_EXPECTED_REFUSALS` (a profile's `expected_refusals`), and a
run must measure at least one arm. A device-specific profile can declare
`expected_refusals` when a refusal is the expected outcome; the shipped
profiles declare none, because the S24 and Pixel 9 Pro must measure
SD-Turbo. The Galaxy A53's memory check refused SD-Turbo (2.9 GiB needed,
2.5 GiB available), so its `image-settings-cpu` run does not verify
(undeclared refusal of `sd_turbo_taesd`) and its `image-settings-cpu-vae`
run has no measured arm. Its SDXS figures come from that unverified run and
are reported as an observation, not verified evidence.

```text
IMAGE_SETTINGS {"type":"config",...}
IMAGE_SETTINGS {"type":"load","variant":"sdxs","arm":"auto","round":0,...}
IMAGE_SETTINGS {"type":"summary","variant":"sdxs","arm":"both_off","ms_per_image_median":...,"vs_auto":{...}}
```

Each record is also appended to `image_settings/run-*/journal.jsonl` (app
external files on Android, the temporary directory elsewhere); the end writes
`image_settings.json` with the summary and one PNG per arm, and verifies them.
The test fails when an arm fails, gives different images for the same seed,
misses a round or an image, or does not start within `IMAGE_SETTINGS_BUDGET_MINUTES` (16).
`IMAGE_SETTINGS_DEVICE=cpu` measures the CPU on a Mac, and
`IMAGE_SETTINGS_VARIANTS` runs a comma-separated subset.

```sh
dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-image-settings-comparison --device <device>
```

For Firebase Test Lab, build it with a validation profile; collection grades
the receipt. Test Lab devices download from Hugging Face at about 3 to 4 MB/s
(SD-Turbo took 10 minutes on a Galaxy S24) and a phone CPU decodes the full
SD-Turbo VAE in about 40 s, so Android splits the variants over two 20-minute
runs: `image-settings-cpu` (SDXS and SD-Turbo with TAESD) and
`image-settings-cpu-vae` (SD-Turbo with its full VAE). The profiles also
compile in `LLAMADART_CHAT_PARALLEL_DOWNLOAD=true`. iOS runs one variant per
run (`image-settings-metal` for SDXS, `image-settings-metal-taesd`,
`image-settings-metal-vae`): Flutter's XCTest runner executes the whole Dart
suite before XCTest reports a test case, and three iPhone 16 Pro runs of all
three variants, about 10 minutes of Dart each, ended in Test Lab
infrastructure errors with no result, while a 3.5-minute image test passes. A profile can also set `rounds` and `measured_per_load`
(compiled in as `IMAGE_SETTINGS_ROUNDS` and `IMAGE_SETTINGS_MEASURED`).
A two-round full-VAE run also ended in infrastructure errors;
`image-settings-metal-vae` sets one of each as the configuration to retry,
and it has not produced evidence yet
([#1033](https://github.com/leehack/llamadart/issues/1033);
[image-generation profiles](cross_platform_validation.md#image-generation-profiles)).

## Micro-batch sweep and the Android Vulkan prompt cap

`integration_test/micro_batch_sweep_e2e_test.dart` loads the locked
`chat-gguf-vulkan` model at several micro-batch sizes in one process and sends
a short history prompt, a long history prompt and a tool request with
`ToolChoice.auto` and `ToolChoice.required` at each. Size `0` is the library
default and the only one the test judges, so the sizes must include it: a
default attempt must load, answer both history prompts with the code and
nothing else, and end both tool requests as the `get_weather` call.

Every other size is a control that is only recorded. With the bundled
runtime, explicit sizes above `8` run uncapped. On a llama.cpp runtime older
than ggml `0.28.0`, native Qwen3.5 on restricted Android Vulkan device facts
records them as a `LlamaUnsupportedException` before context creation instead
([#948](https://github.com/leehack/llamadart/issues/948)). The CPU answers
`Cedar17` to the history prompt; the sweep's oracle accepts the code in any
case.

Every repeat of the default size runs first, then the controls repeat by
repeat, and a control sends the tool requests only in its last repeat, so
nothing a control does to the process costs a judged repeat.

```sh
dart run tool/testing/run_local_e2e.dart \
  --scenario chat-app-micro-batch-sweep --device <device>
```

Only an Android device whose GPU ggml-vulkan registers makes the library
decide about the cap. Elsewhere the run checks the default path and the
harness.

For Test Lab, build both APKs from that target as above, then add:

```sh
--environment-variables=microBatchArms=0+512,microBatchRepeats=6,microBatchBudgetSeconds=450,microBatchNativeLog=debug \
--directories-to-pull=/sdcard/Android/data/com.example.llamadart_chat_example/files/micro_batch_sweep
```

The pulled directory holds `journal.jsonl`, `native_stderr.log`, `vkjson.json`
(`cmd gpu vkjson`, saved before Flutter starts: the driver's API version and
subgroup size) and `app_apk.sha256`. Every journal record is written through
before the next step, and the same records appear in logcat as
`MICRO_BATCH_SWEEP` lines. In the journal:

- `attempt_verdict` is the verdict of one attempt: `passed`, the judged cases
  one by one, the failures and the cap state. `judged` is true for the default
  size. A run that dies keeps the verdicts of the attempts before it.
- `prompt_cap` is what is known about the cap of an attempt's context, as
  `state`:
  - `capped` (with `cap_tokens`) or `not_capped`: the library's own debug
    line, with the Vulkan devices it decided from (`name`, `api_version`,
    `loader_api_version`, `subgroup_size`). The library logs it only when it
    has a Vulkan device to decide from.
  - `no_vulkan_device`: the load asked Vulkan for GPU layers but ggml-vulkan
    registered no device. The library logs nothing and applies the cap all the
    same, although the context runs on the CPU (an emulator, or a load that
    fell back).
  - `explicit_size`: an explicit size, which leaves the cap off.
  - `vulkan_not_requested`, `not_android`: no cap.
  - `not_logged`: a Vulkan device is registered and the cap was to be decided,
    but no decision reached the log. Treat the record as missing.
- `load` holds the backend the model runs on, its GPU layer count and the GPU
  devices the runtime lists.
- `log` is every `LlamaLogger` record, among them the warning of a load that
  fell back to the CPU because the Vulkan driver is below 1.2.
- `load_refused` is a typed exception from a load.
- `case` and `case_error` are each answer (with `passed` for a judged case)
  and each typed exception from a request; `summary` counts the passing
  answers by size.

`microBatchDevice=gpu` asks each load for `ComputeDevice.gpu` first, records a
typed refusal as `load_refused` and then loads as the profile does
(`ComputeDevice.auto`), so one run shows whether a device that cannot run
Vulkan gets a typed error and a CPU fallback. The other arguments are
`microBatchProfile` (a validation profile id) and, at build time,
`--dart-define=MICRO_BATCH_SWEEP_ARMS`, `MICRO_BATCH_SWEEP_REPEATS`,
`MICRO_BATCH_SWEEP_BUDGET_SECONDS`, `MICRO_BATCH_SWEEP_NATIVE_LOG`,
`MICRO_BATCH_SWEEP_DEVICE`, `MICRO_BATCH_SWEEP_PROFILE` and
`MICRO_BATCH_SWEEP_MODEL`.

The budget counts from the end of the model download and check. Past it no
attempt and no request starts and the test fails, which keeps a slow device
inside the Test Lab timeout; give the timeout the download on top (it took 1.5
to 4 minutes for this model on Test Lab) and the length of one request.

`--dart-define=MICRO_BATCH_SWEEP_NEGATIVE_CONTROL=true` checks the judge: it
expects a code the prompts do not hold, so the test must fail, with failures
of the default size only.

When a native crash ends the app, Test Lab reports `Test failed to run`. It
still pulls the directory: the last `attempt_started` or `case_started` record
without its result names the step that was running.

Model-backed Flutter startup and image shutdown checks are documented in
[`doc/testing_matrix.md`](testing_matrix.md). They await pending
startup and disposal before quitting; source-built tests do not qualify
published runtime bytes.


## Collecting image device evidence

For Android Test Lab, pull
`/sdcard/Android/data/com.example.llamadart_chat_example/files/image_generation_e2e`.
Each run contains `image_generation_e2e.png`, `image_generation_screen.png`
and `image_evidence.json`. The test verifies the saved byte hashes and PNG
structure before passing. A test-outcome success or logged file path alone
is insufficient: download both images and their receipt, then run from the
repository root:

```bash
dart run tool/testing/verify_image_e2e_evidence.dart \
  <downloaded-run-directory> <exact-source-commit> CPU
```

Build the app and its matching instrumentation APK with
`--dart-define=VALIDATION_COMMIT=<exact-source-commit>` and
`--dart-define=VALIDATION_SOURCE_DIRTY=false` only from a verified clean
checkout. Use the matching base64 `dart-defines` Gradle property when assembling
Android instrumentation, as in the maintained validation bundle builder.
Without those definitions the PNGs remain useful locally, but strict source
verification fails. Inspect the actual images for visual quality separately;
the validator checks PNG structure, dimensions, byte identity and declared
clean-build/backend metadata, and compares model/profile and runtime pins with
the maintained source. APK identity, model integrity, native runtime provenance
and inference placement require their own evidence. Android image inference
uses the CPU; this capture test does not qualify GPU or whole-host C exit.
