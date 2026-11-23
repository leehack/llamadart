# Genkit model playground

[Open in DartPad Preview](https://preview.dartpad.dev/?package=genkit_llamadart&root=example/dartpad&file=example/dartpad/lib/main.dart).
The link loads the latest published adapter. The example is available starting
in genkit_llamadart 3.10.0.

| Option | Model | Requirements |
| --- | --- | --- |
| GGUF | SmolLM2-135M-Instruct Q4_K_M (about 106 MB) | llamadart 0.20.7 or newer in DartPad. Runs in the browser. |
| LiteRT-LM | Qwen3-0.6B dynamic INT4 (about 343 MB) | llamadart 0.20.6 or newer and Chrome with WebGPU. Runs in the browser. |
| Gemini | Gemini 3.1 Flash-Lite | A Gemini API key and access to Google's API. Prompts are sent to Google. |

Choose a model and select **Load** or **Connect**. Enter a prompt and select
**Generate**. **Stop** cancels the request and keeps the text already streamed.
Gemini checks the key on the first request. The example keeps it in memory
for the active connection and clears the input after **Connect**.

The first local model load needs access to jsDelivr and Hugging Face. Run in a
secure context such as DartPad Preview or localhost.

## Run locally in Chrome

From the repository root, generate the Flutter Web files in the example:

```sh
cd packages/genkit_llamadart/example/dartpad
flutter create --platforms=web --project-name genkit_llamadart_dartpad_example --no-pub .
flutter pub get
flutter run -d chrome
```
