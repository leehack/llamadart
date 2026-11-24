@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/bounded_process.dart';

const _driver = 'tool/testing/playwright_web_js_backed_model_staging.py';

const _driverFixture = r'''
import json
import runpy
import sys
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, Mock, patch

origin = "http://localhost:7358"
model_url = f"{origin}/extra.gguf"
projector_url = f"{origin}/projector.gguf"
driver, = sys.argv[1:]
sys.argv = [driver, f"{origin}/", "--model-url", model_url,
            "--mmproj-url", projector_url, "--gpu"]

playwright = MagicMock()
browser = playwright.__enter__.return_value.chromium.launch.return_value
browser.version = "fixture browser"
api = ModuleType("playwright.sync_api")
api.sync_playwright = Mock(return_value=playwright)
with patch.dict(sys.modules, {"playwright": ModuleType("playwright"),
                              "playwright.sync_api": api}):
    main = runpy.run_path(driver)["main"]

build = Path("build/web_js_backed_model_staging")
build.mkdir(parents=True)
(build / "model.gguf").write_bytes(b"default model")
Path("extra.gguf").write_bytes(b"extra model")
Path("projector.gguf").write_bytes(b"projector")

# Keep the real CLI, loader setup and receipts. Replace downloads and page work.
run_case = Mock(return_value={"output": "fixture output"})
with patch.dict(main.__globals__, {"prepare_legacy_assets": Mock(),
                                   "run_case": run_case}):
    main()

browser.close.assert_called_once_with()
print(json.dumps([case.kwargs for case in run_case.call_args_list
                  if case.args == (browser, origin, model_url)]))
''';

void main() {
  test(
    'staging driver parses projector options and plans browser cases',
    () async {
      final scratch = await Directory.systemTemp.createTemp('staging_driver_');
      addTearDown(() => scratch.delete(recursive: true));

      final result = await runBoundedProcess(
        Platform.isWindows ? 'python' : 'python3',
        ['-I', '-B', '-c', _driverFixture, File(_driver).absolute.path],
        workingDirectory: scratch.path,
        timeout: const Duration(seconds: 60),
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      final [receipt, plan] = const LineSplitter()
          .convert(result.stdout as String)
          .map(jsonDecode)
          .toList();
      expect(receipt['browser'], 'fixture browser');
      expect(receipt['gpu_required'], isTrue);
      expect(receipt['extra_model']['bytes'], 11);
      expect(receipt['projector']['bytes'], 9);
      expect(plan, [
        for (final worker in [false, true])
          for (final mem64 in [false, true]) ...[
            {
              'name': 'extra-default',
              'extra_control': true,
              'worker': worker,
              'mem64': mem64,
              'gpu': true,
              'model_bytes_hint': 11,
              'mmproj_url': 'http://localhost:7358/projector.gguf',
            },
            {
              'name': 'extra-staged',
              'stage': true,
              'reuse': true,
              'worker': worker,
              'mem64': mem64,
              'gpu': true,
              'model_bytes_hint': 11,
              'mmproj_url': 'http://localhost:7358/projector.gguf',
            },
          ],
      ]);
    },
  );
}
