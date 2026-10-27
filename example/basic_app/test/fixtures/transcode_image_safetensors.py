"""Local qualification fixture: retain every unquantized GGUF tensor byte.

This creates test inputs, not a llamadart conversion API. It never imports or
unpickles checkpoint code. Supply gguf-py's directory and an existing F16/F32
GGUF; the output and receipt must not already exist.
"""
import argparse
import hashlib
import json
import mmap
from pathlib import Path
import struct
import sys
import types

parser = argparse.ArgumentParser()
parser.add_argument('--gguf-package', type=Path, required=True)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
pkg = types.ModuleType('gguf')
pkg.__path__ = [str(args.gguf_package)]
sys.modules['gguf'] = pkg
from gguf.gguf_reader import GGUFReader

def digest_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(16 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

model = GGUFReader(str(args.source))
if sys.byteorder != 'little':
    raise ValueError('The fixture writer requires a little-endian host')
header = {'__metadata__': {'format': 'pt'}}
tensors = []
offset = 0
for tensor in model.tensors:
    kind = tensor.tensor_type.name
    if (kind not in ('F16', 'F32') or tensor.name in header or
            tensor.data.dtype.byteorder not in ('=', '<', '|')):
        raise ValueError('Only unique, unquantized F16/F32 tensors are admitted')
    size = int(tensor.n_bytes)
    header[tensor.name] = {
        'dtype': kind,
        'shape': [int(n) for n in reversed(tensor.shape)],
        'data_offsets': [offset, offset + size],
    }
    data = memoryview(tensor.data).cast('B')
    if len(data) != size:
        raise ValueError('Tensor data size mismatch')
    tensors.append((tensor.name, data, offset, size))
    offset += size
encoded = json.dumps(header, separators=(',', ':')).encode()
encoded += b' ' * (-len(encoded) % 8)
records = []
with args.output.open('xb') as stream:
    stream.write(struct.pack('<Q', len(encoded)))
    stream.write(encoded)
    for name, data, start, size in tensors:
        h = hashlib.sha256()
        for index in range(0, size, 16 << 20):
            chunk = data[index:index + (16 << 20)]
            stream.write(chunk)
            h.update(chunk)
        records.append({'name': name, **header[name], 'sha256': h.hexdigest()})

with args.output.open('rb') as stream:
    with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
        length = struct.unpack('<Q', mapped[:8])[0]
        parsed = json.loads(mapped[8:8 + length])
        if parsed != header:
            raise ValueError('Written header differs')
        for record in records:
            start, end = record['data_offsets']
            h = hashlib.sha256()
            for index in range(start, end, 16 << 20):
                h.update(mapped[8 + length + index:8 + length + min(end, index + (16 << 20))])
            if h.hexdigest() != record['sha256']:
                raise ValueError('Written tensor differs')

receipt = {
    'purpose': 'container-only local qualification input, not a public converter',
    'source_sha256': digest_file(args.source),
    'output_sha256': digest_file(args.output),
    'tensor_count': len(records),
    'tensor_bytes': offset,
    'all_tensor_bytes_verified': True,
    'tensors': records,
}
with args.receipt.open('x') as stream:
    json.dump(receipt, stream, indent=2)
    stream.write('\n')
print(json.dumps({k: v for k, v in receipt.items() if k != 'tensors'}))
