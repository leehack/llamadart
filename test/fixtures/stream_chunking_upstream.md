# MiniMax M3 chunking oracle for #1930

The companion [JSON](stream_chunking_upstream.json) records the macOS arm64
`common/chat` oracle at llama.cpp
[`cd959bae99ff4bed22bef2604f45241c09bbb8c8`](https://github.com/ggml-org/llama.cpp/tree/cd959bae99ff4bed22bef2604f45241c09bbb8c8).
The request uses the vendored MiniMax M3 template, the typed `weather(city)`
tool, auto tool choice, parallel calls, and adaptive thinking.

To replay, pass the recorded template path and request to the
`oracle <template.jinja> <request.json>` harness. Add an `outputs` array with
each case's full input as a string and each interior prefix as
`{"text": "<input up to cut>", "partial": true}`. Indices count ASCII bytes,
which also match the Dart string indices here. The JSON keeps the exact
upstream content bytes. Llamadart trims outer whitespace and retains post-scope
text in the native-scope case where upstream's final parse reports an error.

This is a model-free native parser replay. The Dart split-property suite
compares actual content and reasoning deltas with its own final parse.
