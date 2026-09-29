---
name: llamadart-web
description: >-
  Use when running llamadart in a browser or Flutter Web app: adding and
  pinning the WebGPU bridge assets in web/index.html, setting COOP/COEP
  cross-origin isolation headers, loading GGUF models by URL with WebGPU or
  WebAssembly CPU fallback, sizing models for memory64, browser model caching,
  running .litertlm models through @litert-lm/core, or gating web features on
  capability probes and bridge asset versions.
---

# llamadart on the web

On the web, GGUF models run through an app-loaded JavaScript bridge that wraps
llama.cpp (WebGPU, or WebAssembly CPU), and `.litertlm` models run through
`@litert-lm/core`. The web runtime is experimental. Loading and chat basics are
in the llamadart-getting-started and llamadart-chat-streaming skills.

## Guidelines

- llamadart never injects the bridge. Load it in `web/index.html` before
  `flutter_bootstrap.js` (or your compiled script) and assign
  `window.LlamaWebGpuBridge`. At model load llamadart waits up to 12 seconds
  for it, stopping early if `window.__llamadartBridgeLoadError` is set, then
  throws `LlamaUnsupportedException` with `Web bridge is unavailable...`.
- Serve the bridge assets from the app origin (for example
  `web/webgpu_bridge/`), pinned to one tag of
  `leehack/llama-web-bridge-assets`. A cross-origin isolated page cannot start
  the core's worker threads from a CDN URL, so hosted builds must ship the
  core `.js`/`.wasm` files locally even if the bridge module comes from a CDN.
  Do not track a moving tag in production.
- Set `window.__llamadartBridgeCoreModuleUrlMem64` to the local
  `llama_webgpu_core_mem64.js`; without it only the 32-bit core (4 GiB address
  space, shared with the KV cache) loads.
- Serve from a secure context (`https://`, `http://localhost` or
  `http://127.0.0.1`) and send `Cross-Origin-Opener-Policy: same-origin` with
  `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`). Without
  isolation (`window.crossOriginIsolated == false`) the bridge caps inference
  at one thread (`threads_capped_no_coi` in its notes) and large single-file
  GGUF loads become unreliable.
- Treat WebGPU as a runtime capability. A supported browser (Chrome/Edge 128+,
  Firefox 129+, Safari 17.4+) can still lack an adapter, features or memory.
  Prove a first load with a small quantized GGUF, `contextSize: 2048` or less
  and `gpuLayers: 0`, then raise GPU offload.
- Expect automatic fallback: a failed GPU load retries on CPU, then at smaller
  context sizes, then on the other core (wasm32/wasm64) for memory-pressure
  failures. Safari with assets that lack the adaptive GPU probe is forced to
  CPU. Log `engine.getBackendName()` after load; do not assume GPU ran.
- Models, projectors, draft models, LoRA adapters and n-gram caches are URLs
  on the web. `loadModelSource` with a local path throws
  `LlamaUnsupportedException`, as do `ModelLoadOptions` that need the native
  download manager: bearer tokens or headers, `sha256`, `cancelToken`,
  `cacheDirectory`, `resume: false`, or a cache policy other than
  `preferCached`. The model URL must be fetchable from the page (CORS).
- Models are cached in browser Cache Storage keyed by URL, subject to quota and
  private-mode policy. URLs with userinfo, a fragment, or credential-like query
  keys (`token`, `sig`, `key`, `X-Amz-*`, ...) are loaded without a persistent
  cache entry. Projector loads do not use the model cache.
- Pass `ModelParams.modelBytesHint` (web-only) when the size is known: at 2 GiB
  or more llamadart picks the memory64 core up front instead of retrying after
  an out-of-memory failure. `preferMemory64: true`/`false` forces the choice.
- Gate optional features on probes, not on the browser or the asset tag:
  - `await engine.backendGenerationCapabilities` for `presencePenalty`, `minP`,
    `thinkingBudget` and `speculativeDecodingStrategies` (bridge `v0.1.54+`).
    Unreported controls throw `LlamaUnsupportedException`.
  - `engine.supportsNextTokenScoring` (bridge `v0.1.52+`) and
    `engine.supportsStatePersistence` (bridge `v0.1.15+`).
  - Runtime LoRA calls, and loads with `ModelParams.loras`, throw
    `LlamaUnsupportedException` unless the assets report LoRA support
    (`v0.1.54+`).
  - Other floors: embeddings `v0.1.7+`, decision models `v0.1.47+`, per-request
    `usage` `v0.1.54+`, Qwen3-ASR `v0.1.30+` (also needs
    `window.__llamadartBridgeSpeechToTextSupported = true`), Qwen3-TTS
    `v0.1.33+` on memory64.
- WebGPU grammar applies from the first token at `root`: `grammarLazy` or
  another `grammarRoot` throws `LlamaUnsupportedException`. State files live in
  the bridge's WASMFS and are lost on reload; `getPerformanceContext()` returns
  null.
- LiteRT-LM on the web: preload `@litert-lm/core` and set
  `window.LiteRtLmEngine = module.Engine`, or set
  `window.__llamadartLiteRtLmModuleUrl` to its module URL. Otherwise the load
  throws `LlamaModelException` whose details say `LiteRT-LM web runtime is not
  loaded`. It needs a `.litertlm` URL and supports CPU or GPU (NPU is
  rejected); any other `ModelParams` field, such as `batchSize`, throws
  `LlamaUnsupportedException`.
- LiteRT-LM web is single-turn text only: it sends only the last message's
  text, so `ChatSession` history, system prompts and tools are not forwarded.
  It rejects media parts, grammar, `penalty`, `minP`, `presencePenalty`,
  `thinkingBudget` and speculative decoding; generation honors only
  `maxTokens`, `temp`, `topK`, `topP`, `seed` and `stopSequences`. It has no
  embeddings, tokenizer, LoRA, state or usage. Use GGUF for anything more.
- `flutter build web` only copies what is in `web/`: fetch or commit
  `web/webgpu_bridge/` before building, and set the COOP/COEP headers on the
  production host too, not only on the dev server.

## Examples

Fetch pinned assets:

```bash
TAG=vX.Y.Z # the tag pinned in the WebGPU bridge docs for your llamadart version
mkdir -p web/webgpu_bridge
for f in llama_webgpu_bridge.js llama_webgpu_bridge_worker.js \
         llama_webgpu_core.js llama_webgpu_core.wasm \
         llama_webgpu_core_mem64.js llama_webgpu_core_mem64.wasm; do
  curl -fL -o "web/webgpu_bridge/$f" \
    "https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@$TAG/$f"
done
```

Load the bridge (and optionally LiteRT-LM) in `web/index.html`:

```html
<script type="module">
  try {
    const base = new URL('webgpu_bridge/', document.baseURI);
    window.__llamadartBridgeCoreModuleUrlMem64 =
      new URL('llama_webgpu_core_mem64.js', base).href;
    const mod = await import(new URL('llama_webgpu_bridge.js', base).href);
    window.__llamadartBridgeAdaptiveSafariGpu =
      mod.LlamaWebGpuBridge.supportsSafariAdaptiveGpu === true;
    window.LlamaWebGpuBridge = mod.LlamaWebGpuBridge;
  } catch (error) {
    window.__llamadartBridgeLoadError = String(error);
  }
  window.__llamadartLiteRtLmModuleUrl =
    'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.15.0/+esm';
</script>
<script src="flutter_bootstrap.js" async></script>
```

Load a GGUF by URL and pick sampling options from the capability probe:

```dart
import 'package:llamadart/llamadart.dart';

Future<LlamaEngine> loadWebModel(String modelUrl, int modelBytes) async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModelSource(
      ModelSource.parse(modelUrl),
      modelParams: ModelParams(contextSize: 2048, modelBytesHint: modelBytes),
      onProgress: (ModelDownloadProgress progress) {
        final double? fraction = progress.fraction;
        if (fraction != null) print('Loading ${(fraction * 100).round()}%');
      },
    );
  } on LlamaUnsupportedException catch (error) {
    await engine.dispose();
    print('Web runtime unavailable: ${error.message}');
    rethrow;
  }
  print('Runtime: ${await engine.getBackendName()}');
  return engine;
}

Future<GenerationParams> webSamplingParams(LlamaEngine engine) async {
  final BackendGenerationCapabilities caps =
      await engine.backendGenerationCapabilities;
  return GenerationParams(
    maxTokens: 256,
    minP: caps.minP ? 0.05 : 0.0,
    presencePenalty: caps.presencePenalty ? 0.5 : 0.0,
  );
}
```

Single-turn prompt on LiteRT-LM web with only supported parameters:

```dart
import 'package:llamadart/llamadart.dart';

Future<String> askLiteRtLmWeb(LlamaEngine engine, String prompt) async {
  final StringBuffer answer = StringBuffer();
  await for (final LlamaCompletionChunk chunk in engine.create(
    [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt)],
    params: const GenerationParams(maxTokens: 256, temp: 0.7, topK: 40),
  )) {
    final String? text = chunk.choices.first.delta.content;
    if (text != null) answer.write(text);
  }
  return answer.toString();
}
```

## More

- WebGPU bridge: https://llamadart.leehack.com/docs/platforms/webgpu-bridge
- Support matrix: https://llamadart.leehack.com/docs/platforms/support-matrix
- llama.cpp or LiteRT-LM: https://llamadart.leehack.com/docs/guides/backend-selection
- Troubleshooting (web): https://llamadart.leehack.com/docs/troubleshooting/common-issues
