"""Fail-closed evidence checks; imports never execute SDK/native tools."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile

from compare_macho_identity import compare

MODEL_BYTES = 1_117_320_736
MODEL_SHA256 = '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e'
PROMPT = 'Repeat and continue this sequence exactly:\n' + '\n'.join(
    ['alpha beta gamma delta epsilon zeta eta theta'] * 5)
PROMPT_SHA256 = hashlib.sha256(PROMPT.encode()).hexdigest()
TAGS = ('v0.8.0-2', 'v0.8.0-3')
NATIVE_NAME = re.compile(r'^(?:lib)?(?:llama(?:dart)?|ggml|mtmd)(?:[-_.].*)?\.(?:dll|dylib)$', re.I)


class Refusal(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def reject_overrides(environment):
    # Check names only: a refusal must never disclose a credential/value.
    forbidden = []
    for key in environment:
        upper = key.upper()
        if (upper.startswith(('DYLD_', 'LD_', 'GGML_', 'LLAMA_CPP_', 'DART_VM_OPTIONS'))
                or upper in {'DART_NATIVE_ASSETS', 'DART_DEFINES', 'PUB_ENVIRONMENT'}
                or (upper.startswith('LLAMADART_') and not upper.startswith('LLAMADART_DEFAULT_AOT_'))):
            forbidden.append(key)
    require(not forbidden, 'runtime override environment names refused: ' + ', '.join(sorted(forbidden)))


def pins(source, expected_tag, target):
    require(expected_tag in TAGS, 'only explicitly scoped native2/native3 accepted')
    tag = re.findall(r"^const llamaCppTag = '([^']+)';$", source, re.M)
    require(tag == [expected_tag], 'expected-native-tag does not match the committed default pin')
    body = re.search(r'const llamaCppBundleSha256 = <String, String>\{(.*?)\n\};', source, re.S)
    require(body is not None, 'missing pinned archive map')
    pairs = re.findall(r"'([^']+)'\s*:\s*'([a-f0-9]{64})'", body[1])
    require(len(dict(pairs)) == len(pairs), 'duplicate archive pin')
    checksums = {key: value for key, value in pairs if key == target}
    require(target in checksums, 'missing current target archive pin')
    sidecars = re.search(r'const llamaCppBackendSidecarSpecs = .*?\[(.*?)\n\];', source, re.S)
    require(sidecars is not None, 'missing sidecar specification')
    for item in re.findall(r'LlamaCppBackendSidecarSpec\((.*?)\)', sidecars[1], re.S):
        values = dict(re.findall(r"(bundle|backend|archive|sha256): '([^']+)'", item))
        require(set(values) == {'bundle', 'backend', 'archive', 'sha256'}, 'unrecognized sidecar specification')
        if values['bundle'] == target:
            require(re.fullmatch(r'[a-f0-9]{64}', values['sha256']), 'invalid sidecar pin')
            checksums[values['archive']] = values['sha256']
    return checksums


def inside(path, root):
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except ValueError:
        return False


def no_links(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            info = part.lstat()
            require(not stat.S_ISLNK(info.st_mode), 'symlink ancestor refused')
            require(not getattr(info, 'st_file_attributes', 0) & 0x400, 'reparse ancestor refused')


def inventory(root, names=None):
    root = Path(root)
    no_links(root)
    result = {}
    paths = [root / name for name in names] if names is not None else sorted(root.rglob('*'))
    for path in paths:
        no_links(path)
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            if names is None:
                result[path.relative_to(root).as_posix() + '/'] = {'kind': 'directory'}
            continue
        require(stat.S_ISREG(info.st_mode), 'non-regular inventory entry refused')
        result[path.relative_to(root).as_posix()] = {
            'kind': 'file', 'bytes': info.st_size, 'sha256': sha256(path),
            'executable': bool(info.st_mode & 0o111),
        }
    return result


def unchanged(before, after, label):
    require(before == after, label + ' changed')


def copy_bundle(source, destination, excluded_roots):
    import shutil
    source, destination = Path(source), Path(destination)
    require(source.name == 'bundle', 'SDK CLI bundle root required')
    require(not destination.exists(), 'distributed destination must be fresh')
    require(all(not inside(destination, root) for root in excluded_roots),
            'distributed bundle must be outside every source/app root')
    before = inventory(source)
    require(bool(before), 'empty SDK bundle')
    shutil.copytree(source, destination, copy_function=shutil.copy2)
    unchanged(before, inventory(destination), 'whole relocated bundle')
    return before


def public_result(stdout):
    rows = [json.loads(line.removeprefix('CONSUMER_RESULT ')) for line in stdout.splitlines()
            if line.startswith('CONSUMER_RESULT ')]
    require(len(rows) == 1, 'exactly one complete public result required')
    result = rows[0]
    for key in ('completed', 'disposed', 'unloaded', 'fullOutputParity', 'reloadParity', 'reuseParity'):
        require(result.get(key) is True, 'public lifecycle/parity incomplete: ' + key)
    require(not any(key in result for key in ('error', 'disposeError', 'observerError')), 'consumer recorded failure')
    require(result.get('gpuLayers') == 0 and result.get('threads') == 2
            and result.get('maxTokens') == 128, 'CPU0 fixed generation settings missing')
    require(result.get('fixture') == {'strategy': 'ngram-simple', 'sizeN': 4, 'sizeM': 8,
            'minHits': 1, 'promptSha256': PROMPT_SHA256}, 'wrong ngram/prompt fixture')
    for key in ('drafted', 'accepted', 'draftAttempts'):
        require(type(result.get(key)) is int and result[key] > 0, 'inactive ngram: ' + key)
    for key in ('baselineEvalTokens', 'ngramEvalTokens', 'reloadEvalTokens', 'reuseEvalTokens'):
        require(type(result.get(key)) is int and result[key] >= 128, 'generation token bound not met: ' + key)
    outputs = [result.get(key) for key in ('baselineOutput', 'ngramOutput', 'reloadOutput', 'reuseOutput')]
    require(all(isinstance(value, str) and value for value in outputs) and len(set(outputs)) == 1,
            'full public output parity missing')
    require(all(result.get(key) == hashlib.sha256(outputs[0].encode()).hexdigest()
                for key in ('baselineSha256', 'ngramSha256')), 'public output hash mismatch')
    return result


def native_modules(stdout, platform):
    rows = [json.loads(line.removeprefix('PASSIVE_MODULE ')) for line in stdout.splitlines()
            if line.startswith('PASSIVE_MODULE ')]
    require(bool(rows), 'passive loaded-module map missing')
    modules = {}
    for row in rows:
        path = row.get('modulePath', '')
        name = path.replace('\\', '/').rsplit('/', 1)[-1]
        if not NATIVE_NAME.fullmatch(name):
            continue
        require(row.get('checkpoint', '').startswith('after-'), 'observer ran before public outcome')
        require(re.fullmatch('[a-f0-9]{64}', row.get('sha256', '')), 'actual provider hash missing')
        previous = modules.get(path)
        require(previous is None or previous['sha256'] == row['sha256'], 'loaded provider changed between observations')
        modules[path] = row
    require(len(modules) >= 3, 'incomplete native provider map')
    model_owners = set()
    for row in modules.values():
        for exported in row.get('exports', []):
            symbol = exported.get('symbol', '')
            if symbol.startswith(('ggml_', 'llama_')):
                require(exported.get('ownerPath') in modules, 'foreign native export owner')
                require(exported.get('address', 0) > 0, 'native export address missing')
            if symbol == 'llama_model_load_from_file':
                model_owners.add(exported.get('ownerPath'))
        for imported in row.get('imports', []):
            if imported.get('symbol', '').startswith(('ggml_', 'llama_')):
                require(imported.get('ownerPath') in modules, 'foreign native import owner')
    require(len(model_owners) == 1, 'model-load owner missing or ambiguous')
    identities = [json.loads(line.removeprefix('REGISTRY_IDENTITY ')) for line in stdout.splitlines()
                  if line.startswith('REGISTRY_IDENTITY ')]
    require(len(identities) == 1, 'one code-asset registry identity required')
    identity = identities[0]
    require(identity.get('primaryMatchesCodeAsset') is True
            and identity.get('noUnintendedDuplicateRegistry') is True,
            'native primary/code-asset registry mismatch')
    require(identity.get('observerAfterFirstPassiveSnapshot') is True,
            'code-asset resolution must follow passive observation')
    # Check the emitted actual owner map, rather than trusting only booleans.
    providers = identity.get('codeAssetProvider', [])
    primary = identity.get('primaryRegistryImports', [])
    require(len(providers) == len(primary) == 1, 'ambiguous code-asset/primary provider')
    require(providers[0].get('address') == identity.get('codeAssetAddress') == primary[0].get('address')
            and identity.get('codeAssetAddress', 0) > 0, 'registry addresses disagree')
    require(providers[0].get('ownerPath') in modules and primary[0].get('ownerPath') in modules,
            'registry owner outside observed native set')
    return modules, identity


def query_result(result, modules, tag):
    query = result.get('query', {})
    require(query.get('hasNextn') is True and query.get('nextnNullFalse') is True
            and query.get('probeAfterPublicOutcome') is True, 'retained nextn(null) probe failed')
    require(query.get('hasLegacyQuery') is (tag == TAGS[0]), 'legacy query presence disagrees with native scope')
    for path_key, hash_key in (('wrapperPath', 'wrapperSha256'), ('nextnOwnerPath', 'nextnOwnerSha256')):
        require(query.get(path_key) in modules, 'query provider outside observed native map')
        require(query.get(hash_key) == modules[query[path_key]]['sha256'], 'query owner hash mismatch')
    require(query['wrapperPath'] == query['nextnOwnerPath'], 'retained query forwarded to foreign provider')


def archive_members(cache, tag, target, expected):
    """Read only checksum-verified hook archives, never the extracted-cache oracle."""
    cache = Path(cache)
    acquired = {}
    members = {}
    for archive, checksum in expected.items():
        file = cache / tag / archive / f'llamadart-native-{archive}-{tag}.tar.gz'
        if not file.exists():
            require(archive != target, 'ordinary hook base archive missing')
            continue
        no_links(file)
        require(sha256(file) == checksum, 'public hook archive checksum mismatch')
        acquired[archive] = {'path': str(file), 'sha256': checksum, 'bytes': file.stat().st_size,
            'url': f'https://github.com/leehack/llamadart-native/releases/download/{tag}/{file.name}'}
        with tarfile.open(file, mode='r:gz') as bundle:
            entries = bundle.getmembers()
            require(len(entries) <= 4096 and sum(row.size for row in entries) <= 3_000_000_000,
                    'unbounded archive inventory')
            seen = set()
            for row in entries:
                name = PurePosixPath(row.name)
                require(not name.is_absolute() and '..' not in name.parts and '\\' not in row.name,
                        'archive path traversal refused')
                require(row.name not in seen, 'duplicate archive member')
                seen.add(row.name)
                require(row.isdir() or row.isfile(), 'archive links/special entries require explicit review')
                if not row.isfile() or not NATIVE_NAME.fullmatch(name.name):
                    continue
                require(0 < row.size <= 1_000_000_000, 'invalid native member size')
                content = bundle.extractfile(row).read()
                require(name.name not in members, 'ambiguous native member basename')
                members[name.name] = {'archive': archive, 'member': row.name, 'bytes': content}
    require(len(members) >= 3, 'incomplete verified native archive members')
    return acquired, members


def mac_relation(raw, actual):
    if raw == actual:
        return {'wholeFileIdentity': True, 'actualSha256': hashlib.sha256(actual).hexdigest()}
    relation = compare(raw, actual)
    require(relation['code_data_uuid_identity'], 'Mach-O code/data/UUID mismatch')
    left, right = relation['left'], relation['right']
    require([item for item in left['dylib_commands'] if item['cmd'] != 0xD]
            == [item for item in right['dylib_commands'] if item['cmd'] != 0xD],
            'Mach-O dependency commands changed')
    require([item for item in left['referenced_payloads'] if item['label'] != 'command:0x1d']
            == [item for item in right['referenced_payloads'] if item['label'] != 'command:0x1d'],
            'Mach-O non-signature referenced payload changed')
    for row in relation['load_command_differences']:
        a, b = row['left'], row['right']
        require(a is not None and b is not None and a['cmd'] == b['cmd'], 'Mach-O command structure changed')
        if a['cmd'] == 0x19:
            av, bv = a.get('segment', {}), b.get('segment', {})
            require(av.get('name') == bv.get('name') == '__LINKEDIT', 'non-LINKEDIT segment changed')
            require({k: v for k, v in av.items() if k not in {'vmsize', 'filesize'}}
                    == {k: v for k, v in bv.items() if k not in {'vmsize', 'filesize'}}, 'LINKEDIT semantics changed')
        elif a['cmd'] == 0xD:
            require({k: v for k, v in a['dylib'].items() if k != 'name'}
                    == {k: v for k, v in b['dylib'].items() if k != 'name'}, 'self dylib version changed')
        else:
            require(a['cmd'] == 0x1D, 'unreviewed Mach-O command change')
    return relation


def bind_providers(modules, members, platform, allowed_root):
    bound = {}
    for path, row in modules.items():
        require(inside(path, allowed_root), 'foreign loaded provider outside allowed root')
        no_links(path)
        require(sha256(path) == row['sha256'], 'actual provider changed after observation')
        name = Path(path).name
        candidates = [member for key, member in members.items() if key.lower() == name.lower()]
        require(len(candidates) == 1, 'provider not uniquely supplied by verified public acquisition')
        member = candidates[0]
        actual = Path(path).read_bytes()
        if platform == 'windows':
            require(actual == member['bytes'], 'Windows DLL differs from pinned public archive')
            relation = {'wholeFileIdentity': True, 'actualSha256': row['sha256']}
        else:
            relation = mac_relation(member['bytes'], actual)
        bound[path] = {'actualSha256': row['sha256'], 'archive': member['archive'],
            'member': member['member'], 'rawSha256': hashlib.sha256(member['bytes']).hexdigest(),
            'identityRelation': relation}
    return bound


def scope(tag, complete):
    return {'expectedNativeTag': tag, 'pipelineOnly': tag == TAGS[0],
            'finalNative3Qualified': tag == TAGS[1] and complete,
            'independentAcceptance': 'required separately', 'platformScopeOnly': True,
            'gpuQualification': False}
