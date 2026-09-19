"""Behavioral trigger and aggregate tests. Run without Dart or third-party deps."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('select_jobs', ROOT / 'tool/ci/select_jobs.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class SelectionTest(unittest.TestCase):
    def test_documentation_omits_native_and_bundles(self):
        for path in ('README.md', 'doc/testing_matrix.md', 'website/package-lock.json',
                     'packages/llamadart_validation/README.md'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertEqual({j for j, v in plan['jobs'].items() if v},
                                 {'docs-check', 'docs-versions'})
                self.assertEqual(plan['apps'], [])
                self.assertEqual(plan['desktops'], [])

    def test_shared_runtime_and_unknown_select_full(self):
        for path in ('lib/src/core/engine.dart', 'hook/build.dart', 'pubspec.yaml',
                     'pubspec.lock', '.flutter-version', 'dart_test.yaml',
                     'scripts/new-build.sh', 'new/unknown.file', '.github/actions/local/action.yml'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertTrue(plan['jobs']['test-linux-coverage'])
                self.assertTrue(plan['jobs']['test-web'])
                self.assertTrue(plan['jobs']['test-other-os'])
                self.assertTrue(plan['jobs']['native-prompt-reuse-parity'])
                self.assertEqual(plan['desktops'], list(ci.DESKTOPS))
                self.assertEqual(plan['apps'], list(ci.APPS))

    def test_companion_keeps_real_consumers_and_only_affected_package(self):
        for name in ci.COMPANIONS:
            plan = ci.select(['packages/' + name + '/darwin/Package.swift'])
            self.assertEqual(plan['companions'], ['packages/' + name])
            for job in ('analyze', 'companion-packages', 'test-linux-coverage',
                        'test-other-os', 'web-chat-contract'):
                self.assertTrue(plan['jobs'][job], job)
            self.assertFalse(plan['jobs']['test-web'])
            self.assertEqual(plan['apps'], list(ci.APPS))
            self.assertEqual(plan['desktops'], [])

    def test_validation_profiles_tests_keep_contracts_without_compilation(self):
        for path in ('test/validation_test.dart', 'assets/profiles/chat-gguf-cpu.json',
                     'schemas/profile.schema.json'):
            plan = ci.select(['packages/llamadart_validation/' + path])
            for job in ('analyze', 'validation-harness', 'validation-integration'):
                self.assertTrue(plan['jobs'][job])
            self.assertEqual(plan['apps'], [])
            self.assertEqual(plan['desktops'], [])

    def test_validation_implementation_and_deps_build_consumers(self):
        for path in ('lib/src/runner.dart', 'bin/run.dart', 'pubspec.yaml'):
            plan = ci.select(['packages/llamadart_validation/' + path])
            self.assertTrue(plan['jobs']['validation-integration'])
            self.assertEqual(plan['apps'], list(ci.APPS))
            self.assertEqual(plan['desktops'], list(ci.DESKTOPS))

    def test_mixed_changes_keep_flutter_consumer_when_only_root_tests_are_substituted(self):
        validation = 'packages/llamadart_validation/lib/src/runner.dart'
        mixed = ci.select([validation, 'test/unit/tooling/validation_remote_test.dart'])
        self.assertTrue(mixed['jobs']['test-linux-coverage'])
        self.assertFalse(mixed['jobs']['web-chat-contract'])
        self.assertTrue(mixed['jobs']['validation-integration'])
        full = ci.select([validation, 'lib/llamadart.dart'])
        self.assertTrue(full['jobs']['test-linux-coverage'])
        self.assertTrue(full['jobs']['web-chat-contract'])
        self.assertFalse(full['jobs']['validation-integration'])

    def test_platform_targets(self):
        for directory, target in [('android', 'android'), ('ios', 'ios-inputs'), ('web', 'web')]:
            plan = ci.select([f'example/chat_app/{directory}/config'])
            self.assertEqual(plan['apps'], [target])
            self.assertEqual(plan['desktops'], [])
        plan = ci.select(['example/chat_app/lib/validation/controller.dart'])
        self.assertEqual(plan['apps'], list(ci.APPS))

    def test_root_tests_retain_all_os_inventories(self):
        for path in ('test/unit/tooling/windows_test.dart', 'test/test_helper.dart',
                     'test/fixtures/grammar.json'):
            plan = ci.select([path])
            for job in ('test-linux-coverage', 'test-web', 'test-other-os'):
                self.assertTrue(plan['jobs'][job])

    def test_workflows_select_real_artifact_roundtrip(self):
        for path in ('.github/workflows/ci.yml', '.github/workflows/validation_bundles.yml',
                     'tool/ci/select_jobs.py', 'test/ci/test_select_jobs.py'):
            self.assertTrue(ci.select([path])['jobs']['artifact-contract'])
        self.assertFalse(ci.select(['lib/llamadart.dart'])['jobs']['artifact-contract'])

    def test_rename_delete_and_union(self):
        paths = ci.inventory(b'R100\0lib/old.dart\0doc/new.md\0D\0hook/build.dart\0')
        self.assertEqual(paths, ['lib/old.dart', 'doc/new.md', 'hook/build.dart'])
        plan = ci.select(paths)
        self.assertTrue(plan['jobs']['test-other-os'])
        plan = ci.select(ci.inventory(b'D\0example/chat_app/android/build.gradle\0'))
        self.assertEqual(plan['apps'], ['android'])
        plan = ci.select(['example/chat_app/android/a', 'example/chat_app/ios/b'])
        self.assertEqual(plan['apps'], ['android', 'ios-inputs'])

    def test_inventory_rejects_truncation_unsafe_paths_and_invalid_encoding(self):
        for raw in (b'M\0no-terminator', b'R100\0only-one\0', b'M\0../x\0',
                    b'M\0/x\0', b'?\0x\0', b'M\0\xff\0'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                ci.inventory(raw)
        self.assertEqual(ci.inventory(b'M\0path with spaces\nand newline\0'),
                         ['path with spaces\nand newline'])

    def test_manual_or_missing_inventory_is_full(self):
        for plan in (ci.select([]), ci.select(['README.md'], force_full=True)):
            self.assertEqual(plan['desktops'], list(ci.DESKTOPS))
            self.assertTrue(plan['jobs']['artifact-contract'])

    def test_real_git_inventory_for_pr_push_rename_and_delete(self):
        with tempfile.TemporaryDirectory() as scratch:
            def git(*args):
                return subprocess.check_output(['git', '-C', scratch, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.email', 'test@example.invalid')
            git('config', 'user.name', 'CI test')
            file = Path(scratch) / 'runtime.dart'
            file.write_text('same bytes')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (Path(scratch) / 'doc').mkdir()
            git('mv', 'runtime.dart', 'doc/renamed.md')
            git('commit', '-qm', 'rename')
            head = git('rev-parse', 'HEAD')
            previous = os.getcwd()
            try:
                os.chdir(scratch)
                for event, payload in (
                    ('push', {'before': base, 'after': head}),
                    ('pull_request', {'pull_request': {'base': {'sha': base}, 'head': {'sha': head}}}),
                ):
                    self.assertEqual(ci.event_paths(event, payload), ['runtime.dart', 'doc/renamed.md'])
                git('rm', 'doc/renamed.md')
                git('commit', '-qm', 'delete')
                self.assertEqual(ci.event_paths('push', {'before': head, 'after': git('rev-parse', 'HEAD')}),
                                 ['doc/renamed.md'])
            finally:
                os.chdir(previous)

    def test_cli_missing_revision_falls_back_full(self):
        with tempfile.TemporaryDirectory() as scratch:
            event = Path(scratch) / 'event.json'
            event.write_text(json.dumps({'before': '0' * 40, 'after': '1' * 40}))
            output = Path(scratch) / 'output'
            env = dict(os.environ, GITHUB_EVENT_NAME='push', GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/select_jobs.py'), 'select'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertTrue(plan['jobs']['test-other-os'])
            self.assertIn('desktops-enabled=true', output.read_text())


class AggregateTest(unittest.TestCase):
    def test_each_selected_job_must_succeed_and_each_unselected_job_must_skip(self):
        for bundle in (False, True):
            for paths in (['README.md'], ['lib/llamadart.dart'], ['example/chat_app/android/a']):
                plan = ci.select(paths)
                expected = ({'desktop': bool(plan['desktops']), 'app': bool(plan['apps'])}
                            if bundle else plan['jobs'])
                needs = {'changes': {'result': 'success'}}
                needs.update({j: {'result': 'success' if selected else 'skipped'} for j, selected in expected.items()})
                self.assertEqual(ci.aggregate(plan, needs, bundle), [])
                for job, selected in expected.items():
                    correct = needs[job]['result']
                    for result in ('failure', 'cancelled', 'skipped' if selected else 'success'):
                        needs[job]['result'] = result
                        self.assertTrue(ci.aggregate(plan, needs, bundle), (job, result))
                    needs[job]['result'] = correct
                needs['changes']['result'] = 'failure'
                self.assertTrue(ci.aggregate(plan, needs, bundle))

    def test_malformed_selection_cannot_turn_missing_work_into_success(self):
        for field, value in [('jobs', {}), ('desktops', ['unknown']), ('apps', ['web', 'web']),
                             ('companions', ['packages/llamadart_llama_cpp_flutter'])]:
            plan = ci.select(['README.md'])
            plan[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                ci.aggregate(plan, {'changes': {'result': 'success'}})
        plan = ci.select(['README.md'])
        plan['jobs']['analyze'] = 'false'
        with self.assertRaises(ValueError):
            ci.aggregate(plan, {})

    def test_missing_or_extra_dependency_is_not_success(self):
        plan = ci.select(['README.md'])
        self.assertTrue(ci.aggregate(plan, {'changes': {'result': 'success'}}))
        needs = {'changes': {'result': 'success'}}
        needs.update({j: {'result': 'success' if selected else 'skipped'} for j, selected in plan['jobs'].items()})
        needs['new-unaccounted-job'] = {'result': 'success'}
        self.assertTrue(ci.aggregate(plan, needs))


if __name__ == '__main__':
    unittest.main()
