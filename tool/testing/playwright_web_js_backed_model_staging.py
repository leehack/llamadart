"""Compare staging modes through the public Dart engine in Chromium."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen

from playwright.sync_api import sync_playwright


BUILD = Path("build/web_js_backed_model_staging")
BRIDGE = "llama_webgpu_bridge.js"
WORKER = "llama_webgpu_bridge_worker.js"
LEGACY = {
    "v0.1.86": {
        BRIDGE: "c91d386f5b7a42c1a2d9ba9208203cea2e062bc494e98cfcccdfa398a2a2ba24",
        WORKER: "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
        "llama_webgpu_core.js": "fe21febf5ffe94ef1538d9530ab7b422ca21cd7a7631fab050af1abe122cc4af",
        "llama_webgpu_core.wasm": "02651671d474d99856c3ff131e61beae9c0dee0af113f4a6da32980501f93be4",
    },
    "v0.1.90": {
        BRIDGE: "afe2aa6317fc029d2fd4a337a8ca475843defca8db3d14705828fcd88108bf12",
    },
}
WEBKIT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
)
ISOLATION_HEADERS = {
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
}

# The loader imports the pinned bytes unchanged. Sample in the thread that
# owns the core so a worker's linear memory is never reported as page JS heap.
MEASURE_LOADER = """
export default async (config) => {
  const startedAt = performance.timeOrigin + performance.now();
  let memoryRef;
  const Memory = WebAssembly.Memory;
  WebAssembly.Memory = new Proxy(Memory, {
    construct(target, args, newTarget) {
      const instance = Reflect.construct(target, args, newTarget);
      memoryRef = new WeakRef(instance);
      return instance;
    },
  });
  let core;
  try {
    core = await createCore(config);
  } finally {
    WebAssembly.Memory = Memory;
  }
  const inWorker = typeof document === 'undefined';
  let peakWasmBytes = 0;
  let peakJsBytes = 0;
  const sample = () => {
    const current = memoryRef?.deref();
    if (!current) {
      clearInterval(timer);
      return;
    }
    const wasmBytes = current.buffer.byteLength;
    const jsBytes = globalThis.performance?.memory?.usedJSHeapSize ?? null;
    peakWasmBytes = Math.max(peakWasmBytes, wasmBytes);
    peakJsBytes = Math.max(peakJsBytes, jsBytes ?? 0);
    const memory = {
      scope: inWorker ? 'worker' : 'page',
      startedAt,
      wasmBytes, peakWasmBytes: peakWasmBytes || null,
      jsBytes, peakJsBytes: peakJsBytes || null,
    };
    if (inWorker) postMessage({type: 'stagingFixtureMemory', memory});
    else globalThis.recordStagingFixtureMemory(memory);
  };
  const timer = setInterval(sample, 50);
  sample();
  return core;
};
"""

BOOTSTRAP = """async ({
  worker, mem64, oldBridge, oldWorker, oldCore, forcedFetch, config,
}) => {
  const asset = (name) => new URL(name, location.href).href;
  const setup = await import(asset(`${oldBridge ?? 'bridge'}/llama_webgpu_bridge.js`));
  const workerDirectory = oldWorker ? 'v0.1.86' : 'bridge';
  const installCore = (key, suffix) => {
    const baseName = `llama_webgpu_core${suffix}`;
    const directory = oldCore ? 'v0.1.86' : 'bridge';
    const loader = oldCore ? `${directory}/${baseName}.js` : `${baseName}_measured.js`;
    window[`__llamadartBridgeCoreModuleUrl${key}`] = asset(loader);
    window[`__llamadartBridgeWasmUrl${key}`] = asset(`${directory}/${baseName}.wasm`);
  };
  installCore('', '');
  installCore('Mem64', '_mem64');
  window.__llamadartBridgeForceRemoteFetchBackend = forcedFetch;
  window.__llamadartBridgeWorkerUrl = asset(`${workerDirectory}/llama_webgpu_bridge_worker.js`);

  let constructions = 0;
  let loads = 0;
  let latestCoreMemory = null;
  let peakWasmBytes = 0;
  const recordMemory = (memory) => {
    // A retired core can still be sampled until its memory is collected.
    if (!latestCoreMemory || memory.startedAt >= latestCoreMemory.startedAt) {
      latestCoreMemory = memory;
    }
    peakWasmBytes = Math.max(peakWasmBytes, memory.peakWasmBytes);
  };
  window.recordStagingFixtureMemory = recordMemory;
  const NativeWorker = window.Worker;
  window.Worker = class extends NativeWorker {
    constructor(url, options) {
      super(url, options);
      this.addEventListener('message', ({data}) => {
        if (data?.type === 'stagingFixtureMemory') {
          recordMemory(data.memory);
        }
      });
    }
  };
  window.LlamaWebGpuBridge = class extends setup.LlamaWebGpuBridge {
    constructor(config) {
      super({...config, disableWorker: !worker});
      constructions++;
    }
    loadModelFromUrl(...args) {
      loads++;
      return super.loadModelFromUrl(...args);
    }
  };

  let pageJsPeak = null;
  const sampleJs = () => {
    const bytes = performance.memory?.usedJSHeapSize;
    if (bytes != null) pageJsPeak = Math.max(pageJsPeak ?? 0, bytes);
  };
  sampleJs();
  const timer = setInterval(sampleJs, 50);
  try {
    const result = JSON.parse(await window.runJsBackedModelStaging({
      ...config, preferMemory64: mem64,
    }));
    sampleJs();
    let adapter = null;
    if (config.gpu) {
      const gpu = await navigator.gpu?.requestAdapter();
      const info = gpu?.info;
      if (info) {
        adapter = {
          vendor: info.vendor, device: info.device, description: info.description,
          isFallbackAdapter: info.isFallbackAdapter,
        };
      }
    }
    return {
      ...result, adapter, constructions, loads,
      coreMemory: latestCoreMemory && {...latestCoreMemory, peakWasmBytes},
      pageJsPeak, pageJsBytes: performance.memory?.usedJSHeapSize ?? null,
    };
  } finally {
    clearInterval(timer);
  }
}"""


def prepare_legacy_assets():
    for tag, files in LEGACY.items():
        directory = BUILD / tag
        directory.mkdir(parents=True, exist_ok=True)
        for name, expected in files.items():
            target = directory / name
            if target.is_file() and sha256(target) == expected:
                continue
            url = f"https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@{tag}/{name}"
            with urlopen(url, timeout=120) as response:
                data = response.read()
            assert hashlib.sha256(data).hexdigest() == expected, f"{tag}/{name}"
            target.write_bytes(data)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def asset_receipt(origin, url):
    if urlsplit(url).netloc != urlsplit(origin).netloc:
        return None
    root = Path.cwd()
    path = (root / unquote(urlsplit(url).path).lstrip("/")).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        return None
    return {"bytes": path.stat().st_size, "sha256": sha256(path)}


def setup_measurement_loaders():
    for suffix in ("", "_mem64"):
        name = f"llama_webgpu_core{suffix}"
        (BUILD / f"{name}_measured.js").write_text(
            f"import createCore from './bridge/{name}.js';\n{MEASURE_LOADER}",
            encoding="utf-8",
        )


def assert_success(result, *, worker, mem64, staged, projector=False,
                   gpu=False):
    assert result.get("output", "").strip(), result
    assert result["execution"] == ("worker" if worker else "main-thread"), result
    assert not result.get("worker_fallback_reason"), result
    assert result["core_variant"] == ("wasm64" if mem64 else "wasm32"), result
    notes = result["runtime_notes"].split(";")
    assert ("model_staging_js_backed" in notes) == staged, result
    assert ("mmproj_staging_js_backed" in notes) == (staged and projector), result
    assert result["mmproj_loaded"] == ("1" if projector else "0"), result
    if gpu:
        assert "WebGPU" in result["backends"], result


def run_case(browser, origin, model_url, *, name, worker, stage=None, mem64=False,
             webkit=False, old_bridge=None, old_worker=False,
             old_core=False, forced_fetch=False, mmproj_url=None,
             reuse=False, gpu=False, extra_control=False):
    fixture = f"{origin}/{BUILD.as_posix()}/probe.html"
    context = browser.new_context(user_agent=WEBKIT_UA if webkit else None)
    requests = []
    context.on("request", lambda request: requests.append(request.method)
               if request.url == model_url else None)
    page = context.new_page()
    page.route(fixture, lambda route: route.fulfill(
        content_type="text/html",
        headers=ISOLATION_HEADERS,
        body='<script src="js_backed_model_staging.js"></script>',
    ))
    try:
        page.goto(fixture)
        assert page.evaluate("crossOriginIsolated")
        result = page.evaluate(BOOTSTRAP, {
            "worker": worker, "mem64": mem64,
            "oldBridge": old_bridge, "oldWorker": old_worker, "oldCore": old_core,
            "forcedFetch": forced_fetch, "config": {
                "modelUrl": model_url, "jsBackedModelStaging": stage,
                "mmprojUrl": mmproj_url, "gpu": gpu, "reuse": reuse,
            },
        })
        print(json.dumps({
            "case": name, "worker": worker, "memory64": mem64,
            "staging": stage, "model_requests": requests, "result": result,
        }), flush=True)
        if old_bridge or (old_worker and stage is True) or old_core or forced_fetch:
            reason = ("__llamadartBridgeForceRemoteFetchBackend" if forced_fetch
                      else "MODEL_STAGING_UNSUPPORTED" if old_worker or old_core
                      else "v0.1.92+")
            assert reason in result.get("unsupported", ""), result
            assert not requests, requests
            assert result["constructions"] == (0 if old_bridge or forced_fetch else 1)
            assert result["loads"] == (0 if old_bridge or forced_fetch else 1)
            return None
        if extra_control and "model_error" in result:
            return result
        # A large GGUF can exhaust standard wasm32 staging and succeed on
        # the backend's wasm64 retry. Explicit staging must use its requested core.
        control_retried_on_wasm64 = (
            extra_control and not mem64 and result.get("core_variant") == "wasm64"
        )
        expect = dict(worker=worker, mem64=mem64 or control_retried_on_wasm64,
                      staged=stage is True or
                      (stage is None and webkit), projector=mmproj_url is not None,
                      gpu=gpu)
        assert_success(result, **expect)
        memory = result["coreMemory"]
        assert memory and memory["scope"] == ("worker" if worker else "page"), result
        assert memory["peakWasmBytes"] >= memory["wasmBytes"] > 0, result
        if reuse:
            reloaded = result["reloaded"]
            assert_success(reloaded, **expect)
            assert reloaded["output"] == result["output"], result
        return result
    finally:
        context.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("origin")
    parser.add_argument("--model-url")
    parser.add_argument("--mmproj-url")
    parser.add_argument("--gpu", action="store_true")
    args = parser.parse_args()
    if args.mmproj_url and not args.model_url:
        parser.error("--mmproj-url requires its compatible --model-url")
    origin = args.origin.rstrip("/")
    local_model = BUILD / "model.gguf"
    model = f"{origin}/{local_model.as_posix()}"
    if not local_model.is_file():
        parser.error(f"stage the Stories15M GGUF at {local_model}")
    prepare_legacy_assets()
    setup_measurement_loaders()

    launch = ["--enable-unsafe-webgpu", "--enable-precise-memory-info"]
    if platform.system() == "Darwin":
        launch.append("--use-angle=metal")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chromium", args=launch)
        try:
            print(json.dumps({
                "browser": browser.version, "host": platform.platform(),
                "processor": platform.machine(), "gpu_required": args.gpu,
                "model": asset_receipt(origin, model),
                "extra_model": asset_receipt(origin, args.model_url) if args.model_url else None,
                "projector": asset_receipt(origin, args.mmproj_url) if args.mmproj_url else None,
            }), flush=True)
            for worker in (False, True):
                for mem64 in (False, True):
                    common = dict(worker=worker, mem64=mem64, gpu=args.gpu)
                    control = run_case(browser, origin, model, name="chromium-default", **common)
                    staged = run_case(browser, origin, model, name="explicit-on",
                                      stage=True, reuse=True, **common)
                    assert staged["output"] == control["output"], (staged, control)
                    for stage in (None, False):
                        run_case(browser, origin, model, name="webkit-ua-control",
                                 stage=stage, webkit=True, worker=worker, mem64=mem64)
                    if args.model_url:
                        extra = dict(mmproj_url=args.mmproj_url, **common)
                        baseline = run_case(browser, origin, args.model_url,
                                            name="extra-default", extra_control=True, **extra)
                        staged = run_case(browser, origin, args.model_url,
                                          name="extra-staged", stage=True, reuse=True, **extra)
                        if "output" in baseline:
                            assert staged["output"] == baseline["output"], (staged, baseline)
                for old_bridge in LEGACY:
                    run_case(browser, origin, model, name=f"old-bridge-{old_bridge}",
                             stage=True, old_bridge=old_bridge, worker=worker)
                run_case(browser, origin, model, name="forced-fetch",
                         stage=True, forced_fetch=True, worker=worker)
                run_case(browser, origin, model, name="old-core",
                         stage=True, old_core=True, worker=worker)
            run_case(browser, origin, model, name="old-worker",
                     stage=True, old_worker=True, worker=True)
            run_case(browser, origin, model, name="old-worker-opt-out",
                     stage=False, old_worker=True, worker=True)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
