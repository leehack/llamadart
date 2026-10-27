# Qwen3-VL tool-result media reference

`qwen3_vl_tool_media_upstream.json` holds the prompts that an unmodified
Homebrew `llama-server` 0.7.0 (llama.cpp `620d2225c`, `/props` `build_info`
`b11669-620d2225c`) returned from `POST /apply-template` for two requests
whose `role: tool` messages carry `image_url` parts in array `content`:

- `two_results`: two calls; the first result is JSON text, a caption and an
  image, the second only an image.
- `user_image_then_tool_image`: a user image, one call, and a result with
  text after its image.

`RED` and `BLUE` in each `request` stand for base64 PNG data URIs. The server
ran with `LLAMA_MEDIA_MARKER='<__media__>'`, so the marker is reproducible,
and with
`--jinja --chat-template-file test/fixtures/templates/Qwen3-VL-2B-Instruct.jinja -c 4096`
on the hashed Qwen3.5-0.8B GGUF and projector. The template is
`chat_template.json` from `Qwen/Qwen3-VL-2B-Instruct` at revision
`89644892e4d85e24eaac8bacfd4f463576704203`; `chat_template_caps` is what
`/props` reported. Qwen3-VL weights were not available locally. Qwen3.5-0.8B
uses the same `qwen3vl_merger` projector type, and the prompt does not
depend on the weights.

`test/unit/core/template/tool_result_media_render_test.dart` and
`test/unit/core/engine/tool_result_media_public_api_test.dart` render the
same conversations with `LlamaToolResultContent.content` and expect these
exact prompts.

`text_only_cases` also holds string-only Hermes cases rendered with
`test/fixtures/templates/Qwen3-4B.jinja` on the same server and model:
`string_only_leading_empty_result` (`result: ''` and a text part `x`) and
`string_only_null_result_leading_empty_part` (no result, parts `''` and `x`).
Both emit `x` with no leading newline. `string_only_empty_middle_part` (result
`abc`, parts `''` and `x`) keeps the newline after the non-empty `abc` for
the empty part and the one after it.

The same server answered `/v1/chat/completions` at temperature 0 with
`The main color of the photo is **Red**.` and
`The main color of the photo is **blue**.` for the photo-color history the
local-only `tool-result-image-smoke` scenario sends, and with
`The main color of the photo is blue.` for its tool-loop follow-up.
