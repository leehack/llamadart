"""Exercise the public Dart GGUF load path in a real Chromium page."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


LEGACY_ASSETS_URL_FILE = Path("test/e2e/webgpu/fixtures/single_thread_legacy_assets_url.txt")
LEGACY_BRIDGE_DIGESTS = {
    "llama_webgpu_bridge.js": "c91d386f5b7a42c1a2d9ba9208203cea2e062bc494e98cfcccdfa398a2a2ba24",
    "llama_webgpu_bridge_worker.js": "47bbfa0fe897e708455b9497e9aa41d2e94489c329300c33b12936fb3169deca",
}


def run_case(browser, origin, model_url, *, worker, isolated=False,
             opt_in=True, mem64=False, legacy=False, forced_fetch=False, gpu=False,
             allow_wasm64_retry=False):
    legacy_assets_url = (
        LEGACY_ASSETS_URL_FILE.read_text(encoding="utf-8").strip()
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
            expected = "v0.1.93+" if legacy else (
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
            preflight_variant = "memory64" if result["core_variant"] == "wasm64" else "wasm32"
            assert f"core_preflight_variant:{preflight_variant}" in notes, result
            assert "core_preflight_threading:single-thread" in notes, result
            assert result["n_threads"] == result["n_threads_batch"] == "1", result
            assert "model_fetch_backend_attempt" not in notes, result
        if gpu:
            assert "WebGPU" in result["backends"], result
    finally:
        page.close()


def run_bootstrap_case(browser, fixture, model_url, *, worker, case):
    base = f"{fixture}bootstrap/"
    assets_root = Path("build/web_single_thread_core/bridge")
    page = browser.new_page()
    responses = []
    legacy_assets = {}
    missing_asset = {
        "adjacent-wasm-404": "llama_webgpu_core_st.wasm",
        "mem64-unused-wasm32": "llama_webgpu_core_st.wasm",
        "loader-404": "llama_webgpu_core_st.js",
        "wasm-404": "llama_webgpu_core_st.wasm",
    }.get(case)

    mem64 = case == "mem64-unused-wasm32"

    def serve_asset(route):
        name = Path(urlsplit(route.request.url).path).name
        if case == "legacy":
            if name in legacy_assets:
                route.fulfill(body=legacy_assets[name], content_type="text/javascript")
            else:
                route.fulfill(status=404)
        elif name == missing_asset:
            route.fulfill(status=404)
        else:
            route.fulfill(path=assets_root / name)

    try:
        if case == "legacy":
            legacy_url = LEGACY_ASSETS_URL_FILE.read_text(encoding="utf-8").strip()
            for name, digest in LEGACY_BRIDGE_DIGESTS.items():
                response = page.context.request.get(legacy_url + name)
                assert response.ok, (name, response.status)
                payload = response.body()
                assert hashlib.sha256(payload).hexdigest() == digest, name
                legacy_assets[name] = payload

        html = Path("example/chat_app/web/index.html").read_text(encoding="utf-8")
        html = html.replace("$FLUTTER_BASE_HREF", base).replace(
            'src="flutter_bootstrap.js" async', f'src="{fixture}single_thread_core.js"'
        )
        page.context.route(f"{base}webgpu_bridge/**", serve_asset)
        page.route(f"{base}probe.html", lambda route: route.fulfill(
            body=html, content_type="text/html"
        ))
        if case in {"model-404", "bad-model", "mem64-unused-wasm32"}:
            status = 404 if case == "model-404" else 200
            page.context.route(model_url, lambda route: route.fulfill(
                status=status, body=b"invalid GGUF", content_type="application/octet-stream"
            ))
        page.context.on("response", lambda response: responses.append(
            (Path(urlsplit(response.url).path).name, response.status)
        ) if response.url.startswith(f"{base}webgpu_bridge/") or response.url == model_url else None)
        page.add_init_script("window.__llamadartBridgeAllowSingleThreadCore = true")
        page.goto(f"{base}probe.html")
        page.wait_for_function(
            "window.__llamadartBridgeReady === true && typeof runSingleThreadCore === 'function'"
        )
        actual = page.evaluate(
            """async ({worker, modelUrl, mem64, adjacentWasm}) => {
              if (adjacentWasm) delete window.__llamadartBridgeWasmUrlSt;
              window.LlamaWebGpuBridge = class extends window.LlamaWebGpuBridge {
                constructor(config) { super({...config, disableWorker: !worker}); }
              };
              return {
                isolated: crossOriginIsolated,
                source: window.__llamadartBridgeAssetSource,
                coreModuleUrl: window.__llamadartBridgeCoreModuleUrlSt,
                wasmUrl: window.__llamadartBridgeWasmUrlSt ?? null,
                result: JSON.parse(await runSingleThreadCore(modelUrl, mem64, false)),
              };
            }""",
            dict(worker=worker, modelUrl=model_url, mem64=mem64,
                 adjacentWasm=case == "adjacent-wasm-404"),
        )
        print(json.dumps(dict(bootstrap_case=case, worker=worker, **actual,
                              responses=responses)), flush=True)
        assert actual["isolated"] is False and actual["source"] == "local", actual
        assert urlsplit(actual["coreModuleUrl"]).path.endswith("/llama_webgpu_core_st.js"), actual
        if case == "adjacent-wasm-404":
            assert actual["wasmUrl"] is None, actual
        else:
            assert urlsplit(actual["wasmUrl"]).path.endswith("/llama_webgpu_core_st.wasm"), actual
        assert (("llama_webgpu_bridge_worker.js", 200) in responses) == (worker and case != "legacy"), responses
        result = actual["result"]
        if case == "legacy" or (missing_asset and not mem64):
            if missing_asset:
                assert (missing_asset, 404) in responses, responses
            else:
                assert responses == [("llama_webgpu_bridge.js", 200)], responses
            assert all(name != "model.gguf" for name, _ in responses), responses
            detail = result.get("unsupported", "")
            assert all(text in detail for text in ("Single-thread", "COOP/COEP", "v0.1.93+")), result
        else:
            if mem64:
                assert ("llama_webgpu_core_mem64_st.wasm", 200) in responses, responses
                assert all(name != missing_asset for name, _ in responses), responses
            assert ("model.gguf", status) in responses, responses
            assert "model_error" in result, result
    finally:
        page.close()


def check_bootstrap_errors(browser, fixture, model_url):
    failures = []
    for worker in [False, True]:
        for case in [
            "legacy", "loader-404", "wasm-404", "adjacent-wasm-404",
            "model-404", "bad-model", "mem64-unused-wasm32",
        ]:
            try:
                run_bootstrap_case(browser, fixture, model_url, worker=worker, case=case)
            except AssertionError as error:
                failures.append(f"{case}, worker={worker}: {error}")
    assert not failures, "\n".join(failures)


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
            check_bootstrap_errors(browser, f"{origin}/build/web_single_thread_core/", fixture_url)
            if args.model_url:
                for mem64 in [False, True]:
                    run_case(browser, origin, args.model_url, worker=True, mem64=mem64,
                             allow_wasm64_retry=True)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
