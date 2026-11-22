@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/bounded_process.dart';

const _driver = 'tool/testing/playwright_web_js_backed_model_staging.py';
const _fixtures = 'test/fixtures';

const _replayReceipts = r'''
import json
import runpy
import sys
from contextlib import redirect_stdout
from copy import deepcopy
from io import StringIO
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import TestCase, main as run_tests
from unittest.mock import MagicMock, Mock, patch

driver, fixtures = sys.argv[1:]
origin = "https://fixture.invalid"
model_url = f"{origin}/model.gguf"
projector_url = f"{origin}/projector.gguf"

api = ModuleType("playwright.sync_api")
api.sync_playwright = Mock()
with patch.dict(sys.modules, {"playwright": ModuleType("playwright"),
                              "playwright.sync_api": api}):
    functions = runpy.run_path(driver)
run_case = functions["run_case"]
main = functions["main"]


def read_fixture(suffix):
    path = Path(fixtures) / f"web_js_backed_model_staging_{suffix}.json"
    return json.loads(path.read_text(encoding="utf-8"))


# Chromium receipts from audit-2165-a8eeb693/browser.log.
cases = read_fixture("chromium")


def replay(receipt, *, isolated=True, **options):
    browser = Mock()
    context = browser.new_context.return_value
    page = context.new_page.return_value

    def evaluate(script, config=None):
        if script == "crossOriginIsolated":
            return isolated
        if script != functions["BOOTSTRAP"]:
            raise ValueError("Unexpected page evaluation")
        event, request_listener = context.on.call_args.args
        if event != "request":
            raise ValueError("Expected a request listener")
        for method in receipt.get("model_requests", []):
            request_listener(SimpleNamespace(url=model_url, method=method))
        return receipt["result"]

    page.evaluate.side_effect = evaluate
    with redirect_stdout(StringIO()):
        return run_case(
            browser, origin, model_url, name="receipt-replay",
            worker=receipt["worker"], mem64=receipt.get("memory64", False),
            stage=receipt.get("staging"), **options,
        )


def without_note(notes, missing):
    return ";".join(note for note in notes.split(";") if note != missing)


def run_cli(results):
    # Match the real CLI at the run_case boundary so only its comparison
    # sees the divergent output. Reload parity is tested separately.
    argv = [driver, origin, "--model-url", model_url, "--mmproj-url", projector_url]
    playwright = MagicMock()
    playwright.__enter__.return_value.chromium.launch.return_value.version = "fixture"
    with patch.object(sys, "argv", argv), patch.object(Path, "is_file", return_value=True),          patch.dict(main.__globals__, {
             "prepare_legacy_assets": Mock(),
             "setup_measurement_loaders": Mock(),
             "asset_receipt": Mock(return_value=None),
             "sync_playwright": Mock(return_value=playwright),
             "run_case": lambda *args, name, **options: results.get(name),
         }), redirect_stdout(StringIO()):
        main()


projector_options = dict(mmproj_url=projector_url, reuse=True, gpu=True)
refusals = {
    "old-bridge-v0.1.86": dict(old_bridge="v0.1.86"),
    "old-worker": dict(old_worker=True),
    "old-core": dict(old_core=True),
    "forced-fetch": dict(forced_fetch=True),
}


class GraderTest(TestCase):
    def test_success_fields(self):
        receipt = cases["extra-staged"]
        options = dict(projector_options, reuse=False)
        self.assertEqual(replay(receipt, **options), receipt["result"])
        notes = receipt["result"]["runtime_notes"]
        changes = {
            "blank output": ("output", " \n"),
            "wrong execution": ("execution", "worker"),
            "worker fallback": ("worker_fallback_reason", "worker unavailable"),
            "wrong core variant": ("core_variant", "wasm64"),
            "missing model staging": (
                "runtime_notes", without_note(notes, "model_staging_js_backed"),
            ),
            "missing projector staging": (
                "runtime_notes", without_note(notes, "mmproj_staging_js_backed"),
            ),
            "projector not loaded": ("mmproj_loaded", "0"),
            "missing WebGPU": ("backends", "CPU"),
        }
        for name, (field, value) in changes.items():
            with self.subTest(name):
                modified = deepcopy(receipt)
                modified["result"][field] = value
                with self.assertRaises(AssertionError):
                    replay(modified, **options)

    def test_missing_core_variant(self):
        receipt = deepcopy(cases["explicit-on"])
        self.assertEqual(replay(receipt, reuse=True), receipt["result"])
        del receipt["result"]["core_variant"]
        with self.assertRaises(KeyError):
            replay(receipt, reuse=True)

    def test_cross_origin_isolation(self):
        receipt = cases["chromium-default"]
        self.assertEqual(replay(receipt), receipt["result"])
        with self.assertRaises(AssertionError):
            replay(receipt, isolated=False)

    def test_refusal_reasons(self):
        for name, options in refusals.items():
            with self.subTest(name):
                receipt = deepcopy(cases[name])
                self.assertIsNone(replay(receipt, **options))
                receipt["result"]["unsupported"] = "unexpected refusal reason"
                with self.assertRaises(AssertionError):
                    replay(receipt, **options)

    def test_refusal_model_requests(self):
        receipt = deepcopy(cases["old-bridge-v0.1.86"])
        options = refusals["old-bridge-v0.1.86"]
        self.assertIsNone(replay(receipt, **options))
        receipt["model_requests"].append("GET")
        with self.assertRaises(AssertionError):
            replay(receipt, **options)

    def test_refusal_construction_and_load_counts(self):
        for name in ("old-bridge-v0.1.86", "old-core"):
            options = refusals[name]
            self.assertIsNone(replay(cases[name], **options))
            for field in ("constructions", "loads"):
                with self.subTest(name, field=field):
                    receipt = deepcopy(cases[name])
                    receipt["result"][field] = 1 - receipt["result"][field]
                    with self.assertRaises(AssertionError):
                        replay(receipt, **options)

    def test_staging_defaults_and_old_worker_opt_out(self):
        for name, options in (
            ("webkit-default", dict(webkit=True)),
            ("webkit-opt-out", dict(webkit=True)),
            ("old-worker-opt-out", dict(old_worker=True)),
        ):
            with self.subTest(name):
                receipt = cases[name]
                self.assertEqual(replay(receipt, **options), receipt["result"])

    def test_core_memory(self):
        receipt = cases["worker-extra-staged"]
        self.assertEqual(replay(receipt, **projector_options), receipt["result"])
        memory = receipt["result"]["coreMemory"]
        for field, value in (
            ("scope", "page"),
            ("wasmBytes", 0),
            ("peakWasmBytes", memory["wasmBytes"] - 1),
        ):
            with self.subTest(field):
                modified = deepcopy(receipt)
                modified["result"]["coreMemory"][field] = value
                with self.assertRaises(AssertionError):
                    replay(modified, **projector_options)
        modified = deepcopy(receipt)
        modified["result"]["coreMemory"] = None
        with self.assertRaises(AssertionError):
            replay(modified, **projector_options)
        modified = deepcopy(receipt)
        del modified["result"]["coreMemory"]
        with self.assertRaises(KeyError):
            replay(modified, **projector_options)

    def test_reload(self):
        receipt = cases["extra-staged"]
        self.assertEqual(replay(receipt, **projector_options), receipt["result"])
        for field, value in (("mmproj_loaded", "0"), ("output", "different output")):
            with self.subTest(field):
                modified = deepcopy(receipt)
                modified["result"]["reloaded"][field] = value
                with self.assertRaises(AssertionError):
                    replay(modified, **projector_options)
        modified = deepcopy(receipt)
        del modified["result"]["reloaded"]
        with self.assertRaises(KeyError):
            replay(modified, **projector_options)

    def test_cli_output_parity(self):
        results = {name: cases[name]["result"] for name in (
            "chromium-default", "explicit-on", "extra-default", "extra-staged",
        )}
        run_cli(results)
        for staged, default in (("explicit-on", "chromium-default"),
                                ("extra-staged", "extra-default")):
            with self.subTest(staged):
                different = dict(results[staged], output="different output")
                with self.assertRaises(AssertionError) as failure:
                    run_cli(dict(results, **{staged: different}))
                self.assertEqual(failure.exception.args, ((different, results[default]),))

    def test_large_control_accepts_wasm64_retry(self):
        # Qwen3-4B control from audit-2165-a8eeb693/browser-large.jsonl, line 6.
        receipt = read_fixture("chromium_large_wasm64_retry")
        self.assertEqual(replay(receipt, extra_control=True), receipt["result"])
        with self.assertRaises(AssertionError):
            replay(receipt)
        receipt["result"]["output"] = " "
        with self.assertRaises(AssertionError):
            replay(receipt, extra_control=True)

    def test_large_control_accepts_transfer_length_model_error(self):
        # The transfer-length probe is from w2115m/audit-fixes/chromium-after.jsonl, line 5.
        receipt = read_fixture("chromium_transfer_length_model_error")
        result = replay(receipt, extra_control=True)
        self.assertEqual(result, receipt["result"])
        with self.assertRaises(AssertionError):
            replay(receipt)
        run_cli({
            "chromium-default": cases["chromium-default"]["result"],
            "explicit-on": cases["explicit-on"]["result"],
            "extra-default": result,
            "extra-staged": cases["extra-staged"]["result"],
        })


run_tests(argv=[driver], verbosity=2)
''';

void main() {
  test('staging driver grades sanitized Chromium receipts offline', () async {
    final scratch = await Directory.systemTemp.createTemp('staging_grader_');
    addTearDown(() => scratch.delete(recursive: true));
    final result = await runBoundedProcess(
      Platform.isWindows ? 'python' : 'python3',
      [
        '-I',
        '-B',
        '-c',
        _replayReceipts,
        File(_driver).absolute.path,
        Directory(_fixtures).absolute.path,
      ],
      workingDirectory: scratch.path,
      timeout: const Duration(seconds: 60),
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
