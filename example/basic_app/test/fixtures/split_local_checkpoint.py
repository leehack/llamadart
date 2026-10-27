"""Maintainer-only qualification fixture builder, not a public model converter.
Reads the already-derived qualified complete F16/F32 Safetensors checkpoint;
streams its unchanged tensors into two adjacent shards and an index.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

SOURCE_SHA256 = '69f877d397530ba1b20316f136aa6a483233b3b3abbb552821a7b01530d0ff88'
MARKER = 'llamadart-local-checkpoint-fixture-v1'
EXPECTED = {
    'model-00001-of-00002.safetensors': 'd55f55be8c6df2a841679767aa4f006c8eeedf10e6e45fc4baa7b2e7083ec753',
    'model-00002-of-00002.safetensors': 'b9f7a2dd7131635d61deaaade48d16436fdffd2c53314b99663f459973f6e7ef',
    'model.safetensors.index.json': '5267b5194a98f732136cf957a5a7e97dcff66c6a3188ccc73d851d12143668e5',
}

def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: split_local_checkpoint.py COMPLETE_SAFE OUTPUT_DIRECTORY')
    source, output = map(Path, sys.argv[1:])
    if digest(source) != SOURCE_SHA256:
        raise SystemExit('Qualification fixture requires the documented complete SD-Turbo F16/F32 checkpoint identity.')
    receipt_path = output / 'fixture.json'
    if output.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get('marker') != MARKER or receipt.get('sourceSha256') != SOURCE_SHA256:
            raise SystemExit('Refusing an existing output without the matching owned-fixture receipt.')
        if len(receipt['files']) != 3 or {r['name']: r['sha256'] for r in receipt['files']} != EXPECTED:
            raise SystemExit('Existing fixture receipt differs from the fixed qualified shard identities.')
        for record in receipt['files']:
            if digest(output / record['name']) != record['sha256']:
                raise SystemExit('Existing fixture bytes differ; choose a new output directory.')
        print(json.dumps({'reused': True, 'files': receipt['files']}))
        return
    output.mkdir(parents=True)
    records, payloads, mapping = [], [], {}
    with source.open('rb') as handle:
        length = struct.unpack('<Q', handle.read(8))[0]
        if length > 1024 * 1024:
            raise SystemExit('Header exceeds fixture bound.')
        header = json.loads(handle.read(length))
        start = 8 + length
        tensors = [(name, spec) for name, spec in header.items() if name != '__metadata__']
        if len(tensors) != 1323:
            raise SystemExit('Unexpected tensor count.')
        total = sum(spec['data_offsets'][1] - spec['data_offsets'][0] for _, spec in tensors)
        cut = consumed = 0
        while consumed < total // 2:
            a, b = tensors[cut][1]['data_offsets']; consumed += b - a; cut += 1
        for number, group in enumerate([tensors[:cut], tensors[cut:]], 1):
            name = f'model-{number:05d}-of-00002.safetensors'
            new_header, offset = {}, 0
            for tensor, spec in group:
                a, b = spec['data_offsets']
                new_header[tensor] = {'dtype': spec['dtype'], 'shape': spec['shape'], 'data_offsets': [offset, offset + b - a]}
                offset += b - a; mapping[tensor] = name
            raw = json.dumps(new_header, separators=(',', ':')).encode()
            raw += b' ' * (-len(raw) % 8)
            with (output / name).open('wb') as target:
                target.write(struct.pack('<Q', len(raw)) + raw)
                for tensor, spec in group:
                    a, b = spec['data_offsets']; handle.seek(start + a); left = b - a
                    tensor_hash = hashlib.sha256()
                    while left:
                        chunk = handle.read(min(left, 1024 * 1024))
                        if not chunk: raise SystemExit('Truncated fixture source.')
                        target.write(chunk); tensor_hash.update(chunk); left -= len(chunk)
                    payloads.append({'name': tensor, 'sha256': tensor_hash.hexdigest(), 'shard': name})
            records.append({'name': name, 'bytes': (output / name).stat().st_size, 'sha256': digest(output / name)})
        index = output / 'model.safetensors.index.json'
        index.write_text(json.dumps({'metadata': {'total_size': total}, 'weight_map': mapping}, sort_keys=True, indent=2) + '\n')
        records.append({'name': index.name, 'bytes': index.stat().st_size, 'sha256': digest(index)})
    if {r['name']: r['sha256'] for r in records} != EXPECTED:
        raise SystemExit('Generated shard identities differ from the fixed qualification recipe.')
    receipt = {'marker': MARKER, 'sourceSha256': SOURCE_SHA256, 'tensorCount': 1323, 'tensorBytes': total, 'files': records, 'tensors': payloads}
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'reused': False, 'files': records}))

if __name__ == '__main__':
    main()
