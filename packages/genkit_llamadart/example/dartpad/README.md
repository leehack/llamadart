# Genkit model playground

[Open in DartPad Preview](https://preview.dartpad.dev/?package=genkit_llamadart&root=example/dartpad&file=example/dartpad/lib/main.dart).
The link loads the latest published adapter. The original playground shipped
in genkit_llamadart 3.10.0.

| Option | Model | Requirements |
| --- | --- | --- |
| GGUF | SmolLM2-135M-Instruct Q4_K_M (about 106 MB) | llamadart 0.20.7 or newer. Runs in the browser. |
| LiteRT-LM | Qwen3-0.6B dynamic INT4 (about 343 MB) | Chrome with WebGPU. Runs in the browser. |
| Gemini | Gemini 3.1 Flash-Lite | A Gemini API key and access to Google's API. Prompts are sent to Google. |

Choose a model and select **Load** or **Connect**. Enter a prompt or tap a
preset, then select **Send**. **Stop** cancels the request and keeps the text
already streamed. **Clear** resets the chat and per-turn stats.

GGUF and Gemini send the conversation history with each turn. LiteRT-LM Web
currently runs single-turn: the transcript remains visible, and each request
uses only the current prompt. **Settings** lets you change temperature and max
tokens and edit the system prompt when the loaded runtime supports it.

The stats show the runtime label and elapsed time while streaming. When the
provider reports token usage, completed replies show the output token count
and throughput. LiteRT-LM Web shows elapsed time.

Gemini checks the key on the first request. The example keeps it in memory
for the active connection and clears the input after **Connect**.

The first local model load needs access to jsDelivr and Hugging Face. Run in a
secure context such as DartPad Preview or localhost. In preview iframes
without cross-origin isolation, the GGUF bridge selects the single-thread
core automatically.

## Run locally in Chrome

From the repository root, generate the Flutter Web files in the example:

```sh
cd packages/genkit_llamadart/example/dartpad
flutter create --platforms=web --project-name genkit_llamadart_dartpad_example --no-pub .
flutter pub get
flutter run -d chrome
```
