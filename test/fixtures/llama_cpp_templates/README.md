# Vendored llama.cpp chat templates

Copied verbatim from `models/templates` in [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
at the ref pinned in `tool/testing/llama_cpp_templates.ref`. Only the templates
that `test/unit/core/template/handlers/firefunction_v2_handler_test.dart` reads
live here, so that unit test runs on a clean checkout with no network.

`test/integration/core/template/llama_cpp_template_detection_integration_test.dart`
needs the full set and only reads it from `LLAMA_CPP_TEMPLATES_DIR`, defaulting to
`.dart_tool/llama_cpp/models/templates`. Nothing in the test provisions that
directory: CI downloads the release tarball at the pinned ref, and locally
`tool/testing/prepare_llama_cpp_source.sh` clones the source tree there.

To refresh, at a newer llama.cpp tag:

1. Update `tool/testing/llama_cpp_templates.ref`.
2. Re-run `tool/testing/prepare_llama_cpp_source.sh` and copy the files here.
3. Reconcile the expectation map and `unclassifiedTemplates` in the detection test.
