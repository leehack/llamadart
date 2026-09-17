# llamadart validation

Private maintainer package (`publish_to: none`). It exercises the exported
llamadart API through the same core on desktop, Flutter mobile, and Web.
It is independent of the public package's implementation and exports.

Start from the repository root:

```sh
dart run tool/testing/run_local_e2e.dart --scenario validation-harness
dart run tool/testing/validation.dart local --profile tiny-gguf-cpu
dart run tool/testing/validation.dart build --target desktop --out .dart_tool/validation/bundles/desktop
```

See [the runbook](../../doc/cross_platform_validation.md) for models, bundles,
Firebase/GCE setup, run/recovery commands, evidence and cost boundaries.
See [the full plan](../../doc/cross_platform_validation_plan.md) for subsequent
platform and feature qualification. A quick run does not qualify a release.

`assets/profiles/` locks each model URL/revision/SHA256/size and inference
configuration. `lib/` has no Flutter or filesystem dependency; `lib/io.dart`
is the native filesystem adapter. `bin/run.dart` and `bin/report.dart` are the
CLI entrypoints. Flutter uses the package's profile assets and shared runner.
Native wrappers persist JSONL per event; reports always derive from that journal.

Exit 0 means this selected run qualified, 1 means failed/incomplete.
Unknown/dirty source provenance, missing counters, unknown backend placement, skipped mandatory cases and missing
records remain incomplete. `release` selection deliberately records unimplemented
feature packs as NOT_RUN until their fixtures and wrappers are qualified.
