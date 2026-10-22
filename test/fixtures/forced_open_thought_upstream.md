# Forced-open thought upstream parses

`forced_open_thought_upstream.json` records how llama.cpp parses output after a
prompt that opens a thought, for issue #742.

The templates are the vendored `MiniMax-M2.jinja` and
`deepseek-ai-DeepSeek-V3.1.jinja` (identical at `b10549` and `620d2225c`).
Both end their generation prompt with `<think>`. The DeepSeek V3.1 entry passes
`{"thinking": true}` because llamadart does not yet map `enableThinking` to that
template's `thinking` variable (#750).

`upstream` comes from a probe built from unchanged llama.cpp
`620d2225cc436ab0b001e3200e590e3b286ef9ab`, the source of the pinned native
runtime `v0.7.0-2`. With no model loaded, it called `common_chat_templates_init`
on the template, built a `common_chat_session` from one user message, the
`weather` tool, `enable_thinking = true` and `COMMON_REASONING_FORMAT_AUTO`
(format `peg-native`), and called `finish` on the whole output. Feeding the
output one byte at a time before `finish` gave the same result for every case.

A thought that never closes is reasoning, including a tool-call envelope inside
it. llamadart trims some of the whitespace llama.cpp keeps around reasoning and
content, so the test compares trimmed text.

No EXAONE MoE, Seed-OSS, Apriel 1.5 or Xiaomi MiMo template that llamadart
routes to those formats and that opens a thought in the prompt is available;
their handlers follow the same rule.
