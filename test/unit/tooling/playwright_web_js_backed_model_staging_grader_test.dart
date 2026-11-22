@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/bounded_process.dart';

const _driver = 'tool/testing/playwright_web_js_backed_model_staging.py';
const _receipt = 'test/fixtures/web_js_backed_model_staging_chromium.json';

const _replayReceipt = r'''
import json
import runpy
import sys
from pathlib import Path
from types import ModuleType
from unittest import TestCase
from unittest.mock import patch

driver, receipt_path = sys.argv[1:]
api = ModuleType("playwright.sync_api")
api.sync_playwright = None
with patch.dict(sys.modules, {"playwright": ModuleType("playwright"),
                              "playwright.sync_api": api}):
    grade = runpy.run_path(driver)["assert_success"]

receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
options = dict(worker=receipt["worker"], mem64=receipt["memory64"],
               staged=receipt["staging"])
result = receipt["result"]
grade(result, **options)

without_staging_note = dict(result, runtime_notes=";".join(
    note for note in result["runtime_notes"].split(";")
    if note != "model_staging_js_backed"
))
with TestCase().assertRaises(AssertionError):
    grade(without_staging_note, **options)
''';

void main() {
  test(
    'staging grader accepts the Chromium receipt and rejects a missing staging note',
    () async {
      final result =
          await runBoundedProcess(Platform.isWindows ? 'python' : 'python3', [
            '-I',
            '-B',
            '-c',
            _replayReceipt,
            File(_driver).absolute.path,
            File(_receipt).absolute.path,
          ], timeout: const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
