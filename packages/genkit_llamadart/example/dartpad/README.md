# Genkit model playground

[Open in DartPad Preview](https://preview.dartpad.dev/?package=genkit_llamadart&root=example/dartpad&file=example/dartpad/lib/main.dart).
The link loads the latest published adapter. The original playground shipped
in genkit_llamadart 3.10.0.

| Option | Model | Requirements |
| --- | --- | --- |
| GGUF | SmolLM2 135M (~105 MB, default), Qwen3.5 0.8B (~533 MB), or Gemma 4 E2B (~3 GB) | llamadart 0.20.7 or newer. Gemma 4 E2B can take several minutes to download and requires desktop Chrome with WebAssembly `memory64`. Safari and mobile browsers are unsupported for this GGUF. |
| LiteRT-LM | Qwen3 0.6B (~343 MB, default) or Gemma 4 E2B (~2 GB) | Desktop Chrome with WebGPU. Gemma 4 E2B reached ~3 GB peak browser memory on desktop Chrome and ~7 GB on Safari. Keep the Safari tab visible while loading. Reloading the page or switching back to the model re-downloads the file. |
| Gemini | Gemini 3.1 Flash-Lite | A Gemini API key and access to Google's API. Prompts are sent to Google. |

The lower memory usage needs bridge assets v0.1.94+ and automatic staging.
Gemma 4 E2B Q4_K_S used ~3.5 GiB steady and ~4–6 GiB peak browser RSS in
Chrome 158 on Apple silicon macOS. Usage varies by device and can be higher
on older runtimes.

Choose a model and select **Load** or **Connect**. Switching GGUF or LiteRT-LM
models unloads the current runtime, clears the chat and stats, and waits for
**Load**.
Enter a prompt or tap a preset, then select **Send**. **Stop** cancels the
request and keeps the text already streamed. **Clear** resets the chat and
per-turn stats.

GGUF and Gemini send the conversation history with each turn. To fit GGUF's
2,048-token context window, long local chats automatically trim the oldest turns
forwarded while keeping the full transcript visible on screen. LiteRT-LM Web
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
core automatically, and the one-time browser console warning about using the
single-thread core is expected. Standalone deployments can serve COOP/COEP
headers for the threaded core; see
[Single-threaded GGUF without isolation](https://llamadart.leehack.com/docs/platforms/webgpu-bridge#single-threaded-gguf-without-isolation).

## Run locally in Chrome

Requires **Flutter 3.47+ / Dart 3.13+** (for `material_ui`). From the repository
root, generate the Flutter Web files in the example:

```sh
cd packages/genkit_llamadart/example/dartpad
flutter create --platforms=web --project-name genkit_llamadart_dartpad_example --no-pub .
flutter pub get
flutter run -d chrome
```
