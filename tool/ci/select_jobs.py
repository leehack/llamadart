#!/usr/bin/env python3
"""Conservative CI impact selection and truthful conditional-job aggregation.

Only enumerated independent paths may omit work. Missing revisions, malformed
Git output, unknown inputs and runtime/shared changes select the full graph.
Uses Git's NUL-delimited, rename-aware inventory rather than GitHub's capped
changed-files API. No changed path is evaluated as shell text.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

COMPANIONS = (
    'llamadart_llama_cpp_flutter', 'llamadart_litert_lm_flutter',
    'llamadart_stable_diffusion_flutter',
)
CORE_JOBS = (
    'analyze', 'docs-check', 'docs-versions', 'validation-harness',
    'validation-integration', 'companion-packages', 'test-linux-coverage',
    'test-web', 'web-chat-contract', 'test-other-os',
    'native-prompt-reuse-parity', 'artifact-contract',
    'genkit', 'example-packages', 'model-store', 'studio', 'markdown-tests',
)
# Jobs outside the plan that run exactly when the planned job they feed is
# selected: the Linux VM test shards. The planned test-linux-coverage job only
# merges their coverage, which runs after merge (push and manual runs).
SHARD_JOBS = {'test-linux-vm': 'test-linux-coverage'}
MACOS_SHARDS = (
    {'os': 'macos-latest', 'lane': 'macos', 'shard': 1, 'shards': 2},
    {'os': 'macos-latest', 'lane': 'macos', 'shard': 2, 'shards': 2},
)
WINDOWS_SHARDS = (
    {'os': 'windows-latest', 'lane': 'windows-tooling', 'shard': 1, 'shards': 1},
    {'os': 'windows-latest', 'lane': 'windows-runtime', 'shard': 1, 'shards': 1},
)
DESKTOPS = ('ubuntu-24.04', 'windows-2022', 'macos-15')
APPS = ('android', 'web', 'ios-inputs')
# Bundle targets a pull request builds only when it changes their own build
# inputs; pushes to main and manual runs build them for every selecting change.
# Their Dart code also compiles in the Linux desktop and Web builds.
_BUNDLE_WORKFLOW = ('.github/workflows/validation_bundles.yml', 'tool/ci/select_jobs.py')
_NATIVE_BUILD_INPUTS = ('hook/', 'lib/src/hook/', 'pubspec.yaml', 'pubspec.lock',
                        'tool/testing/validation/', 'tool/testing/validation.dart')
POST_MERGE_TARGETS = {
    'macos-15': _BUNDLE_WORKFLOW + _NATIVE_BUILD_INPUTS + ('.flutter-version',),
    'android': _BUNDLE_WORKFLOW + _NATIVE_BUILD_INPUTS + tuple(
        'packages/' + name + '/' + part for name in COMPANIONS
        for part in ('lib/', 'pubspec.yaml')),
}
# The validation package's `flutter.assets`, which the chat app bundles.
VALIDATION_BUNDLED_ASSETS = (
    'packages/llamadart_validation/assets/profiles/',
    'packages/llamadart_validation/assets/fixtures/s24/chat-litert-gpu-legacy.json',
    'packages/llamadart_validation/assets/decision/',
    'packages/llamadart_validation/assets/embeddings/v1/',
)

EXAMPLE_PACKAGES = (
    'example/basic_app/',
    'example/dartpad_gguf/',
    'example/laya_command_bar/',
    'example/laya_tetris/',
    'example/llamadart_cli/',
    'example/llamadart_server/',
    'example/tui_coding_agent/',
)
EXAMPLE_NOTEBOOK = 'example/training_notebook/'

# The Linux VM also runs each root suite that imports or reads these files.
BASIC_APP_ROOT_VM = (
    'example/basic_app/bin/src/live_asr_pcm.dart',
    'example/basic_app/bin/src/macos_mic_asr.dart',
)
BASIC_APP_ROOT_CHROME = (
    'example/basic_app/bin/llamadart_engine_lifecycle_example.dart',
    'example/basic_app/test/fixtures/image_warmup_comparison.dart',
)
BASIC_APP_ROOT_HOST_VM = (
    'example/basic_app/test/fixtures/image_container_native_reference.cpp',
    'example/basic_app/test/fixtures/image_original_container_model.dart',
    'example/basic_app/test/image_generation_smoke.yaml',
)

# Use exact paths so new tools and fixtures default to full CI.
TOOLS_STATIC = {
    'scripts/android_runtime_smoke.sh',
    'tool/gen_litert_lm_templates.dart',
    'tool/gguf_chat_features_smoke.dart',
    'tool/git/pr_head_update_evidence.schema.json',
    'tool/litert_lm_pixel_benchmark.sh',
    'tool/macos_fair_litert_vs_llamadart.sh',
    'tool/macos_llamadart_benchmark.dart',
    'tool/native/fixtures/litert_lm_legacy_Package.swift',
    'tool/native/fixtures/litert_lm_modern_provider_Package.swift',
    'tool/native/fixtures/litert_lm_v0191_owner_SHA256SUMS',
    'tool/native/fixtures/litert_lm_v0191_owner_manifest.json',
    'tool/native/fixtures/litert_lm_v0191_owner_release.json',
    'tool/native/fixtures/litert_lm_v019_owner_SHA256SUMS',
    'tool/native/fixtures/litert_lm_v019_owner_manifest.json',
    'tool/native/fixtures/litert_lm_v019_owner_release.json',
    'tool/native/fixtures/v0.16.0-native.2-manifest.json',
    'tool/testing/gemma4_mtp_smoke.dart',
    'tool/testing/native_embedding_benchmark.dart',
    'tool/testing/native_embedding_sweep.dart',
    'tool/testing/native_inference_benchmark.dart',
    'tool/testing/playwright_bridge_smoke.py',
    'tool/testing/playwright_chat_app_benchmark.py',
    'tool/testing/playwright_qwen_cpu_multimodal_smoke.py',
    'tool/testing/playwright_qwen_harness.py',
    'tool/testing/playwright_web_single_thread_core.py',
    'tool/testing/prepare_llama_cpp_source.sh',
    'tool/testing/prompts/native_prompt_reuse_parity_prompts.txt',
    'tool/testing/run_webgpu_multimodal_regression_gate.sh',
    'tool/web_fair_litert_vs_llamadart.sh',
}
TOOLS_LINUX_VM = {
    'tool/litert_lm_templates/gemma.jinja',
    'tool/litert_lm_templates/gemma3n.jinja',
    'tool/litert_lm_templates/qwen25.jinja',
    'tool/litert_lm_templates/qwen3.jinja',
    'tool/release/collect_pr_changelog.dart',
    'tool/release/nonpublishing_auth_probe.py',
    'tool/release/patch_branch.dart',
    'tool/release/reopen_unreleased_changelog.dart',
    'tool/testing/run_llama_cpp_chat_tests.sh',
}
# The host suites that execute these shell scripts skip those tests on Windows.
TOOLS_MACOS_VM = {
    'tool/release/genkit_release_helpers.sh',
    'tool/release/verify_release_candidate.sh',
    'tool/testing/build_llama_cpp_runtime_gbnf_validator.sh',
    'tool/testing/run_template_parity_suites.sh',
    'tool/testing/without_app_nap.sh',
}
TOOLS_ALL_HOST_VM = {
    'tool/litert_lm_asr_smoke.dart',
    'tool/litert_lm_templates/gemma4.jinja',
    'tool/native/fixtures/litert_lm_schema2_owner_manifest.json',
    'tool/native/fixtures/litert_lm_schema2_owner_release.json',
    'tool/native/fixtures/litert_lm_v018_samplers_Package.swift',
    'tool/native/fixtures/litert_lm_v019_apple_inventory_projection.json',
    'tool/release/check_core_archive.py',
    'tool/release/companion_package_contents.dart',
    'tool/release/companion_pub_preflight.dart',
    'tool/release/pr_changelog.dart',
    'tool/release/pub_content_limits.dart',
    'tool/release/pub_dev_api.dart',
    'tool/release/stage_companion_package.dart',
    'tool/release/stage_genkit_package.py',
    'tool/testing/litert_text_history_web_e2e.py',
    'tool/testing/llama_cpp_speculative_benchmark.dart',
    'tool/testing/playwright_chat_app_microphone_lifecycle.py',
    'tool/testing/playwright_chat_app_text_to_speech_smoke.py',
    'tool/testing/playwright_web_js_backed_model_staging.py',
    'tool/testing/test_matrix.dart',
    'tool/testing/verify_image_e2e_evidence.dart',
    'tool/testing/verify_speech_stream_qualification.dart',
}
BRIDGE_PIN_INPUTS = {
    'scripts/fetch_webgpu_bridge_assets.sh',
    'tool/testing/check_webgpu_bridge_tag.dart',
}

def inventory(raw):
    """Return both endpoints of renames/copies and deleted paths; reject truncation."""
    parts = raw.decode('utf-8', errors='strict').split('\0')
    if parts.pop() != '':
        raise ValueError('Git inventory must end in NUL')
    paths = []
    while parts:
        status = parts.pop(0)
        if not re.fullmatch(r'(?:[AMDUT]|[RC][0-9]{1,3})', status):
            raise ValueError('Unsupported Git status')
        count = 2 if status[0] in 'RC' else 1
        if len(parts) < count:
            raise ValueError('Truncated Git inventory')
        for _ in range(count):
            path = parts.pop(0)
            if not path or path.startswith('/') or '..' in PurePosixPath(path).parts:
                raise ValueError('Invalid Git path')
            paths.append(path)
    return paths


def builds_target(target, path):
    """Whether a pull request changing [path] builds a post-merge [target]."""
    if path.startswith(POST_MERGE_TARGETS[target]):
        return True
    if path.startswith('packages/llamadart_validation/'):
        return not path.startswith(('packages/llamadart_validation/test/',
                                    'packages/llamadart_validation/assets/',
                                    'packages/llamadart_validation/schemas/'))
    if target == 'android' and path.startswith('example/chat_app/'):
        return not (path.endswith('.md') or path.startswith(tuple(
            'example/chat_app/' + part + '/'
            for part in ('test', 'test_vm', 'web', 'ios', 'macos', 'linux', 'windows'))))
    return False


def select(paths, force_full=False, pull_request=False, host_suites=None):
    # Every path runs the Markdown reader inventory unless Linux VM runs it.
    jobs, companions, desktops, apps = {'markdown-tests'}, set(), set(), set()
    reasons = []
    macos_native = False
    windows_native = False
    studio_macos = False
    macos_validation_memory = False
    apple_cache = False

    def full(reason):
        nonlocal macos_native, windows_native, studio_macos, macos_validation_memory, apple_cache
        # Do not clear an artifact check selected by another changed path.
        jobs.update(job for job in CORE_JOBS if job != 'artifact-contract')
        companions.update(COMPANIONS)
        desktops.update(DESKTOPS)
        apps.update(APPS)
        macos_native = True
        windows_native = True
        studio_macos = True
        macos_validation_memory = True
        apple_cache = True
        reasons.append(reason)

    if force_full or not paths:
        full('manual, missing or unavailable change inventory')
        jobs.add('artifact-contract')
    for path in paths:
        if path.startswith(('.github/workflows/', '.github/actions/', 'tool/ci/', 'test/ci/')):
            full('workflow or selector change')
            jobs.add('artifact-contract')
        elif path == 'website/docs/integrations/genkit.md':
            jobs.update(('docs-check', 'docs-versions', 'genkit'))
        elif path.startswith('packages/genkit_llamadart/'):
            jobs.update(('genkit', 'test-linux-coverage'))
        elif path.startswith(('packages/llamadart_studio/',
                              'packages/llamadart_studio_core/')):
            jobs.add('studio')
            if path.startswith('packages/llamadart_studio/web/'):
                jobs.add('docs-versions')
            if not path.startswith(('packages/llamadart_studio/web/',
                                    'packages/llamadart_studio/windows/',
                                    'packages/llamadart_studio/linux/')):
                studio_macos = True
        elif path == 'website/docs/guides/model-store.md':
            jobs.update(('docs-check', 'docs-versions', 'model-store'))
        elif path.startswith('packages/llamadart_model_store/'):
            jobs.update(('model-store', 'test-linux-coverage'))
        elif path in ('.github/pull_request_template.md', '.dockerignore'):
            continue  # Markdown Tests covers the template. Docker builds run locally.
        elif (path in ('README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'AGENTS.md',
                       'LICENSE', 'MIGRATION.md', 'example/README.md')
              or path.startswith(('doc/', 'website/', 'tool/docs/'))
              or (path.endswith('.md') and path.startswith(
                  ('packages/', 'example/chat_app/', EXAMPLE_NOTEBOOK) + EXAMPLE_PACKAGES))):
            jobs.update(('docs-check', 'docs-versions'))
        elif (path in ('.github/dependabot.yml', 'dartdoc_options.yaml')
              or path.startswith(('skills/', 'docker/'))):
            jobs.add('analyze')
        elif path in ('.github/CODEOWNERS', '.pubignore'):
            jobs.update(('analyze', 'test-linux-coverage'))
        elif path == 'codecov.yml':
            jobs.add('test-linux-coverage')
        elif path in TOOLS_STATIC:
            jobs.add('analyze')
        elif path in TOOLS_LINUX_VM:
            jobs.update(('analyze', 'test-linux-coverage'))
        elif path in TOOLS_MACOS_VM:
            jobs.update(('analyze', 'test-linux-coverage'))
            macos_native = True
        elif path in TOOLS_ALL_HOST_VM:
            jobs.update(('analyze', 'test-linux-coverage'))
            macos_native = True
            windows_native = True
            if path == 'tool/release/stage_genkit_package.py':
                jobs.add('genkit')
        elif path in BRIDGE_PIN_INPUTS:
            jobs.update(('analyze', 'test-linux-coverage', 'test-web'))
            macos_native = True
            windows_native = True
            if path == 'scripts/fetch_webgpu_bridge_assets.sh':
                jobs.update(('web-chat-contract', 'example-packages'))
                # Every bundle records the fetch script's default bridge tag.
                desktops.update(DESKTOPS)
                apps.update(APPS)
        elif any(path.startswith('packages/' + name + '/') for name in COMPANIONS):
            name = path.split('/')[1]
            companions.add(name)
            # Root hooks/loaders and Flutter consumers depend on companions.
            jobs.update(('analyze', 'companion-packages', 'test-linux-coverage',
                         'test-other-os', 'web-chat-contract', 'studio'))
            apps.update(APPS)
            macos_native = True
            windows_native = True
            studio_macos = True
            apple_cache = True
        # Root suites import, copy and read files throughout the validation
        # trees and the chat app, so no list of files or suites can stand in
        # for the root Linux tests there.
        elif path.startswith('packages/llamadart_validation/'):
            jobs.update(('analyze', 'validation-harness', 'validation-integration',
                         'test-linux-coverage'))
            compiled = not path.startswith(('packages/llamadart_validation/test/',
                                            'packages/llamadart_validation/assets/',
                                            'packages/llamadart_validation/schemas/'))
            if compiled or path.startswith(VALIDATION_BUNDLED_ASSETS):
                # The chat app depends on this package, so it is a deployed input.
                jobs.add('web-chat-contract')
            if compiled:
                desktops.update(DESKTOPS)
                apps.update(APPS)
            if compiled or path in (
                'packages/llamadart_validation/test/process_memory_test.dart',
                'packages/llamadart_validation/test/fixtures/process_memory_probe.dart',
            ):
                macos_validation_memory = True
        elif path.startswith(('tool/testing/validation/', 'tool/testing/validation.dart')):
            jobs.update(('analyze', 'validation-harness', 'validation-integration',
                         'test-linux-coverage'))
            # Build/orchestration helpers are shared between all bundle targets.
            desktops.update(DESKTOPS)
            apps.update(APPS)
        elif path.startswith('example/chat_app/'):
            jobs.update(('analyze', 'test-linux-coverage'))
            if path.startswith('example/chat_app/android/'):
                apps.add('android')
            elif path.startswith('example/chat_app/ios/'):
                apps.add('ios-inputs')
                macos_native = True
                apple_cache = True
            elif path.startswith('example/chat_app/macos/'):
                jobs.update(('web-chat-contract', 'validation-harness'))
                apps.update(APPS)
                macos_native = True
                apple_cache = True
            elif path.startswith('example/chat_app/web/'):
                jobs.add('web-chat-contract')
                apps.add('web')
            elif path.startswith(('example/chat_app/linux/', 'example/chat_app/windows/')):
                jobs.update(('web-chat-contract', 'validation-harness'))
                apps.update(APPS)
            elif path.startswith(('example/chat_app/test/', 'example/chat_app/test_vm/')):
                jobs.add('web-chat-contract')
                if path == 'example/chat_app/test_vm/physical_ios_speech_e2e_support_test.dart':
                    apple_cache = True
            else:
                jobs.update(('web-chat-contract', 'validation-harness'))
                apps.update(APPS)
                apple_cache = True
        # DartPad already narrows .gitignore. Keep the other examples' ignore
        # files on the full path because bundle builds check for a dirty tree.
        elif path.startswith('example/dartpad_gguf/') or (
            path.startswith(EXAMPLE_PACKAGES) and not path.endswith('/.gitignore')
        ):
            jobs.update(('analyze', 'example-packages'))
            if path in BASIC_APP_ROOT_VM:
                jobs.add('test-linux-coverage')
            elif path in BASIC_APP_ROOT_CHROME:
                jobs.update(('test-linux-coverage', 'test-web'))
            elif path in BASIC_APP_ROOT_HOST_VM:
                jobs.add('test-linux-coverage')
                macos_native = True
                windows_native = True
        elif path.startswith(EXAMPLE_NOTEBOOK) and not path.endswith('/.gitignore'):
            jobs.add('analyze')
        elif path.startswith('test/'):
            # Preserve all root test inventories, including Linux/Chrome/Windows.
            jobs.update(('analyze', 'test-linux-coverage', 'test-web', 'test-other-os'))
            windows_native = True
            if path.endswith('_test.dart'):
                if path == 'test/integration/apple_companion_flutter_cache_test.dart':
                    macos_native = True
                    apple_cache = True
                elif host_suites is not None and host_suites.get(path) is False:
                    pass
                else:
                    macos_native = True
                    if host_suites is not None and path not in host_suites:
                        reasons.append('missing host-suite probe result: ' + path)
            else:
                # Studio core tests import and read root test support and fixtures.
                jobs.add('studio')
                studio_macos = True
                macos_native = True
                apple_cache = True
        elif path.startswith(('lib/src/backends/web/', 'lib/src/backends/webgpu/')):
            jobs.update(job for job in CORE_JOBS
                        if job not in ('artifact-contract', 'companion-packages'))
            windows_native = True
            desktops.update(d for d in DESKTOPS if d != 'macos-15')
            apps.update(APPS)
        elif path.startswith(('lib/', 'example/')):
            full('shared/runtime or example path: ' + path)
        else:
            # .gitattributes can change checkout bytes. .gitignore can expose
            # generated files to the validation bundle clean-tree checks.
            full('shared/runtime or unclassified path: ' + path)
    if 'analyze' in jobs:
        jobs.discard('docs-versions')  # Already included in root static validation.
    if 'test-linux-coverage' in jobs:
        jobs.discard('markdown-tests')  # Linux coverage runs every root test.
    if 'test-linux-coverage' in jobs and 'web-chat-contract' in jobs:
        # Both root provider tests and all Flutter consumer tests are covered.
        jobs.discard('validation-integration')
    if macos_native or windows_native:
        jobs.add('test-other-os')
    else:
        jobs.discard('test-other-os')
    if companions:
        jobs.add('companion-packages')
    else:
        jobs.discard('companion-packages')
    if pull_request and paths and not force_full:
        for target in POST_MERGE_TARGETS:
            if not any(builds_target(target, path) for path in paths):
                desktops.discard(target)
                apps.discard(target)
    other_os_matrix = [
        *(MACOS_SHARDS if macos_native else ()),
        *(WINDOWS_SHARDS if windows_native else ()),
    ]
    return {
        'schema_version': 1,
        'jobs': {job: job in jobs for job in CORE_JOBS},
        # PRs skip coverage; main and manual runs collect and enforce it.
        'coverage': not pull_request,
        'companions': ['packages/' + name for name in COMPANIONS if name in companions],
        'desktops': [name for name in DESKTOPS if name in desktops],
        'apps': [name for name in APPS if name in apps],
        'studio-macos': studio_macos,
        'macos-native': macos_native,
        'windows-native': windows_native,
        'macos-validation-memory': macos_validation_memory,
        'apple-cache': apple_cache,
        'test-other-os-matrix': other_os_matrix,
        'reasons': reasons,
    }


def validate_plan(plan):
    if not isinstance(plan, dict) or plan.get('schema_version') != 1:
        raise ValueError('Unsupported plan schema')
    jobs = plan.get('jobs')
    if not isinstance(jobs, dict) or set(jobs) != set(CORE_JOBS):
        raise ValueError('Incomplete job selection')
    if any(type(value) is not bool for value in jobs.values()):
        raise ValueError('Selections must be boolean')
    for field in ('coverage', 'studio-macos', 'macos-native', 'windows-native',
                  'macos-validation-memory', 'apple-cache'):
        if type(plan.get(field)) is not bool:
            raise ValueError(f'{field} selection must be boolean')
    for field, allowed in (
        ('companions', ['packages/' + name for name in COMPANIONS]),
        ('desktops', DESKTOPS), ('apps', APPS),
    ):
        values = plan.get(field)
        if not isinstance(values, list) or any(not isinstance(v, str) or v not in allowed for v in values):
            raise ValueError('Invalid target matrix')
        if len(values) != len(set(values)):
            raise ValueError('Duplicate target')
    if jobs['companion-packages'] != bool(plan['companions']):
        raise ValueError('Companion matrix disagrees with job selection')
    expected_matrix = [
        *(MACOS_SHARDS if plan['macos-native'] else ()),
        *(WINDOWS_SHARDS if plan['windows-native'] else ()),
    ]
    if plan.get('test-other-os-matrix') != expected_matrix:
        raise ValueError('Other-OS matrix disagrees with host selections')
    if jobs['test-other-os'] != (plan['macos-native'] or plan['windows-native']):
        raise ValueError('Other-OS job disagrees with host selections')


def expected_jobs(plan, bundle=False):
    """Whether each job the aggregate needs, other than `changes`, is selected."""
    if bundle:
        return {'desktop': bool(plan['desktops']), 'app': bool(plan['apps'])}
    return {
        **plan['jobs'],
        **{job: plan['jobs'][fed] for job, fed in SHARD_JOBS.items()},
        'test-linux-coverage': plan['jobs']['test-linux-coverage'] and plan['coverage'],
        'companion-packages': companion_job_selected(plan),
        'studio-macos': plan['studio-macos'],
    }


def companion_job_selected(plan):
    return (bool(plan['companions']) or plan['macos-validation-memory']
            or plan['apple-cache'])


def validation_harness_oses(plan):
    """Windows runs the harness test in Test Native whenever that job is selected."""
    return ['ubuntu-latest'] + ([] if plan['windows-native'] else ['windows-latest'])


def aggregate(plan, needs, bundle=False):
    """A selected job must succeed; only intentionally unselected jobs may skip."""
    validate_plan(plan)
    expected = expected_jobs(plan, bundle)
    errors = []
    if needs.get('changes', {}).get('result') != 'success':
        errors.append('change selection did not succeed')
    if set(needs) != set(expected) | {'changes'}:
        errors.append('aggregate dependency inventory differs from plan')
    for job, selected in expected.items():
        result = needs.get(job, {}).get('result')
        if result != ('success' if selected else 'skipped'):
            errors.append(f'{job}: selected={selected}, result={result}')
    return errors


def event_paths(event_name, event):
    if event_name == 'pull_request':
        base = event['pull_request']['base']['sha']
        head = event['pull_request']['head']['sha']
        mode = 'pr'
    elif event_name == 'push':
        base, head, mode = event['before'], event['after'], 'push'
    else:
        raise ValueError('No incremental selection for this event')
    if not all(re.fullmatch(r'[0-9a-f]{40}', ref) and int(ref, 16) for ref in (base, head)):
        raise ValueError('Invalid revision')
    if mode == 'pr':
        base = subprocess.check_output(['git', 'merge-base', base, head], text=True).strip()
    raw = subprocess.check_output(['git', 'diff', '--name-status', '-z', '-M', base, head, '--'])
    return inventory(raw)


def probe_candidates(paths):
    """Extant root test suites whose host sensitivity can decide Mac admission."""
    return sorted({
        path for path in paths
        if path.startswith('test/') and path.endswith('_test.dart')
        and path != 'test/integration/apple_companion_flutter_cache_test.dart'
        and Path(path).is_file()
    })


def needs_dart_probe(paths, pull_request=False):
    if not pull_request or not paths:
        return False
    candidates = probe_candidates(paths)
    if not candidates:
        return False
    hypothetical = select(paths, pull_request=True,
                          host_suites={path: False for path in candidates})
    return not hypothetical['macos-native']


def run_host_suite_probe(suites):
    try:
        completed = subprocess.run(
            ['dart', 'tool/ci/test_shards.dart', 'hosts-json'],
            input=json.dumps(suites),
            capture_output=True,
            text=True,
            timeout=30,
        )
        if completed.returncode != 0:
            return None, f'Host-suite probe exited {completed.returncode}'
        decoded = json.loads(completed.stdout)
        if (not isinstance(decoded, dict) or set(decoded) != set(suites)
                or any(type(v) is not bool for v in decoded.values())):
            return None, 'Host-suite probe returned malformed output'
        return decoded, None
    except (OSError, subprocess.SubprocessError, ValueError, TypeError) as error:
        return None, f'Host-suite probe failed: {type(error).__name__}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('select', 'aggregate', 'preflight'))
    parser.add_argument('--bundle', action='store_true')
    args = parser.parse_args()
    if args.command == 'aggregate':
        try:
            errors = aggregate(json.loads(os.environ['PLAN']), json.loads(os.environ['NEEDS']), args.bundle)
        except (KeyError, ValueError, TypeError) as error:
            errors = [f'Invalid aggregate input: {error}']
        for error in errors:
            print(error, file=sys.stderr)
        return int(bool(errors))
    pull_request = os.environ.get('GITHUB_EVENT_NAME') == 'pull_request'
    if args.command == 'preflight':
        try:
            event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
            paths = event_paths(os.environ['GITHUB_EVENT_NAME'], event)
            needs_dart = needs_dart_probe(paths, pull_request=pull_request)
        except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError):
            needs_dart = False
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(f'needs-dart={str(needs_dart).lower()}\n')
        return 0
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        paths = event_paths(os.environ['GITHUB_EVENT_NAME'], event)
        host_suites = None
        probe_reason = None
        if needs_dart_probe(paths, pull_request=pull_request):
            host_suites, probe_reason = run_host_suite_probe(probe_candidates(paths))
        plan = select(paths, pull_request=pull_request, host_suites=host_suites)
        if probe_reason:
            plan['reasons'].append(probe_reason)
    except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError) as error:
        plan = select([], force_full=True, pull_request=pull_request)
        plan['reasons'] = ['Full fallback: ' + type(error).__name__]
    encoded = json.dumps(plan, separators=(',', ':'))
    print(json.dumps(plan, indent=2))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write('plan=' + encoded + '\n')
        for name, selected in plan['jobs'].items():
            out.write(f'{name}={str(selected).lower()}\n')
        out.write(f'companion-job={str(companion_job_selected(plan)).lower()}\n')
        out.write(f'coverage={str(plan["coverage"]).lower()}\n')
        out.write(f'studio-macos={str(plan["studio-macos"]).lower()}\n')
        out.write(f'macos-validation-memory={str(plan["macos-validation-memory"]).lower()}\n')
        out.write(f'apple-cache={str(plan["apple-cache"]).lower()}\n')
        out.write('test-other-os-matrix=' + json.dumps(plan['test-other-os-matrix'], separators=(',', ':')) + '\n')
        out.write('validation-harness-os=' + json.dumps(validation_harness_oses(plan), separators=(',', ':')) + '\n')
        for name in ('companions', 'desktops', 'apps'):
            out.write(name + '=' + json.dumps(plan[name], separators=(',', ':')) + '\n')
            out.write(name + '-enabled=' + str(bool(plan[name])).lower() + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
