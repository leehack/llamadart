# Seed-OSS parallel-call upstream parses

`seed_oss_parallel_upstream.json` records how llama.cpp parses Seed-OSS
replies with two or three consecutive tool calls, each in its own
`<seed:tool_call>` scope, for issue #1540. It has the layout of
`qwen3_coder_parallel_upstream.json`, which documents the probe, on the vendored
`ByteDance-Seed-OSS.jinja` template.

Every case returned one `get_weather` call per city, in order, with the
`location` value as generated, line breaks included.

Cases where llamadart already differs from that probe for a single call are
left out: text after the last call, which llama.cpp rejects and llamadart keeps
as content, a `</seed:think>` without its opening tag, which llama.cpp keeps as
content, and a thought with thinking off, which llamadart does not stream as
reasoning.
