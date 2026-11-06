"""Synthetic contracts only. No SDK, model, provider or archive release is read."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import qualify
import verify as v
from test_compare_macho_identity import fixture, dylib


def good_result():
    output = 'synthetic public text'
    return {**{key: True for key in ('completed', 'disposed', 'unloaded', 'fullOutputParity', 'reloadParity', 'reuseParity')},
        'gpuLayers': 0, 'threads': 2, 'maxTokens': 128,
        'fixture': {'strategy': 'ngram-simple', 'sizeN': 4, 'sizeM': 8, 'minHits': 1,
                    'promptSha256': v.PROMPT_SHA256},
        **{key: 128 for key in ('baselineEvalTokens', 'ngramEvalTokens', 'reloadEvalTokens', 'reuseEvalTokens')},
        **{key: 5 for key in ('drafted', 'accepted', 'draftAttempts')},
        **{key: output for key in ('baselineOutput', 'ngramOutput', 'reloadOutput', 'reuseOutput')},
        **{key: hashlib.sha256(output.encode()).hexdigest() for key in ('baselineSha256', 'ngramSha256')}}


def line(result):
    return 'CONSUMER_RESULT ' + json.dumps(result) + '\n'


def observations(root):
    paths = [str(root / name) for name in ('libllamadart.dylib', 'libllama.dylib', 'libggml.dylib')]
    wrapper, llama, ggml = paths
    digest = hashlib.sha256(fixture()).hexdigest()
    owner = {'address': 2048, 'ownerBase': 1024, 'ownerPath': ggml}
    rows = [{'modulePath': path, 'checkpoint': 'after-public-model-outcome', 'sha256': digest,
        'exports': ([{'symbol': 'llama_model_load_from_file', 'address': 3000, 'ownerPath': llama}]
                    if path == llama else []), 'imports': []} for path in paths]
    registry = {'primaryMatchesCodeAsset': True, 'noUnintendedDuplicateRegistry': True,
        'observerAfterFirstPassiveSnapshot': True, 'codeAssetAddress': 2048,
        'codeAssetProvider': [owner], 'primaryRegistryImports': [owner]}
    result = good_result()
    result['query'] = {'hasNextn': True, 'nextnNullFalse': True, 'probeAfterPublicOutcome': True,
        'hasLegacyQuery': True, 'wrapperPath': wrapper, 'wrapperSha256': digest,
        'nextnOwnerPath': wrapper, 'nextnOwnerSha256': digest}
    text = ''.join('PASSIVE_MODULE ' + json.dumps(row) + '\n' for row in rows)
    return text + 'REGISTRY_IDENTITY ' + json.dumps(registry) + '\n' + line(result)


class QualificationControls(unittest.TestCase):
    def setUp(self):
        # Resolve host /var alias once. Synthetic layout must not test a host
        # symlink when it intends to test a regular positive fixture.
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_native2_can_never_count_as_native3(self):
        self.assertFalse(v.scope('v0.8.0-2', True)['finalNative3Qualified'])
        self.assertTrue(v.scope('v0.8.0-2', True)['pipelineOnly'])
        self.assertFalse(v.scope('v0.8.0-3', False)['finalNative3Qualified'])
        self.assertTrue(v.scope('v0.8.0-3', True)['finalNative3Qualified'])

    def test_tag_is_verification_only_and_mismatch_refused(self):
        source = (qualify.FIXTURE.parents[2] / 'lib/src/hook/native_release_pins.dart').read_text()
        self.assertIn('macos-arm64', v.pins(source, 'v0.8.0-2', 'macos-arm64'))
        with self.assertRaisesRegex(v.Refusal, 'committed default pin'):
            v.pins(source, 'v0.8.0-3', 'macos-arm64')
        config = qualify.pubspec(self.root)
        self.assertIn('llamadart_native_runtimes: [llama_cpp]', config)
        for forbidden in ('native_tag', 'native_path', 'native_repository', 'native_backends', 'v0.8.0'):
            self.assertNotIn(forbidden, config)

    def test_override_environment_refused_without_values(self):
        for name in ('DYLD_LIBRARY_PATH', 'LD_PRELOAD', 'GGML_BACKEND_PATH',
                     'LLAMADART_NATIVE_LIB_DIR', 'LLAMADART_BACKEND_MODULE_DIR', 'DART_DEFINES'):
            with self.subTest(name=name), self.assertRaises(v.Refusal) as caught:
                v.reject_overrides({name: 'DO_NOT_DISCLOSE'})
            self.assertNotIn('DO_NOT_DISCLOSE', str(caught.exception))
        v.reject_overrides({'LLAMADART_DEFAULT_AOT_EXPECTED_NATIVE_TAG': 'v0.8.0-2'})

    def test_environment_preserves_home_without_repurposing_and_removes_sdk_path(self):
        parent = {'HOME': '/synthetic-home', 'PATH': '/foreign-sdk:/foreign-runtime', 'TOKEN': 'private'}
        if os.name == 'nt':
            parent['SystemRoot'] = os.environ['SystemRoot']
        actual = qualify.clean_environment(parent, self.root / 'temp', self.root / 'pub')
        self.assertEqual('/synthetic-home', actual['HOME'])
        self.assertNotIn('foreign', actual['PATH'])
        self.assertNotIn('TOKEN', actual)

    def test_whole_bundle_copy_retains_hidden_nested_and_excludes_parent_only_file(self):
        app = self.root / 'app'
        bundle = app / 'build/stock/bundle'
        (bundle / 'bin').mkdir(parents=True)
        (bundle / '.hidden/nested').mkdir(parents=True)
        (bundle / 'bin/consumer').write_bytes(b'not executable synthetic')
        (bundle / '.hidden/nested/sidecar').write_bytes(b'sidecar')
        (bundle.parent / 'parent-only').write_bytes(b'not shipped')
        manifest = v.copy_bundle(bundle, self.root / 'distributed', (app,))
        self.assertIn('.hidden/nested/sidecar', manifest)
        self.assertNotIn('parent-only', manifest)
        with self.assertRaisesRegex(v.Refusal, 'bundle root'):
            v.copy_bundle(bundle.parent, self.root / 'wrong', (app,))

    def test_bundle_destination_inside_app_refused(self):
        app = self.root / 'app'; bundle = app / 'bundle'; bundle.mkdir(parents=True)
        (bundle / 'file').write_bytes(b'a')
        with self.assertRaisesRegex(v.Refusal, 'outside every'):
            v.copy_bundle(bundle, app / 'distributed', (app,))

    def test_changed_bundle_and_written_cwd_refused(self):
        bundle = self.root / 'bundle'; bundle.mkdir()
        (bundle / 'library').write_bytes(b'raw')
        before = v.inventory(bundle)
        (bundle / 'library').write_bytes(b'changed')
        with self.assertRaisesRegex(v.Refusal, 'bundle changed'):
            v.unchanged(before, v.inventory(bundle), 'bundle')
        with self.assertRaisesRegex(v.Refusal, 'CWD changed'):
            v.unchanged({}, v.inventory(bundle), 'CWD')

    @unittest.skipIf(os.name == 'nt', 'symlink creation requires host privilege')
    def test_linked_provider_ancestor_refused(self):
        real = self.root / 'real'; real.mkdir(); (real / 'provider').write_bytes(b'a')
        alias = self.root / 'alias'; alias.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(v.Refusal, 'symlink'):
            v.no_links(alias / 'provider')

    def test_public_result_requires_complete_positive_active_full_output(self):
        v.public_result(line(good_result()))
        for key, value in [('drafted', 0), ('accepted', 0), ('draftAttempts', 0), ('completed', False),
                           ('disposed', False), ('reuseParity', False), ('ngramEvalTokens', 127),
                           ('ngramOutput', 'different'), ('baselineSha256', '0' * 64)]:
            changed = good_result(); changed[key] = value
            with self.subTest(key=key), self.assertRaises(v.Refusal):
                v.public_result(line(changed))
        for text in ('', line(good_result()) * 2, line({'completed': True})):
            with self.assertRaises(v.Refusal):
                v.public_result(text)

    def test_provider_map_and_query_validate_actual_addresses_and_owners(self):
        stdout = observations(self.root)
        result = v.public_result(stdout)
        modules, registry = v.native_modules(stdout, 'macos-arm64')
        v.query_result(result, modules, 'v0.8.0-2')
        with self.assertRaisesRegex(v.Refusal, 'legacy query'):
            v.query_result(result, modules, 'v0.8.0-3')
        wrong = stdout.replace('"codeAssetAddress": 2048', '"codeAssetAddress": 2049')
        with self.assertRaisesRegex(v.Refusal, 'addresses disagree'):
            v.native_modules(wrong, 'macos-arm64')
        wrong = stdout.replace('"ownerPath": ' + json.dumps(str(self.root / 'libggml.dylib')),
                               '"ownerPath": "/foreign/libggml.dylib"')
        with self.assertRaisesRegex(v.Refusal, 'owner outside'):
            v.native_modules(wrong, 'macos-arm64')

    def test_provider_binding_preserves_actual_hash_and_rejects_foreign_or_changed(self):
        path = self.root / 'libllama.dylib'; path.write_bytes(fixture())
        members = {path.name: {'bytes': fixture(), 'archive': 'synthetic', 'member': 'lib/' + path.name}}
        modules = {str(path): {'sha256': v.sha256(path)}}
        bound = v.bind_providers(modules, members, 'macos', self.root)
        self.assertEqual(v.sha256(path), bound[str(path)]['actualSha256'])
        with self.assertRaisesRegex(v.Refusal, 'foreign loaded'):
            v.bind_providers(modules, members, 'macos', self.root / 'elsewhere')
        path.write_bytes(fixture(text=b'CHANGED!'))
        with self.assertRaisesRegex(v.Refusal, 'changed after'):
            v.bind_providers(modules, members, 'macos', self.root)

    def test_mac_scoped_relation_records_unattributed_difference_and_refuses_code_or_dependencies(self):
        raw = fixture()
        relation = v.mac_relation(raw, fixture(tail=b'CHANGEDSIGNATURE!'))
        self.assertFalse(relation['whole_file_identity'])
        self.assertFalse(relation['runtime_identity_proven'])
        self.assertIn('Unattributed', relation['transformation_cause'])
        with self.assertRaisesRegex(v.Refusal, 'code/data/UUID'):
            v.mac_relation(raw, fixture(text=b'CHANGED!'))
        with self.assertRaisesRegex(v.Refusal, 'dependency commands'):
            v.mac_relation(fixture(extra_commands=[dylib('/one', 0xc)]),
                           fixture(extra_commands=[dylib('/two', 0xc)]))

    def test_windows_dll_requires_exact_raw_bytes(self):
        path = self.root / 'llama.dll'; path.write_bytes(b'actualDLL')
        modules = {str(path): {'sha256': v.sha256(path)}}
        members = {'llama.dll': {'bytes': b'actualDLL', 'archive': 'synthetic', 'member': 'lib/llama.dll'}}
        v.bind_providers(modules, members, 'windows', self.root)
        members['llama.dll']['bytes'] = b'otherDLL'
        with self.assertRaisesRegex(v.Refusal, 'differs from pinned'):
            v.bind_providers(modules, members, 'windows', self.root)

    def test_archive_checksum_and_native_members_are_acquisition_oracle(self):
        tag, target = 'v0.8.0-2', 'macos-arm64'
        directory = self.root / tag / target; directory.mkdir(parents=True)
        archive = directory / f'llamadart-native-{target}-{tag}.tar.gz'
        def make(unsafe=False):
            with tarfile.open(archive, 'w:gz') as bundle:
                for name in ('libllamadart.dylib', 'libllama.dylib', 'libggml.dylib'):
                    row = tarfile.TarInfo('../escape' if unsafe else 'lib/' + name)
                    row.size = len(fixture()); bundle.addfile(row, io.BytesIO(fixture()))
        make()
        acquired, members = v.archive_members(self.root, tag, target, {target: v.sha256(archive)})
        self.assertEqual(3, len(members)); self.assertEqual(1, len(acquired))
        with self.assertRaisesRegex(v.Refusal, 'checksum mismatch'):
            v.archive_members(self.root, tag, target, {target: '0' * 64})
        make(True)
        with self.assertRaisesRegex(v.Refusal, 'traversal'):
            v.archive_members(self.root, tag, target, {target: v.sha256(archive)})

    def test_dry_run_uses_no_child_sdk_or_model_read(self):
        core = self.root / 'core'; core.mkdir()
        pins = core / 'lib/src/hook/native_release_pins.dart'; pins.parent.mkdir(parents=True)
        pins.write_text((qualify.FIXTURE.parents[2] / 'lib/src/hook/native_release_pins.dart').read_text())
        (core / '.flutter-version').write_text('3.47.1\n')
        args = argparse.Namespace(core_root=str(core), expected_core_sha='a' * 40,
            expected_native_tag='v0.8.0-2', model='/nonexistent-model', output=str(self.root / 'out'), dry_run=True)
        with (patch.dict(os.environ, {}, clear=True),
             patch.object(qualify, 'command', side_effect=AssertionError('no SDK')),
             patch.object(qualify, 'git', side_effect=AssertionError('no child')),
             patch.object(qualify, 'sdk_paths', side_effect=AssertionError('no SDK discovery')),
             patch('sys.stdout', new=io.StringIO()) as stdout):
            qualify.qualify(args)
        self.assertTrue(json.loads(stdout.getvalue())['dryRun'])
        self.assertFalse((self.root / 'out').exists())

    def test_synthetic_python_child_timeout_is_reaped_and_receipted(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            qualify.command([sys.executable, '-c', 'import time; time.sleep(30)'], cwd=self.root,
                env=dict(os.environ), timeout=0.05, log=self.root / 'timeout')
        receipt = json.loads((self.root / 'timeout.command.json').read_text())
        self.assertTrue(receipt['cleanupComplete'])
        self.assertNotIn('exitCode', receipt)

    def test_synthetic_python_child_failure_still_has_cleanup_receipt(self):
        with self.assertRaises(v.Refusal):
            qualify.command([sys.executable, '-c', 'raise SystemExit(7)'], cwd=self.root,
                env=dict(os.environ), timeout=5, log=self.root / 'failure')
        receipt = json.loads((self.root / 'failure.command.json').read_text())
        self.assertEqual(7, receipt['exitCode']); self.assertTrue(receipt['cleanupComplete'])


if __name__ == '__main__':
    unittest.main()
