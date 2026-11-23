# GGUF in DartPad

[Open in DartPad](https://dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
with llamadart 0.20.7 or later. Run the Flutter preview, choose **Load** to
download the model, then select **Run** to generate. **Stop** cancels generation
and keeps the text already received.

- **Stories15M** (39.4 MB) continues a prompt through `LlamaEngine.generate`.
- **SmolLM2 135M Instruct** (105.5 MB) answers a single chat turn through
  `LlamaEngine.create`.

Both presets use a pinned GGUF download. The runtime panel below **Load**
shows the backend, Wasm variant, execution mode, and threading after the
model loads.

## Run locally in Chrome

From the repository root, generate Flutter's Web scaffolding locally:

```sh
cd example/dartpad_gguf
flutter create --platforms=web --project-name dartpad_gguf_example --no-pub .
flutter pub get
flutter run -d chrome
```

## Browser requirements

Run in a secure context such as DartPad (HTTPS) or localhost. The
[bootstrap](lib/bridge_bootstrap_web.dart) sets absolute CDN URLs and loads
the matching bridge module from Dart. It opts into the single-thread core
so the DartPad iframe can initialize Wasm without cross-origin isolation
(COOP/COEP). The bridge can offload layers when a compatible WebGPU adapter
is available. Check the backend shown after loading to see which mode is active.

The first load needs access to jsDelivr and Hugging Face. Inference runs in the
browser. Browser Cache Storage can reuse a model download when available.
