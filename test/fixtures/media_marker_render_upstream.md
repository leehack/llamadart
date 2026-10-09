# Media marker render reference

`media_marker_render_upstream.json` holds the prompts that an unmodified
`llama-server`, built from llama.cpp `d81235049` (tag `v0.6.0`, the pinned
native runtime), returned from `POST /apply-template` for conversations with
image and audio parts. It pins
[#964](https://github.com/leehack/llamadart/issues/964): llama-server gives a
chat template the media marker in the message text, where the image or audio
part was, and never the part itself. A template's own image placeholder
(`<|vision_start|><|image_pad|><|vision_end|>` in Qwen3.5, `<start_of_image>`
in Gemma 3, `<|image|>` in Gemma 4) is therefore not in the prompt, and mtmd
adds the image begin and end tokens when it tokenizes the marker.

`conversations` holds each conversation as ordered `parts` (`text`, `image`
or `audio`), the form the test builds typed `LlamaChatMessage`s from. The
request sent each image as an `image_url` part carrying `image_png_base64` and
each audio part as an `input_audio` part carrying `audio_wav_base64` (0.1 s of
16 kHz silence), and a message with a single text part as string content.

For each template the server ran with
`--jinja --chat-template-file <template> -c 1024 -t 2 -ngl 0 --mmproj <mmproj> --no-mmproj-offload --no-warmup -np 1`
and `LLAMA_MEDIA_MARKER='<__media__>'`, which replaces the random marker
llama-server prints by default. The prompt comes from the fixture template,
not from the GGUF, so the model only supplies the projector that lets the
server accept the media part, and its `eos_token`:

- `media_model: vision` cases ran on `vision_model` and `vision_mmproj` from
  [LiquidAI/LFM2-VL-450M-GGUF](https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF).
- `media_model: audio` cases ran on `audio_model` and `audio_mmproj` from
  [ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF](https://huggingface.co/ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF).

llama-server returned the prompts without the template's leading `bos_token`.
`template_sha256` is the template's hash, and `supports_string_content` and
`supports_typed_content` are the `chat_template_caps` that `/props` reported.
SmolVLM is the template that reads content only as a part list; the others
read strings too.

`test/unit/core/template/media_marker_render_parity_test.dart` renders each
conversation through `ChatTemplateEngine.render` with `bos_token` empty and
the case's `eos_token`, and expects the exact prompt.
