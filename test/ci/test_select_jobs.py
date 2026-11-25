"""Behavioral trigger and aggregate tests. Run without Dart or third-party deps."""
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('select_jobs', ROOT / 'tool/ci/select_jobs.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

EXAMPLE_TEST_PACKAGES = {
    'basic_app', 'laya_command_bar', 'laya_tetris', 'llamadart_cli',
    'llamadart_server', 'tui_coding_agent',
}
WAVE4_EXAMPLE_ROOTS = tuple(
    'example/' + name for name in sorted(EXAMPLE_TEST_PACKAGES | {'training_notebook'})
)


def tracked_paths(*roots):
    return subprocess.check_output(
        ['git', 'ls-files', '-z', '--', *roots], cwd=ROOT,
    ).decode().rstrip('\0').split('\0')


def example_file_references():
    # Match tracked file names, including those with spaces, within literal paths.
    files = '|'.join(re.escape(path) for path in tracked_paths(*WAVE4_EXAMPLE_ROOTS))
    pattern = re.compile(
        rb'(?<![\w.-])(?:' + files.encode() + rb')(?![\w./+-])',
    )
    for reader in tracked_paths('test', 'tool', 'scripts', 'packages', '.github'):
        if reader.endswith('.md'):
            continue
        source = (ROOT / reader).read_bytes()
        if b'\0' not in source:
            for path in sorted(set(pattern.findall(source))):
                yield reader, path.decode()


def root_suite_imports():
    """Files outside `test/` that a root test suite imports, directly or not."""
    directive = re.compile(r'''^\s*(?:import|export|part)\s+((?:[^;'"]|'[^']*'|"[^"]*")*);''', re.M)
    seen, pending = set(), [path.relative_to(ROOT).as_posix()
                            for path in (ROOT / 'test').rglob('*_test.dart')]
    while pending:
        path = pending.pop()
        if path in seen or not (ROOT / path).is_file():
            continue
        seen.add(path)
        for match in directive.finditer((ROOT / path).read_text(encoding='utf-8')):
            for uri in re.findall(r'''['"]([^'"]+)['"]''', match.group(1)):
                if uri.startswith('package:llamadart/'):
                    pending.append('lib/' + uri[len('package:llamadart/'):])
                elif ':' not in uri:
                    pending.append(posixpath.normpath(posixpath.join(posixpath.dirname(path), uri)))
    return {path for path in seen if not path.startswith('test/')}


def root_flutter_versions(workflow_name, workflow):
    job = None
    companion_setup = False
    for line_number, line in enumerate(workflow.splitlines(), start=1):
        header = re.fullmatch(r'  ([\w-]+):[ \t]*(?:#.*)?', line)
        if header:
            job = header[1]
        if workflow_name == 'ci.yml' and job in ('studio', 'studio-macos'):
            continue
        if workflow_name == 'publish_companion_pubdev.yml':
            if line.startswith('      - '):
                companion_setup = False
            if re.match(r' +(?:- )?uses: flutter-actions/setup-flutter@', line):
                companion_setup = True
        input_name = 'version' if companion_setup else 'flutter-version'
        pin = re.fullmatch(rf""" +(['"]?){input_name}\1:[ \t]*(.*)""", line)
        if pin:
            version = re.split(r'(?:^|[ \t]+)#', pin[2], maxsplit=1)[0].rstrip()
            if version.startswith(("'", '"')) and version.endswith(version[0]):
                version = version[1:-1]
            yield line_number, version


class SelectionTest(unittest.TestCase):
    def test_marker_only_tamper_runs_protected_changelog_policy(self):
        marker = 'tool/release/recoveries/' + 'a' * 40 + '.json'
        self.assertTrue(ci.select([marker], pull_request=True)['jobs']['analyze'])

    def assert_narrow_plan(self, plan, jobs, *, macos=False, windows=False):
        self.assertEqual({job for job, selected in plan['jobs'].items() if selected}, jobs)
        self.assertEqual(plan['macos-native'], macos)
        self.assertEqual(plan['windows-native'], windows)
        self.assertEqual(plan['test-other-os-matrix'], [
            *(ci.MACOS_SHARDS if macos else ()),
            *(ci.WINDOWS_SHARDS if windows else ()),
        ])
        for key in ('companions', 'desktops', 'apps', 'reasons'):
            self.assertEqual(plan[key], [], key)
        for key in ('studio-macos', 'macos-validation-memory', 'apple-cache'):
            self.assertFalse(plan[key], key)

    def test_tool_paths_select_their_consumers(self):
        static = {'analyze', 'markdown-tests'}
        vm = {'analyze', 'test-linux-coverage'}
        hosts = vm | {'test-other-os'}
        # Pin membership independently of the selector without a second path list.
        cases = (
            ('TOOLS_STATIC', 'f04534c726523fd8909566c2e8bc034b63b08cb0336b12549c0a51674ebfd990',
             static, False, False),
            ('TOOLS_LINUX_VM', '4ad9b53eb752fd2040d3708cd61cf04368ba4cbe75ef72be333efa35bbcb66b7',
             vm, False, False),
            ('TOOLS_MACOS_VM', 'a149081b75f50d5bd6e6c1db2de4b9a923c21f72eb01757c6ce9fa9135a47caa',
             hosts, True, False),
            ('TOOLS_ALL_HOST_VM', '16a1e80f72b56844b50c6509995e14ad5b15c00dc7e292727bb66678a676e33b',
             hosts, True, True),
        )
        for group, fingerprint, jobs, macos, windows in cases:
            paths = sorted(getattr(ci, group))
            with self.subTest(group=group):
                self.assertEqual(
                    sha256('\n'.join(paths).encode()).hexdigest(), fingerprint,
                    f'{group} membership changed. Trace readers before updating the pin: {paths}',
                )
            for path in paths:
                for pull_request in (True, False):
                    with self.subTest(path=path, pull_request=pull_request):
                        plan = ci.select([path], pull_request=pull_request)
                        self.assert_narrow_plan(plan, jobs, macos=macos, windows=windows)
                        self.assertEqual(plan['coverage'], not pull_request)

    def test_tool_workflow_inputs_and_unknown_paths_stay_full(self):
        paths = (
            'tool/prepare_workspace.dart',
            'tool/litert_lm_tokenizer_fixture.dart',
            'tool/testing/run_local_e2e.dart',
            'tool/testing/llama_cpp_templates.ref',
            'tool/testing/playwright_chat_app_utils.py',
            'tool/testing/serve_static_with_headers.py',
            'tool/native/sync_native_release_pins.py',
            'tool/native/fixtures/legacy_release_allowlist.json',
            'tool/native/fixtures/native_release_tag_grammar.json',
            'tool/release/pr_resolutions/48af8ec5bc294620bd63a1e1818f6c6593afb5d3.json',
            'tool/release/pub_content_limits.dart',
            'tool/release/reopen_unreleased_changelog.dart',
            'tool/git/safe_pr_head_update.dart',
            'scripts/build_chat_app_web.sh',
            'scripts/fetch_webgpu_bridge_assets.sh',
            'tool/new_benchmark.dart',
            'tool/testing/playwright_new_smoke.py',
            'tool/native/fixtures/new_release.json',
            'tool/release/new_gate.dart',
            'tool/git/new_writer.dart',
            'tool/litert_lm_templates/new_model.jinja',
            'scripts/new_runtime_smoke.sh',
        )
        for pull_request in (True, False):
            full = ci.select(['new/unknown'], pull_request=pull_request)
            for path in paths:
                with self.subTest(path=path, pull_request=pull_request):
                    plan = ci.select([path], pull_request=pull_request)
                    self.assertEqual({**plan, 'reasons': full['reasons']}, full)
                    self.assertEqual(plan['reasons'], [
                        'shared/runtime or unclassified path: ' + path,
                    ])

    def test_tool_rules_union_with_each_other_and_existing_lanes(self):
        paths = [
            'scripts/android_runtime_smoke.sh',
            'tool/litert_lm_templates/qwen3.jinja',
            'tool/testing/without_app_nap.sh',
            'tool/testing/test_matrix.dart',
            'website/docs/examples/dartpad-gguf.md',
            'example/chat_app/android/build.gradle',
        ]
        for pull_request in (True, False):
            for changed in (paths, paths[::-1]):
                with self.subTest(paths=changed, pull_request=pull_request):
                    plan = ci.select(changed, pull_request=pull_request)
                    self.assertEqual(
                        {job for job, selected in plan['jobs'].items() if selected},
                        {'analyze', 'docs-check', 'test-linux-coverage', 'test-other-os'},
                    )
                    self.assertEqual(plan['test-other-os-matrix'], [
                        *ci.MACOS_SHARDS, *ci.WINDOWS_SHARDS,
                    ])
                    self.assertEqual(plan['apps'], ['android'])
                    self.assertEqual(plan['desktops'], [])
                    self.assertEqual(plan['reasons'], [])

            for path in ('tool/native/fixtures/new_release.json', 'tool/ci/select_jobs.py'):
                with self.subTest(fallback=path, pull_request=pull_request):
                    expected = ci.select([*paths[4:], path], pull_request=pull_request)
                    self.assertEqual(ci.select([*paths, path], pull_request=pull_request), expected)
                    self.assertEqual(ci.select([path, *paths[::-1]], pull_request=pull_request),
                                     expected)

            validation = 'tool/testing/validation/bundle.dart'
            expected = ci.select([*paths[4:], validation], pull_request=pull_request)
            for changed in ([*paths, validation], [validation, *paths[::-1]]):
                with self.subTest(validation=changed, pull_request=pull_request):
                    plan = ci.select(changed, pull_request=pull_request)
                    self.assertEqual(plan['jobs'], {**expected['jobs'], 'test-other-os': True})
                    self.assertEqual(plan['desktops'], expected['desktops'])
                    self.assertEqual(plan['apps'], expected['apps'])
                    self.assertEqual(plan['test-other-os-matrix'], [
                        *ci.MACOS_SHARDS, *ci.WINDOWS_SHARDS,
                    ])

    def test_documentation_omits_native_and_bundles(self):
        for path in ('website/pubspec.lock', 'website/sidebars.json'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertEqual({j for j, v in plan['jobs'].items() if v},
                                 {'docs-check', 'docs-versions', 'markdown-tests'})
                self.assertEqual(plan['apps'], [])
                self.assertEqual(plan['desktops'], [])

    def test_every_maintained_markdown_path_runs_only_the_markdown_tests(self):
        for path in ('AGENTS.md', 'CONTRIBUTING.md', 'doc/testing_matrix.md',
                     'doc/pr_branch_writer_inventory.md', 'README.md', 'CHANGELOG.md',
                     'website/docs/guides/embeddings.md',
                     'website/versioned_docs/version-0.15.2/intro.md',
                     'packages/llamadart_validation/README.md',
                     'packages/llamadart_stable_diffusion_flutter/README.md',
                     'example/chat_app/README.md', 'example/dartpad_gguf/README.md'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertEqual({j for j, v in plan['jobs'].items() if v},
                                 {'docs-check', 'docs-versions', 'markdown-tests'})
                self.assertEqual(plan['apps'], [])
                self.assertEqual(plan['desktops'], [])

        # Unclassified Markdown retains the conservative full fallback too.
        self.assertTrue(ci.select(['new/unclassified.md'])
                        ['jobs']['test-linux-coverage'])

    def test_markdown_tests_defer_to_linux_coverage_which_runs_them_too(self):
        for paths in (['README.md', 'lib/llamadart.dart'], ['doc/a.md', 'test/unit/a_test.dart'],
                      ['test/README.md'], ['packages/llamadart_litert_lm_flutter/lib/a.dart', 'doc/a.md'],
                      ['new/unclassified.md'], []):
            with self.subTest(paths=paths):
                plan = ci.select(paths)
                self.assertTrue(plan['jobs']['test-linux-coverage'])
                self.assertFalse(plan['jobs']['markdown-tests'])

    def test_every_path_runs_the_markdown_reader_guard(self):
        # Any file a root suite reaches can start reading Markdown, so no lane
        # may skip both jobs that run the reader-inventory guard.
        for path in ('.github/workflows/ci.yml', 'website/docs/integrations/genkit.md',
                     'packages/genkit_llamadart/lib/a.dart', 'website/docs/guides/model-store.md',
                     'packages/llamadart_model_store/lib/a.dart', 'README.md', 'LICENSE',
                     'doc/images/a.png', 'website/sidebars.json', 'website/tool/a.dart',
                     'tool/docs/build_site.sh', 'packages/llamadart_litert_lm_flutter/lib/a.dart',
                     'packages/llamadart_validation/schemas/a.json', 'tool/testing/validation.dart',
                     'example/chat_app/android/a', 'example/chat_app/lib/main.dart',
                     'example/dartpad_gguf/lib/main.dart',
                     'test/unit/a_test.dart', 'new/unknown.file'):
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    jobs = ci.select([path], pull_request=pull_request)['jobs']
                    self.assertNotEqual(jobs['markdown-tests'], jobs['test-linux-coverage'])
        for path in ('tool/docs/build_site.sh', 'website/lib/src/site/site_model.dart',
                     'LICENSE'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertTrue(plan['jobs']['markdown-tests'])
                self.assertFalse(plan['jobs']['test-linux-coverage'])
                self.assertFalse(plan['jobs']['test-web'])
                self.assertFalse(plan['jobs']['test-other-os'])

    def test_metadata_paths_select_their_consumers(self):
        static = {'analyze', 'markdown-tests'}
        static_and_vm = {'analyze', 'test-linux-coverage'}
        cases = {
            'skills/llamadart-web/SKILL.md': static,
            'skills/llamadart-web/references/bridge.json': static,
            'MIGRATION.md': {'docs-check', 'docs-versions', 'markdown-tests'},
            '.github/CODEOWNERS': static_and_vm,
            '.github/pull_request_template.md': {'markdown-tests'},
            '.github/dependabot.yml': static,
            '.pubignore': static_and_vm,
            '.dockerignore': {'markdown-tests'},
            'codecov.yml': {'test-linux-coverage'},
            'dartdoc_options.yaml': static,
            'docker/Dockerfile': static,
            'docker/validation/Dockerfile.hip-linkcheck': static,
        }
        for path, expected in cases.items():
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    plan = ci.select([path], pull_request=pull_request)
                    self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected)
                    for key in ('apps', 'desktops', 'companions', 'test-other-os-matrix',
                                'reasons'):
                        self.assertEqual(plan[key], [], key)
                    for key in ('macos-native', 'windows-native', 'studio-macos',
                                'macos-validation-memory', 'apple-cache'):
                        self.assertFalse(plan[key], key)
                    self.assertEqual(plan['coverage'], not pull_request)

    def test_root_gitignore_keeps_full_validation_bundle_admission(self):
        for pull_request, desktops, apps in (
            (True, ['ubuntu-24.04', 'windows-2022'], ['web', 'ios-inputs']),
            (False, ['ubuntu-24.04', 'windows-2022', 'macos-15'],
             ['android', 'web', 'ios-inputs']),
        ):
            with self.subTest(pull_request=pull_request):
                plan = ci.select(['.gitignore'], pull_request=pull_request)
                self.assertEqual(plan['desktops'], desktops)
                self.assertEqual(plan['apps'], apps)
                self.assertEqual(
                    plan['reasons'], ['shared/runtime or unclassified path: .gitignore'])

    def test_metadata_mixes_with_docs_bundles_and_full_fallback(self):
        for pull_request in (True, False):
            mixed = ['MIGRATION.md', '.github/CODEOWNERS', 'docker/Dockerfile',
                     'example/chat_app/android/build.gradle']
            for paths in (mixed, mixed[::-1]):
                plan = ci.select(paths, pull_request=pull_request)
                self.assertEqual(
                    {j for j, v in plan['jobs'].items() if v},
                    {'analyze', 'docs-check', 'test-linux-coverage'},
                )
                self.assertEqual(plan['apps'], ['android'])
                self.assertEqual(plan['desktops'], [])
                self.assertEqual(plan['reasons'], [])

            for path in ('.gitattributes', '.gitignore', '.github/unknown.yml',
                         'skills-backup/example.md', 'docker-backup/Dockerfile',
                         'codecov.yml.backup', 'nested/.pubignore'):
                with self.subTest(path=path, pull_request=pull_request):
                    full = ci.select([path], pull_request=pull_request)
                    self.assertTrue(full['reasons'])
                    self.assertTrue(full['macos-native'])
                    self.assertTrue(full['windows-native'])
                    self.assertTrue(full['jobs']['test-web'])
                    for paths in ([path, 'skills/llamadart-web/SKILL.md'],
                                  ['skills/llamadart-web/SKILL.md', path]):
                        self.assertEqual(ci.select(paths, pull_request=pull_request), full)

    def test_deleted_and_renamed_markdown_keep_tooling_and_specialized_jobs(self):
        for raw in (b'D\0website/docs/integrations/genkit.md\0',
                    b'R100\0packages/genkit_llamadart/README.md\0website/docs/new.md\0'):
            plan = ci.select(ci.inventory(raw))
            self.assertTrue(plan['jobs']['genkit'])
            source_is_package = raw.startswith(b'R')
            self.assertEqual(plan['jobs']['test-linux-coverage'], source_is_package)
            self.assertEqual(plan['jobs']['markdown-tests'], not source_is_package)
            self.assertEqual(plan['apps'], [])
            self.assertEqual(plan['desktops'], [])

    def test_chat_app_tests_select_chat_app_and_root_linux_tests_only(self):
        for path in ('example/chat_app/test/unit_test.dart',
                     'example/chat_app/test_vm/image_evidence_test.dart'):
            with self.subTest(path=path):
                plan = ci.select([path])
                self.assertEqual({j for j, v in plan['jobs'].items() if v},
                                 {'analyze', 'web-chat-contract', 'test-linux-coverage'})
                self.assertEqual(plan['apps'], [])

    def test_example_package_tests_follow_core_and_example_changes_only(self):
        for path in ('lib/llamadart.dart', 'pubspec.yaml', 'example/basic_app/lib/main.dart',
                     'example/dartpad_gguf/lib/main.dart', 'example/laya_tetris/test/tetris_test.dart',
                     'example/tui_coding_agent/pubspec.yaml'):
            with self.subTest(path=path):
                self.assertTrue(ci.select([path])['jobs']['example-packages'])
        for path in ('example/chat_app/lib/main.dart', 'example/chat_app/test/unit_test.dart',
                     'example/basic_app/README.md', 'example/dartpad_gguf/README.md',
                     'test/unit/core/engine_test.dart',
                     'packages/genkit_llamadart/lib/genkit_llamadart.dart',
                     'packages/llamadart_validation/lib/src/runner.dart'):
            with self.subTest(path=path):
                self.assertFalse(ci.select([path])['jobs']['example-packages'])

    def test_dartpad_gguf_selects_static_example_and_markdown_guards_only(self):
        base = 'example/dartpad_gguf/'
        source_jobs = {'analyze', 'example-packages', 'markdown-tests'}
        pr_2200_files = [
            'example/README.md',
            base + 'README.md',
            'website/docs/examples/dartpad-gguf.md',
            base + 'lib/chat_controller.dart',
            base + 'lib/chat_widgets.dart',
            base + 'lib/main.dart',
            base + 'test/widget_test.dart',
        ]
        cases = [
            *[([base + path], source_jobs) for path in (
                'lib/main.dart', 'lib/bridge_bootstrap_web.dart', 'test/widget_test.dart',
                'pubspec.yaml', 'analysis_options.yaml',
            )],
            ([base + 'README.md'], {'docs-check', 'docs-versions', 'markdown-tests'}),
            ([base + 'README.md', base + 'lib/main.dart'], source_jobs | {'docs-check'}),
            (pr_2200_files, source_jobs | {'docs-check'}),
        ]
        for paths, expected_jobs in cases:
            for pull_request in (True, False):
                with self.subTest(paths=paths, pull_request=pull_request):
                    plan = ci.select(paths, pull_request=pull_request)
                    self.assertEqual({j for j, selected in plan['jobs'].items() if selected},
                                     expected_jobs)
                    for field in ('desktops', 'apps', 'companions', 'test-other-os-matrix', 'reasons'):
                        self.assertEqual(plan[field], [], field)
                    for field in ('studio-macos', 'macos-native', 'windows-native',
                                  'macos-validation-memory', 'apple-cache'):
                        self.assertFalse(plan[field], field)

    def test_dartpad_gguf_plus_core_keeps_the_full_runtime_plan(self):
        for pull_request in (True, False):
            with self.subTest(pull_request=pull_request):
                runtime = ci.select(['lib/llamadart.dart'], pull_request=pull_request)
                mixed = ci.select(['example/dartpad_gguf/lib/main.dart', 'lib/llamadart.dart'],
                                  pull_request=pull_request)
                self.assertEqual(mixed, runtime)

    def test_remaining_examples_select_every_tracked_paths_consumers(self):
        markdown = {'docs-check', 'docs-versions', 'markdown-tests'}
        static = {'analyze', 'markdown-tests'}
        example = static | {'example-packages'}
        example_vm = {'analyze', 'example-packages', 'test-linux-coverage'}
        basic_app = 'example/basic_app/'
        root_consumers = {
            basic_app + 'bin/src/live_asr_pcm.dart': example_vm,
            basic_app + 'bin/src/macos_mic_asr.dart': example_vm,
            basic_app + 'bin/llamadart_engine_lifecycle_example.dart': example_vm | {'test-web'},
            basic_app + 'test/fixtures/image_warmup_comparison.dart': example_vm | {'test-web'},
            basic_app + 'test/fixtures/image_original_container_model.dart': (
                example_vm | {'test-other-os'}
            ),
        }
        self.assertEqual(
            {path for path in root_suite_imports() if path.startswith(basic_app)},
            set(root_consumers),
            'Trace the root test platforms for any new Basic App imports.',
        )
        for relative in ('test/image_generation_smoke.yaml',
                         'test/fixtures/image_container_native_reference.cpp'):
            root_consumers[basic_app + relative] = example_vm | {'test-other-os'}
        roots = WAVE4_EXAMPLE_ROOTS
        paths = tracked_paths(*roots) + [root + '/nested/.gitignore' for root in roots]
        paths += [root + '/new_input' for root in roots]
        for path in paths:
            name = path.split('/')[1]
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    plan = ci.select([path], pull_request=pull_request)
                    if path.endswith('/.gitignore'):
                        expected = ci.select(['lib/llamadart.dart'], pull_request=pull_request)
                        expected['reasons'] = ['shared/runtime or example path: ' + path]
                        self.assertEqual(plan, expected)
                    else:
                        jobs = root_consumers.get(
                            path, example if name in EXAMPLE_TEST_PACKAGES else static,
                        )
                        if path.endswith('.md'):
                            jobs = markdown
                        host = 'test-other-os' in jobs
                        self.assert_narrow_plan(plan, jobs, macos=host, windows=host)

    def test_literal_example_references_keep_their_readers(self):
        basic = 'example/basic_app/'
        vm = {'test-linux-coverage'}
        macos_vm = vm | {'macos-native'}
        host_vm = macos_vm | {'windows-native'}
        chrome_vm = vm | {'test-web'}
        readers = {
            'test/unit/core/engine/engine_lifecycle_contract_test.dart': {
                basic + 'bin/llamadart_engine_lifecycle_example.dart': chrome_vm,
            },
            'test/unit/tooling/image_warmup_comparison_test.dart': {
                basic + 'test/fixtures/image_warmup_comparison.dart': chrome_vm,
            },
            'test/unit/tooling/macos_mic_asr_test.dart': {
                basic + 'bin/src/live_asr_pcm.dart': vm,
                basic + 'bin/src/macos_mic_asr.dart': vm,
            },
            'test/unit/tooling/run_local_e2e_test.dart': {
                basic + 'test/image_generation_smoke.yaml': host_vm,
            },
            'test/unit/tooling/sd_original_mode_public_test.dart': {
                basic + 'test/fixtures/image_original_container_model.dart': host_vm,
            },
            # sd_original_mode_test.dart runs this suite and skips on Windows.
            'packages/llamadart_validation/native/sd_original_mode/test_native.py': {
                basic + 'test/fixtures/image_container_native_reference.cpp': macos_vm,
            },
            'tool/release/check_core_archive.py': {
                basic + 'pubspec.yaml': {'analyze'},
                basic + 'bin/llamadart_litert_embedding_example.dart': {'analyze'},
            },
            'test/unit/tooling/pubignore_test.dart': dict.fromkeys((
                basic + 'README.md',
                basic + 'pubspec.yaml',
                basic + 'bin/llamadart_litert_embedding_example.dart',
                'example/llamadart_server/lib/src/features/openai_api/presentation/docs/docs.dart',
            ), {'markdown-tests'}),
        }
        non_readers = {
            # The preparation test opens a synthetic workspace.
            'test/unit/tooling/prepare_workspace_test.dart': {
                'example/llamadart_server/pubspec.yaml',
            },
            # A comment points to the local E2E suite.
            'test/unit/backends/stable_diffusion/stable_diffusion_image_worker_test.dart': {
                basic + 'test/image_generation_e2e_test.dart',
            },
            # Operator steps are tested as rendered commands and help text.
            'tool/testing/run_local_e2e.dart': {
                basic + 'test/fixtures/split_local_checkpoint.py',
                basic + 'test/image_exit_teardown_e2e_test.dart',
            },
        }
        changes_readers = {
            'test/ci/test_core_archive.py', 'test/ci/test_deploy_guard.py',
            'test/ci/test_select_jobs.py', 'tool/ci/select_jobs.py',
        }
        references = set(example_file_references())
        for reader, path in sorted(references):
            if path in non_readers.get(reader, ()):
                continue
            required = {'changes'} if reader in changes_readers else readers.get(reader, {}).get(path)
            for pull_request in (True, False):
                with self.subTest(reader=reader, path=path, pull_request=pull_request):
                    self.assertIsNotNone(required, f'Classify the reader {reader} of {path}')
                    plan = ci.select([path], pull_request=pull_request)
                    enabled = {'changes'} | {job for job, value in plan['jobs'].items() if value}
                    enabled.update(job for job in ('macos-native', 'windows-native') if plan[job])
                    if 'test-linux-coverage' in enabled:
                        enabled.add('markdown-tests')  # Linux VM includes the Markdown inventory.
                    self.assertFalse(
                        required - enabled,
                        f'{reader} reads {path}; missing {sorted(required - enabled)}',
                    )
        for reader, paths in readers.items():
            for path in paths:
                self.assertIn((reader, path), references, f'Stale reader mapping: {reader} → {path}')

    def test_example_rules_union_with_docs_other_examples_and_full_fallback(self):
        cases = (
            ('example/basic_app/bin/llamadart_engine_lifecycle_example.dart',
             'example/basic_app/test/fixtures/image_original_container_model.dart',
             {'analyze', 'example-packages', 'test-linux-coverage', 'test-web', 'test-other-os'}),
            ('example/laya_tetris/lib/main.dart', 'example/laya_command_bar/README.md',
             {'analyze', 'example-packages', 'docs-check', 'markdown-tests'}),
            ('example/training_notebook/lora_training.ipynb', 'example/llamadart_cli/pubspec.yaml',
             {'analyze', 'example-packages', 'markdown-tests'}),
        )
        for pull_request in (True, False):
            for left, right, jobs in cases:
                with self.subTest(left=left, right=right, pull_request=pull_request):
                    plan = ci.select([left, right], pull_request=pull_request)
                    host = 'test-other-os' in jobs
                    self.assert_narrow_plan(plan, jobs, macos=host, windows=host)
                    self.assertEqual(plan, ci.select([right, left], pull_request=pull_request))
                    for full in ('example/new_example/README.md', 'example/basic_app/.gitignore'):
                        expected = ci.select([full], pull_request=pull_request)
                        self.assertTrue(expected['reasons'])
                        self.assertEqual(
                            ci.select([left, full, right], pull_request=pull_request), expected,
                        )
                        self.assertEqual(
                            ci.select([right, full, left], pull_request=pull_request), expected,
                        )

    def test_tracked_directory_boundaries_are_explicitly_classified(self):
        root_files = {
            False: {'.dockerignore', '.pubignore', 'AGENTS.md', 'CHANGELOG.md',
                    'CONTRIBUTING.md', 'LICENSE', 'MIGRATION.md', 'README.md',
                    'codecov.yml', 'dartdoc_options.yaml'},
            True: {'.flutter-version', '.gitattributes', '.gitignore', 'analysis_options.yaml',
                   'dart_test.yaml', 'ffigen.yaml', 'ffigen_litert_lm_embedding.yaml',
                   'ffigen_stable_diffusion.yaml', 'pubspec.yaml'},
        }
        directories = {
            '': {
                False: {'doc', 'docker', 'skills', 'test', 'website'},
                True: {'.github', 'bin', 'example', 'hook', 'lib', 'packages', 'scripts', 'tool'},
            },
            'example/': {
                False: {'basic_app', 'chat_app', 'dartpad_gguf', 'laya_command_bar',
                        'laya_tetris', 'llamadart_cli', 'llamadart_server',
                        'training_notebook', 'tui_coding_agent'},
                True: set(),
            },
            'tool/': {
                False: {'docs'},
                True: {'ci', 'git', 'litert_lm_templates', 'native', 'release', 'testing'},
            },
        }
        paths = tracked_paths()
        self.assertEqual(
            {path for path in paths if '/' not in path}, root_files[False] | root_files[True],
            'Classify new root files before narrowing their CI coverage.',
        )
        for prefix, groups in directories.items():
            descendants = [path[len(prefix):] for path in paths if path.startswith(prefix)]
            actual = {path.split('/', 1)[0] for path in descendants if '/' in path}
            self.assertEqual(
                actual, groups[False] | groups[True],
                f'Classify new directories under {prefix or "the root"} before narrowing CI.',
            )
        for full, files in root_files.items():
            probes = files | {
                prefix + directory + '/ci_selection_probe'
                for prefix, groups in directories.items() for directory in groups[full]
            }
            for probe in sorted(probes):
                for pull_request in (True, False):
                    with self.subTest(path=probe, pull_request=pull_request):
                        plan = ci.select([probe], pull_request=pull_request)
                        self.assertEqual(bool(plan['reasons']), full)

    def test_genkit_gateway_runs_package_snippet_compilation_with_docs(self):
        plan = ci.select(['website/docs/integrations/genkit.md'])
        self.assertEqual({j for j, v in plan['jobs'].items() if v},
                         {'docs-check', 'docs-versions', 'markdown-tests',
                          'genkit'})
        self.assertEqual(plan['companions'], [])
        self.assertEqual(plan['apps'], [])

    def test_genkit_package_changes_run_root_readers_and_the_adapter(self):
        for path in ('lib/genkit_llamadart.dart', 'README.md', 'pubspec.yaml',
                     '.github/check_docs.py', 'test/contract_test.dart'):
            plan = ci.select(['packages/genkit_llamadart/' + path])
            self.assertEqual({j for j, v in plan['jobs'].items() if v},
                             {'genkit', 'test-linux-coverage'})
            self.assertEqual(plan['companions'], [])
            self.assertEqual(plan['apps'], [])
            self.assertEqual(plan['desktops'], [])
        for paths in (['lib/llamadart.dart'], ['pubspec.yaml'], ['hook/build.dart'],
                      ['.github/workflows/ci.yml'], [],
                      ['packages/genkit_llamadart/lib/a.dart', 'lib/llamadart.dart']):
            plan = ci.select(paths)
            self.assertTrue(plan['jobs']['genkit'])

    def test_studio_packages_run_together_without_selecting_root_or_bundles(self):
        for package in ('llamadart_studio', 'llamadart_studio_core'):
            for suffix in ('lib/main.dart', 'pubspec.yaml', 'test/chat_test.dart',
                           'README.md'):
                plan = ci.select(['packages/' + package + '/' + suffix])
                expected = {'studio', 'markdown-tests'}
                self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected)
                self.assertEqual(plan['companions'], [])
                self.assertEqual(plan['apps'], [])
                self.assertEqual(plan['desktops'], [])

    def test_studio_native_regressions_require_the_standalone_macos_job(self):
        plan = ci.select(['packages/llamadart_studio/lib/main.dart'], pull_request=True)
        expected = ci.expected_jobs(plan)
        self.assertTrue(expected['studio-macos'])
        self.assertFalse(expected['companion-packages'])
        needs = {'changes': {'result': 'success'}}
        needs.update({job: {'result': 'success' if selected else 'skipped'}
                      for job, selected in expected.items()})
        self.assertEqual(ci.aggregate(plan, needs), [])
        for result in ('skipped', 'cancelled', 'failure'):
            needs['studio-macos']['result'] = result
            self.assertEqual(ci.aggregate(plan, needs),
                             [f'studio-macos: selected=True, result={result}'])

    def test_full_host_matrix_rejects_incomplete_shards_and_cancelled_jobs(self):
        plan = ci.select(['.github/workflows/ci.yml'], pull_request=True)
        host_rows = plan['test-other-os-matrix']
        self.assertEqual([(row['os'], row['lane'], row['shard'], row['shards'])
                          for row in host_rows], [
            ('macos-latest', 'macos', 1, 2),
            ('macos-latest', 'macos', 2, 2),
            ('windows-latest', 'windows-tooling', 1, 1),
            ('windows-latest', 'windows-runtime', 1, 1),
        ])
        needs = {'changes': {'result': 'success'}}
        needs.update({job: {'result': 'success' if selected else 'skipped'}
                      for job, selected in ci.expected_jobs(plan).items()})
        self.assertEqual(ci.aggregate(plan, needs), [])
        for row in host_rows:
            with self.subTest(row=row), self.assertRaisesRegex(ValueError, 'Other-OS matrix'):
                ci.aggregate({**plan, 'test-other-os-matrix': [r for r in host_rows if r != row]},
                             needs)
        needs['test-other-os']['result'] = 'cancelled'
        self.assertEqual(ci.aggregate(plan, needs),
                         ['test-other-os: selected=True, result=cancelled'])
        del needs['test-other-os']
        self.assertIn('test-other-os: selected=True, result=None', ci.aggregate(plan, needs))

    def test_ci_passes_the_root_sdk_pin_directly(self):
        root_pin = (ROOT / '.flutter-version').read_text().strip()
        workflows = ROOT / '.github/workflows'
        pins = [
            (path.relative_to(ROOT), line, version)
            for pattern in ('*.yml', '*.yaml')
            for path in sorted(workflows.glob(pattern))
            for line, version in root_flutter_versions(
                path.name, path.read_text(encoding='utf-8'))
        ]
        self.assertTrue(any(path.name == 'ci.yml' for path, _, _ in pins),
                        'No explicit root Flutter pins found in ci.yml')
        self.assertTrue(any(path.name == 'publish_companion_pubdev.yml'
                            for path, _, _ in pins),
                        'No explicit root Flutter pin found in publish_companion_pubdev.yml')
        for path, line, version in pins:
            with self.subTest(workflow=path.as_posix(), line=line):
                self.assertEqual(version, root_pin)

    def test_root_flutter_versions_include_each_input_and_skip_studio_jobs(self):
        workflow = """jobs:
  studio:
    steps:
      - with:
          flutter-version: 3.50.0
  root:
    steps:
      - with:
          flutter-version: 3.47.1
      - with:
          flutter-version: '3.47.0' # stale
      - with:
          "flutter-version": "3.47.1"
  studio-macos:
    steps:
      - with:
          flutter-version: 3.50.0
"""
        root_inputs = [(9, '3.47.1'), (11, '3.47.0'), (13, '3.47.1')]
        self.assertEqual(list(root_flutter_versions('ci.yml', workflow)), root_inputs)
        self.assertEqual(list(root_flutter_versions('other.yaml', workflow)),
                         [(5, '3.50.0'), *root_inputs, (17, '3.50.0')])

    def test_root_flutter_versions_include_the_companion_setup_version(self):
        workflow = """jobs:
  publish-companion:
    steps:
      - uses: flutter-actions/setup-flutter@sha
        if: steps.publish.outputs.should_publish == 'true'
        with:
          version: '3.47.0' # stale
      - uses: other/action@sha
        with:
          version: 2.0.0
"""
        self.assertEqual(list(root_flutter_versions('publish_companion_pubdev.yml', workflow)),
                         [(7, '3.47.0')])

    def test_studio_web_changes_run_the_shared_bridge_pin_gate(self):
        plan = ci.select(['packages/llamadart_studio/web/index.html'])
        self.assertTrue(plan['jobs']['studio'])
        self.assertTrue(plan['jobs']['docs-versions'])

    def test_studio_runs_for_runtime_companions_shared_changes_and_fallback(self):
        for paths in (['lib/llamadart.dart'], ['pubspec.yaml'], ['hook/build.dart'],
                      ['.github/workflows/ci.yml'], [],
                      ['packages/llamadart_llama_cpp_flutter/lib/runtime.dart']):
            self.assertTrue(ci.select(paths)['jobs']['studio'], paths)

    def test_root_test_fixtures_studio_reads_run_the_studio_lanes(self):
        for path in ('test/fixtures/templates/Qwen3_5-0_8B.jinja',
                     'test/support/qwen35_tool_result_fixture.dart'):
            for pull_request in (True, False):
                plan = ci.select([path], pull_request=pull_request)
                self.assertTrue(plan['jobs']['studio'], path)
                self.assertTrue(ci.expected_jobs(plan)['studio-macos'], path)

    def test_model_store_package_changes_run_root_readers_and_package_tests(self):
        for path in ('lib/llamadart_model_store.dart', 'README.md', 'pubspec.yaml',
                     'test/model_store_test.dart'):
            plan = ci.select(['packages/llamadart_model_store/' + path])
            self.assertEqual({j for j, v in plan['jobs'].items() if v},
                             {'model-store', 'test-linux-coverage'})
            self.assertEqual(plan['companions'], [])
            self.assertEqual(plan['apps'], [])
            self.assertEqual(plan['desktops'], [])
        plan = ci.select(['website/docs/guides/model-store.md'])
        self.assertEqual({j for j, v in plan['jobs'].items() if v},
                         {'docs-check', 'docs-versions', 'markdown-tests',
                          'model-store'})
        for paths in (['lib/llamadart.dart'], ['pubspec.yaml'],
                      ['.github/workflows/ci.yml'], []):
            self.assertTrue(ci.select(paths)['jobs']['model-store'], paths)

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

    def test_unknown_example_keeps_the_full_runtime_plan(self):
        for path in ('example/foo/lib/main.dart', 'example/foo/README.md',
                     'example/laya_tetris_extra/lib/main.dart'):
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    expected = ci.select(['lib/llamadart.dart'], pull_request=pull_request)
                    expected['reasons'] = ['shared/runtime or example path: ' + path]
                    self.assertEqual(ci.select([path], pull_request=pull_request), expected)

    def test_companions_name_every_checked_out_flutter_apple_companion(self):
        checked_out = sorted(
            path.parents[2].name
            for path in (ROOT / 'packages').glob('*/darwin/*/Package.swift')
            if path.parent.name == path.parents[2].name
        )
        self.assertIn('llamadart_stable_diffusion_flutter', checked_out)
        self.assertEqual(sorted(ci.COMPANIONS), checked_out)

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
            for job in ('analyze', 'validation-harness', 'test-linux-coverage'):
                self.assertTrue(plan['jobs'][job])
            # Web Chat runs the Flutter consumer tests when it is selected.
            self.assertNotEqual(plan['jobs']['validation-integration'],
                                plan['jobs']['web-chat-contract'])
            self.assertEqual(plan['apps'], [])
            self.assertEqual(plan['desktops'], [])

    def test_validation_files_the_chat_app_builds_from_select_web_chat(self):
        for path in ('lib/src/runner.dart', 'pubspec.yaml', 'assets/profiles/chat-gguf-cpu.json',
                     'assets/decision/laya_0_3_5_reference.json',
                     'assets/embeddings/v1/reference.json'):
            with self.subTest(path=path):
                self.assertTrue(ci.select(['packages/llamadart_validation/' + path])
                                ['jobs']['web-chat-contract'])
        for path in ('test/validation_test.dart', 'schemas/profile.schema.json',
                     'assets/capability_coverage.json', 'assets/speech/tone.wav'):
            with self.subTest(path=path):
                self.assertFalse(ci.select(['packages/llamadart_validation/' + path])
                                 ['jobs']['web-chat-contract'])

    def test_bundled_validation_assets_match_the_package_flutter_assets(self):
        lines = (ROOT / 'packages/llamadart_validation/pubspec.yaml').read_text().splitlines()
        start = lines.index('  assets:', lines.index('flutter:'))
        declared = []
        for line in lines[start + 1:]:
            if not line.startswith('    - '):
                break
            declared.append('packages/llamadart_validation/' + line[len('    - '):])
        self.assertEqual(sorted(declared), sorted(ci.VALIDATION_BUNDLED_ASSETS))

    def test_validation_implementation_and_deps_build_consumers(self):
        for path in ('lib/src/runner.dart', 'bin/run.dart', 'pubspec.yaml'):
            plan = ci.select(['packages/llamadart_validation/' + path])
            self.assertTrue(plan['jobs']['test-linux-coverage'])
            self.assertTrue(plan['jobs']['web-chat-contract'])
            self.assertFalse(plan['jobs']['validation-integration'])
            self.assertEqual(plan['apps'], list(ci.APPS))
            self.assertEqual(plan['desktops'], list(ci.DESKTOPS))

    def test_mixed_changes_keep_flutter_consumer_when_only_root_tests_are_substituted(self):
        validation = 'packages/llamadart_validation/test/validation_test.dart'
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
        self.assertFalse(plan['jobs']['validation-integration'])

    def test_chat_app_and_validation_trees_run_the_root_linux_tests(self):
        # Root suites import, copy or read each of these.
        for path in ('example/chat_app/integration_test/support/micro_batch_sweep_support.dart',
                     'example/chat_app/lib/models/downloadable_model.dart',
                     'example/chat_app/lib/validation/controller.dart',
                     'example/chat_app/test_vm/evidence_png_fixture.dart',
                     'example/chat_app/test/unit_test.dart',
                     'example/chat_app/pubspec.lock',
                     'example/chat_app/web/index.html',
                     'example/chat_app/android/app/src/main/AndroidManifest.xml',
                     'packages/llamadart_validation/lib/src/case_catalog.dart',
                     'packages/llamadart_validation/bin/run.dart',
                     'packages/llamadart_validation/assets/image_profiles/image-sdxs-cpu.json',
                     'packages/llamadart_validation/test/validation_test.dart',
                     'tool/testing/validation/process.dart', 'tool/testing/validation.dart'):
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    jobs = ci.select([path], pull_request=pull_request)['jobs']
                    self.assertTrue(jobs['test-linux-coverage'])
                    self.assertFalse(jobs['markdown-tests'])
                    self.assertFalse(jobs['test-web'])
                    self.assertFalse(jobs['test-other-os'])
        for path in ('example/chat_app/macos/Runner/Configs/AppInfo.xcconfig',
                     'example/chat_app/ios/Runner.xcodeproj/project.pbxproj'):
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    plan = ci.select([path], pull_request=pull_request)
                    self.assertTrue(plan['jobs']['test-linux-coverage'])
                    self.assertFalse(plan['jobs']['markdown-tests'])
                    self.assertFalse(plan['jobs']['test-web'])
                    self.assertTrue(plan['jobs']['test-other-os'])
                    self.assertTrue(plan['macos-native'])
                    self.assertFalse(plan['windows-native'])
                    self.assertTrue(plan['apple-cache'])

    def test_every_file_a_root_suite_imports_runs_the_root_linux_tests(self):
        imported = root_suite_imports()
        for path in ('lib/llamadart.dart', 'tool/testing/validation/remote.dart',
                     'example/chat_app/lib/models/downloadable_model.dart',
                     'packages/llamadart_validation/lib/src/report.dart'):
            self.assertIn(path, imported)
        for path in sorted(imported):
            with self.subTest(path=path):
                self.assertTrue(ci.select([path])['jobs']['test-linux-coverage'])

    def test_root_tests_retain_all_os_inventories(self):
        for path in ('test/unit/tooling/windows_test.dart', 'test/test_helper.dart',
                     'test/fixtures/grammar.json'):
            plan = ci.select([path])
            for job in ('test-linux-coverage', 'test-web', 'test-other-os'):
                self.assertTrue(plan['jobs'][job])

    def test_pull_requests_build_macos_desktop_and_android_for_their_inputs_only(self):
        for paths in (['lib/llamadart.dart'], ['lib/src/core/engine.dart', 'README.md'],
                      ['.github/workflows/ci.yml'], ['new/unknown.file'],
                      ['skills/llamadart-web/SKILL.md'], ['MIGRATION.md'],
                      ['tool/testing/test_matrix.dart'],
                      ['example/basic_app/lib/main.dart'], ['example/chat_app/web/config'],
                      ['example/chat_app/test/unit_test.dart']):
            with self.subTest(paths=paths):
                after_merge = ci.select(paths)
                plan = ci.select(paths, pull_request=True)
                self.assertNotIn('macos-15', plan['desktops'])
                self.assertNotIn('android', plan['apps'])
                self.assertEqual(plan['jobs'], after_merge['jobs'])
                self.assertEqual(
                    [d for d in after_merge['desktops'] if d != 'macos-15'], plan['desktops'])
                self.assertEqual(
                    [a for a in after_merge['apps'] if a != 'android'], plan['apps'])
        for path in ('hook/build.dart', 'lib/src/hook/native_release_pins.dart', 'pubspec.yaml',
                     'pubspec.lock', 'tool/testing/validation/bundle.dart',
                     'tool/testing/validation.dart', 'packages/llamadart_validation/bin/run.dart',
                     '.github/workflows/validation_bundles.yml', 'tool/ci/select_jobs.py'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertIn('macos-15', plan['desktops'])
                self.assertIn('android', plan['apps'])
        for path in ('.flutter-version',):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertIn('macos-15', plan['desktops'])
                self.assertNotIn('android', plan['apps'])
        for path in ('example/chat_app/android/app/build.gradle', 'example/chat_app/lib/main.dart',
                     'example/chat_app/pubspec.yaml',
                     'packages/llamadart_llama_cpp_flutter/pubspec.yaml'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertNotIn('macos-15', plan['desktops'])
                self.assertIn('android', plan['apps'])
        # An unknown or unreadable inventory stays full.
        self.assertEqual(ci.select([], pull_request=True)['desktops'], list(ci.DESKTOPS))
        self.assertEqual(ci.select(['README.md'], force_full=True, pull_request=True)['apps'],
                         list(ci.APPS))

    def test_coverage_runs_after_merge_only(self):
        self.assertTrue(ci.select(['lib/llamadart.dart'])['coverage'])
        self.assertTrue(ci.select([], force_full=True)['coverage'])
        plan = ci.select(['lib/llamadart.dart'], pull_request=True)
        self.assertFalse(plan['coverage'])
        self.assertTrue(plan['jobs']['test-linux-coverage'])
        expected = ci.expected_jobs(plan)
        self.assertTrue(expected['test-linux-vm'])
        self.assertFalse(expected['test-linux-coverage'])

    def test_workflows_select_real_artifact_roundtrip(self):
        for path in ('.github/workflows/ci.yml', '.github/workflows/validation_bundles.yml',
                     'tool/ci/select_jobs.py', 'test/ci/test_select_jobs.py'):
            self.assertTrue(ci.select([path])['jobs']['artifact-contract'])
        self.assertFalse(ci.select(['lib/llamadart.dart'])['jobs']['artifact-contract'])

    def test_workflow_artifact_selection_survives_later_shared_paths(self):
        for paths in (
            ['.github/workflows/ci.yml', 'tool/testing/test_matrix.dart'],
            ['tool/testing/test_matrix.dart', '.github/workflows/ci.yml'],
            ['.github/workflows/ci.yml', 'lib/llamadart.dart', 'README.md'],
        ):
            with self.subTest(paths=paths):
                self.assertTrue(ci.select(paths)['jobs']['artifact-contract'])

    def test_selection_is_independent_of_changed_path_order(self):
        paths = [
            'README.md', 'lib/llamadart.dart', '.github/workflows/ci.yml',
            'tool/testing/test_matrix.dart', 'new/unknown',
            'packages/llamadart_llama_cpp_flutter/lib/plugin.dart',
            'packages/llamadart_validation/lib/src/runner.dart',
            'packages/llamadart_validation/assets/profiles/chat-gguf-cpu.json',
            'test/unit/tooling/validation_remote_test.dart',
            'example/chat_app/android/config', 'example/chat_app/web/config',
            'example/dartpad_gguf/lib/main.dart',
            'skills/llamadart-web/SKILL.md', 'MIGRATION.md', '.github/CODEOWNERS',
            '.github/pull_request_template.md', '.github/dependabot.yml', '.gitignore',
            '.pubignore', '.dockerignore', 'codecov.yml', 'dartdoc_options.yaml',
            'docker/Dockerfile', '.gitattributes',
        ]
        for left in paths:
            for right in paths:
                forward, reverse = ci.select([left, right]), ci.select([right, left])
                for key in ('jobs', 'companions', 'desktops', 'apps',
                            'studio-macos', 'macos-native', 'windows-native',
                            'macos-validation-memory', 'apple-cache',
                            'test-other-os-matrix'):
                    self.assertEqual(forward[key], reverse[key], (left, right, key))

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
            self.assertIn('coverage=true', output.read_text())

    def test_cli_pull_request_skips_coverage_even_when_it_falls_back_full(self):
        with tempfile.TemporaryDirectory() as scratch:
            event = Path(scratch) / 'event.json'
            event.write_text(json.dumps({'pull_request': {'base': {'sha': '0' * 40},
                                                          'head': {'sha': '1' * 40}}}))
            output = Path(scratch) / 'output'
            env = dict(os.environ, GITHUB_EVENT_NAME='pull_request',
                       GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/select_jobs.py'), 'select'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertTrue(plan['jobs']['test-linux-coverage'])
            self.assertFalse(plan['coverage'])
            self.assertEqual(plan['desktops'], list(ci.DESKTOPS))
            self.assertIn('coverage=false', output.read_text())

    def test_cli_manual_run_selects_every_job_that_gates_the_chat_app_deploy(self):
        with tempfile.TemporaryDirectory() as scratch:
            event = Path(scratch) / 'event.json'
            event.write_text(json.dumps({'ref': 'refs/heads/main', 'inputs': None}))
            output = Path(scratch) / 'output'
            env = dict(os.environ, GITHUB_EVENT_NAME='workflow_dispatch',
                       GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/select_jobs.py'), 'select'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['jobs'],
                             ci.select([], force_full=True)['jobs'])
            written = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(written['web-chat-contract'], 'true')
            for key in ('studio-macos', 'companion-job', 'macos-validation-memory', 'apple-cache'):
                with self.subTest(key=key):
                    self.assertEqual(written.get(key), 'true')
            self.assertEqual(json.loads(written['companions']),
                             ['packages/' + name for name in ci.COMPANIONS])
            self.assertEqual(json.loads(written['test-other-os-matrix']),
                             json.loads(result.stdout)['test-other-os-matrix'])


class AggregateTest(unittest.TestCase):
    def test_dartpad_core_result_requires_both_selected_example_guards(self):
        plan = ci.select(['example/dartpad_gguf/lib/main.dart'], pull_request=True)
        selected_jobs = {'changes', 'analyze', 'example-packages', 'markdown-tests'}
        needs = {job: {'result': 'success' if job in selected_jobs else 'skipped'}
                 for job in {'changes', *ci.expected_jobs(plan)}}
        self.assertEqual(ci.aggregate(plan, needs), [])
        for job in ('analyze', 'example-packages'):
            with self.subTest(job=job):
                needs[job]['result'] = 'skipped'
                self.assertEqual(ci.aggregate(plan, needs), [f'{job}: selected=True, result=skipped'])
                needs[job]['result'] = 'success'

    def test_dartpad_bundle_result_skips_builds_and_rejects_a_failed_selected_build(self):
        example = 'example/dartpad_gguf/lib/main.dart'
        needs = {'changes': {'result': 'success'}, 'desktop': {'result': 'skipped'},
                 'app': {'result': 'skipped'}}
        plan = ci.select([example], pull_request=True)
        self.assertEqual(ci.aggregate(plan, needs, bundle=True), [])

        mixed = ci.select([example, 'example/chat_app/web/index.html'], pull_request=True)
        needs['app']['result'] = 'failure'
        self.assertEqual(ci.aggregate(mixed, needs, bundle=True),
                         ['app: selected=True, result=failure'])

    def test_each_selected_job_must_succeed_and_each_unselected_job_must_skip(self):
        for bundle, pull_request in ((False, False), (True, False), (False, True), (True, True)):
            for paths in (['README.md'], ['lib/llamadart.dart'], ['example/chat_app/android/a'],
                          ['example/chat_app/ios/a']):
                plan = ci.select(paths, pull_request=pull_request)
                expected = ci.expected_jobs(plan, bundle)
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

    def test_linux_vm_shards_share_the_coverage_selection(self):
        for paths, selected in ((['README.md'], False), (['example/chat_app/android/a'], True),
                                (['lib/llamadart.dart'], True)):
            plan = ci.select(paths)
            self.assertEqual(plan['jobs']['test-linux-coverage'], selected)
            self.assertEqual(ci.expected_jobs(plan)['test-linux-vm'], selected)
            self.assertNotIn('test-linux-vm', ci.expected_jobs(plan, bundle=True))
            needs = {'changes': {'result': 'success'}}
            needs.update({j: {'result': 'success' if s else 'skipped'}
                          for j, s in ci.expected_jobs(plan).items()})
            del needs['test-linux-vm']
            self.assertTrue(ci.aggregate(plan, needs), paths)

    def test_companion_job_runs_for_every_check_it_hosts(self):
        # Each path selects one of the checks without the others being implied.
        cases = (
            (['packages/llamadart_litert_lm_flutter/lib/a.dart'], True),
            (['test/integration/apple_companion_flutter_cache_test.dart'], True),
            (['packages/llamadart_validation/test/process_memory_test.dart'], True),
            (['example/chat_app/lib/main.dart'], True),
            (['README.md'], False),
            (['packages/genkit_llamadart/lib/a.dart'], False),
            (['example/chat_app/test/unit_test.dart'], False),
        )
        for paths, selected in cases:
            with self.subTest(paths=paths):
                plan = ci.select(paths)
                self.assertEqual(ci.expected_jobs(plan)['companion-packages'], selected)
                needs = {'changes': {'result': 'success'}}
                needs.update({j: {'result': 'success' if s else 'skipped'}
                              for j, s in ci.expected_jobs(plan).items()})
                self.assertEqual(ci.aggregate(plan, needs), [])
                needs['companion-packages']['result'] = 'failure' if selected else 'success'
                self.assertTrue(ci.aggregate(plan, needs))

    def test_windows_harness_leg_stands_alone_only_without_test_native(self):
        cases = (
            (['packages/llamadart_validation/test/process_memory_test.dart'],
             ['ubuntu-latest', 'windows-latest']),
            (['example/chat_app/lib/main.dart'], ['ubuntu-latest', 'windows-latest']),
            (['packages/llamadart_validation/lib/src/runner.dart'],
             ['ubuntu-latest', 'windows-latest']),
            (['lib/llamadart.dart'], ['ubuntu-latest']),
            (['packages/llamadart_validation/test/a.dart', 'test/unit/core/a_test.dart'],
             ['ubuntu-latest']),
        )
        for paths, oses in cases:
            with self.subTest(paths=paths):
                plan = ci.select(paths)
                self.assertTrue(plan['jobs']['validation-harness'])
                self.assertEqual(ci.validation_harness_oses(plan), oses)

    def test_malformed_selection_cannot_turn_missing_work_into_success(self):
        for field, value in [('jobs', {}), ('desktops', ['unknown']), ('apps', ['web', 'web']),
                             ('companions', ['packages/llamadart_llama_cpp_flutter']),
                             ('coverage', 'false')]:
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
        needs.update({j: {'result': 'success' if selected else 'skipped'}
                      for j, selected in ci.expected_jobs(plan).items()})
        self.assertEqual(ci.aggregate(plan, needs), [])
        needs['new-unaccounted-job'] = {'result': 'success'}
        self.assertTrue(ci.aggregate(plan, needs))


class MacosPathGatingTest(unittest.TestCase):
    def _assert_zero_macos(self, plan):
        self.assertFalse(plan['macos-native'])
        self.assertFalse(plan['studio-macos'])
        self.assertFalse(plan['macos-validation-memory'])
        self.assertFalse(plan['apple-cache'])
        self.assertEqual(plan['companions'], [])
        self.assertNotIn('macos-15', plan['desktops'])
        self.assertFalse(ci.companion_job_selected(plan))
        self.assertNotIn('macos', {row['lane'] for row in plan['test-other-os-matrix']})

    def test_isolated_linux_only_root_suite_admits_zero_macos_jobs_on_pr(self):
        suite = 'test/unit/core/grammar/response_schema_validation_test.dart'
        plan = ci.select([suite], pull_request=True, host_suites={suite: False})
        self._assert_zero_macos(plan)
        self.assertTrue(plan['jobs']['test-linux-coverage'])
        self.assertTrue(plan['jobs']['test-web'])
        self.assertTrue(plan['jobs']['test-other-os'])
        self.assertTrue(plan['windows-native'])
        self.assertEqual(plan['test-other-os-matrix'], list(ci.WINDOWS_SHARDS))
        self.assertFalse(plan['jobs']['studio'])

    def test_pr_2053_pair_admits_macos_native_and_desktop_only(self):
        suite = 'test/unit/tooling/validation_remote_test.dart'
        plan = ci.select(
            [suite, 'tool/testing/validation/bundle.dart'],
            pull_request=True,
            host_suites={suite: True},
        )
        self.assertTrue(plan['macos-native'])
        self.assertTrue(plan['windows-native'])
        self.assertIn('macos-15', plan['desktops'])
        self.assertFalse(plan['studio-macos'])
        self.assertFalse(plan['macos-validation-memory'])
        self.assertFalse(plan['apple-cache'])
        self.assertFalse(ci.companion_job_selected(plan))
        self.assertEqual(plan['companions'], [])

    def test_docs_only_main_push_keeps_incremental_selection_without_macos_overlay(self):
        for pull_request in (True, False):
            with self.subTest(pull_request=pull_request):
                plan = ci.select(['README.md'], pull_request=pull_request)
                self._assert_zero_macos(plan)
                self.assertEqual(plan['coverage'], not pull_request)

    def test_validation_profile_vs_memory_probe_and_speech_runner(self):
        profile = ci.select(['packages/llamadart_validation/assets/profiles/chat-gguf-cpu.json'],
                            pull_request=True)
        self._assert_zero_macos(profile)
        self.assertEqual(ci.validation_harness_oses(profile), ['ubuntu-latest', 'windows-latest'])
        for path in ('packages/llamadart_validation/test/process_memory_test.dart',
                     'packages/llamadart_validation/test/fixtures/process_memory_probe.dart',
                     'packages/llamadart_validation/lib/src/speech_runner.dart',
                     'packages/llamadart_validation/pubspec.yaml'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertTrue(plan['macos-validation-memory'])
                self.assertTrue(ci.companion_job_selected(plan))
                self.assertFalse(plan['macos-native'])
                self.assertFalse(plan['studio-macos'])
                self.assertFalse(plan['apple-cache'])

    def test_web_backend_exemption_and_conditional_entrypoint_pins(self):
        for path in ('lib/src/backends/web/web_backend.dart',
                     'lib/src/backends/webgpu/webgpu_backend.dart'):
            for pull_request in (True, False):
                with self.subTest(path=path, pull_request=pull_request):
                    plan = ci.select([path], pull_request=pull_request)
                    self._assert_zero_macos(plan)
                    self.assertTrue(plan['jobs']['test-linux-coverage'])
                    self.assertTrue(plan['jobs']['test-web'])
                    self.assertTrue(plan['jobs']['web-chat-contract'])
                    self.assertTrue(plan['jobs']['studio'])
                    self.assertTrue(plan['windows-native'])
        for entrypoint in ('lib/src/backends/backend.dart', 'lib/backend.dart'):
            plan = ci.select([entrypoint], pull_request=True)
            self.assertTrue(plan['macos-native'])
            self.assertTrue(plan['studio-macos'])
            self.assertEqual(plan['companions'], ['packages/' + name for name in ci.COMPANIONS])
        # Detect any new production import of web/ or webgpu/ outside the
        # established browser trees and the pinned conditional entrypoints.
        directive = re.compile(r'''^\s*(?:import|export|part)\s+((?:[^;'"]|'[^']*'|"[^"]*")*);''', re.M)
        imports_web = []
        for dart_file in sorted((ROOT / 'lib').rglob('*.dart')):
            rel = dart_file.relative_to(ROOT).as_posix()
            if rel.startswith(('lib/src/backends/web/', 'lib/src/backends/webgpu/')):
                continue
            text = dart_file.read_text(encoding='utf-8')
            for match in directive.finditer(text):
                for uri in re.findall(r'''['"]([^'"]+)['"]''', match.group(1)):
                    resolved = ('lib/' + uri[len('package:llamadart/'):]
                                if uri.startswith('package:llamadart/')
                                else (posixpath.normpath(posixpath.join(posixpath.dirname(rel), uri))
                                      if ':' not in uri else ''))
                    if resolved.startswith(('lib/src/backends/web/', 'lib/src/backends/webgpu/')):
                        imports_web.append(rel)
                        break
        self.assertEqual(
            imports_web,
            ['lib/src/backends/backend.dart', 'lib/src/backends/litert_lm/litert_lm_backend_web.dart'],
        )

    def test_studio_packaging_exemptions_vs_shared_ui(self):
        for path in ('packages/llamadart_studio/web/index.html',
                     'packages/llamadart_studio/windows/runner/main.cpp',
                     'packages/llamadart_studio/linux/my_application.cc'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertTrue(plan['jobs']['studio'])
                self._assert_zero_macos(plan)
        for path in ('packages/llamadart_studio/lib/main.dart',
                     'packages/llamadart_studio/macos/Runner/AppDelegate.swift',
                     'packages/llamadart_studio/test/macos_app_delegate_test.dart',
                     'packages/llamadart_studio_core/lib/src/studio.dart'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertTrue(plan['jobs']['studio'])
                self.assertTrue(plan['studio-macos'])
                self.assertFalse(plan['macos-native'])

    def test_chat_app_apple_vs_portable_inputs(self):
        for path in ('example/chat_app/pubspec.lock',
                     'example/chat_app/lib/main.dart',
                     'example/chat_app/integration_test/physical_ios_speech_e2e_test.dart',
                     'example/chat_app/test_vm/physical_ios_speech_e2e_support_test.dart'):
            with self.subTest(path=path):
                plan = ci.select([path], pull_request=True)
                self.assertTrue(plan['apple-cache'])
                self.assertTrue(ci.companion_job_selected(plan))
                self.assertFalse(plan['macos-native'])
        for path in ('example/chat_app/android/app/build.gradle',
                     'example/chat_app/web/index.html',
                     'example/chat_app/linux/CMakeLists.txt',
                     'example/chat_app/windows/CMakeLists.txt',
                     'example/chat_app/test/unit_test.dart'):
            with self.subTest(path=path):
                self._assert_zero_macos(ci.select([path], pull_request=True))

    def test_mixed_deleted_and_missing_probe_stay_conservative(self):
        mixed = ci.select(['lib/src/backends/web/web_backend.dart', 'lib/llamadart.dart'],
                          pull_request=True)
        self.assertTrue(mixed['macos-native'])
        self.assertEqual(mixed['companions'], ['packages/' + name for name in ci.COMPANIONS])
        suite = 'test/unit/core/grammar/response_schema_validation_test.dart'
        # Missing probe result or deleted/unknown root test input stays conservative.
        self.assertTrue(ci.select([suite], pull_request=True)['macos-native'])
        self.assertTrue(ci.select([suite], pull_request=True, host_suites={})['macos-native'])
        self.assertTrue(ci.select(['test/support/helper.dart'], pull_request=True)['studio-macos'])
        self.assertTrue(ci.select(['test/support/helper.dart'], pull_request=True)['apple-cache'])

    def test_cli_pr_probe_and_fallback_and_main_push(self):
        with tempfile.TemporaryDirectory() as scratch:
            def git(*args):
                return subprocess.check_output(['git', '-C', scratch, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.email', 'test@example.invalid')
            git('config', 'user.name', 'CI test')
            (Path(scratch) / 'tool/ci').mkdir(parents=True)
            (Path(scratch) / 'test/unit/core').mkdir(parents=True)
            (Path(scratch) / 'tool/ci/select_jobs.py').write_text((ROOT / 'tool/ci/select_jobs.py').read_text())
            (Path(scratch) / 'tool/ci/test_shards.dart').write_text((ROOT / 'tool/ci/test_shards.dart').read_text())
            (Path(scratch) / 'README.md').write_text('base\n')
            (Path(scratch) / 'test/unit/core/neutral_test.dart').write_text('void main() {}\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (Path(scratch) / 'test/unit/core/neutral_test.dart').write_text('void main() { /* edit */ }\n')
            git('add', '.')
            git('commit', '-qm', 'edit neutral test')
            head = git('rev-parse', 'HEAD')

            # Hermetic fake `dart` on PATH so this suite runs without a Dart SDK.
            fake_bin = Path(scratch) / 'bin'
            fake_bin.mkdir()
            fake_dart = fake_bin / 'dart'
            fake_dart.write_text(
                f'#!{sys.executable}\n'
                'import json, sys\n'
                'assert sys.argv[1:] == ["tool/ci/test_shards.dart", "hosts-json"]\n'
                'files = json.loads(sys.stdin.read())\n'
                'print(json.dumps({f: False for f in files}))\n'
            )
            fake_dart.chmod(0o755)

            event = Path(scratch) / 'event.json'
            event.write_text(json.dumps({'pull_request': {'base': {'sha': base}, 'head': {'sha': head}}}))
            output = Path(scratch) / 'output'
            env = dict(os.environ, PATH=f'{fake_bin}:/usr/bin:/bin',
                       GITHUB_EVENT_NAME='pull_request',
                       GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, 'tool/ci/select_jobs.py', 'select'],
                                    cwd=scratch, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self._assert_zero_macos(plan)

            # Non-zero probe exit falls back conservatively to Mac native.
            fake_dart.write_text(f'#!{sys.executable}\nimport sys; sys.exit(3)\n')
            nonzero = subprocess.run([sys.executable, 'tool/ci/select_jobs.py', 'select'],
                                     cwd=scratch, env=env, capture_output=True, text=True)
            self.assertEqual(nonzero.returncode, 0, nonzero.stderr)
            nonzero_plan = json.loads(nonzero.stdout)
            self.assertTrue(nonzero_plan['macos-native'])
            self.assertIn('Host-suite probe exited 3', nonzero_plan['reasons'])

            # Malformed probe output falls back conservatively to Mac native.
            fake_dart.write_text(f'#!{sys.executable}\nprint("not-json")\n')
            bad_out = subprocess.run([sys.executable, 'tool/ci/select_jobs.py', 'select'],
                                     cwd=scratch, env=env, capture_output=True, text=True)
            self.assertEqual(bad_out.returncode, 0, bad_out.stderr)
            self.assertTrue(json.loads(bad_out.stdout)['macos-native'])

            # Missing Dart falls back conservatively to Mac native.
            no_dart_env = dict(env, PATH='/usr/bin:/bin')
            fallback = subprocess.run([sys.executable, 'tool/ci/select_jobs.py', 'select'],
                                      cwd=scratch, env=no_dart_env, capture_output=True, text=True)
            self.assertEqual(fallback.returncode, 0, fallback.stderr)
            self.assertTrue(json.loads(fallback.stdout)['macos-native'])

            # Docs-only main push keeps zero Mac jobs.
            (Path(scratch) / 'README.md').write_text('docs\n')
            git('add', 'README.md')
            git('commit', '-qm', 'docs')
            docs_head = git('rev-parse', 'HEAD')
            event.write_text(json.dumps({'before': head, 'after': docs_head}))
            push_env = dict(os.environ, GITHUB_EVENT_NAME='push',
                            GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
            push_res = subprocess.run([sys.executable, 'tool/ci/select_jobs.py', 'select'],
                                      cwd=scratch, env=push_env, capture_output=True, text=True)
            self.assertEqual(push_res.returncode, 0, push_res.stderr)
            self._assert_zero_macos(json.loads(push_res.stdout))

    def test_validate_plan_checks_macos_fields_and_matrix_consistency(self):
        for field, value in [
            ('studio-macos', 'true'),
            ('macos-native', 1),
            ('windows-native', 'false'),
            ('macos-validation-memory', None),
            ('apple-cache', 0),
            ('test-other-os-matrix', [{'os': 'macos-latest', 'lane': 'macos', 'shard': 1, 'shards': 3}]),
        ]:
            plan = ci.select(['lib/llamadart.dart'])
            plan[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                ci.validate_plan(plan)

    def test_recent_pr_diffs_never_exceed_base_macos_job_count(self):
        def macos_job_count(plan):
            return (sum(row['lane'] == 'macos' for row in plan['test-other-os-matrix'])
                    + int(ci.companion_job_selected(plan))
                    + int(plan['studio-macos'])
                    + int('macos-15' in plan['desktops']))

        cases = (
            ('skill-only', ['skills/llamadart-web/SKILL.md'], None, 0),
            ('#2055', ['lib/llamadart.dart', 'MIGRATION.md',
                       'skills/llamadart-chat/SKILL.md', 'tool/testing/test_matrix.dart'],
             None, 5),
            ('#2053', ['test/unit/tooling/validation_remote_test.dart',
                       'tool/testing/validation/bundle.dart'],
             {'test/unit/tooling/validation_remote_test.dart': True}, 6),
            ('#1985', ['lib/src/backends/web/web_backend.dart',
                       'test/unit/backends/web/web_backend_test.dart'],
             {'test/unit/backends/web/web_backend_test.dart': True}, 5),
            ('grammar-leaf', ['test/unit/core/grammar/response_schema_validation_test.dart'],
             {'test/unit/core/grammar/response_schema_validation_test.dart': False}, 5),
        )
        for label, paths, host_suites, base_count in cases:
            with self.subTest(label=label):
                plan = ci.select(paths, pull_request=True, host_suites=host_suites)
                self.assertLessEqual(macos_job_count(plan), base_count, label)


if __name__ == '__main__':
    unittest.main()
