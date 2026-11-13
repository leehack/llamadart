# BOS and EOS prompt token reference

`bos_eos_prompt_tokens_upstream.json` holds, per model, the `bos_token` and
`eos_token` text that an unmodified `llama-server` built from llama.cpp
`cd959bae9` (build b12110, the pinned runtime) reports, the prompts it returned
from `POST /apply-template`, and the token ids `POST /tokenize` returned for
each prompt with `add_special: true` and `parse_special: true`
([#1972](https://github.com/leehack/llamadart/issues/1972)). The server ran
with `-c 512 -t 2 -tb 2 -ngl 0 --no-warmup` on the model whose sha256 is
`model_sha256`.

`test/e2e/backends/gguf_bos_eos_prompt_tokens_e2e_test.dart` (`local-only`)
loads each model from `LLAMADART_TEST_MODELS_DIR`, checks the sha256, and
expects `getMetadata()` to report the same BOS and EOS text and
`chatTemplate` plus `tokenize` to produce the same token ids. It skips a model
whose file is absent.
