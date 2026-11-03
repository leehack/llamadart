import base64
import copy
import hashlib
import unittest

from decode_raw import recover


def fixture():
    rows = [{'event': 'manifest', 'schema': 1, 'plan': {'cases': ['a35.public.cpu']}},
            {'event': 'case_started', 'case_id': 'a35.public.cpu'}]
    inventory = []
    payloads = {'a35.public.cpu.maps': b'mapping\n',
                'a35.public.cpu.stderr.log': bytes(range(256)) * 100}
    for name, raw in payloads.items():
        count = (len(raw) + 24575) // 24576
        lock = dict(name=name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), chunks=count)
        rows.append(dict(event='raw_file_start', **lock))
        for index in range(count):
            rows.append(dict(event='raw_file_chunk', name=name, index=index,
                base64=base64.b64encode(raw[index*24576:(index+1)*24576]).decode()))
        rows.append(dict(event='raw_file_end', **lock))
        inventory.append(lock)
    rows.append(dict(event='raw_export_end', complete=True, files=inventory,
        total_bytes=sum(map(len, payloads.values()))))
    rows.append(dict(event='summary', raw_export_complete=True, case_inventory={'a35.public.cpu': {'status': 'PASS'}}))
    return rows, payloads


class DecoderTest(unittest.TestCase):
    def test_binary_roundtrip(self):
        rows, files = fixture()
        self.assertEqual(recover(rows), files)

    def test_corruption_and_truncation_refused(self):
        rows, _ = fixture()
        variants = []
        for index in range(len(rows)):
            variants.append(rows[:index] + rows[index+1:])
        for index, row in enumerate(rows):
            if row['event'] == 'raw_file_chunk':
                variants.append(rows[:index] + [row, row] + rows[index+1:])
                bad = copy.deepcopy(rows)
                bad[index]['base64'] = base64.b64encode(b'wrong').decode()
                variants.append(bad)
        bad = copy.deepcopy(rows)
        bad[-2]['total_bytes'] += 1
        variants.append(bad)
        bad = copy.deepcopy(rows)
        bad[2]['name'] = '../outside'
        variants.append(bad)
        for variant in variants:
            with self.subTest(events=[r['event'] for r in variant]):
                with self.assertRaises((ValueError, KeyError)):
                    recover(variant)

    def test_reordering_inventory_and_public_locks(self):
        rows, files = fixture()
        variants = []
        chunks = [i for i, row in enumerate(rows)
                  if row['event'] == 'raw_file_chunk' and row['name'].endswith('stderr.log')]
        bad = copy.deepcopy(rows)
        bad[chunks[0]], bad[chunks[1]] = bad[chunks[1]], bad[chunks[0]]
        variants.append(bad)
        for field, value in [('sha256', '0' * 64), ('bytes', 1), ('chunks', 9)]:
            bad = copy.deepcopy(rows)
            bad[2][field] = value
            variants.append(bad)
        bad = copy.deepcopy(rows)
        bad[-2]['files'].pop()
        variants.append(bad)
        bad = copy.deepcopy(rows)
        bad.insert(2, {'event': 'public_stderr_capture', 'case_id': 'a35.public.cpu',
                       'bytes': 25600, 'sha256': '0' * 64})
        variants.append(bad)
        for bad in variants:
            with self.assertRaises(ValueError):
                recover(bad)


if __name__ == '__main__':
    unittest.main()
