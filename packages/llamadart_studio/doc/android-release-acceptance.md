# Android release acceptance builds

`integration_test/cloud_mobile_acceptance_test.dart` needs both the SDK's native
completion plugin in the app and `FlutterTestRunner` on the instrumentation
classpath. Flutter 3.50 deliberately excludes dev plugins from release
registration and release API dependencies. Selecting `testBuildType = "release"`
alone therefore fails at `compileReleaseAndroidTestJavaWithJavac`; adding only a
compile dependency leaves the runner waiting for an unregistered channel.

Studio's opt-in Gradle property `studioReleaseAcceptance=true` selects the release
test build type, adds the pinned SDK's `:integration_test` project to
`releaseImplementation`, selects the maintained registration adapter, and keeps
the SDK classes referenced by the separate test APK through R8. `MainActivity`
registers it before Dart starts, after normal generated registration. Registration
is idempotent. The ordinary adapter is empty and has no test-plugin dependency.
No generated registrant or SDK source is edited. `integration_test` remains a dev
dependency in Studio's pubspec. R8 remains enabled.

The Dart fixture registers `TestTextInput` inside the `testWidgets` body, after
the binding reset, and restores an initially unregistered state at teardown.
Flutter 3.50's integration binding disables automatic registration. Without it,
synthetic edits send client ID `-1`, which Flutter accepts only in debug builds.
The shared input helper requires registration and an active positive client
before editing. Its model-free regression starts with registration disabled,
checks client changes across fields, and exercises the real Send and Notes
controllers with a fake inference port. This checks the fixture configuration;
debug test results do not qualify release input or physical inference.

Prepare the root with its Flutter pin first, on a clean checkout:

```sh
PATH="/path/to/flutter-3.47.1/bin:$PATH" dart run tool/prepare_workspace.dart
```

Commit the maintained source before building. Use Studio's separate Flutter pin
(currently 3.50.0), an Android SDK with build-tools 36.1.0 (or select
`--build-tools`), and JDK 17 or newer. From the repository root:

```sh
export JAVA_HOME="/path/to/jdk"
export ORG_GRADLE_PROJECT_studioAllowDebugSigningForQualification=true
python3 packages/llamadart_studio/tool/build_android_release_acceptance.py \
  --flutter-sdk /path/to/flutter-3.50.0 \
  --android-sdk /path/to/android-sdk \
  --model-sha256 bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517 \
  --output "$PWD/.dart_tool/studio-android-release-acceptance"
```

The output directory must not exist. The helper selects the acceptance property
itself and rejects inherited qualification/consumer/NPU staging flags. It resolves
core with `dart pub get` and UI with `flutter pub get`, using `os.pathsep` for PATH,
and verifies bare tool paths and the Studio SDK pin. It builds arm64 release AOT
with the unchanged cloud fixture, source commit and admitted model hash, then
builds `app:assembleReleaseAndroidTest` with the same target and Dart defines.
The existing `MainActivityTest` and `stageModel=true` mechanism are unchanged.
The helper neither stages weights nor runs, submits or uploads artifacts.

The retained `receipt.json` records source commit/tree, commands, signing
certificate, SDK/tool versions, and SHA-256/size of every retained input and
output. `source.tar` retains exact committed source; the SDK integration-test
Android source is retained separately. There is no source-build overlay. Keep
the entire directory, including failed receipts and logs. Checks verify matching
app/test signatures, nondebuggable app manifest, arm64 ELF `libapp.so`, no kernel
blob, app completion-plugin/runner inclusion, the activity registration bytecode,
the SDK completion channel and shared future, and the maintained instrumentation
class/target without a duplicate completion plugin in the test APK. R8 mapping
and the unedited generated registrant are retained.

Build the ordinary production entry point in a separate output directory to
verify exclusion in actual release DEX:

```sh
python3 packages/llamadart_studio/tool/build_android_release_acceptance.py \
  --flutter-sdk /path/to/flutter-3.50.0 --android-sdk /path/to/android-sdk \
  --ordinary --output "$PWD/.dart_tool/studio-android-ordinary-release"
```

The ordinary check requires both `IntegrationTestPlugin` and `FlutterTestRunner`
to be absent. It retains the same AOT, signing and manifest evidence. Debug-signed
qualification APKs, including the ordinary comparison artifact, must never be
distributed. Without the existing explicit signing opt-in or production
credentials, the normal signing guard still fails.

Run the model-free helper regressions with the configured JDK:

```sh
python3 -m unittest discover -s packages/llamadart_studio/tool/test -v
```

These compile both maintained native adapters against an observing engine double,
verify registration happens once, compile the ordinary adapter with no plugin
class available, and exercise runner/exclusion and AOT rejection checks. They do
not simulate native completion delivery. A verified build remains
`qualified: false`, `deviceExecuted: false` until the parent executes the exact
retained pair on an admitted physical device, stages the exact model with
`stageModel=true`, and grades the real fixture outputs, JUnit, logs and storage
receipts. Rebuild after integration: a constituent's source identity does not
qualify the integration head. See [production acceptance](production-readiness.md).
