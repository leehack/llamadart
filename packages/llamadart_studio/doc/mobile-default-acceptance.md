# Mobile production-default workflow preparation

`integration_test/mobile_default_workflows_acceptance_test.dart` is a separate
`local-only` suite, enabled only by `STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true`.
The fixed-profile `cloud_mobile_acceptance_test.dart` and its expected `4`
assertion remain unchanged. Its retained expected4/actual2 failure reproduces
outside mobile and Dart; this suite does not repair or supersede that profile.

The new suite calls `bootstrapProduction` with an owned temporary data root,
an isolated model-scanner root and a test-only namespace delegating to real
`SharedPreferencesKeyValueStore`. It constructs the real storage, Direct
inference, speech, image, Playground and file stores. No inference wrapper,
fake port, direct Coding handler invocation, download or runtime URL input is
used. Preference overrides disable automatic startup selection, so startup
selection is explicitly **unqualified**. Every inference case activates the
curated model through the visible Hub control.

The curated primary and projector are both required. A primary-only `local:`
descriptor does not qualify this profile. Sampling, thinking, default enabled
skill, default Chat tools, compute-auto and normal hardware fitting remain
intact. The sole declared hardware override is two decode and two batch CPU
threads, set before activation. This is not pristine hardware-default evidence.
Effective settings, engine signature and cached backend/context/layer metadata
are recorded. Those targets are not independent native placement measurements.

| Independent case | Required result | Case deadline |
| --- | --- | --- |
| Chat arithmetic | Original question, answer exactly `4`, no turn error | 3 minutes |
| Chat math tool | Actual `evaluateMath` with `(18.5 * 4) + sqrt(81)`, result and final answer numeric `83` (`83.0` allowed) | 3 minutes |
| Coding files | Visible local workspace creation; model write/read nested Unicode file, then read/edit/reread; real invocation results, independent exact disk bytes/hashes and browser-displayed text | 4 minutes |
| Notes | Exact Unicode title/body through UI and committed JSON; dispose all dependencies, reload preferences, fresh production bootstrap and exact UI/file reopen | 2 minutes |

The math final answer must parse in full, after trimming, as one finite decimal
number equal to `83`. Explanations, multiple numbers, `NaN` and `Infinity` fail.
This contract applies to future candidates; retained runs and grades stay unchanged.

There are at most four user-level model turns across the suite (one, one, two,
zero). Existing production tool-round caps remain unchanged. Operations have
90-second bounds; there are no automatic generation retries, alternate prompts,
relaxed answers or profile/model fallbacks. The execution owner must configure
an external process/provider deadline above the 12-minute case sum, for example
15 minutes. A Dart timeout cannot terminate blocked native work; the execution
owner owns that outer process deadline and cleanup. Do not start execution from
this source-preparation procedure without the parent's separate execution gate.

Notes proves **same-process fresh-bootstrap text persistence only**. It does not
prove process recreation, cold restart, media persistence or embedding/retrieval.
No Nomic asset is required for this text scope. Permissions, supported media,
hardware coverage, Coding provider grants, clipboard/cold root reopen, native
keyboard/back/focus, lifecycle/endurance and remaining six-platform gates stay
open.

## Closed local asset stage

Use only the already local admitted files. Never download or substitute weights.
From the repository root, create a new stage outside tracked source:

```sh
python3 packages/llamadart_studio/tool/mobile_default_assets.py \
  --primary /existing/Qwen3.5-0.8B-Q4_K_M.gguf \
  --projector /existing/Qwen3.5-0.8B-mmproj-F16.gguf \
  --output "$PWD/.dart_tool/mobile-default-input"
```

| Relative name | Bytes | SHA-256 |
| --- | --- | --- |
| `Qwen3.5-0.8B-Q4_K_M.gguf` | 532517120 | `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` |
| `Qwen3.5-0.8B-mmproj-F16.gguf` | 204987232 | `56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453` |

Source and copied bytes must match the allowlist. The stage contains exactly
those two names and `manifest.json`, with no URLs, credential fields or path
aliases. Stage verification rejects symlinks, extras, missing companions,
changed sizes and changed hashes. Dart verifies the native-staged bytes again
before bootstrap. Keep a failed stage for investigation; use a new output path
for a new attempt.

## Release build routing

First prepare a clean root using Flutter 3.47.1 as required by `AGENTS.md`, then
resolve and check both Studio packages with their own Flutter 3.50.0 pin. Commit
the source before provenance builds. No global SDK change is needed. Precache
the admitted platform release engine inputs before the build tranche; helpers
freeze SDK/compiler/engine identities before building and reject changes after.
Retain the full receipts, committed source archive and signing evidence.

Android keeps the existing builder's default diagnostic target and its signing,
release AOT, completion plugin and runner checks. Select the new suite explicitly:

```sh
python3 packages/llamadart_studio/tool/build_android_release_acceptance.py \
  --flutter-sdk /path/to/flutter-3.50.0 --android-sdk /path/to/android-sdk \
  --suite default-workflows --models "$PWD/.dart_tool/mobile-default-input" \
  --output "$PWD/.dart_tool/mobile-default-android"
```

Keep the existing explicit qualification-signing opt-in or production signing
configuration from [Android release acceptance](android-release-acceptance.md).
The builder retains a separate `studio-mobile-default-models` shell input
directory; neither APK embeds weights or qualification resource payloads.
The execution owner stages **only its two GGUF files** under the fixed shell
directory `/data/local/tmp/studio-mobile-default-models/` and selects the
instrumentation argument `studioMobileDefault=true`. `MainActivityTest` copies
and hashes these fixed allowlisted names into a fresh app cache directory,
then writes the immutable manifest. Do not also select `stageModel=true`.
A stale app cache stage is rejected; use a fresh admitted install/run.

For iOS, the guarded helper configures the exact Dart target and builds signed
Release `build-for-testing` products without running XCTest:

```sh
python3 packages/llamadart_studio/tool/build_ios_release_acceptance.py \
  --flutter-sdk /path/to/flutter-3.50.0 --team EXISTING_SIGNING_TEAM \
  --models "$PWD/.dart_tool/mobile-default-input" \
  --output "$PWD/.dart_tool/mobile-default-ios"
```

Use an already admitted signing identity/profile. The helper does not obtain
credentials, enable provisioning updates or substitute unsigned/ad hoc signing.
The Xcode resource phase requires the exact target, Dart opt-in, explicit
`STUDIO_MOBILE_DEFAULT_ACCEPTANCE=YES`, `Release`, `iphoneos` and signing enabled.
Only then can `STUDIO_MOBILE_DEFAULT_MODELS` supply the verified stage. It copies
resources before code signing. App and XCTest signatures, matching team,
arm64 AOT and XCTest manifest are checked. Retained products remain development
qualification artifacts, not distributable releases.

Build ordinary comparisons with each helper's `--ordinary` mode, without
`--models` or a suite override. Android additionally requires the completion
plugin/runner to be absent. The iOS phase removes stale owned qualification
resources on ordinary builds, rejects inherited staging inputs and the helper
checks actual product exclusion. Run those actual artifact checks after parent
review/integration; model-free routing tests do not prove a signed build.

## Evidence and model-free checks

Each case synchronously flushes checkpoints, effective settings, synthetic
outputs, real tool outcomes, disk hashes, failures and cleanup. A shared summary
retains separate case status. Android writes to the existing external-files
`studio-acceptance/<UTC-run>-defaults/`; iOS uses
`Documents/validation/runs/<UTC-run>-defaults/`, collected by the existing
KeepAlways XCTest attachment hook even on failure. Retain every failed result.
Build identity includes source, harness/support hashes, native pin source hash
and pre/post SDK/compiler/engine inputs. Artifact receipts hash the actual
app/native products. These bindings do not turn cached runtime placement
metadata into measured hardware execution.

```sh
python3 -m unittest discover -s packages/llamadart_studio/tool/test -v
cd packages/llamadart_studio
dart format --output=none --set-exit-if-changed integration_test test
flutter analyze --no-pub
TMPDIR="$(mktemp -d)" flutter test --no-pub test/mobile_default_inputs_test.dart \
  test/fixture_text_input_test.dart test/coding_local_workspace_test.dart \
  test/notebook_async_save_test.dart
```

Python tests use tiny local bytes to exercise actual copy/hash rejection and
compile the maintained Java staging helper. Preference tests use the platform
test backend with the real SharedPreferences adapter; the integration suite
never installs that backend. Follow package-local core analysis/tests as well.
Review the exact integrated head before any signed build or physical/cloud run.
