"""Exercise the public Dart GGUF load path in a real Chromium page."""

import argparse
import json
import platform
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


def run_case(browser, origin, model_url, *, worker, isolated=False,
             opt_in=True, mem64=False, legacy=False, forced_fetch=False, gpu=False,
             allow_wasm64_retry=False):
    legacy_assets_url = (
        Path("test/e2e/webgpu/fixtures/single_thread_legacy_assets_url.txt")
        .read_text(encoding="utf-8")
        .strip()
        if legacy
        else None
    )
    page = browser.new_page()
    wasm_files = []

    def track_wasm(request):
        if request.url.startswith(f"{origin}/build/web_single_thread_core/bridge/"):
            name = Path(urlsplit(request.url).path).name
            if name.endswith(".wasm"):
                wasm_files.append(name)

    page.context.on("request", track_wasm)
    # Only the isolated control receives COOP/COEP on its document.
    headers = {
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
    } if isolated else {}
    fixture = f"{origin}/build/web_single_thread_core/"
    page.route(
        f"{fixture}probe.html",
        lambda route: route.fulfill(
            content_type="text/html",
            headers=headers,
            body='<script src="single_thread_core.js"></script>',
        ),
    )
    try:
        page.goto(f"{fixture}probe.html")
        assert page.evaluate("crossOriginIsolated") == isolated
        assert page.evaluate("typeof SharedArrayBuffer === 'function'") == isolated
        result = json.loads(page.evaluate(
            """async ({ worker, optIn, mem64, legacyAssetsUrl, forcedFetch, gpu, modelUrl }) => {
              const base = legacyAssetsUrl ?? new URL('bridge/', location.href).href;
              const asset = (file) => new URL(file, base).href;
              const {LlamaWebGpuBridge} = await import(asset('llama_webgpu_bridge.js'));
              window.LlamaWebGpuBridge = class extends LlamaWebGpuBridge {
                constructor(config) {
                  super({ ...config, disableWorker: !worker });
                }
              };
              window.__llamadartBridgeAllowSingleThreadCore = optIn;
              window.__llamadartBridgeAllowAutoRemoteFetchBackend = true;
              window.__llamadartBridgeForceRemoteFetchBackend = forcedFetch;
              window.__llamadartBridgeWorkerUrl = asset('llama_webgpu_bridge_worker.js');
              window.__llamadartBridgeCoreModuleUrl = asset('llama_webgpu_core.js');
              window.__llamadartBridgeWasmUrl = asset('llama_webgpu_core.wasm');
              window.__llamadartBridgeCoreModuleUrlMem64 = asset('llama_webgpu_core_mem64.js');
              window.__llamadartBridgeWasmUrlMem64 = asset('llama_webgpu_core_mem64.wasm');
              if (!legacyAssetsUrl) {
                window.__llamadartBridgeCoreModuleUrlSt = asset('llama_webgpu_core_st.js');
                window.__llamadartBridgeWasmUrlSt = asset('llama_webgpu_core_st.wasm');
                window.__llamadartBridgeCoreModuleUrlMem64St = asset('llama_webgpu_core_mem64_st.js');
                window.__llamadartBridgeWasmUrlMem64St = asset('llama_webgpu_core_mem64_st.wasm');
              }
              return window.runSingleThreadCore(modelUrl, mem64, gpu);
            }""",
            dict(worker=worker, optIn=opt_in, mem64=mem64, legacyAssetsUrl=legacy_assets_url,
                 forcedFetch=forced_fetch, gpu=gpu, modelUrl=model_url),
        ))
        print(json.dumps(dict(
            worker=worker, isolated=isolated, opt_in=opt_in, mem64=mem64,
            legacy=legacy, forced_fetch=forced_fetch, gpu=gpu, wasm_files=wasm_files, result=result,
        )), flush=True)
        if legacy or not opt_in or (forced_fetch and not isolated):
            assert "unsupported" in result, result
            detail = result["unsupported"]
            expected = "v0.1.87" if legacy else (
                "COOP/COEP" if not opt_in else "fetch-backed"
            )
            assert expected in detail, result
            return

        assert result.get("output", "").strip(), result
        assert result["execution"] == ("worker" if worker else "main-thread"), result
        assert not result.get("worker_fallback_reason"), result
        expected_core = "wasm64" if mem64 else "wasm32"
        if allow_wasm64_retry and not mem64 and result["core_variant"] == "wasm64":
            assert wasm_files == [
                "llama_webgpu_core_st.wasm",
                "llama_webgpu_core_mem64_st.wasm",
            ], wasm_files
        else:
            assert result["core_variant"] == expected_core, result
        notes = result["runtime_notes"].split(";")
        if isolated:
            assert "core_pthreads:1" in notes, result
            assert "core_single_thread" not in notes, result
            if forced_fetch:
                assert "model_fetch_backend_attempt" in notes, result
                assert result["model_source"] == "network-fetch", result
        else:
            assert "core_pthreads:0" in notes and "core_single_thread" in notes, result
            assert result["n_threads"] == result["n_threads_batch"] == "1", result
            assert "model_fetch_backend_attempt" not in notes, result
        if gpu:
            assert "WebGPU" in result["backends"], result
    finally:
        page.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("origin")
    parser.add_argument("--model-url")
    parser.add_argument("--gpu", action="store_true")
    args = parser.parse_args()
    origin = args.origin.rstrip("/")
    fixture_url = f"{origin}/build/web_single_thread_core/model.gguf"
    local_model = Path("build/web_single_thread_core/model.gguf")
    if not local_model.is_file():
        parser.error(f"stage the Stories15M GGUF at {local_model} before running the scenario")

    launch_args = ["--enable-unsafe-webgpu", "--disable-dev-shm-usage"]
    if platform.system() == "Darwin":
        launch_args.append("--use-angle=metal")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chromium", args=launch_args)
        try:
            print(json.dumps(dict(browser=browser.version, bytes=local_model.stat().st_size)))
            for worker in [False, True]:
                run_case(browser, origin, fixture_url, worker=worker, opt_in=False)
                run_case(browser, origin, fixture_url, worker=worker, legacy=True)
                run_case(browser, origin, fixture_url, worker=worker, forced_fetch=True)
                run_case(browser, origin, fixture_url, worker=worker, isolated=True,
                         forced_fetch=worker)
                for mem64 in [False, True]:
                    run_case(browser, origin, fixture_url, worker=worker, mem64=mem64, gpu=args.gpu)
            if args.model_url:
                for mem64 in [False, True]:
                    run_case(browser, origin, args.model_url, worker=True, mem64=mem64,
                             allow_wasm64_retry=True)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
