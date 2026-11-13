#!/usr/bin/env python3
"""Drives the chat app's Web microphone recorder through its failure paths.

Every case checks the message the app shows and that the browser released the
microphone: no live track, no open AudioContext, no unrevoked recording blob.
"""
import argparse
import json
import re
import tempfile
import time
import wave
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

from playwright_chat_app_real_model_smoke import wait_for_text
from playwright_chat_app_utils import (
    browser_args,
    emit,
    enable_flutter_semantics,
    local_storage_init_script,
    safe_body_text,
    word_error_rate,
)

CASES = ("discard", "too-short", "track-ended", "denied")

DENIED_MESSAGE = "Microphone permission was denied."
TOO_SHORT_MESSAGE = "The microphone recording was too short."
INTERRUPTED_MESSAGE = (
    "Microphone input was interrupted. Using the audio recorded so far."
)
FAILURE_MARKERS = (
    "Transcription failed:",
    DENIED_MESSAGE,
    TOO_SHORT_MESSAGE,
    "The microphone recording was silent or too quiet.",
    "The browser microphone returned an unsupported WAV encoding.",
    "No microphone was found.",
    "Could not start browser microphone recording.",
    "Could not finish browser microphone recording.",
    "The browser did not return a completed microphone recording.",
    "The microphone recording did not contain valid WAV audio.",
)

# Wraps the browser APIs that hold the microphone, so a case can tell what the
# app released. begin() marks a case; snapshot() reports what happened since.
INSTRUMENTATION_SCRIPT = """
(() => {
  const state = {streams: [], contexts: [], blobs: [], events: [], gumErrors: []};
  const mark = {name: null, streams: 0, contexts: 0, blobs: 0, events: 0, gumErrors: 0};
  const devices = navigator.mediaDevices;
  if (devices && typeof devices.getUserMedia === 'function') {
    const original = devices.getUserMedia.bind(devices);
    devices.getUserMedia = async (constraints) => {
      try {
        const stream = await original(constraints);
        const record = {stream, tracks: []};
        for (const track of stream.getTracks()) {
          const entry = {track, ended: false};
          track.addEventListener('ended', () => {
            entry.ended = true;
            state.events.push('track-ended');
          });
          record.tracks.push(entry);
        }
        state.streams.push(record);
        return stream;
      } catch (error) {
        state.gumErrors.push(String(error?.name ?? error));
        throw error;
      }
    };
  }
  const OriginalAudioContext = window.AudioContext;
  if (typeof OriginalAudioContext === 'function') {
    window.AudioContext = class extends OriginalAudioContext {
      constructor(...args) {
        super(...args);
        state.contexts.push(this);
      }
    };
  }
  const create = URL.createObjectURL.bind(URL);
  const revoke = URL.revokeObjectURL.bind(URL);
  URL.createObjectURL = (object) => {
    const url = create(object);
    if (object instanceof Blob && object.type === 'audio/wav') {
      state.blobs.push({url, revoked: false});
    }
    return url;
  };
  URL.revokeObjectURL = (url) => {
    for (const blob of state.blobs) {
      if (blob.url === url) blob.revoked = true;
    }
    return revoke(url);
  };
  window.__llamadartMicBegin = (name) => {
    mark.name = name;
    mark.streams = state.streams.length;
    mark.contexts = state.contexts.length;
    mark.blobs = state.blobs.length;
    mark.events = state.events.length;
    mark.gumErrors = state.gumErrors.length;
  };
  window.__llamadartMicSnapshot = () => ({
    tracks: state.streams.slice(mark.streams).flatMap((record) =>
      record.tracks.map((entry) => ({
        readyState: entry.track.readyState,
        ended: entry.ended,
      }))),
    contexts: state.contexts.slice(mark.contexts).map((context) => context.state),
    blobsRevoked: state.blobs.slice(mark.blobs).map((blob) => blob.revoked),
    events: state.events.slice(mark.events),
    gumErrors: state.gumErrors.slice(mark.gumErrors),
  });
})();
"""

BEGIN_CASE_SCRIPT = "(name) => window.__llamadartMicBegin(name)"
SNAPSHOT_SCRIPT = "() => window.__llamadartMicSnapshot()"


class CaseFailure(Exception):
    pass


def release_problems(snapshot: dict) -> list[str]:
    """What the page still holds after a case, from an instrumentation
    snapshot."""
    problems = []
    live = sum(1 for track in snapshot["tracks"] if track["readyState"] == "live")
    if live:
        problems.append(f"{live} live microphone track(s)")
    open_contexts = sum(1 for state in snapshot["contexts"] if state != "closed")
    if open_contexts:
        problems.append(f"{open_contexts} AudioContext(s) not closed")
    unrevoked = sum(1 for revoked in snapshot["blobsRevoked"] if not revoked)
    if unrevoked:
        problems.append(f"{unrevoked} recording blob URL(s) not revoked")
    return problems


def failure_markers(body: str) -> list[str]:
    return [marker for marker in FAILURE_MARKERS if marker in body]


def new_markers(body: str, baseline: str) -> list[str]:
    return [
        marker
        for marker in FAILURE_MARKERS
        if body.count(marker) > baseline.count(marker)
    ]


def record_button(page):
    return page.get_by_role("button", name="Record for transcription")


def stop_button(page):
    return page.get_by_role("button", name="Stop & transcribe")


def wait_until(predicate, timeout_s: float, label: str):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    raise CaseFailure(f"Timed out waiting for {label}")


def is_idle(page) -> bool:
    try:
        return bool(record_button(page).is_enabled(timeout=500))
    except Exception:  # noqa: BLE001
        return False


def start_recording(page) -> None:
    record_button(page).click()
    try:
        stop_button(page).wait_for(timeout=30000)
    except Exception as error:  # noqa: BLE001
        raise CaseFailure(
            "Recording did not start: " + safe_body_text(page)[-600:]
        ) from error


def run_discard(page, context, args, baseline: str) -> list[str]:
    start_recording(page)
    page.wait_for_timeout(3000)
    page.get_by_role("button", name="Discard").click()
    wait_until(lambda: is_idle(page), 30, "the composer to go idle")
    page.wait_for_timeout(1000)
    unexpected = new_markers(safe_body_text(page), baseline)
    if unexpected:
        raise CaseFailure(f"Discarding showed a message: {unexpected}")
    return []


def run_too_short(page, context, args, baseline: str) -> list[str]:
    start_recording(page)
    page.wait_for_timeout(1200)
    stop_button(page).click()
    wait_until(
        lambda: TOO_SHORT_MESSAGE in new_markers(safe_body_text(page), baseline),
        args.message_timeout_ms / 1000,
        f"{TOO_SHORT_MESSAGE!r}",
    )
    wait_until(lambda: is_idle(page), 30, "the composer to go idle")
    return [TOO_SHORT_MESSAGE]


def copy_buttons(page) -> int:
    return page.get_by_role("button", name="Copy response").count()


def run_track_ended(page, context, args, baseline: str) -> list[str]:
    responses_before = copy_buttons(page)
    start_recording(page)
    page.wait_for_timeout(4500)
    # Revoking the permission is how the browser ends a live track on its own.
    context.clear_permissions()
    ended = wait_until(
        lambda: page.evaluate(SNAPSHOT_SCRIPT)["events"].count("track-ended"),
        10,
        "the browser to fire 'ended' on the microphone track",
    )
    emit("lifecycle_track_ended", ended_events=ended)
    # clear_permissions also drops the clipboard grants the checks below need.
    grant_permissions(context, args, microphone=True)
    wait_until(
        lambda: INTERRUPTED_MESSAGE in safe_body_text(page),
        args.message_timeout_ms / 1000,
        f"{INTERRUPTED_MESSAGE!r}",
    )
    wait_until(
        lambda: copy_buttons(page) > responses_before,
        args.response_timeout_ms / 1000,
        "a transcript of the partial recording",
    )
    wait_until(lambda: is_idle(page), 30, "the composer to go idle")
    unexpected = new_markers(safe_body_text(page), baseline)
    if unexpected:
        raise CaseFailure(f"The partial take failed: {unexpected}")
    transcript = copy_last_response(page)
    error_rate = word_error_rate(args.reference, transcript)
    emit("lifecycle_partial_transcript", transcript=transcript, wer=error_rate)
    if not transcript.strip() or error_rate >= 1:
        raise CaseFailure(f"Empty or unrelated partial transcript: {transcript!r}")
    return []


def grant_permissions(context, args, *, microphone: bool) -> None:
    parts = urlsplit(args.app_url)
    context.grant_permissions(
        ["clipboard-read", "clipboard-write"] + (["microphone"] if microphone else []),
        origin=f"{parts.scheme}://{parts.netloc}",
    )


def copy_last_response(page) -> str:
    button = page.get_by_role("button", name="Copy response").last
    button.click()
    return str(page.evaluate("() => navigator.clipboard.readText()") or "")


def run_denied(page, context, args, baseline: str) -> list[str]:
    record_button(page).click()
    wait_until(
        lambda: DENIED_MESSAGE in new_markers(safe_body_text(page), baseline),
        args.message_timeout_ms / 1000,
        f"{DENIED_MESSAGE!r}",
    )
    if stop_button(page).is_visible():
        raise CaseFailure("The recording UI stayed up after the denial")
    return [DENIED_MESSAGE]


CASE_RUNNERS = {
    "discard": run_discard,
    "too-short": run_too_short,
    "track-ended": run_track_ended,
    "denied": run_denied,
}


def run_case(name: str, page, context, args) -> dict:
    wait_until(lambda: is_idle(page), 60, "an idle composer")
    baseline = safe_body_text(page)
    page.evaluate(BEGIN_CASE_SCRIPT, name)
    result = {"case": name, "ok": False, "problems": []}
    try:
        CASE_RUNNERS[name](page, context, args, baseline)
        page.wait_for_timeout(1500)
        snapshot = page.evaluate(SNAPSHOT_SCRIPT)
        result["snapshot"] = snapshot
        if name == "denied":
            if "NotAllowedError" not in snapshot["gumErrors"]:
                result["problems"].append(
                    "the browser never rejected getUserMedia with NotAllowedError"
                )
        else:
            for key, what in (
                ("tracks", "a microphone stream"),
                ("contexts", "an AudioContext"),
                ("blobsRevoked", "a recording blob URL"),
            ):
                if not snapshot[key]:
                    result["problems"].append(f"the app never opened {what}")
        result["problems"].extend(release_problems(snapshot))
    except CaseFailure as error:
        result["problems"].append(str(error))
        try:
            result["snapshot"] = page.evaluate(SNAPSHOT_SCRIPT)
            result["problems"].extend(release_problems(result["snapshot"]))
        except Exception:  # noqa: BLE001
            pass
    result["ok"] = not result["problems"]
    emit("lifecycle_case", **result)
    return result


def seeded_settings(args) -> dict[str, str]:
    return {
        "flutter.model_path": json.dumps(args.model_url),
        "flutter.mmproj_path": json.dumps(args.mmproj_url),
        "flutter.preferred_backend": json.dumps(1),
        "flutter.context_size": json.dumps(4096),
        "flutter.max_tokens": json.dumps(512),
        "flutter.gpu_layers": json.dumps(0),
        "flutter.threads": json.dumps(2),
        "flutter.threads_batch": json.dumps(2),
        "flutter.temperature": json.dumps(0.0),
        "flutter.top_k": json.dumps(1),
        "flutter.top_p": json.dumps(1.0),
        "flutter.min_p": json.dumps(0.0),
        "flutter.penalty": json.dumps(1.0),
        "flutter.tools_enabled": json.dumps(False),
        "flutter.tool_declarations": json.dumps("[]"),
        "flutter.thinking_enabled": json.dumps(False),
        "flutter.single_turn_mode": json.dumps(True),
        "flutter.model_supports_audio": json.dumps(True),
        "flutter.model_supports_speech_to_text": json.dumps(True),
        "flutter.log_level": json.dumps(0),
        "flutter.native_log_level": json.dumps(2),
    }


def fake_microphone_clip(source: str, directory: str) -> str:
    """A capture file that plays one second of silence, then the clip once.

    Without %noloop Chromium repeats the clip for as long as the page records.
    """
    target = Path(directory) / "capture.wav"
    with wave.open(source, "rb") as clip:
        params = clip.getparams()
        frames = clip.readframes(params.nframes)
    if params.sampwidth != 2:
        raise ValueError("Fake microphone input must use PCM16 WAV")
    with wave.open(str(target), "wb") as padded:
        padded.setparams(params)
        padded.writeframes(bytes(params.framerate * params.nchannels * 2))
        padded.writeframes(frames)
    return f"{target}%noloop"


def run_session(playwright, args, capture_spec: str, cases: list[str], *, deny: bool):
    launch_args = browser_args(args.browser_angle) + [
        "--use-fake-device-for-media-stream",
        f"--use-file-for-fake-audio-capture={capture_spec}",
        "--use-fake-ui-for-media-stream=deny" if deny else "--use-fake-ui-for-media-stream",
    ]
    browser = playwright.chromium.launch(headless=not args.headed, args=launch_args)
    try:
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        grant_permissions(context, args, microphone=not deny)
        page = context.new_page()
        page.set_default_timeout(120000)
        page.add_init_script(
            f"""
            window.__llamadartPreferLocalBridgeRuntime = true;
            window.__llamadartBridgeThreadPoolSize = 2;
            window.__llamadartBridgeEnableMem64 = false;
            window.__llamadartBridgePreferMemory64 = false;
            {local_storage_init_script(seeded_settings(args))}
            """
        )
        page.add_init_script(INSTRUMENTATION_SCRIPT)
        page.goto(args.app_url, wait_until="domcontentloaded")
        enable_flutter_semantics(page)
        button = page.get_by_role("button", name=re.compile(r"Load Model", re.I))
        button.wait_for(timeout=120000)
        emit("load_click", model_url=args.model_url, denied_launch=deny)
        button.click()
        wait_for_text(
            page,
            "Model loaded successfully! Ready to chat.",
            args.load_timeout_ms,
            "model load",
        )
        return [run_case(name, page, context, args) for name in cases]
    finally:
        browser.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app_url")
    parser.add_argument("--model-url", required=True)
    parser.add_argument("--mmproj-url", required=True)
    parser.add_argument(
        "--speech-audio-path",
        required=True,
        help="PCM16 WAV the fake microphone plays after one second of silence.",
    )
    parser.add_argument(
        "--reference",
        required=True,
        help="Transcript of --speech-audio-path.",
    )
    parser.add_argument(
        "--cases",
        default=",".join(CASES),
        help=f"Comma-separated subset of: {', '.join(CASES)}.",
    )
    parser.add_argument("--message-timeout-ms", type=int, default=30000)
    parser.add_argument("--load-timeout-ms", type=int, default=20 * 60 * 1000)
    parser.add_argument("--response-timeout-ms", type=int, default=5 * 60 * 1000)
    parser.add_argument(
        "--browser-angle",
        choices=["auto", "default", "metal", "vulkan"],
        default="auto",
    )
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()
    cases = [name for name in args.cases.split(",") if name]
    unknown = [name for name in cases if name not in CASES]
    if unknown or not cases:
        parser.error(f"--cases must name some of {', '.join(CASES)}: {unknown}")
    audio_path = Path(args.speech_audio_path).resolve()
    if not audio_path.is_file() or audio_path.suffix.lower() != ".wav":
        parser.error(f"--speech-audio-path must be an existing WAV: {audio_path}")
    args.speech_audio_path = str(audio_path)

    started_at = time.monotonic()
    results: list[dict] = []
    with tempfile.TemporaryDirectory(
        prefix="llamadart-fake-microphone-"
    ) as tmp_dir, sync_playwright() as playwright:
        capture_spec = fake_microphone_clip(args.speech_audio_path, tmp_dir)
        shared = [name for name in cases if name != "denied"]
        if shared:
            results += run_session(playwright, args, capture_spec, shared, deny=False)
        if "denied" in cases:
            results += run_session(playwright, args, capture_spec, ["denied"], deny=True)
    failed = [result for result in results if not result["ok"]]
    emit(
        "result",
        ok=not failed,
        elapsedSeconds=round(time.monotonic() - started_at, 1),
        cases={result["case"]: result["problems"] or "ok" for result in results},
    )
    if failed:
        raise RuntimeError(
            "Microphone lifecycle failures: "
            + "; ".join(f"{r['case']}: {r['problems']}" for r in failed)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
