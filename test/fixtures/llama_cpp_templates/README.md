# Vendored llama.cpp chat templates

Copied verbatim from `models/templates` in [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
at tag `b10549`. Only the templates needed by unit tests live here, so those tests
run on a clean checkout with no network.

The full set is used by
`test/integration/core/template/llama_cpp_template_detection_integration_test.dart`,
which fetches it at the pinned ref instead — see `tool/testing/prepare_llama_cpp_source.sh`.

To refresh: re-run the prepare script at a newer tag, copy the files, and update the tag above.
