"""Create and verify tensor-only PyTorch inputs from a trusted F16/F32 GGUF.

The local fixture producer never loads Python objects from an input checkpoint.
Only its own newly written state dictionaries are read with weights_only=True.
"""
import argparse
from collections import OrderedDict
import gc
import hashlib
import json
from pathlib import Path
import resource
import sys
import types

import torch

parser = argparse.ArgumentParser()
parser.add_argument('--gguf-package', type=Path, required=True)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
pkg = types.ModuleType('gguf')
pkg.__path__ = [str(args.gguf_package)]
sys.modules['gguf'] = pkg
from gguf.gguf_reader import GGUFReader

def digest(data):
    data = memoryview(data).cast('B')
    result = hashlib.sha256()
    for start in range(0, len(data), 16 << 20):
        result.update(data[start:start + (16 << 20)])
    return result.hexdigest()

def digest_file(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(16 << 20), b''):
            result.update(data)
    return result.hexdigest()

if sys.byteorder != 'little':
    raise ValueError('Little-endian fixture host required')
reader = GGUFReader(str(args.source))
state = OrderedDict()
expected = OrderedDict()
for tensor in reader.tensors:
    if (tensor.tensor_type.name not in ('F16', 'F32') or
            tensor.data.dtype.byteorder not in ('=', '<', '|') or
            tensor.name in state):
        raise ValueError('Unique little-endian F16/F32 tensors required')
    owned = tensor.data.copy()
    state[tensor.name] = torch.from_numpy(owned)
    expected[tensor.name] = {
        'shape': list(owned.shape), 'dtype': str(owned.dtype),
        'sha256': digest(owned), 'bytes': int(owned.nbytes),
    }
records = []
variants = [
    ('torch-zip.pt', False, True),
    ('torch-nested.ckpt', True, True),
    ('torch-legacy.pth', False, False),
]
for name, nested, zipped in variants:
    path = args.output_dir / name
    with path.open('xb') as output:
        torch.save({'state_dict': state} if nested else state, output,
                   pickle_protocol=2, _use_new_zipfile_serialization=zipped)
    records.append({'file': name, 'nested_state_dict': nested,
                    'zip_serialization': zipped,
                    'size': path.stat().st_size, 'sha256': digest_file(path)})
del state, owned
gc.collect()
for record in records:
    # These are newly generated, trusted tensor-only fixtures, not downloaded
    # pickles. Never change this to a weights_only=False compatibility fallback.
    loaded = torch.load(args.output_dir / record['file'],
                        map_location='cpu', weights_only=True)
    if record['nested_state_dict']:
        loaded = loaded['state_dict']
    if list(loaded) != list(expected):
        raise ValueError('Tensor names/order differ after serialization')
    for name, tensor in loaded.items():
        array = tensor.numpy()
        actual = {'shape': list(array.shape), 'dtype': str(array.dtype),
                  'sha256': digest(array), 'bytes': int(array.nbytes)}
        if actual != expected[name]:
            raise ValueError('Tensor differs after serialization')
    record['all_tensor_bytes_verified'] = True
    del loaded, tensor, array
    gc.collect()
receipt = {
    'producer': 'torch.save', 'torch_version': torch.__version__,
    'pickle_protocol': 2, 'source_sha256': digest_file(args.source),
    'tensor_count': len(expected),
    'tensor_bytes': sum(t['bytes'] for t in expected.values()),
    'outputs': records,
    'peak_rss_bytes_macos': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
}
with (args.output_dir / 'torch-transcode-receipt.json').open('x') as output:
    json.dump(receipt, output, indent=2)
    output.write('\n')
print(json.dumps(receipt), flush=True)
