# BOS and EOS render reference

`bos_eos_render_upstream.json` holds the prompts that an unmodified
`llama-server` built from llama.cpp `cd959bae9` (build b12110, the pinned
runtime) returned from `POST /apply-template`
([#1972](https://github.com/leehack/llamadart/issues/1972)). llama.cpp gives
every template the vocabulary's BOS and EOS text as `bos_token` and
`eos_token`; GGUF files store only their ids.

Each request sent `messages` and, for `tools: true` cases, `tools`. The server
ran with `--jinja --chat-template-file <template> -c 512 -ngl 0 --no-warmup`
on `model` (sha256 `model_sha256`), which only supplies `bos_token` and
`eos_token`. `template_sha256` pins the vendored template each case renders.

`test/unit/core/template/bos_eos_render_parity_test.dart` renders each case
through `ChatTemplateEngine.render` with those two tokens as
`tokenizer.ggml.bos_token` and `tokenizer.ggml.eos_token` and expects the exact
prompt, so no handler adds, drops or duplicates a BOS.

`excluded` lists the cases left out, each with its reason: a prompt that
differs from llama-server outside BOS and EOS, or a template llamadart does not
render.
