# Hermes double-brace tool call

`hermes_double_brace_tool_call.json` records two Qwen2.5 emissions that wrap
the Hermes tool call in an extra `{` (issue #662).

`hermes_double_brace_qwen2_5.jinja` is the unchanged `tokenizer.chat_template`
of `qwen2.5-0.5b-instruct-q4_k_m.gguf` from `Qwen/Qwen2.5-0.5B-Instruct-GGUF`,
revision `9217f5db79a29953eb74d5343926648285ec7e67`.
Model SHA256: `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`.
Template UTF-8 SHA256: `d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4`.
Its tool prompt prints `{{"name": <function-name>, "arguments": <args-json-object>}}`
literally. With no grammar constraining it, the model copied the double braces
in both cases below.

Both cases use the fixture's user prompt and `get_weather` tool with
`ToolChoice.auto`:

- `webgpu-bridge-v0.1.49`: the emission reported in issue #662 for WebGPU
  bridge assets `v0.1.49`, where llamadart sends no tool grammar for
  `ToolChoice.auto`.
- `native-no-grammar`: llamadart native `v0.5.0` on CPU with 4 threads,
  `temp: 0`, `maxTokens: 96`, the prompt from `engine.chatTemplate`, and
  `engine.generate` without the tool grammar. `pieces` are the strings
  `engine.generate` yielded.

`upstream_result` comes from a probe built from unchanged llama.cpp
`7fe450e19305b828c199d602c23a8337aaa1f03b`. It loaded the model vocabulary
only, then called `common_chat_templates_init`, `common_chat_templates_apply`
with the same tool and auto tool choice (format `peg-native`), and
`common_chat_parse` with `is_partial = false`. For both emissions the parse
throws the recorded error and extracts no tool call. The single-brace control
`<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>`
parses to one `get_weather` call with empty content.

`expected` is llamadart's deliberate behavior, which differs from upstream: it
extracts the call and leaves no content, as for the single-brace form.
