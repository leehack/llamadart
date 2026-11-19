# Gemma 4 loose tool-call oracle for #1930

The companion [JSON](gemma4_loose_tool_upstream.json) records a macOS arm64
`common/chat` replay at the shipped llama.cpp v1.0.0 commit
[`b1b770d9`](https://github.com/ggml-org/llama.cpp/blob/b1b770d90d94cad9e9ea5b993bdbc383a522fb28/common/parsers/gemma4.cpp#L389-L392).
It uses the checked-in Gemma 4 E2B template, auto tool choice, and typed weather
tools. Upstream preserves every byte of the prose-plus-JSON and Hermes-wrapped
replies and returns no calls for those inputs. The native-framed control
preserves its preceding prose and returns one call. Llamadart additionally
recovers loose JSON calls and keeps the exact visible prefix preceding the
payload and its wrapper.

To replay, pass the recorded template and request to
`oracle <template.jinja> <request.json>`. Populate `outputs` with each final
row's input as a string and each partial row's input as
`{"text": "<input>", "partial": true}`.
