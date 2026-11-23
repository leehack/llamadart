# GGUF in DartPad

[Open on preview.dartpad.dev](https://preview.dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
The link always opens the latest published llamadart.
The example is available starting in 0.20.7.

Choose a model from the **Model** selector and select **Load** to download it:

- **SmolLM2 135M** (~105 MB, default) — fastest download for quick tests.
- **Qwen3.5 0.8B** (~533 MB) — stronger replies, with thinking disabled.
- **Gemma 4 E2B** (~3 GB, flagged in the UI with a pre-download warning) —
  higher quality; the download can take several minutes. Measured ~11 GB peak
  browser memory; requires desktop Chrome with WebAssembly `memory64` and
  16+ GB RAM recommended. Not supported on Safari or mobile browsers.

Switching models disposes the active engine, clears the conversation, and
requires choosing **Load** again. Enter a prompt or pick a preset, then choose
**Send** to stream a reply. Follow-up prompts use the conversation history.
Choose **Clear** to start a new conversation with the same model.

Open **Settings** to change temperature, maximum output tokens, or the system
prompt. The stats show the active backend and elapsed time while streaming,
then token count and throughput when available. **Stop** keeps the partial
reply, including text the runtime flushes as it finishes.

## Run locally in Chrome

Requires Flutter 3.47+ and Dart 3.13+ (for `material_ui`). From the repository
root, generate Flutter's Web scaffolding locally:

```sh
cd example/dartpad_gguf
flutter create --platforms=web --project-name dartpad_gguf_example --no-pub .
flutter pub get
flutter run -d chrome
```

## Browser requirements

Run in a secure context such as preview.dartpad.dev or localhost. The
[bootstrap](lib/bridge_bootstrap_web.dart) sets absolute CDN URLs and loads
the matching bridge module from Dart. The bridge automatically uses the
single-thread core in the preview iframe, where cross-origin isolation is
unavailable. On first load, the browser console logs an expected warning that
`llamadart` is using the single-thread GGUF core; for standalone deployments
with multi-threaded workers, configure COOP/COEP headers per
[Single-threaded GGUF without isolation](https://llamadart.leehack.com/docs/platforms/webgpu-bridge#single-threaded-gguf-without-isolation).
It can offload layers when a compatible WebGPU adapter is available.

The first load needs access to jsDelivr and Hugging Face. Inference runs in the
browser. Browser Cache Storage can reuse a model download when available;
Chromium Incognito and off-the-record profiles cap Cache Storage entries at
256 MiB, so larger models re-download on each load there.
