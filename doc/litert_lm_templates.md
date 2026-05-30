# LiteRT-LM chat templates

This document explains how llamadart picks a chat template for `.litertlm`
model bundles, the families that are supported out of the box, and how to add a
new one.

## Why a built-in registry is needed

llamadart builds every prompt the same way on both backends: it reads
`tokenizer.chat_template` from the model's metadata, detects the template
format, and renders/parses with the matching handler. For llama.cpp this
template is read straight from the GGUF.

`.litertlm` bundles also embed a chat template, but the LiteRT-LM native FFI
exposes **no way to read it back** (it only offers load / generate / tokenize /
detokenize). So the backend has to supply `tokenizer.chat_template` itself. It
does this by detecting the model family from the bundle filename and mapping it
to a canonical template copied verbatim from the one llama.cpp ships — which
keeps the LiteRT-LM path byte-for-byte consistent with the llama.cpp path.

> Note: the native runtime adds the model's start token itself, so the bundled
> templates have their leading `bos_token` stripped to avoid a doubled BOS.

## Resolution order

`LiteRtLmService.getMetadata()` resolves the template in this order (later wins):

1. **Built-in registry** — if the bundle filename matches a known family
   (`kLiteRtLmChatTemplates`), its template is used.
2. **`ModelParams.chatTemplate` override** — if set, it always wins. This is the
   reliable path for any model, including families not in the registry.

If neither applies, no chat template is exposed and the engine falls back to its
generic ChatML handling — usable for plain text, but not the model's native
format.

## Supported families

| Family | Detected as | Filename match | Chat | Tools | Thinking |
| --- | --- | --- | --- | --- | --- |
| Gemma 4 (E2B/E4B) | `gemma4` | `gemma-4`, `gemma4` | ✅ | ✅ native `<\|tool_call>` | ✅ `<\|channel>` |
| Gemma 3n (E2B/E4B) | `gemma` | `gemma-3n`, `gemma3n` | ✅ | ⚠️ prompt-engineered, no schema¹ | — |
| Gemma 3 / 2 / 1B / 270m | `gemma` | `gemma-3`, `gemma-2` | ✅ | ⚠️ prompt-engineered, no schema¹ | — |
| Qwen 3 / 3.5 | `hermes` | `qwen3`, `qwen-3` | ✅ | ✅ `<tool_call>` | ✅ `<think>` |
| Qwen 2.5 | `hermes` | `qwen2.5`, `qwen2` | ✅ | ✅ `<tool_call>` | — |

¹ For Gemma 3/3n the engine injects a generic "respond with `tool_call` JSON"
instruction but does **not** render the tool schemas into the prompt. This
matches the llama.cpp backend's Gemma 3 behavior — it is a property of the Gemma
handler, not a LiteRT-LM limitation. Gemma **4** has full native tool calling.

Detection is best-effort and based on the bundle filename. If a bundle is
renamed or its family isn't listed above, pass the template explicitly via
`ModelParams.chatTemplate`.

The registry is ordered most-specific-first, so `gemma-4` and `gemma-3n` are
matched before `gemma-3`, and `qwen3` before the generic `qwen` rule.

## Adding a model family

Templates are committed as jinja under `tool/litert_lm_templates/` and embedded
into `lib/src/backends/litert_lm/litert_lm_chat_templates.dart` by a generator.
You never hand-author a template — copy the canonical one llama.cpp uses.

1. Copy the canonical jinja into `tool/litert_lm_templates/<id>.jinja`
   (e.g. from `.dart_tool/llama_cpp/models/templates/` or the model's GGUF /
   Hugging Face `tokenizer_config.json`).
2. Add an entry to `_manifest` in `tool/gen_litert_lm_templates.dart`:
   - `id` / `jinja` — the identifier and source filename.
   - `familyMatches` — lower-cased filename substrings; place the entry above
     any broader family it could collide with.
   - `bosToken` / `eosToken` — exposed via `tokenizer.ggml.*` metadata.
   - `stripLeadingBosToken: true` if the template emits a leading `bos_token`.
3. Regenerate: `dart run tool/gen_litert_lm_templates.dart`.
4. Verify the family is detected as the intended `ChatFormat` and renders
   correctly (a render check plus an entry in
   `test/unit/backends/litert_lm/litert_lm_chat_templates_test.dart`). The
   existing handler renders and parses it — no handler changes are needed for
   families llamadart already supports.

### Known gaps

- **Phi-4** has no dedicated handler (falls back to generic) and no canonical
  jinja vendored, so it is not seeded.
- **TranslateGemma / FunctionGemma** have handlers but no vendored canonical
  jinja yet.

## Runtime behavior (beyond templating)

Two LiteRT-LM-specific behaviors complement the templates above; both live in
the backend, not the registry:

- **Thinking is reassembled from a channel stream.** The native runtime streams
  reasoning and the answer on separate channels — thought as
  `{"role":"assistant","channels":{"thought":"..."}}` and the answer as
  `{"role":"assistant","content":[{"type":"text",...}]}`. `LiteRtLmChannelAssembler`
  (in `litert_lm_runtime.dart`) wraps thought runs in the active handler's
  reasoning tags (`<|channel>thought … <channel|>` for Gemma 4, `<think>…</think>`
  for Qwen/Hermes) so chat-template handlers extract them as reasoning instead
  of leaking raw JSON.
- **Grammar-constrained decoding is skipped.** Grammar-using handlers (Hermes/Qwen)
  emit a GBNF grammar for tool calls, which the LiteRT-LM backend rejects.
  `NativeAutoBackend` forwards `supportsGrammarConstraints == false` from the
  active delegate, so the engine drops the grammar and tool calls are parsed
  best-effort from the model output. Gemma 4 emits no grammar, so it is
  unaffected.

> The web backend (`@litert-lm/core`) uses a separate response path and does not
> share this channel reassembly; web thinking remains limited/single-turn.

## Longer-term direction

The registry is a deliberate bridge, not the end state. Two "proper" endgames,
both larger changes, are worth tracking:

1. Read the embedded template straight from the `.litertlm` bundle once the FFI
   exposes a getter — mirroring how the llama.cpp path reads it from the GGUF.
2. Use LiteRT-LM's native conversation tool API
   (`litert_lm_conversation_config_set_tools` / `set_messages`, already exported
   by the shipped library) and let `Gemma4DataProcessor` format tools and parse
   tool calls — the approach the official SDKs and `flutter_gemma` take.
