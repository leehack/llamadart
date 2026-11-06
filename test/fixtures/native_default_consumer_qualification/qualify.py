#!/usr/bin/env python3
"""Reviewed default-native consumer/AOT qualifier. Heavy execution is opt-in.

The expected tag is an assertion on committed source, never a hook selector.
A native2 success is explicitly pipeline-only. No publication/deployment occurs.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True

import verify as v
from owned_process import WindowsJob

FIXTURE = Path(__file__).resolve().parent


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def command(argv, *, cwd, env, timeout, log):
    """Own, terminate and reap the whole child group before returning/raising."""
    argv = [str(value) for value in argv]
    started = time.monotonic()
    process = None
    job = WindowsJob() if os.name == 'nt' else None
    receipt = {'argv': argv, 'cwd': str(cwd), 'timeoutSeconds': timeout,
               'cleanupComplete': False}
    try:
        with Path(str(log) + '.stdout.log').open('wb') as stdout, Path(str(log) + '.stderr.log').open('wb') as stderr:
            options = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP | 0x4} if os.name == 'nt' else {'start_new_session': True}
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr, **options)
            receipt['pid'] = process.pid
            try:
                if job is not None:
                    job.attach_and_resume(process)
                receipt['exitCode'] = process.wait(timeout=timeout)
            finally:
                # Reap descendants even if the leader exited but left children.
                cleanup_error = None
                if job is not None:
                    try:
                        job.close()
                    except OSError as error:
                        cleanup_error = error
                    finally:
                        job = None
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=30)
                receipt['cleanupComplete'] = cleanup_error is None
                if cleanup_error is not None:
                    raise cleanup_error
        v.require(receipt['exitCode'] == 0, 'child failed: ' + Path(argv[0]).name)
        return Path(str(log) + '.stdout.log').read_text(encoding='utf-8')
    finally:
        if job is not None:
            job.close()
        receipt['elapsedSeconds'] = time.monotonic() - started
        write_json(str(log) + '.command.json', receipt)


def git(root, *args):
    # No fetch, credentials or remote command; exact source is local.
    environment = dict(os.environ, GIT_NO_LAZY_FETCH='1', GIT_OPTIONAL_LOCKS='0')
    return subprocess.check_output(['git', '-C', str(root), *args], env=environment)


def pubspec(source):
    # JSON strings are valid YAML scalars, including Windows backslashes.
    return ('name: default_native_consumer\npublish_to: none\nversion: 0.0.0\n'
        'environment:\n  sdk: ">=3.13.1 <4.0.0"\ndependencies:\n'
        '  llamadart:\n    path: ' + json.dumps(str(source)) + '\n'
        '  crypto: ^3.0.0\n  ffi: ^2.1.0\n'
        'hooks:\n  user_defines:\n    llamadart:\n'
        '      llamadart_native_runtimes: [llama_cpp]\n')


def clean_environment(parent, temporary, pub_cache, *, sdk=False):
    v.reject_overrides(parent)
    keep = ('SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'HOME', 'USERPROFILE',
            'LOCALAPPDATA', 'APPDATA', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR')
    result = {key: parent[key] for key in keep if key in parent}
    if os.name == 'nt':
        system = Path(parent['SystemRoot'])
        result['PATH'] = os.pathsep.join((str(system / 'System32'), str(system)))
    else:
        result['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    # Build tools may need the pinned SDK on PATH; AOT never receives it.
    if sdk:
        result['PATH'] = str(sdk) + os.pathsep + result['PATH']
    for key in ('TMPDIR', 'TMP', 'TEMP'):
        result[key] = str(temporary)
    result['PUB_CACHE'] = str(pub_cache)
    result['CI'] = 'true'
    return result


def sdk_paths(environment):
    flutter_root = environment.get('FLUTTER_ROOT')
    if flutter_root:
        flutter_root = Path(flutter_root).resolve()
    else:
        flutter = shutil.which('flutter', path=environment.get('PATH'))
        v.require(flutter is not None, 'pinned Flutter SDK missing')
        flutter_root = Path(flutter).resolve().parent.parent
    dart = flutter_root / 'bin' / 'cache' / 'dart-sdk' / 'bin' / ('dart.exe' if os.name == 'nt' else 'dart')
    flutter = flutter_root / 'bin' / ('flutter.bat' if os.name == 'nt' else 'flutter')
    v.require(dart.is_file() and flutter.is_file(), 'pinned Flutter/Dart SDK incomplete')
    return flutter_root, flutter, dart


def plan(args):
    root = Path(args.core_root).absolute()
    output = Path(args.output).absolute()
    v.require(re.fullmatch('[a-f0-9]{40}', args.expected_core_sha), 'expected-core-sha must be full lowercase SHA')
    v.no_links(root)
    v.no_links(output)
    v.require(not output.exists(), 'output must be a fresh nonexistent directory')
    v.require(not v.inside(output, root) and not v.inside(root, output), 'output and core source roots must be separate')
    v.reject_overrides(os.environ)
    pin_source = (root / 'lib/src/hook/native_release_pins.dart').read_text(encoding='utf-8')
    # Dry-run deliberately accepts either target without executing host/SDK discovery.
    checksums = {target: v.pins(pin_source, args.expected_native_tag, target)
                 for target in ('macos-arm64', 'windows-x64')}
    v.require((root / '.flutter-version').read_text().strip() == '3.47.1', 'unreviewed Flutter SDK pin')
    return root, output, checksums


def qualify(args):
    root, output, checksums = plan(args)
    if args.dry_run:
        print(json.dumps({'dryRun': True, 'coreRoot': str(root), 'expectedCoreSha': args.expected_core_sha,
            'expectedNativeTagVerificationOnly': args.expected_native_tag,
            'output': str(output), 'operations': ['verify clean exact H and SDK pins',
                'export tracked H; ordinary hooks.runtimes=[llama_cpp]', 'public JIT CPU0 baseline/active/reload/reuse/dispose',
                'dart build cli -o build/default -t consumer.dart', 'copy build/default/bundle wholly outside source/app roots',
                'execute copied bundle/bin/consumer from empty CWD/system PATH',
                'bind actual providers and symbol owners to committed public hook archive checksums',
                'seal complete before/after source and bundle inventories'],
            **v.scope(args.expected_native_tag, False)}, indent=2))
        return
    system = platform.system()
    target = {('Darwin', 'arm64'): 'macos-arm64', ('Windows', 'AMD64'): 'windows-x64',
              ('Windows', 'x86_64'): 'windows-x64'}.get((system, platform.machine()))
    v.require(target is not None, 'supported qualification hosts: macOS arm64 or Windows x64')
    v.require(git(root, 'rev-parse', 'HEAD').decode().strip() == args.expected_core_sha, 'reviewed source SHA mismatch')
    v.require(not git(root, 'status', '--porcelain=v1', '--untracked-files=normal').strip(), 'reviewed source is dirty')
    v.require(FIXTURE == root / 'test/fixtures/native_default_consumer_qualification',
              'driver must run from the reviewed core checkout')
    files = [name.decode('utf-8') for name in git(root, 'ls-files', '-z').split(b'\0') if name]
    v.require(all(not name.startswith('/') and '..' not in Path(name).parts for name in files), 'unsafe source inventory')
    source_before = v.inventory(root, files)
    v.require(all(row['kind'] == 'file' for row in source_before.values()), 'source must contain only regular tracked files')
    model = Path(args.model).absolute()
    v.no_links(model)
    v.require(model.is_file() and model.stat().st_size == v.MODEL_BYTES
              and v.sha256(model) == v.MODEL_SHA256, 'fixed Qwen model checksum/size mismatch')
    flutter_root, flutter, dart = sdk_paths(os.environ)
    output.mkdir()
    logs = output / 'logs'; logs.mkdir()
    temporary = output / 'temp'; temporary.mkdir()
    pub_cache = output / 'pub-cache'; pub_cache.mkdir()
    environment = clean_environment(os.environ, temporary, pub_cache, sdk=dart.parent)
    terminal = {'schemaVersion': 1, 'completed': False, 'expectedCoreSha': args.expected_core_sha,
                'target': target, 'model': {'bytes': v.MODEL_BYTES, 'sha256': v.MODEL_SHA256},
                **v.scope(args.expected_native_tag, False)}
    write_json(output / 'source-before.json', source_before)
    try:
        # Invoke the pinned Dart directly. Flutter version is read from its
        # machine-readable pinned SDK version file, avoiding shell/.bat dispatch.
        flutter_version = json.loads((flutter_root / 'bin/cache/flutter.version.json').read_text(encoding='utf-8'))
        v.require(flutter_version.get('frameworkVersion') == '3.47.1'
                  and flutter_version.get('dartSdkVersion', '').split()[0] == '3.13.1', 'Flutter/Dart version pin mismatch')
        dart_version = command([dart, '--version'], cwd=output, env=environment, timeout=60, log=logs / 'dart-version')
        # Dart writes version to stdout on the pinned SDK; retain stderr too.
        version_text = dart_version + (logs / 'dart-version.stderr.log').read_text()
        v.require('Dart SDK version: 3.13.1 ' in version_text, 'Dart executable version mismatch')
        terminal['sdk'] = {'flutterRoot': str(flutter_root), 'dart': str(dart), 'version': flutter_version}
        source = output / 'source'; source.mkdir()
        for name in files:
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / name, destination)
        v.unchanged(source_before, v.inventory(source, files), 'exported reviewed source')
        app = output / 'app'; app.mkdir()
        (app / 'pubspec.yaml').write_text(pubspec(source), encoding='utf-8')
        for name in ('consumer.dart', 'providers.dart', 'passive_modules.dart'):
            # Read the reviewed exported fixture, not an unrelated checkout.
            shutil.copy2(source / 'test/fixtures/native_default_consumer_qualification' / name, app / name)
        command([dart, 'pub', 'get'], cwd=app, env=environment, timeout=600, log=logs / 'pub-get')
        command([dart, 'analyze', 'consumer.dart', 'providers.dart', 'passive_modules.dart'],
                cwd=app, env=environment, timeout=120, log=logs / 'analyze')
        jit_stdout = command([dart, 'run', 'consumer.dart', model], cwd=app, env=environment,
                             timeout=900, log=logs / 'jit')
        jit_result = v.public_result(jit_stdout)
        jit_modules, jit_registry = v.native_modules(jit_stdout, target)
        v.query_result(jit_result, jit_modules, args.expected_native_tag)
        command([dart, 'build', 'cli', '-o', 'build/default', '-t', 'consumer.dart'],
                cwd=app, env=environment, timeout=600, log=logs / 'build')
        bundle = app / 'build/default/bundle'
        distributed = output / 'distributed'
        bundle_before = v.copy_bundle(bundle, distributed, (root, source, app))
        write_json(output / 'bundle-before.json', bundle_before)
        empty_cwd = output / 'empty-cwd'; empty_cwd.mkdir()
        cwd_before = v.inventory(empty_cwd)
        executable = distributed / 'bin' / ('consumer.exe' if system == 'Windows' else 'consumer')
        v.require(executable.is_file(), 'SDK CLI executable missing in complete bundle')
        aot_env = clean_environment(os.environ, temporary, pub_cache)
        aot_stdout = command([executable, model], cwd=empty_cwd, env=aot_env,
                             timeout=900, log=logs / 'aot')
        v.unchanged(cwd_before, v.inventory(empty_cwd), 'empty execution CWD')
        aot_result = v.public_result(aot_stdout)
        aot_modules, aot_registry = v.native_modules(aot_stdout, target)
        v.query_result(aot_result, aot_modules, args.expected_native_tag)
        cache = source / '.dart_tool/llamadart/native_bundles_v2'
        acquired, members = v.archive_members(cache, args.expected_native_tag, target, checksums[target])
        jit_bound = v.bind_providers(jit_modules, members, 'windows' if system == 'Windows' else 'macos', output)
        aot_bound = v.bind_providers(aot_modules, members, 'windows' if system == 'Windows' else 'macos', distributed)
        v.require(jit_result['baselineOutput'] == aot_result['baselineOutput'], 'JIT/AOT full public output mismatch')
        terminal.update({'publicAcquisition': acquired, 'jit': {'result': jit_result, 'registry': jit_registry, 'providers': jit_bound},
            'aot': {'result': aot_result, 'registry': aot_registry, 'providers': aot_bound},
            'aotEnvironment': {key: aot_env[key] for key in ('PATH', 'TMPDIR', 'TMP', 'TEMP', 'PUB_CACHE')}, 'emptyCwdInventory': cwd_before})
        v.unchanged(bundle_before, v.inventory(bundle), 'SDK source bundle')
        v.unchanged(bundle_before, v.inventory(distributed), 'distributed bundle')
        write_json(output / 'bundle-after.json', v.inventory(distributed))
        v.require(model.stat().st_size == v.MODEL_BYTES and v.sha256(model) == v.MODEL_SHA256,
                  'fixed model changed during qualification')
        v.unchanged(source_before, v.inventory(source, files), 'exported tracked source')
        v.unchanged(source_before, v.inventory(root, files), 'reviewed tracked source')
        v.require(not git(root, 'status', '--porcelain=v1', '--untracked-files=normal').strip(), 'reviewed source became dirty')
        write_json(output / 'source-after.json', v.inventory(root, files))
        terminal.update({'completed': True, **v.scope(args.expected_native_tag, True)})
    except BaseException as error:
        terminal['failureType'] = type(error).__name__
        terminal['failure'] = str(error)
        raise
    finally:
        for label, snapshot_root in (('source', root), ('exported-source', output / 'source')):
            if snapshot_root.exists():
                try:
                    after = v.inventory(snapshot_root, files)
                    write_json(output / (label + '-after.json'), after)
                    v.unchanged(source_before, after, label)
                except (v.Refusal, OSError) as error:
                    terminal.update({'completed': False, **v.scope(args.expected_native_tag, False)})
                    terminal.setdefault('inventoryFailures', []).append({'scope': label, 'error': str(error)})
        if 'bundle_before' in locals():
            for label, bundle_root in (('sdk-bundle', bundle), ('distributed-bundle', distributed)):
                try:
                    after = v.inventory(bundle_root)
                    write_json(output / (label + '-after.json'), after)
                    v.unchanged(bundle_before, after, label)
                except (v.Refusal, OSError) as error:
                    terminal.update({'completed': False, **v.scope(args.expected_native_tag, False)})
                    terminal.setdefault('inventoryFailures', []).append({'scope': label, 'error': str(error)})
        # The manifest seals retained regular evidence, with its own file
        # excluded. A partial campaign is always retained as completed=false.
        terminal['evidenceInventory'] = v.inventory(logs)
        write_json(output / 'terminal.json', terminal)
        write_json(output / 'manifest.json', {'schemaVersion': 1,
            'files': v.inventory(output), 'terminalSha256': v.sha256(output / 'terminal.json')})
        v.verify_seal(output)
        if terminal.get('inventoryFailures') and sys.exc_info()[0] is None:
            raise v.Refusal('final source/bundle inventory changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-root', required=True)
    parser.add_argument('--expected-core-sha', required=True)
    parser.add_argument('--expected-native-tag', required=True, choices=v.TAGS,
                        help='verification of committed pin only; never a runtime selector')
    parser.add_argument('--model', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        qualify(args)
    except (v.Refusal, OSError, subprocess.SubprocessError) as error:
        print(f'qualification refused: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
