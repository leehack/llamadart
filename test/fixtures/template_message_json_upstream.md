# Template message JSON render reference

`template_message_json_upstream.json` holds the prompts that an unmodified
`llama-server`, built from llama.cpp `7fe450e19` (tag `v0.5.0`, the pinned
native runtime), returned from `POST /apply-template` for each case's
`request`. Each case names the issue it pins:

- [#715](https://github.com/leehack/llamadart/issues/715): assistant turns
  with only tool calls or only reasoning (`content: null` in the request).
- [#717](https://github.com/leehack/llamadart/issues/717): Map and List tool
  results. llama-server accepts only string tool content, so the request
  carries the compact JSON text that llamadart sends for the typed result.
- [#702](https://github.com/leehack/llamadart/issues/702): earlier tool-call
  arguments written as compact JSON. The Functionary v3.2 case is a control:
  llama-server reports `supports_object_arguments: false` for that template,
  so its arguments stay a string.

`conversations` holds each conversation in the form the test builds typed
`LlamaChatMessage`s from; `request` is the same conversation in OpenAI form.

For each template the server ran with
`--jinja --chat-template-file <template> -c 512 -t 2 -ngl 0` on
`stories15M.gguf` from
[ggml-org/tiny-llamas](https://huggingface.co/ggml-org/tiny-llamas), whose
SHA256 is `model_sha256`. The prompt comes from the fixture template, not from
the GGUF. That model's `bos_token` is `<s>` and its `eos_token` is `</s>`;
llama-server returned the prompts without the template's leading `<s>`. `template_sha256` is the
template's hash, and `supports_object_arguments` is what `/props` reported.

The `media_tool_call_only` cases (an image, then a tool-call-only assistant
turn) ran with `--mmproj` on `media_model` from
[LiquidAI/LFM2-VL-450M-GGUF](https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF)
and its `media_mmproj`, with `-c 1024 --no-mmproj-offload --no-warmup -np 1`
and the request's `tools`. llama-server prints each image as a random
`<__media_…__>` marker, and llamadart renders images in a different form, so
these cases compare only the prompt segments their `checks` name:
`same_after` (everything after a marker), `same_between` (between two
markers), and `contains_between` (values that both prompts hold between two
markers). llama.cpp renders Apriel 1.6 tool calls in its own format, which
llamadart's generic tool format does not match, so that case checks that the
call is rendered and that the rest of the prompt is the same.

`test/unit/core/template/template_message_json_parity_test.dart` renders each
conversation through `ChatTemplateEngine.render` with `bos_token` empty and
`eos_token` `</s>`, expects the exact prompt (or the `checks`), and expects `TemplateCaps.detect`
to report the same `supports_object_arguments`. The gpt-oss and Solar Open
templates print the current date with `strftime_now`, which reads the wall
clock, so the test masks that date on both sides.
