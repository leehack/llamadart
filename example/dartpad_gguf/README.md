# GGUF in DartPad

[Open on preview.dartpad.dev](https://preview.dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
The link always opens the latest published llamadart.
The example is available starting in 0.20.7.

Run the Flutter preview and choose **Load** to download SmolLM2-135M-Instruct
Q4_K_M (about 106 MB). Enter a prompt or pick a preset, then choose **Send** to
stream a reply. Follow-up prompts use the conversation history. Choose **Clear**
to start a new conversation with the same model.

Open **Settings** to change temperature, maximum output tokens, or the system
prompt. The stats show the active backend and elapsed time while streaming,
then token count and throughput when available. **Stop** keeps the partial
reply, including text the runtime flushes as it finishes.

## Run locally in Chrome

From the repository root, generate Flutter's Web scaffolding locally:

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
unavailable. It can offload layers when a compatible WebGPU adapter is
available.

The first load needs access to jsDelivr and Hugging Face. Inference runs in the
browser. Browser Cache Storage can reuse a model download when available.
