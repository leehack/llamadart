"""Root formatting keeps independently pinned Studio out of the old SDK."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('check_format', ROOT / 'tool/ci/check_format.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class FormatTargetsTest(unittest.TestCase):
    def test_keeps_root_and_other_packages_but_excludes_studio_and_hidden_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('lib', 'test', 'tool', 'example', 'website', '.dart_tool',
                         'packages/llamadart_studio', 'packages/llamadart_studio_core',
                         'packages/llamadart_model_store', 'packages/future_package'):
                (root / name).mkdir(parents=True, exist_ok=True)
            (root / 'main.dart').touch()
            (root / 'README.md').touch()
            self.assertEqual(check.format_targets(root), [
                'example', 'lib', 'main.dart', 'packages/future_package',
                'packages/llamadart_model_store', 'test', 'tool', 'website'])
