"""Drive Safari (safaridriver) or Firefox (geckodriver) over W3C WebDriver.

Safari needs Settings > Developer > Allow Remote Automation. Firefox runs the
binary in FIREFOX_EXECUTABLE (the system Firefox when unset) through the
geckodriver in GECKODRIVER (the one on PATH when unset).
"""
import contextlib
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

SAFARIDRIVER = "/usr/bin/safaridriver"
# Generous: a cold Python stand-in driver on a busy CI runner can take this long.
_DRIVER_START_TIMEOUT_S = 60
_ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"


def element_id(reference: dict[str, str]) -> str:
    """Returns the id of an element reference that a script returned."""
    return reference[_ELEMENT_KEY]


class WebDriverError(RuntimeError):
    pass


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _driver_command(browser: str) -> tuple[str, dict[str, Any]]:
    """Returns the driver executable and the W3C capabilities for [browser]."""
    if browser == "safari":
        return SAFARIDRIVER, {"browserName": "safari"}
    if browser != "firefox":
        raise ValueError(f"Unsupported WebDriver browser: {browser}")
    driver = os.environ.get("GECKODRIVER") or shutil.which("geckodriver")
    if not driver:
        raise WebDriverError("geckodriver not found: set GECKODRIVER or add it to PATH")
    capabilities: dict[str, Any] = {"browserName": "firefox"}
    if binary := os.environ.get("FIREFOX_EXECUTABLE"):
        capabilities["moz:firefoxOptions"] = {"binary": binary}
    return driver, capabilities


class SafariSession:
    """One WebDriver process (safaridriver or geckodriver) and one browser window."""

    def __init__(self, *, browser: str = "safari", command_timeout_s: float = 300) -> None:
        self.browser = browser
        driver, capabilities = _driver_command(browser)
        self._timeout = command_timeout_s
        self._port = _free_port()
        # A file, not a pipe: nothing reads stderr while the driver runs, and a
        # chatty driver would block on a full pipe.
        self._stderr = tempfile.TemporaryFile()
        try:
            self._driver = subprocess.Popen(
                [driver, "-p", str(self._port)],
                stdout=subprocess.DEVNULL,
                stderr=self._stderr,
            )
        except BaseException:
            self._stderr.close()
            raise
        self._base = f"http://127.0.0.1:{self._port}"
        self.session_id: str | None = None
        try:
            self._wait_for_driver()
            value = self._request(
                "POST",
                "/session",
                {"capabilities": {"alwaysMatch": capabilities}},
            )
            self.session_id = value["sessionId"]
            self.capabilities = value.get("capabilities", {})
        except BaseException:
            self.close()
            raise

    def _wait_for_driver(self) -> None:
        deadline = time.monotonic() + _DRIVER_START_TIMEOUT_S
        while time.monotonic() < deadline:
            if self._driver.poll() is not None:
                raise WebDriverError(f"{self.browser} driver exited: {self._driver_stderr()}")
            try:
                self._request("GET", "/status")
                return
            except (OSError, WebDriverError):
                time.sleep(0.2)
        detail = self._driver_stderr()
        raise WebDriverError(
            f"{self.browser} driver did not start within {_DRIVER_START_TIMEOUT_S} s"
            + (f": {detail}" if detail else "")
        )

    def _driver_stderr(self) -> str:
        self._stderr.seek(0)
        return self._stderr.read().decode(errors="replace").strip()

    def _request(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            self._base + path,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                payload = json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            payload = json.loads(error.read() or b"{}")
            value = payload.get("value", {})
            raise WebDriverError(
                f"{method} {path}: {value.get('error')}: {value.get('message')}"
            ) from None
        return payload.get("value")

    def _command(self, method: str, path: str, body: Any = None) -> Any:
        return self._request(method, f"/session/{self.session_id}{path}", body)

    def navigate(self, url: str) -> None:
        self._command("POST", "/url", {"url": url})

    def execute(self, script: str, *args: Any) -> Any:
        """Runs [script] as a function body; `return` yields its value."""
        return self._command(
            "POST", "/execute/sync", {"script": script, "args": list(args)}
        )

    def run_in_page(self, script: str) -> None:
        """Runs [script] in the page's own JavaScript world.

        geckodriver executes scripts in a sandbox that hides page globals and
        wraps page objects, so a script that installs capture hooks must run
        as a page <script> element there.
        """
        if self.browser != "firefox":
            self.execute(script)
            return
        self.execute(
            "const node = document.createElement('script');"
            "node.textContent = arguments[0];"
            "document.documentElement.appendChild(node);"
            "node.remove();",
            script,
        )

    def click(self, element: str) -> None:
        self._command("POST", f"/element/{element}/click", {})

    def type_text(self, text: str) -> None:
        actions = [{"type": "keyDown", "value": c} for c in text]
        actions = [
            step
            for action in actions
            for step in (action, {"type": "keyUp", "value": action["value"]})
        ]
        self._command(
            "POST",
            "/actions",
            {"actions": [{"type": "key", "id": "keyboard", "actions": actions}]},
        )
        self._command("DELETE", "/actions")

    def set_window_size(self, width: int, height: int) -> None:
        self._command("POST", "/window/rect", {"width": width, "height": height})

    def close(self) -> None:
        if self.session_id is not None:
            with contextlib.suppress(Exception):
                self._request("DELETE", f"/session/{self.session_id}")
            self.session_id = None
        if self._driver.poll() is None:
            self._driver.terminate()
            try:
                self._driver.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._driver.kill()
                self._driver.wait()
        self._stderr.close()

    def __enter__(self) -> "SafariSession":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()
