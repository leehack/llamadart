import json
import platform
import re
import time
from typing import Any, Callable

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError


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


def safe_body_text(page, timeout_ms: int = 5000) -> str:
    try:
        return page.locator("body").inner_text(timeout=timeout_ms)
    except Exception as error:
        return f"<body unavailable: {error}>"


def enable_flutter_semantics(
    page,
    *,
    timeout_ms: int = 120000,
    settle_timeout_ms: int = 1000,
) -> None:
    semantics = page.locator("flt-semantics-placeholder")
    semantics.wait_for(timeout=timeout_ms)
    try:
        semantics.evaluate("(element) => element.click()")
    except Exception:
        semantics.focus()
        page.keyboard.press("Enter")
    page.wait_for_timeout(settle_timeout_ms)


def local_storage_init_script(
    settings: dict[str, str],
    *,
    remove_keys: tuple[str, ...] = (),
) -> str:
    remove_lines = "\n".join(
        f"localStorage.removeItem({json.dumps(key)});" for key in remove_keys
    )
    return f"""
      const seededSettings = {json.dumps(settings)};
      for (const [key, value] of Object.entries(seededSettings)) {{
        localStorage.setItem(key, value);
      }}
      {remove_lines}
    """


def append_console_log(
    console_logs: list[dict[str, str]],
    message,
    *,
    limit: int = 3000,
    echo_predicate: Callable[[dict[str, str]], bool] | None = None,
) -> dict[str, str]:
    record = {
        "type": str(message.type),
        "text": truncate_text(str(message.text), limit=limit),
    }
    console_logs.append(record)
    if echo_predicate is not None and echo_predicate(record):
        emit("console", **record)
    return record


def enter_chat_prompt(
    page, prompt: str, *, timeout_ms: int = 30000, button_name: str = "Send message"
) -> None:
    textbox = page.get_by_role("textbox").last
    textbox.click()
    modifier = "Meta" if platform.system() == "Darwin" else "Control"
    page.keyboard.press(f"{modifier}+A")
    page.keyboard.press("Backspace")
    page.keyboard.type(prompt)
    wait_for_send_enabled(page, timeout_ms=timeout_ms, button_name=button_name)


def wait_for_send_enabled(
    page, *, timeout_ms: int = 30000, button_name: str = "Send message"
) -> None:
    deadline = time.monotonic() + (timeout_ms / 1000)
    button = page.get_by_role("button", name=button_name)
    while time.monotonic() < deadline:
        try:
            if button.is_enabled(timeout=250):
                return
        except PlaywrightTimeoutError:
            pass
        time.sleep(0.05)
    raise TimeoutError(f"Timed out waiting for {button_name} button to enable")


def normalized_words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.lower().replace("\u2019", "'"))


def word_error_rate(reference: str, hypothesis: str) -> float:
    """Word-level edit distance over the reference length, ignoring case and
    punctuation."""
    reference_words = normalized_words(reference)
    hypothesis_words = normalized_words(hypothesis)
    if not reference_words:
        return 0.0 if not hypothesis_words else 1.0
    previous = list(range(len(hypothesis_words) + 1))
    for i, expected in enumerate(reference_words, 1):
        current = [i]
        for j, actual in enumerate(hypothesis_words, 1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (expected != actual),
                )
            )
        previous = current
    return previous[-1] / len(reference_words)


def contains_words(text: str, expected: str) -> bool:
    """Whether `expected` occurs in `text`, as a substring or as a run of
    words that differ only in case and punctuation."""
    if expected.lower() in text.lower():
        return True
    needle = normalized_words(expected)
    haystack = normalized_words(text)
    return bool(needle) and any(
        haystack[start : start + len(needle)] == needle
        for start in range(len(haystack) - len(needle) + 1)
    )
