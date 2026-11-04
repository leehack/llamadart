"""Source-only admission of retained Dart transport bytes; no SDK or device calls."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import decode_s24 as decoder

FIXTURES = Path(__file__).parent / 'fixtures/dart_transport'


class ExportAliasTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan = {'run_id': 'synthetic-run', 'binding': {'path': str(self.root / 'binding.json')}}
        (self.root / 'binding.json').write_bytes((FIXTURES / 'unicode-2028/binding.json').read_bytes())

    def install(self, export='a', point='2028', framing='lf', encoding='compact'):
        source = FIXTURES / ('unicode-' + point)
        target = self.root / export / self.plan['run_id']
        shutil.copytree(source, target)
        path = target / 's24-litert-public.jsonl'
        path.write_bytes((source / (framing + '-' + encoding + '.jsonl')).read_bytes())
        return path

    def inspect(self):
        return decoder.inspect_collection(self.root, self.plan)

    def assert_rejected(self, text=None):
        result = self.inspect()
        self.assertFalse(result['qualified'])
        self.assertFalse(result['strict_raw_decode_complete'])
        self.assertTrue(result['errors'])
        if text:
            self.assertIn(text, result['errors'][0]['message'])
        return result

    def test_pinned_actual_Dart_fixtures_hashes_and_complete_single_journal(self):
        manifest = json.loads((FIXTURES / 'manifest.json').read_bytes())
        for name, lock in manifest.items():
            raw = (FIXTURES / name).read_bytes()
            self.assertEqual(len(raw), lock['bytes'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), lock['sha256'])
        for point in ('0085', '2028', '2029'):
            for framing in ('lf', 'crlf'):
                for encoding in ('compact', 'base64'):
                    with self.subTest(point=point, framing=framing, encoding=encoding):
                        path = self.install(point + framing + encoding, point, framing, encoding)
                        raw = path.read_bytes()
                        self.assertEqual(chr(int(point, 16)).encode() in raw, encoding == 'compact')
                        decoded = decoder.decode(path, json.loads((self.root / 'binding.json').read_bytes()))
                        self.assertEqual(decoded['records'], 106)
                        self.assertEqual(len(decoded['producer_statuses']), 20)
                        self.assertEqual(set(decoded['producer_statuses'].values()), {'PASS'})
                        self.assertFalse(decoded['qualified'])
                        self.assertEqual(sum(row['event'] == 'lifetime_closed' for row in decoder.jsonl(raw, decoder.JOURNAL_LIMIT, decoder.JOURNAL_LIMIT)), 6)
                        shutil.rmtree(path.parent.parent)
        self.install()
        self.assertTrue(self.inspect()['strict_raw_decode_complete'])

    def test_identical_two_aliases_deterministic_canonical_and_raw_preserved(self):
        paths = [self.install('z'), self.install('a')]
        before = {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.inspect()
        self.assertTrue(result['strict_raw_decode_complete'], result)
        self.assertFalse(result['qualified'])
        self.assertFalse(result['decoded']['qualified'])
        self.assertEqual(result['canonical_journal'], 'a/synthetic-run/s24-litert-public.jsonl')
        self.assertEqual(result['journal_candidates'], sorted(result['journal_candidates']))
        self.assertEqual(len(result['journal_aliases']), 2)
        for lock in result['journal_aliases']:
            self.assertEqual(lock['bytes'], len(paths[0].read_bytes()))
            self.assertEqual(lock['sha256'], result['decoded']['journal_sha256'])
        self.assertEqual(before, {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_different_same_size_bytes_size_empty_truncated_oversized_rejected(self):
        self.install('a')
        alias = self.install('z')
        original = alias.read_bytes()
        for raw in (original.replace(b'synthetic-byte-fixture', b'synthetic-byte-fixturX'), original + b' ', b'', original[:-1]):
            with self.subTest(size=len(raw)):
                alias.write_bytes(raw)
                self.assert_rejected()
        with alias.open('wb') as stream:
            stream.truncate(decoder.JOURNAL_LIMIT + 1)
        with patch.object(Path, 'open', side_effect=AssertionError('Oversized alias must fail before reading')):
            self.assert_rejected('oversized')

    def test_symlink_nonregular_foreign_run_and_count_limit_rejected(self):
        canonical = self.install('a')
        alias = self.install('z')
        alias.unlink()
        alias.symlink_to(canonical)
        self.assert_rejected('nonsymlink')
        alias.unlink()
        alias.mkdir()
        self.assert_rejected('nonsymlink')
        alias.rmdir()
        alias.parent.rename(alias.parent.with_name('foreign-run'))
        foreign = alias.parent.with_name('foreign-run') / alias.name
        foreign.write_bytes(canonical.read_bytes())
        self.assert_rejected('Foreign run')
        shutil.rmtree(foreign.parent.parent)
        for number in range(decoder.MAX_JOURNAL_ALIASES):
            self.install('alias-' + str(number))
        self.assert_rejected('count limit')

    def test_symlink_directory_and_unreadable_traversal_fail_closed(self):
        self.install()
        linked = self.root / 'linked-export'
        linked.symlink_to(self.root / 'a', target_is_directory=True)
        self.assert_rejected('Symlink directory')
        linked.unlink()
        def inaccessible(*args, **kwargs):
            kwargs['onerror'](PermissionError('unreadable export'))
            return iter(())
        with patch.object(decoder.os, 'walk', side_effect=inaccessible):
            self.assert_rejected('unreadable export')

    def test_missing_malformed_identical_and_incomplete_identical_rejected(self):
        self.assert_rejected('Missing')
        canonical, alias = self.install('a'), self.install('z')
        original = canonical.read_bytes()
        for raw, error in ((b'not JSON\n', 'Expecting'), (b'\xff\n', 'utf-8'),
                           (original[:original.rfind(b'{"event":"complete"')], 'completion')):
            with self.subTest(error=error):
                self.assertTrue(raw)
                canonical.write_bytes(raw)
                alias.write_bytes(raw)
                self.assert_rejected(error)


if __name__ == '__main__':
    unittest.main()
