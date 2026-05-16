#!/usr/bin/env python3
import argparse
import json
import platform
import re
import time
from typing import Any

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


def emit(event: str, **data: Any) -> None:
    print(json.dumps({"event": event, **data}, ensure_ascii=False), flush=True)


def browser_args(angle: str) -> list[str]:
    args = [
        "--disable-dev-shm-usage",
        "--enable-unsafe-webgpu",
    ]
    features = ["SharedArrayBuffer"]

    effective_angle = angle
    if effective_angle == "auto":
        effective_angle = "metal" if platform.system() == "Darwin" else "vulkan"

    if effective_angle == "metal":
        args.append("--use-angle=metal")
    elif effective_angle == "vulkan":
        args.append("--disable-vulkan-surface")
        features.append("Vulkan")

    args.append(f"--enable-features={','.join(features)}")
    return args


def safe_body_text(page) -> str:
    try:
        return page.locator("body").inner_text(timeout=5000)
    except Exception as error:
        return f"<body unavailable: {error}>"


def wait_for_text(page, needle: str, timeout_ms: int, label: str) -> str:
    deadline = time.monotonic() + (timeout_ms / 1000)
    last_status = 0.0
    lower_needle = needle.lower()
    while time.monotonic() < deadline:
        text = safe_body_text(page)
        if lower_needle in text.lower():
            return text

        now = time.monotonic()
        if now - last_status >= 30:
            last_status = now
            emit(
                "waiting",
                label=label,
                elapsed_seconds=round(now - (deadline - timeout_ms / 1000), 1),
                body_tail=text[-500:],
            )
        time.sleep(2)

    raise TimeoutError(f"Timed out waiting for {label}: {needle}")


def wait_for_bridge_response(
    page,
    expected: str,
    timeout_ms: int,
    allow_any_response: bool,
) -> tuple[str, str]:
    deadline = time.monotonic() + (timeout_ms / 1000)
    last_status = 0.0
    lower_expected = expected.lower()
    while time.monotonic() < deadline:
        bridge_state = page.evaluate(
            """() => ({
              response: window.__llamadartRealBridgeLastResponse,
              error: window.__llamadartRealBridgeLastError,
            })"""
        )
        response = str(bridge_state.get("response") or "")
        error = bridge_state.get("error")
        body = safe_body_text(page)

        if error:
            raise RuntimeError(f"Bridge generation failed: {error}")
        if lower_expected in response.lower():
            return response, body
        if allow_any_response and response.strip():
            return response, body

        now = time.monotonic()
        if now - last_status >= 30:
            last_status = now
            emit(
                "waiting",
                label="model response",
                elapsed_seconds=round(now - (deadline - timeout_ms / 1000), 1),
                bridge_response=response[-500:],
                body_tail=body[-500:],
            )
        time.sleep(2)

    raise TimeoutError(f"Timed out waiting for model response: {expected}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app_url")
    parser.add_argument("--model-url", required=True)
    parser.add_argument("--mmproj-url")
    parser.add_argument("--prompt", default="What is 2+2? Answer in one short sentence.")
    parser.add_argument("--expect", default="4")
    parser.add_argument("--allow-any-response", action="store_true")
    parser.add_argument("--backend-index", type=int, default=1)
    parser.add_argument("--context-size", type=int, default=1024)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--thread-pool-size", type=int, default=2)
    parser.add_argument("--load-timeout-ms", type=int, default=20 * 60 * 1000)
    parser.add_argument("--response-timeout-ms", type=int, default=5 * 60 * 1000)
    parser.add_argument("--mem64", action="store_true")
    parser.add_argument("--disable-auto-remote-fetch", action="store_true")
    parser.add_argument(
        "--browser-angle",
        choices=["auto", "default", "metal", "vulkan"],
        default="auto",
    )
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()

    console_logs: list[dict[str, str]] = []
    page_errors: list[str] = []
    request_failures: list[str] = []
    started_at = time.monotonic()

    seeded_settings = {
        "flutter.model_path": json.dumps(args.model_url),
        "flutter.preferred_backend": json.dumps(args.backend_index),
        "flutter.context_size": json.dumps(args.context_size),
        "flutter.max_tokens": json.dumps(args.max_tokens),
        "flutter.gpu_layers": json.dumps(0),
        "flutter.threads": json.dumps(args.threads),
        "flutter.threads_batch": json.dumps(args.threads),
        "flutter.temperature": json.dumps(0.0),
        "flutter.top_k": json.dumps(1),
        "flutter.top_p": json.dumps(1.0),
        "flutter.min_p": json.dumps(0.0),
        "flutter.penalty": json.dumps(1.0),
        "flutter.tools_enabled": json.dumps(False),
        "flutter.tool_declarations": json.dumps("[]"),
        "flutter.thinking_enabled": json.dumps(False),
        "flutter.thinking_budget_tokens": json.dumps(0),
        "flutter.single_turn_mode": json.dumps(True),
        "flutter.log_level": json.dumps(0),
        "flutter.native_log_level": json.dumps(2),
    }
    if args.mmproj_url:
        seeded_settings["flutter.mmproj_path"] = json.dumps(args.mmproj_url)

    init_script = f"""
        window.__llamadartPreferLocalBridgeRuntime = true;
        window.__llamadartBridgeBootstrapVerbose = true;
        window.__llamadartBridgeThreadPoolSize = {args.thread_pool_size};
        window.__llamadartBridgeEnableMem64 = {str(args.mem64).lower()};
        window.__llamadartBridgeAllowAutoRemoteFetchBackend =
            {str(not args.disable_auto_remote_fetch).lower()};
        window.__llamadartRealBridgeLastResponse = null;
        window.__llamadartRealBridgeLastError = null;
        window.__llamadartRealBridgePatchTimer = setInterval(() => {{
          const BridgeClass = window.LlamaWebGpuBridge;
          if (typeof BridgeClass !== 'function') {{
            return;
          }}
          if (BridgeClass.__llamadartRealE2ePatched === true) {{
            clearInterval(window.__llamadartRealBridgePatchTimer);
            return;
          }}
          const original = BridgeClass.prototype?.createCompletion;
          if (typeof original !== 'function') {{
            return;
          }}
          BridgeClass.prototype.createCompletion = async function(prompt, options) {{
            window.__llamadartRealBridgeLastResponse = null;
            window.__llamadartRealBridgeLastError = null;
            try {{
              const result = await original.call(this, prompt, options);
              window.__llamadartRealBridgeLastResponse = String(result ?? '');
              return result;
            }} catch (error) {{
              window.__llamadartRealBridgeLastError = String(error);
              throw error;
            }}
          }};
          BridgeClass.__llamadartRealE2ePatched = true;
          clearInterval(window.__llamadartRealBridgePatchTimer);
        }}, 20);
        const seededSettings = {json.dumps(seeded_settings)};
        for (const [key, value] of Object.entries(seededSettings)) {{
          localStorage.setItem(key, value);
        }}
        if (!("flutter.mmproj_path" in seededSettings)) {{
          localStorage.removeItem("flutter.mmproj_path");
        }}
    """

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=not args.headed,
            args=browser_args(args.browser_angle),
        )
        page = browser.new_page(viewport={"width": 1440, "height": 1100})
        page.set_default_timeout(120000)
        page.add_init_script(init_script)

        def on_console(message) -> None:
            record = {"type": str(message.type), "text": str(message.text)}
            console_logs.append(record)
            text = record["text"]
            if (
                record["type"] in ("warning", "error")
                or "llamadart" in text
                or "WebGpuLlamaBackend" in text
            ):
                emit("console", **record)

        page.on("console", on_console)
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        page.on(
            "requestfailed",
            lambda request: request_failures.append(
                f"{request.method} {request.url}: {request.failure}"
            ),
        )

        emit("goto", app_url=args.app_url)
        page.goto(args.app_url, wait_until="domcontentloaded")

        semantics = page.locator("flt-semantics-placeholder")
        semantics.wait_for(timeout=120000)
        semantics.focus()
        page.keyboard.press("Enter")
        page.wait_for_timeout(1000)

        button = page.get_by_role("button", name=re.compile(r"Load Model"))
        button.wait_for(timeout=120000)
        emit("load_click", model_url=args.model_url, mmproj_url=args.mmproj_url)
        button.click()

        body_after_load = wait_for_text(
            page,
            "Model loaded successfully! Ready to chat.",
            args.load_timeout_ms,
            "model load",
        )
        emit(
            "loaded",
            elapsed_seconds=round(time.monotonic() - started_at, 1),
            body_tail=body_after_load[-500:],
        )

        textbox = page.get_by_role("textbox").last
        textbox.fill(args.prompt)
        page.get_by_role("button", name="Send message").click()

        try:
            page.get_by_role("button", name="Stop generation").wait_for(timeout=10000)
            emit("generation_started")
        except PlaywrightTimeoutError:
            emit("generation_start_not_observed")

        bridge_response, body_after_response = wait_for_bridge_response(
            page,
            args.expect,
            args.response_timeout_ms,
            args.allow_any_response,
        )
        bridge_globals = page.evaluate(
            """() => ({
              crossOriginIsolated: window.crossOriginIsolated,
              assetSource: window.__llamadartBridgeAssetSource ?? null,
              coreModuleUrl: window.__llamadartBridgeCoreModuleUrl ?? null,
              coreModuleUrlMem64: window.__llamadartBridgeCoreModuleUrlMem64 ?? null,
              wasmUrl: window.__llamadartBridgeWasmUrl ?? null,
              wasmUrlMem64: window.__llamadartBridgeWasmUrlMem64 ?? null,
              workerUrl: window.__llamadartBridgeWorkerUrl ?? null,
              preferMemory64: window.__llamadartBridgePreferMemory64 ?? null,
              workerFallbackReason: window.__llamadartBridgeWorkerFallbackReason ?? null,
              loadError: window.__llamadartBridgeLoadError ?? null,
              threadPoolSize: window.__llamadartBridgeThreadPoolSize ?? null,
            })"""
        )
        emit(
            "result",
            ok=True,
            elapsedSeconds=round(time.monotonic() - started_at, 1),
            modelUrl=args.model_url,
            mmprojUrl=args.mmproj_url,
            expectedText=args.expect,
            bridgeResponse=bridge_response,
            bridgeGlobals=bridge_globals,
            bodyTail=body_after_response[-1200:],
            consoleTail=console_logs[-30:],
            pageErrors=page_errors[-10:],
            requestFailures=request_failures[-10:],
        )
        browser.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
