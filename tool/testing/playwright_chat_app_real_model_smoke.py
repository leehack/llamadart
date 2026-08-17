#!/usr/bin/env python3
import argparse
import json
import re
import tempfile
import time
import wave
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright

from playwright_chat_app_utils import (
    append_console_log,
    browser_args,
    emit,
    enable_flutter_semantics,
    enter_chat_prompt,
    local_storage_init_script,
    safe_body_text,
)


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


def copy_last_assistant_response(page, timeout_ms: int) -> str:
    copy_button = page.get_by_role("button", name="Copy response").last
    copy_button.wait_for(timeout=timeout_ms)
    copy_button.click()
    return str(page.evaluate("() => navigator.clipboard.readText()") or "")


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
              bridgePrompt: window.__llamadartRealBridgeLastPrompt,
              bridgeOptions: window.__llamadartRealBridgeLastOptions,
              bridgeTokenEvents: window.__llamadartRealBridgeTokenEvents,
              bridgeTokenBytes: window.__llamadartRealBridgeTokenBytes,
              bridgeLastPieceType: window.__llamadartRealBridgeLastPieceType,
              bridgeLastCurrentTextLength:
                window.__llamadartRealBridgeLastCurrentTextLength,
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

        for failure_marker in (
            "Transcription failed:",
            "The microphone recording was too short.",
            "The microphone recording was silent or too quiet.",
            "The browser microphone returned an unsupported WAV encoding.",
        ):
            if failure_marker in body:
                raise RuntimeError(
                    "Speech workflow reported a terminal failure: "
                    f"{body[-800:]!r}"
                )

        if response_source in ("bridge", "auto") and bridge_error:
            raise RuntimeError(f"Bridge generation failed: {bridge_error}")
        if response_source in ("litert", "auto") and litert_error:
            raise RuntimeError(f"LiteRT-LM generation failed: {litert_error}")
        for source, candidate in responses:
            if lower_expected in candidate.lower():
                emit(
                    "response_observed",
                    source=source,
                    bridge_token_events=state.get("bridgeTokenEvents"),
                    bridge_token_bytes=state.get("bridgeTokenBytes"),
                    bridge_last_piece_type=state.get("bridgeLastPieceType"),
                    bridge_last_current_text_length=state.get(
                        "bridgeLastCurrentTextLength"
                    ),
                )
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
                bridge_prompt=str(state.get("bridgePrompt") or "")[-500:],
                bridge_options=state.get("bridgeOptions"),
                bridge_token_events=state.get("bridgeTokenEvents"),
                bridge_token_bytes=state.get("bridgeTokenBytes"),
                bridge_last_piece_type=state.get("bridgeLastPieceType"),
                bridge_last_current_text_length=state.get(
                    "bridgeLastCurrentTextLength"
                ),
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
    parser.add_argument(
        "--speech-audio-path",
        help="Select a local WAV through the chat app's typed transcription action.",
    )
    parser.add_argument(
        "--speech-microphone",
        action="store_true",
        help="Also feed the WAV through Chromium's fake microphone and record UI.",
    )
    parser.add_argument("--prefetch-mmproj-cache", action="store_true")
    parser.add_argument("--expect-mmproj-cache-hit", action="store_true")
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
    remote_fetch_group = parser.add_mutually_exclusive_group()
    remote_fetch_group.add_argument(
        "--disable-auto-remote-fetch",
        action="store_true",
        help="Explicitly disable automatic fetch-backed model loading.",
    )
    remote_fetch_group.add_argument(
        "--allow-auto-remote-fetch",
        action="store_true",
        help="Allow fetch-backed loading and recovery for a controlled origin.",
    )
    remote_fetch_group.add_argument(
        "--force-remote-fetch",
        action="store_true",
        help="Force fetch-backed loading from the first attempt for diagnostics.",
    )
    parser.add_argument(
        "--browser-angle",
        choices=["auto", "default", "metal", "vulkan"],
        default="auto",
    )
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()
    if args.expect_mmproj_cache_hit and not args.prefetch_mmproj_cache:
        parser.error("--expect-mmproj-cache-hit requires --prefetch-mmproj-cache")
    if args.speech_audio_path:
        audio_path = Path(args.speech_audio_path).resolve()
        if not audio_path.is_file():
            parser.error(f"--speech-audio-path does not exist: {audio_path}")
        if audio_path.suffix.lower() != ".wav":
            parser.error("--speech-audio-path must be a WAV file")
        if not args.mmproj_url:
            parser.error("--speech-audio-path requires --mmproj-url")
        args.speech_audio_path = str(audio_path)
    if args.speech_microphone and not args.speech_audio_path:
        parser.error("--speech-microphone requires --speech-audio-path")

    remote_fetch_mode = "default"
    remote_fetch_init = """
        delete window.__llamadartBridgeAllowAutoRemoteFetchBackend;
        delete window.__llamadartBridgeForceRemoteFetchBackend;
    """
    if args.disable_auto_remote_fetch:
        remote_fetch_mode = "disabled"
        remote_fetch_init = """
            window.__llamadartBridgeAllowAutoRemoteFetchBackend = false;
            delete window.__llamadartBridgeForceRemoteFetchBackend;
        """
    elif args.allow_auto_remote_fetch:
        remote_fetch_mode = "automatic"
        remote_fetch_init = """
            window.__llamadartBridgeAllowAutoRemoteFetchBackend = true;
            delete window.__llamadartBridgeForceRemoteFetchBackend;
        """
    elif args.force_remote_fetch:
        remote_fetch_mode = "forced"
        remote_fetch_init = """
            delete window.__llamadartBridgeAllowAutoRemoteFetchBackend;
            window.__llamadartBridgeForceRemoteFetchBackend = true;
        """

    console_logs: list[dict[str, str]] = []
    page_errors: list[str] = []
    request_failures: list[str] = []
    mmproj_requests: list[str] = []
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
    if args.speech_audio_path:
        seeded_settings["flutter.model_supports_audio"] = json.dumps(True)
        seeded_settings["flutter.model_supports_speech_to_text"] = json.dumps(True)

    init_script = f"""
        window.__llamadartPreferLocalBridgeRuntime = true;
        window.__llamadartBridgeBootstrapVerbose = true;
        window.__llamadartBridgeThreadPoolSize = {args.thread_pool_size};
        window.__llamadartBridgeEnableMem64 = {str(args.mem64).lower()};
        window.__llamadartBridgePreferMemory64 = {str(args.mem64).lower()};
        {remote_fetch_init}
        window.__llamadartRealBridgeLastResponse = null;
        window.__llamadartRealBridgeLastError = null;
        window.__llamadartRealBridgeLastPrompt = null;
        window.__llamadartRealBridgeLastOptions = null;
        window.__llamadartRealBridgeTokenEvents = 0;
        window.__llamadartRealBridgeTokenBytes = 0;
        window.__llamadartRealBridgeLastPieceType = null;
        window.__llamadartRealBridgeLastCurrentTextLength = 0;
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
            window.__llamadartRealBridgeLastPrompt = String(prompt ?? '');
            window.__llamadartRealBridgeLastOptions = {{
              nPredict: options?.nPredict ?? null,
              temp: options?.temp ?? null,
              topK: options?.topK ?? null,
              topP: options?.topP ?? null,
              penalty: options?.penalty ?? null,
              seed: options?.seed ?? null,
              partTypes: Array.from(options?.parts ?? []).map(
                part => String(part?.type ?? ''),
              ),
            }};
            const downstreamOnToken = options?.onToken;
            if (typeof downstreamOnToken === 'function') {{
              options.onToken = function(piece, currentText) {{
                window.__llamadartRealBridgeTokenEvents += 1;
                window.__llamadartRealBridgeLastPieceType =
                  piece?.constructor?.name ?? typeof piece;
                window.__llamadartRealBridgeTokenBytes +=
                  typeof piece === 'string'
                    ? new TextEncoder().encode(piece).byteLength
                    : Number(piece?.byteLength ?? piece?.length ?? 0);
                window.__llamadartRealBridgeLastCurrentTextLength =
                  String(currentText ?? '').length;
                return downstreamOnToken(piece, currentText);
              }};
            }}
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
              : 'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.15.0/+esm';
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
        {local_storage_init_script(
            seeded_settings,
            remove_keys=() if args.mmproj_url else ("flutter.mmproj_path",),
        )}
    """

    with tempfile.TemporaryDirectory(
        prefix="llamadart-fake-microphone-"
    ) as microphone_tmp_dir, sync_playwright() as playwright:
        launch_args = browser_args(args.browser_angle)
        if args.speech_microphone:
            fake_microphone_path = Path(microphone_tmp_dir) / "capture.wav"
            with wave.open(args.speech_audio_path, "rb") as source_wav:
                params = source_wav.getparams()
                frames = source_wav.readframes(params.nframes)
            if params.sampwidth != 2:
                raise ValueError("Fake microphone input must use PCM16 WAV")
            with wave.open(str(fake_microphone_path), "wb") as padded_wav:
                padded_wav.setparams(params)
                padded_wav.writeframes(
                    bytes(params.framerate * params.nchannels * params.sampwidth)
                )
                padded_wav.writeframes(frames)
            launch_args.extend(
                [
                    "--use-fake-ui-for-media-stream",
                    "--use-fake-device-for-media-stream",
                    f"--use-file-for-fake-audio-capture={fake_microphone_path}",
                ]
            )
        browser = playwright.chromium.launch(
            headless=not args.headed,
            args=launch_args,
        )
        app_url_parts = urlsplit(args.app_url)
        app_origin = f"{app_url_parts.scheme}://{app_url_parts.netloc}"
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        context.grant_permissions(
            ["clipboard-read", "clipboard-write", "microphone"],
            origin=app_origin,
        )
        page = context.new_page()
        page.set_default_timeout(120000)
        page.add_init_script(init_script)

        def on_console(message) -> None:
            append_console_log(
                console_logs,
                message,
                echo_predicate=lambda record: (
                    record["type"] in ("warning", "error")
                    or "llamadart" in record["text"]
                    or "WebGpuLlamaBackend" in record["text"]
                ),
            )

        page.on("console", on_console)
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        if args.mmproj_url:
            page.on(
                "request",
                lambda request: (
                    mmproj_requests.append(request.url)
                    if request.url == args.mmproj_url
                    else None
                ),
            )
        page.on(
            "requestfailed",
            lambda request: request_failures.append(
                f"{request.method} {request.url}: {request.failure}"
            ),
        )

        emit("goto", app_url=args.app_url)
        page.goto(args.app_url, wait_until="domcontentloaded")

        enable_flutter_semantics(page)

        if args.prefetch_mmproj_cache:
            if not args.mmproj_url:
                raise ValueError("--prefetch-mmproj-cache requires --mmproj-url")
            cached = page.evaluate(
                """async (url) => {
                  const cache = await caches.open('llamadart-webgpu-model-cache-v1');
                  await cache.add(url);
                  return Boolean(await cache.match(url));
                }""",
                args.mmproj_url,
            )
            emit(
                "mmproj_cache_prefetch",
                mmproj_url=args.mmproj_url,
                cached=bool(cached),
                request_count=len(mmproj_requests),
            )
            if not cached:
                raise RuntimeError("mmproj prefetch did not populate CacheStorage")

        button = page.get_by_role("button", name=re.compile(r"Load Model", re.I))
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

        if args.speech_audio_path:
            attachment_button = page.get_by_role("button", name="Add attachment")
            attachment_box = attachment_button.bounding_box()
            if attachment_box is None:
                raise RuntimeError("Add attachment button has no bounding box")
            attachment_button.click()
            page.wait_for_timeout(500)
            emit(
                "attachment_menu_opened",
                body_tail=safe_body_text(page)[-800:],
            )
            with page.expect_file_chooser() as file_chooser_info:
                # Flutter's canvas-backed popup exposes only its dismiss
                # barrier to Chromium accessibility. The final transcription
                # item opens over the attachment button, so a second click at
                # the anchor activates it without depending on painted text.
                page.mouse.click(
                    attachment_box["x"] + attachment_box["width"] / 2,
                    attachment_box["y"] + attachment_box["height"] / 2,
                )
            file_chooser_info.value.set_files(args.speech_audio_path)
            emit(
                "speech_file_selected",
                filename=Path(args.speech_audio_path).name,
                encodedByteLength=Path(args.speech_audio_path).stat().st_size,
            )
        else:
            enter_chat_prompt(page, args.prompt)
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
        if args.speech_audio_path:
            copied_response = copy_last_assistant_response(
                page,
                min(args.response_timeout_ms, 30000),
            )
            if args.expect.lower() not in copied_response.lower():
                raise RuntimeError(
                    "Copied speech transcript did not contain expected text: "
                    f"{copied_response!r}"
                )
            if "<asr_text>" in copied_response:
                raise RuntimeError("Raw Qwen3-ASR control markers leaked into the chat UI")
            emit(
                "rendered_speech_transcript_verified",
                source="selected-file",
                method="copy-response",
                character_count=len(copied_response),
            )
            body_after_response = safe_body_text(page)
        microphone_bridge_response = None
        if args.speech_microphone:
            page.evaluate("() => { window.__llamadartRealBridgeLastResponse = null; }")
            record_button = page.get_by_role(
                "button", name="Record for transcription"
            )
            record_button.click()
            stop_recording_button = page.get_by_role(
                "button", name="Stop & transcribe"
            )
            try:
                stop_recording_button.wait_for(timeout=30000)
            except PlaywrightTimeoutError as error:
                emit(
                    "microphone_recording_start_failed",
                    body_tail=safe_body_text(page)[-1200:],
                    console_tail=console_logs[-20:],
                    page_errors=page_errors[-10:],
                )
                raise RuntimeError(
                    "Browser microphone recording did not enter the active state."
                ) from error
            with wave.open(args.speech_audio_path, "rb") as wav_input:
                capture_seconds = wav_input.getnframes() / wav_input.getframerate()
            page.wait_for_timeout(int((capture_seconds + 0.75) * 1000))
            stop_recording_button.click()
            try:
                page.get_by_role("button", name="Stop generation").wait_for(
                    timeout=30000
                )
                emit("microphone_generation_started")
            except PlaywrightTimeoutError:
                emit("microphone_generation_start_not_observed")
            microphone_bridge_response, _ = wait_for_bridge_response(
                page,
                args.expect,
                args.response_timeout_ms,
                False,
                args.response_source,
            )
            copied_microphone_response = copy_last_assistant_response(
                page,
                min(args.response_timeout_ms, 30000),
            )
            if args.expect.lower() not in copied_microphone_response.lower():
                raise RuntimeError(
                    "Copied microphone transcript did not contain expected text: "
                    f"{copied_microphone_response!r}"
                )
            if "<asr_text>" in copied_microphone_response:
                raise RuntimeError(
                    "Raw Qwen3-ASR control markers leaked from microphone transcription"
                )
            emit(
                "rendered_speech_transcript_verified",
                source="microphone",
                method="copy-response",
                character_count=len(copied_microphone_response),
                capture_seconds=round(capture_seconds, 3),
            )
            body_after_response = safe_body_text(page)
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
              allowAutoRemoteFetchBackend:
                window.__llamadartBridgeAllowAutoRemoteFetchBackend ?? null,
              forceRemoteFetchBackend:
                window.__llamadartBridgeForceRemoteFetchBackend ?? null,
              liteRtLmModuleUrl: window.__llamadartLiteRtLmModuleUrl ?? null,
              liteRtLmPatched: window.LiteRtLmEngine?.__llamadartRealE2ePatched ?? null,
              promptSpeechToTextSupported:
                window.__llamadartBridgeSpeechToTextSupported ?? null,
            })"""
        )
        if args.expect_mmproj_cache_hit and len(mmproj_requests) != 1:
            raise RuntimeError(
                "Expected one mmproj network request from CacheStorage prefetch, "
                f"but saw {len(mmproj_requests)} requests: {mmproj_requests}"
            )
        emit(
            "result",
            ok=True,
            elapsedSeconds=round(time.monotonic() - started_at, 1),
            modelUrl=args.model_url,
            mmprojUrl=args.mmproj_url,
            expectedText=args.expect,
            variant=(
                "speechToTextWithMicrophone"
                if args.speech_microphone
                else ("speechToText" if args.speech_audio_path else "chat")
            ),
            speechAudio=(
                {
                    "filename": Path(args.speech_audio_path).name,
                    "encodedByteLength": Path(args.speech_audio_path).stat().st_size,
                }
                if args.speech_audio_path
                else None
            ),
            bridgeResponse=bridge_response,
            microphoneBridgeResponse=microphone_bridge_response,
            remoteFetchMode=remote_fetch_mode,
            mmprojRequestCount=len(mmproj_requests),
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
