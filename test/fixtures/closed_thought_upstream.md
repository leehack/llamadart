# Closed-thought upstream parses

`closed_thought_upstream.json` records how llama.cpp parses output after a
prompt that ends with an empty thought, for issue #750.

The templates are the vendored DeepSeek V3.1, Qwen3 4B, QwQ 32B and Qwen3.5
0.8B templates. With thinking off, each ends its generation prompt with an
empty thought: `<think></think>`, `<think>\n</think>` or
`<think>\n\n</think>\n\n`.

`upstream` comes from a probe built from unchanged llama.cpp
`620d2225cc436ab0b001e3200e590e3b286ef9ab`, the source of the pinned native
runtime `v0.7.0-2`. With no model loaded, it called `common_chat_templates_init`
on the template, built a `common_chat_session` from one user message, the
`weather` tool, `enable_thinking = false` and `COMMON_REASONING_FORMAT_AUTO`
(format `peg-native`), and called `finish` on the whole output. Feeding the
output one byte at a time before `finish` gave the same result for every case.
No case has reasoning: thinking tags are content.

With the Bielik 11B v3 or Spark 2.5 templates, whose prompts end without an
empty thought when thinking is off, the same probe still parses a leading
`<think>` thought, so llamadart keeps parsing thoughts there.
