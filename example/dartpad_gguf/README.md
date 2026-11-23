# GGUF in DartPad

[Open on preview.dartpad.dev](https://preview.dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
The link always opens the latest published llamadart.
The example is available starting in 0.20.7.

Run the Flutter preview and choose **Load** to download Stories15M MoE Q8_0
(39.4 MB). Enter a prompt and select **Generate** to stream a continuation.
**Stop** cancels generation and keeps the text already received.

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
the matching bridge module from Dart. It opts into the single-thread core
so the preview iframe can initialize Wasm without cross-origin isolation
(COOP/COEP). The bridge can offload layers when a compatible WebGPU adapter
is available.

The first load needs access to jsDelivr and Hugging Face. Inference runs in the
browser. Browser Cache Storage can reuse a model download when available.
