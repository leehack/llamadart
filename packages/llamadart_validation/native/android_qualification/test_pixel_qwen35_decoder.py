"""Model-free checks of collection admission and exact native-byte transport."""
import base64
import tempfile
from pathlib import Path
import unittest
import pixel_qwen35_decoder as d


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.canonical = self.root / d.COLLECTION_JOURNAL
        self.canonical.parent.mkdir(parents=True)
        self.raw = b'{"event":"unqualified fixture"}\n'
        self.canonical.write_bytes(self.raw)
        self.alias = self.canonical.parent / d.PRODUCER_RUN / 'journal.jsonl'

    def test_canonical_and_one_exact_known_alias(self):
        self.assertEqual(d.collection_journal(self.root), self.canonical)
        self.alias.parent.mkdir()
        self.alias.write_bytes(self.raw)
        self.assertEqual(d.collection_journal(self.root), self.canonical)
        self.alias.write_bytes(self.raw + b'\n')
        with self.assertRaises(ValueError):
            d.collection_journal(self.root)

    def test_foreign_extra_or_missing_canonical(self):
        foreign = self.root / 'foreign' / 'journal.jsonl'
        foreign.parent.mkdir()
        foreign.write_bytes(self.raw)
        with self.assertRaises(ValueError):
            d.collection_journal(self.root)
        self.canonical.unlink()
        with self.assertRaises(ValueError):
            d.collection_journal(self.root)

    def test_symlinks_and_size_bound(self):
        self.alias.parent.mkdir()
        self.alias.symlink_to(self.canonical)
        with self.assertRaises(ValueError):
            d.collection_journal(self.root)
        self.alias.unlink()
        with self.canonical.open('wb') as output:
            output.truncate(8 * 1024 * 1024 + 1)
        with self.assertRaises(ValueError):
            d.collection_journal(self.root)

    def test_exact_capture_and_corrupted_hash_or_length(self):
        raw = bytes([0, 255, 128, 13, 10])
        capture = {'base64': base64.b64encode(raw).decode(), 'bytes': len(raw), 'sha256': d.digest(raw)}
        self.assertEqual(d.capture(capture), raw)
        for field, value in [('bytes', 1), ('sha256', '0' * 64), ('base64', '!!!')]:
            with self.assertRaises(ValueError):
                d.capture({**capture, field: value})

    def test_native_proof_is_embedded_and_optional_raw_must_agree(self):
        raw = bytes([0, 255, 128, 13, 10])
        lock = {'schema': 'pixel-native-stderr.v1', 'file': 'cpu-original.stderr.log',
                'base64': base64.b64encode(raw).decode(), 'bytes': len(raw), 'sha256': d.digest(raw)}
        self.assertEqual(d.native_stderr(self.root, 'cpu-original', lock), raw)
        sibling = self.root / lock['file']
        sibling.write_bytes(raw)
        self.assertEqual(d.native_stderr(self.root, 'cpu-original', lock), raw)
        sibling.write_bytes(b'changed')
        with self.assertRaises(ValueError):
            d.native_stderr(self.root, 'cpu-original', lock)
        sibling.unlink()
        sibling.symlink_to(self.canonical)
        with self.assertRaises(ValueError):
            d.native_stderr(self.root, 'cpu-original', lock)
        for bad in [{k: v for k, v in lock.items() if k != 'schema'}, {**lock, 'file': '../foreign'}]:
            with self.assertRaises(ValueError):
                d.native_stderr(self.root, 'cpu-original', bad)


if __name__ == '__main__':
    unittest.main()
