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


def truncate_text(text: str, limit: int = 3000) -> str:
    if len(text) <= limit:
        return text
    return f"{text[:limit]}...<truncated {len(text) - limit} chars>"


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
        if "Something went wrong" in text and "Retry" in text:
            state = page.evaluate(
                """() => ({
                  bridgeError: window.__llamadartRealBridgeLastError,
                  liteRtLmError: window.__llamadartRealLiteRtLmLastError,
                  liteRtLmSettings: window.__llamadartRealLiteRtLmLastSettings,
                })"""
            )
            raise RuntimeError(
                f"App entered error state while waiting for {label}: "
                f"{json.dumps(state, ensure_ascii=False)}\n{text[-1200:]}"
            )

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


def enable_flutter_semantics(page) -> None:
    semantics = page.locator("flt-semantics-placeholder")
    semantics.wait_for(timeout=120000)
    try:
        semantics.evaluate("(element) => element.click()")
    except Exception:
        semantics.focus()
        page.keyboard.press("Enter")
    page.wait_for_timeout(1000)


def wait_for_bridge_response(
    page,
    expected: str,
    timeout_ms: int,
    allow_any_response: bool,
    response_source: str,
) -> tuple[str, str]:
    deadline = time.monotonic() + (timeout_ms / 1000)
    last_status = 0.0
    lower_expected = expected.lower()
    while time.monotonic() < deadline:
        state = page.evaluate(
            """() => ({
              bridgeResponse: window.__llamadartRealBridgeLastResponse,
              bridgeError: window.__llamadartRealBridgeLastError,
              liteRtLmResponse: window.__llamadartRealLiteRtLmLastResponse,
              liteRtLmError: window.__llamadartRealLiteRtLmLastError,
              liteRtLmPrompt: window.__llamadartRealLiteRtLmLastPrompt,
              liteRtLmSettings: window.__llamadartRealLiteRtLmLastSettings,
              liteRtLmConversationConfig:
                window.__llamadartRealLiteRtLmLastConversationConfig,
              liteRtLmChunks: window.__llamadartRealLiteRtLmLastChunks,
            })"""
        )
        bridge_response = str(state.get("bridgeResponse") or "")
        litert_response = str(state.get("liteRtLmResponse") or "")
        responses = []
        if response_source in ("bridge", "auto"):
            responses.append(("bridge", bridge_response))
        if response_source in ("litert", "auto"):
            responses.append(("litert", litert_response))
        response = next((value for _, value in responses if value.strip()), "")
        bridge_error = state.get("bridgeError")
        litert_error = state.get("liteRtLmError")
        body = safe_body_text(page)

        if response_source in ("bridge", "auto") and bridge_error:
            raise RuntimeError(f"Bridge generation failed: {bridge_error}")
        if response_source in ("litert", "auto") and litert_error:
            raise RuntimeError(f"LiteRT-LM generation failed: {litert_error}")
        for source, candidate in responses:
            if lower_expected in candidate.lower():
                emit("response_observed", source=source)
                return candidate, body
        if allow_any_response and response.strip():
            return response, body

        now = time.monotonic()
        if now - last_status >= 30:
            last_status = now
            emit(
                "waiting",
                label="model response",
                elapsed_seconds=round(now - (deadline - timeout_ms / 1000), 1),
                response_source=response_source,
                bridge_response=bridge_response[-500:],
                litert_response=litert_response[-500:],
                litert_prompt=str(state.get("liteRtLmPrompt") or "")[-500:],
                litert_settings=state.get("liteRtLmSettings"),
                litert_conversation_config=state.get(
                    "liteRtLmConversationConfig"
                ),
                litert_chunks=state.get("liteRtLmChunks"),
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
    parser.add_argument("--gpu-layers", type=int, default=0)
    parser.add_argument("--context-size", type=int, default=1024)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--penalty", type=float, default=1.0)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--thread-pool-size", type=int, default=2)
    parser.add_argument("--load-timeout-ms", type=int, default=20 * 60 * 1000)
    parser.add_argument("--response-timeout-ms", type=int, default=5 * 60 * 1000)
    parser.add_argument(
        "--response-source",
        choices=["auto", "bridge", "litert"],
        default="bridge",
    )
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
        "flutter.gpu_layers": json.dumps(args.gpu_layers),
        "flutter.threads": json.dumps(args.threads),
        "flutter.threads_batch": json.dumps(args.threads),
        "flutter.temperature": json.dumps(0.0),
        "flutter.top_k": json.dumps(1),
        "flutter.top_p": json.dumps(1.0),
        "flutter.min_p": json.dumps(0.0),
        "flutter.penalty": json.dumps(args.penalty),
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
        window.__llamadartBridgePreferMemory64 = {str(args.mem64).lower()};
        window.__llamadartBridgeAllowAutoRemoteFetchBackend =
            {str(not args.disable_auto_remote_fetch).lower()};
        window.__llamadartRealBridgeLastResponse = null;
        window.__llamadartRealBridgeLastError = null;
        window.__llamadartRealLiteRtLmLastResponse = null;
        window.__llamadartRealLiteRtLmLastError = null;
        window.__llamadartRealLiteRtLmLastSettings = null;
        window.__llamadartRealLiteRtLmLastConversationConfig = null;
        window.__llamadartRealLiteRtLmLastPrompt = null;
        window.__llamadartRealLiteRtLmLastChunks = [];
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
        window.__llamadartRealLiteRtLmExtractText = function(value) {{
          if (value == null) {{
            return '';
          }}
          if (typeof value === 'string') {{
            return value;
          }}
          if (typeof value.text === 'string') {{
            return value.text;
          }}
          if (Array.isArray(value.content)) {{
            return value.content
              .map(item => item && typeof item.text === 'string' ? item.text : '')
              .join('');
          }}
          return '';
        }};
        window.__llamadartRealLiteRtLmCapture = async function(stream) {{
          try {{
            const reader = stream.getReader();
            let text = '';
            let chunks = [];
            while (true) {{
              const result = await reader.read();
              if (result.done) {{
                break;
              }}
              chunks.push(result.value);
              window.__llamadartRealLiteRtLmLastChunks = chunks.slice(-8);
              text += window.__llamadartRealLiteRtLmExtractText(result.value);
              window.__llamadartRealLiteRtLmLastResponse = text;
            }}
            if (typeof reader.releaseLock === 'function') {{
              reader.releaseLock();
            }}
          }} catch (error) {{
            window.__llamadartRealLiteRtLmLastError = String(error);
          }}
        }};
        window.__llamadartRealLiteRtLmInstallModuleWrapper = function() {{
          const originalModuleUrl =
            typeof window.__llamadartLiteRtLmModuleUrl === 'string' &&
            window.__llamadartLiteRtLmModuleUrl.length > 0
              ? window.__llamadartLiteRtLmModuleUrl
              : 'https://cdn.jsdelivr.net/npm/@litert-lm/core/+esm';
          window.__llamadartLiteRtLmOriginalModuleUrl = originalModuleUrl;
          const moduleSource = [
            'import * as mod from ' + JSON.stringify(originalModuleUrl) + ';',
            'const summarizeSettings = (settings) => {{',
            '  const mainExecutorSettings = settings?.mainExecutorSettings;',
            '  return {{',
            '    model: settings?.model,',
            '    backend: settings?.backend,',
            '    mainExecutorSettings: mainExecutorSettings ? {{',
            '      maxNumTokens: mainExecutorSettings.maxNumTokens,',
            '      samplerBackend: mainExecutorSettings.samplerBackend,',
            '      backendConfig: mainExecutorSettings.backendConfig,',
            '      advancedSettings: mainExecutorSettings.advancedSettings,',
            '    }} : null,',
            '  }};',
            '}};',
            'const wrapConversation = (conversation) => new Proxy(conversation, {{',
            '  get(target, prop, receiver) {{',
            '    if (prop === "sendMessageStreaming") {{',
            '      return function(prompt) {{',
            '        globalThis.__llamadartRealLiteRtLmLastResponse = null;',
            '        globalThis.__llamadartRealLiteRtLmLastError = null;',
            '        globalThis.__llamadartRealLiteRtLmLastPrompt = String(prompt ?? "");',
            '        globalThis.__llamadartRealLiteRtLmLastChunks = [];',
            '        try {{',
            '          const stream = target.sendMessageStreaming(prompt);',
            '          if (stream && typeof stream.tee === "function") {{',
            '            const branches = stream.tee();',
            '            globalThis.__llamadartRealLiteRtLmCapture(branches[1]);',
            '            return branches[0];',
            '          }}',
            '          return stream;',
            '        }} catch (error) {{',
            '          globalThis.__llamadartRealLiteRtLmLastError = String(error);',
            '          throw error;',
            '        }}',
            '      }};',
            '    }}',
            '    const value = Reflect.get(target, prop, receiver);',
            '    return typeof value === "function" ? value.bind(target) : value;',
            '  }}',
            '}});',
            'const wrapEngine = (engine) => new Proxy(engine, {{',
            '  get(target, prop, receiver) {{',
            '    if (prop === "createConversation") {{',
            '      return async function(config) {{',
            '        globalThis.__llamadartRealLiteRtLmLastConversationConfig = config;',
            '        const conversation = await target.createConversation(config);',
            '        return wrapConversation(conversation);',
            '      }};',
            '    }}',
            '    const value = Reflect.get(target, prop, receiver);',
            '    return typeof value === "function" ? value.bind(target) : value;',
            '  }}',
            '}});',
            'export const Backend = mod.Backend;',
            'export const Engine = new Proxy(mod.Engine, {{',
            '  get(target, prop, receiver) {{',
            '    if (prop === "create") {{',
            '      return async function(settings) {{',
            '        globalThis.__llamadartRealLiteRtLmLastSettings = summarizeSettings(settings);',
            '        try {{',
            '          const engine = await target.create(settings);',
            '          return wrapEngine(engine);',
            '        }} catch (error) {{',
            '          globalThis.__llamadartRealLiteRtLmLastError = String(error);',
            '          throw error;',
            '        }}',
            '      }};',
            '    }}',
            '    const value = Reflect.get(target, prop, receiver);',
            '    return typeof value === "function" ? value.bind(target) : value;',
            '  }}',
            '}});',
            'export default mod.default ?? null;',
          ].join('\\n');
          window.__llamadartLiteRtLmModuleUrl = URL.createObjectURL(
            new Blob([moduleSource], {{ type: 'text/javascript' }})
          );
        }};
        window.__llamadartRealLiteRtLmInstallModuleWrapper();
        window.__llamadartRealLiteRtLmPatchTimer = setInterval(() => {{
          const EngineClass = window.LiteRtLmEngine;
          if (!EngineClass || typeof EngineClass.create !== 'function') {{
            return;
          }}
          if (EngineClass.__llamadartRealE2ePatched === true) {{
            clearInterval(window.__llamadartRealLiteRtLmPatchTimer);
            return;
          }}
          const originalCreate = EngineClass.create.bind(EngineClass);
          const summarizeSettings = (settings) => {{
            const mainExecutorSettings = settings?.mainExecutorSettings;
            return {{
              model: settings?.model,
              backend: settings?.backend,
              mainExecutorSettings: mainExecutorSettings
                ? {{
                    maxNumTokens: mainExecutorSettings.maxNumTokens,
                    samplerBackend: mainExecutorSettings.samplerBackend,
                    backendConfig: mainExecutorSettings.backendConfig,
                    advancedSettings: mainExecutorSettings.advancedSettings,
                  }}
                : null,
            }};
          }};
          EngineClass.create = async function(settings) {{
            window.__llamadartRealLiteRtLmLastSettings =
              summarizeSettings(settings);
            let engine;
            try {{
              engine = await originalCreate(settings);
            }} catch (error) {{
              window.__llamadartRealLiteRtLmLastError = String(error);
              throw error;
            }}
            const originalCreateConversation = engine.createConversation?.bind(engine);
            if (typeof originalCreateConversation !== 'function') {{
              return engine;
            }}
            engine.createConversation = async function(config) {{
              window.__llamadartRealLiteRtLmLastConversationConfig = config;
              const conversation = await originalCreateConversation(config);
              const originalSend = conversation.sendMessageStreaming?.bind(conversation);
              if (typeof originalSend !== 'function') {{
                return conversation;
              }}
              conversation.sendMessageStreaming = function(prompt) {{
                window.__llamadartRealLiteRtLmLastResponse = null;
                window.__llamadartRealLiteRtLmLastError = null;
                window.__llamadartRealLiteRtLmLastPrompt = String(prompt ?? '');
                window.__llamadartRealLiteRtLmLastChunks = [];
                try {{
                  const stream = originalSend(prompt);
                  if (stream && typeof stream.tee === 'function') {{
                    const branches = stream.tee();
                    window.__llamadartRealLiteRtLmCapture(branches[1]);
                    return branches[0];
                  }}
                  return stream;
                }} catch (error) {{
                  window.__llamadartRealLiteRtLmLastError = String(error);
                  throw error;
                }}
              }};
              return conversation;
            }};
            return engine;
          }};
          EngineClass.__llamadartRealE2ePatched = true;
          clearInterval(window.__llamadartRealLiteRtLmPatchTimer);
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
            record = {
                "type": str(message.type),
                "text": truncate_text(str(message.text)),
            }
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

        enable_flutter_semantics(page)

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
            args.response_source,
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
              liteRtLmModuleUrl: window.__llamadartLiteRtLmModuleUrl ?? null,
              liteRtLmPatched: window.LiteRtLmEngine?.__llamadartRealE2ePatched ?? null,
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
