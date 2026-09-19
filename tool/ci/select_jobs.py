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

COMPANIONS = ('llamadart_llama_cpp_flutter', 'llamadart_litert_lm_flutter')
CORE_JOBS = (
    'analyze', 'docs-check', 'docs-versions', 'validation-harness',
    'validation-integration', 'companion-packages', 'test-linux-coverage',
    'test-web', 'web-chat-contract', 'test-other-os',
    'native-prompt-reuse-parity', 'artifact-contract',
)
DESKTOPS = ('ubuntu-24.04', 'windows-2022', 'macos-15')
APPS = ('android', 'web', 'ios-inputs')


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


def select(paths, force_full=False):
    jobs, companions, desktops, apps = set(), set(), set(), set()
    reasons = []

    def full(reason):
        jobs.update(CORE_JOBS)
        # Synthetic upload/download is only necessary for workflow changes.
        jobs.discard('artifact-contract')
        companions.update(COMPANIONS)
        desktops.update(DESKTOPS)
        apps.update(APPS)
        reasons.append(reason)

    if force_full or not paths:
        full('manual, missing or unavailable change inventory')
        jobs.add('artifact-contract')
    for path in paths:
        if path.startswith(('.github/workflows/', '.github/actions/', 'tool/ci/', 'test/ci/')):
            full('workflow or selector change')
            jobs.add('artifact-contract')
        elif (path in ('README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'AGENTS.md', 'LICENSE')
              or path.startswith(('doc/', 'website/', 'tool/docs/'))
              or (path.startswith(('packages/', 'example/')) and path.endswith('.md'))):
            jobs.update(('docs-check', 'docs-versions'))
        elif any(path.startswith('packages/' + name + '/') for name in COMPANIONS):
            name = path.split('/')[1]
            companions.add(name)
            # Root hooks/loaders and Flutter consumers depend on companions.
            jobs.update(('analyze', 'companion-packages', 'test-linux-coverage',
                         'test-other-os', 'web-chat-contract'))
            apps.update(APPS)
        elif path.startswith('packages/llamadart_validation/'):
            jobs.update(('analyze', 'validation-harness', 'validation-integration'))
            if not path.startswith(('packages/llamadart_validation/test/',
                                    'packages/llamadart_validation/assets/',
                                    'packages/llamadart_validation/schemas/')):
                desktops.update(DESKTOPS)
                apps.update(APPS)
        elif path.startswith(('tool/testing/validation/', 'tool/testing/validation.dart')):
            jobs.update(('analyze', 'validation-harness', 'validation-integration'))
            # Build/orchestration helpers are shared between all bundle targets.
            desktops.update(DESKTOPS)
            apps.update(APPS)
        elif path.startswith('example/chat_app/android/'):
            jobs.add('analyze')
            apps.add('android')
        elif path.startswith('example/chat_app/ios/'):
            jobs.add('analyze')
            apps.add('ios-inputs')
        elif path.startswith('example/chat_app/web/'):
            jobs.update(('analyze', 'web-chat-contract'))
            apps.add('web')
        elif path.startswith('example/chat_app/test/'):
            jobs.update(('analyze', 'web-chat-contract'))
        elif path.startswith('example/chat_app/'):
            jobs.update(('analyze', 'web-chat-contract', 'validation-harness'))
            apps.update(APPS)
        elif path.startswith('test/'):
            # Preserve all root test inventories, including platform-sensitive tests.
            jobs.update(('analyze', 'test-linux-coverage', 'test-web', 'test-other-os'))
        else:
            full('shared/runtime or unclassified path: ' + path)
    if 'analyze' in jobs:
        jobs.discard('docs-versions')  # Already included in root static validation.
    if 'test-linux-coverage' in jobs and 'web-chat-contract' in jobs:
        # Both root provider tests and all Flutter consumer tests are covered.
        jobs.discard('validation-integration')
    return {
        'schema_version': 1,
        'jobs': {job: job in jobs for job in CORE_JOBS},
        'companions': ['packages/' + name for name in COMPANIONS if name in companions],
        'desktops': [name for name in DESKTOPS if name in desktops],
        'apps': [name for name in APPS if name in apps],
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


def aggregate(plan, needs, bundle=False):
    """A selected job must succeed; only intentionally unselected jobs may skip."""
    validate_plan(plan)
    expected = ({'desktop': bool(plan['desktops']), 'app': bool(plan['apps'])}
                if bundle else plan['jobs'])
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('select', 'aggregate'))
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
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        plan = select(event_paths(os.environ['GITHUB_EVENT_NAME'], event))
    except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError) as error:
        plan = select([], force_full=True)
        plan['reasons'] = ['Full fallback: ' + type(error).__name__]
    encoded = json.dumps(plan, separators=(',', ':'))
    print(json.dumps(plan, indent=2))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write('plan=' + encoded + '\n')
        for name, selected in plan['jobs'].items():
            out.write(f'{name}={str(selected).lower()}\n')
        for name in ('companions', 'desktops', 'apps'):
            out.write(name + '=' + json.dumps(plan[name], separators=(',', ':')) + '\n')
            out.write(name + '-enabled=' + str(bool(plan[name])).lower() + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
