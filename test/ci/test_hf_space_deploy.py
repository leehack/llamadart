"""Behavioral checks for Hugging Face Space deploy retries and diagnostics."""
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import logging
import ntpath
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Event, Thread
import traceback
from types import SimpleNamespace
import unittest
from unittest import mock
import warnings

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import hf_space_deploy as hf


class HttpError(Exception):
    def __init__(self, status, headers=None):
        super().__init__(f'HTTP {status}')
        self.response = mock.Mock(status_code=status, headers=headers or {})


class SensitiveHttpError(HttpError):
    def __init__(self, status, retry_after, chain):
        super().__init__(status, {'Retry-After': retry_after})
        self.args = (self.signed_url('args'),)
        self.response.text = self.signed_url('response')
        setattr(self, f'__{chain}__', RuntimeError(self.signed_url(chain)))

    def __repr__(self):
        return self.signed_url('repr')

    @staticmethod
    def signed_url(field):
        return f'https://example.invalid/{field}?X-Amz-Signature=stand-in'


TERMINAL_CASES = (
    (403, '0', 0),
    (429, str(hf.MAX_TOTAL_WAIT + 1), 0),
    (429, '0', hf.MAX_ATTEMPTS - 1),
)


def missing_space_api():
    api = mock.Mock()
    api.repo_info.side_effect = HttpError(404)
    return api


def run_deploy(api, *, folder='build', log=lambda *a, **k: None, **options):
    sleeps = []
    hf.deploy(api, 'org/space', folder, 'msg', ['*'], True,
              sleep=sleeps.append, jitter=lambda: 1.0, log=log, **options)
    return sleeps


class RetryTest(unittest.TestCase):
    def test_recovers_from_429_on_create_and_upload(self):
        api = missing_space_api()
        api.create_repo.side_effect = [HttpError(429), HttpError(429), None]
        api.upload_folder.side_effect = [HttpError(429), None]
        sleeps = run_deploy(api)
        self.assertEqual(api.create_repo.call_count, 3)
        self.assertEqual(api.upload_folder.call_count, 2)
        self.assertEqual(sleeps, [5.0, 10.0, 5.0])

    def test_retry_after_overrides_backoff(self):
        api = missing_space_api()
        api.create_repo.side_effect = [HttpError(429, {'Retry-After': '7'}), None]
        self.assertEqual(run_deploy(api), [7.0])

    def test_exhausted_attempts_fail_with_the_429(self):
        api = missing_space_api()
        api.create_repo.side_effect = HttpError(429)
        with self.assertRaises(hf.DeployError):
            run_deploy(api)
        self.assertEqual(api.create_repo.call_count, hf.MAX_ATTEMPTS)
        api.upload_folder.assert_not_called()

    def test_retry_after_beyond_budget_fails_without_sleeping(self):
        api = missing_space_api()
        api.create_repo.side_effect = HttpError(429, {'Retry-After': str(hf.MAX_TOTAL_WAIT + 1)})
        sleeps = []
        with self.assertRaises(hf.DeployError):
            hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                      log=lambda *a, **k: None)
        self.assertEqual(sleeps, [])

    def test_non_retryable_errors_fail_immediately(self):
        for status in (400, 401, 403, 404, 409, 422, 500, 503, None):
            for step in ('create_repo', 'upload_folder'):
                api = missing_space_api()
                getattr(api, step).side_effect = (
                    HttpError(status) if status else ValueError('bad'))
                sleeps = []
                with self.assertRaises(hf.DeployError) as raised:
                    hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                              log=lambda *a, **k: None)
                diagnostic = (f'HTTP {status}, HttpError' if status
                              else 'HTTP status unavailable, ValueError')
                self.assertEqual(str(raised.exception), f'{step}: failed ({diagnostic})')
                self.assertEqual(getattr(api, step).call_count, 1, (status, step))
                self.assertEqual(sleeps, [], (status, step))

    def test_wrapped_upload_failure_reports_the_chained_status(self):
        for status in (403, 429):
            with self.subTest(status=status):
                api = missing_space_api()
                wrapped = RuntimeError(SensitiveHttpError.signed_url('wrapper'))
                wrapped.__cause__ = SensitiveHttpError(status, '0', 'cause')
                api.upload_folder.side_effect = wrapped
                sleeps = []
                with self.assertRaises(hf.DeployError) as raised:
                    hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                              log=lambda *a, **k: None)
                self.assertEqual(str(raised.exception),
                                 f'upload_folder: failed (HTTP {status}, RuntimeError)')
                self.assertEqual(api.upload_folder.call_count, 1)
                self.assertEqual(sleeps, [])

    def test_cyclic_exception_chain_reports_unavailable_status(self):
        api = missing_space_api()
        first, second = RuntimeError('a'), ValueError('b')
        first.__context__, second.__context__ = second, first
        api.upload_folder.side_effect = first
        with self.assertRaises(hf.DeployError) as raised:
            run_deploy(api)
        self.assertEqual(str(raised.exception),
                         'upload_folder: failed (HTTP status unavailable, RuntimeError)')

    def test_logs_never_include_the_token(self):
        api = missing_space_api()
        api.create_repo.side_effect = [HttpError(429), None]
        lines = []
        hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=lambda s: None,
                  log=lambda line, **k: lines.append(line))
        self.assertTrue(lines)
        self.assertNotIn('hf_', ''.join(lines))


class PolicyTest(unittest.TestCase):
    def test_policy_constants(self):
        self.assertEqual(hf.MAX_ATTEMPTS, 5)
        self.assertEqual(hf.MAX_TOTAL_WAIT, 240.0)

    def test_backoff_doubles_then_caps_with_jitter_bounds(self):
        for jitter, scale in ((0.0, 0.5), (1.0, 1.0)):
            api = missing_space_api()
            api.create_repo.side_effect = [HttpError(429)] * 4 + [None]
            sleeps = []
            hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                      jitter=lambda: jitter, log=lambda *a, **k: None)
            self.assertEqual(sleeps, [5 * scale, 10 * scale, 20 * scale, 30 * scale])

    def test_exactly_max_attempts_when_every_try_is_429(self):
        api = missing_space_api()
        api.upload_folder.side_effect = HttpError(429)
        with self.assertRaises(hf.DeployError):
            run_deploy(api)
        self.assertEqual(api.upload_folder.call_count, 5)

    def test_wait_budget_is_shared_across_create_and_upload(self):
        api = missing_space_api()
        api.create_repo.side_effect = [HttpError(429, {'Retry-After': '100'}), None]
        api.upload_folder.side_effect = [HttpError(429, {'Retry-After': '100'}),
                                         HttpError(429, {'Retry-After': '100'}), None]
        sleeps = []
        with self.assertRaises(hf.DeployError):
            hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                      log=lambda *a, **k: None)
        self.assertEqual(sleeps, [100.0, 100.0])
        self.assertEqual(api.upload_folder.call_count, 2)

    def test_only_numeric_non_negative_retry_after_is_honored(self):
        for value, expected in (('-5', 5.0), ('Wed, 21 Oct 2026 07:28:00 GMT', 5.0),
                                ('nan', 5.0), ('', 5.0), ('0', 0.0), ('3.5', 3.5)):
            api = missing_space_api()
            api.create_repo.side_effect = [HttpError(429, {'Retry-After': value}), None]
            self.assertEqual(run_deploy(api), [expected], value)


class DeployCallTest(unittest.TestCase):
    def test_public_flag_and_arguments_reach_the_api(self):
        api = missing_space_api()
        run_deploy(api)
        api.create_repo.assert_called_once_with(
            repo_id='org/space', repo_type='space', space_sdk='static', exist_ok=True,
            private=False)
        api.upload_folder.assert_called_once_with(
            repo_id='org/space', repo_type='space', folder_path='build', revision='main',
            delete_patterns=['*'], commit_message='msg')

    def test_private_is_omitted_without_public(self):
        api = missing_space_api()
        hf.deploy(api, 'r', 'f', 'm', ['*'], False)
        self.assertNotIn('private', api.create_repo.call_args.kwargs)


class ProvisioningTest(unittest.TestCase):
    def test_existing_space_uploads_when_creation_would_be_rate_limited(self):
        api = mock.Mock()
        api.create_repo.side_effect = HttpError(429, {'Retry-After': '86400'})
        self.assertEqual(run_deploy(api), [])
        api.repo_info.assert_called_once_with(repo_id='org/space', repo_type='space')
        api.create_repo.assert_not_called()
        api.upload_folder.assert_called_once_with(
            repo_id='org/space', repo_type='space', folder_path='build', revision='main',
            delete_patterns=['*'], commit_message='msg')

    def test_missing_space_is_created_before_upload(self):
        api = missing_space_api()
        self.assertEqual(run_deploy(api), [])
        self.assertEqual(api.mock_calls, [
            mock.call.repo_info(repo_id='org/space', repo_type='space'),
            mock.call.create_repo(repo_id='org/space', repo_type='space', space_sdk='static',
                                  exist_ok=True, private=False),
            mock.call.upload_folder(repo_id='org/space', repo_type='space', folder_path='build',
                                    revision='main', delete_patterns=['*'], commit_message='msg'),
        ])

    def test_probe_auth_and_other_errors_fail_without_writes(self):
        for error in [HttpError(status) for status in (400, 401, 403, 409, 422, 500, 503)] + [
                OSError('network unavailable'), ValueError('invalid response')]:
            with self.subTest(error=error):
                api = mock.Mock()
                api.repo_info.side_effect = error
                with self.assertRaises(hf.DeployError):
                    run_deploy(api)
                api.repo_info.assert_called_once()
                api.create_repo.assert_not_called()
                api.upload_folder.assert_not_called()

    def test_probe_429_retries_before_existing_space_upload(self):
        api = mock.Mock()
        api.repo_info.side_effect = [HttpError(429, {'Retry-After': '7'}), mock.Mock()]
        self.assertEqual(run_deploy(api), [7.0])
        self.assertEqual(api.repo_info.call_count, 2)
        api.create_repo.assert_not_called()
        api.upload_folder.assert_called_once()

    def test_probe_exhaustion_fails_without_writes(self):
        for headers, attempts in (({}, hf.MAX_ATTEMPTS), ({'Retry-After': '86400'}, 1)):
            with self.subTest(headers=headers):
                api = mock.Mock()
                api.repo_info.side_effect = HttpError(429, headers)
                with self.assertRaises(hf.DeployError):
                    run_deploy(api)
                self.assertEqual(api.repo_info.call_count, attempts)
                api.create_repo.assert_not_called()
                api.upload_folder.assert_not_called()

    def test_probe_create_and_upload_share_one_wait_budget(self):
        api = missing_space_api()
        api.repo_info.side_effect = [HttpError(429, {'Retry-After': '100'}), HttpError(404)]
        api.create_repo.side_effect = [HttpError(429, {'Retry-After': '100'}), None]
        api.upload_folder.side_effect = HttpError(429, {'Retry-After': '41'})
        sleeps = []
        with self.assertRaises(hf.DeployError):
            hf.deploy(api, 'org/space', 'build', 'msg', ['*'], True,
                      sleep=sleeps.append, log=lambda *a, **k: None)
        self.assertEqual(sleeps, [100.0, 100.0])
        self.assertEqual(api.repo_info.call_count, 2)
        self.assertEqual(api.create_repo.call_count, 2)
        api.upload_folder.assert_called_once()

    def test_missing_space_creation_quota_still_blocks_upload(self):
        api = missing_space_api()
        api.create_repo.side_effect = HttpError(429, {'Retry-After': '86400'})
        with self.assertRaises(hf.DeployError):
            run_deploy(api)
        api.create_repo.assert_called_once()
        api.upload_folder.assert_not_called()

    def test_existing_space_upload_failure_skips_creation(self):
        api = mock.Mock()
        api.upload_folder.side_effect = HttpError(403)
        with self.assertRaises(hf.DeployError):
            run_deploy(api)
        api.create_repo.assert_not_called()
        api.upload_folder.assert_called_once()

    def test_probe_retry_logs_exclude_exception_secrets(self):
        api = mock.Mock()
        error = HttpError(429)
        error.args = ('hf_test_secret https://example.invalid/file?X-Amz-Signature=secret',)
        api.repo_info.side_effect = [error, mock.Mock()]
        lines = []
        hf.deploy(api, 'org/space', 'build', 'msg', ['*'], True, sleep=lambda s: None,
                  jitter=lambda: 1.0, log=lambda line, **k: lines.append(line))
        self.assertEqual(lines, ['repo_info: HTTP 429 on attempt 1/5; retrying in 5s'])
        api.create_repo.assert_not_called()


class SquashTest(unittest.TestCase):
    def test_squash_history_runs_after_upload_with_exact_arguments(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                api = mock.Mock()
                run_deploy(api, squash_history=enabled)
                calls = [
                    mock.call.repo_info(repo_id='org/space', repo_type='space'),
                    mock.call.upload_folder(
                        repo_id='org/space', repo_type='space', folder_path='build',
                        revision='main', delete_patterns=['*'], commit_message='msg'),
                ]
                if enabled:
                    calls.append(mock.call.super_squash_history(
                        repo_id='org/space', repo_type='space', branch='main',
                        commit_message='msg'))
                self.assertEqual(api.mock_calls, calls)

    def test_squash_history_retries_429_within_shared_budget(self):
        for final_delay in (100, 101):
            with self.subTest(final_delay=final_delay):
                api = missing_space_api()
                api.repo_info.side_effect = [HttpError(429, {'Retry-After': '60'}), HttpError(404)]
                api.create_repo.side_effect = [HttpError(429, {'Retry-After': '40'}), None]
                api.upload_folder.side_effect = [HttpError(429, {'Retry-After': '40'}), None]
                error = HttpError(429, {'Retry-After': str(final_delay)})
                api.super_squash_history.side_effect = [error, None]
                sleeps = []

                def deploy():
                    hf.deploy(api, 'org/space', 'build', 'msg', ['*'], True,
                              squash_history=True, sleep=sleeps.append, log=mock.Mock())

                if final_delay == 100:
                    deploy()
                    self.assertEqual(sleeps, [60.0, 40.0, 40.0, 100.0])
                    self.assertEqual(api.super_squash_history.call_count, 2)
                else:
                    with self.assertRaises(hf.DeployError):
                        deploy()
                    self.assertEqual(sleeps, [60.0, 40.0, 40.0])
                    api.super_squash_history.assert_called_once()
                self.assertEqual(api.upload_folder.call_count, 2)

    def test_squash_history_non_429_errors_fail_immediately(self):
        for status in (400, 401, 403, 500):
            with self.subTest(status=status):
                api = mock.Mock()
                error = HttpError(status)
                api.super_squash_history.side_effect = error
                sleep = mock.Mock()
                with self.assertRaises(hf.DeployError):
                    hf.deploy(api, 'org/space', 'build', 'msg', ['*'], True,
                              squash_history=True, sleep=sleep)
                api.super_squash_history.assert_called_once()
                sleep.assert_not_called()

    def test_squash_history_not_called_when_upload_fails(self):
        for status in (403, 500):
            with self.subTest(status=status):
                api = mock.Mock()
                api.upload_folder.side_effect = HttpError(status)
                with self.assertRaises(hf.DeployError):
                    run_deploy(api, squash_history=True)
                api.super_squash_history.assert_not_called()

    def test_squash_history_retry_logs_exclude_secrets(self):
        api = mock.Mock()
        error = HttpError(429)
        error.args = ('hf_test_secret https://example.invalid/artifact?X-Amz-Signature=secret',)
        api.super_squash_history.side_effect = [error, None]
        log = mock.Mock()
        self.assertEqual(run_deploy(api, squash_history=True, log=log), [5.0])
        log.assert_called_once_with(
            'super_squash_history: HTTP 429 on attempt 1/5; retrying in 5s', file=sys.stderr)


class PreflightTest(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory(prefix='w2155-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.folder = self.root / 'site'
        self.folder.mkdir()
        self.api = mock.Mock()

    def test_max_folder_bytes_blocks_oversized_folder_before_api_calls(self):
        (self.folder / 'index.html').write_bytes(b'demo')
        nested = self.folder / 'assets'
        nested.mkdir()
        (nested / 'asset').write_bytes(b'asset')
        with self.assertRaisesRegex(ValueError, 'Folder size 9 bytes exceeds.*limit 8 bytes'):
            self.deploy(max_folder_bytes=8)
        self.assertEqual(self.api.mock_calls, [])

        for limit in (9, 10):
            with self.subTest(limit=limit):
                self.api.reset_mock()
                self.deploy(max_folder_bytes=limit)
                self.api.upload_folder.assert_called_once()
                self.api.super_squash_history.assert_called_once()

    def test_max_folder_bytes_rejects_nonpositive_limits_and_invalid_folders(self):
        file_path = self.root / 'file'
        file_path.touch()
        for folder, limit in ((self.folder, 0), (self.folder, -1),
                              (file_path, 1), (self.root / 'missing', 1)):
            with self.subTest(folder=folder.name, limit=limit):
                with self.assertRaises(ValueError):
                    run_deploy(self.api, folder=folder, max_folder_bytes=limit)
                self.assertEqual(self.api.mock_calls, [])

    def test_max_folder_bytes_rejects_file_directory_and_broken_symlinks(self):
        large_file = self.root / 'external-file'
        with large_file.open('wb') as stream:
            stream.truncate(250_000_001)
        internal_directory = self.folder / 'assets'
        internal_directory.mkdir()
        for target, link_name, is_directory in (
                (large_file, 'large-link', False),
                (internal_directory, 'directory-link', True),
                (self.root / 'missing-target', 'broken-link', False)):
            with self.subTest(link=link_name):
                link = self.folder / link_name
                self.create_symlink(link, target, is_directory=is_directory)
                try:
                    with self.assertRaisesRegex(ValueError, link_name) as raised:
                        self.deploy(max_folder_bytes=250_000_000)
                    self.assertNotIn(str(target), str(raised.exception))
                    self.assertEqual(self.api.mock_calls, [])
                finally:
                    link.unlink()

    def test_max_folder_bytes_rejects_symlinked_root_spellings(self):
        target_parent = self.root / 'target-parent'
        target = target_parent / 'target'
        target.mkdir(parents=True)
        (target / 'index.html').write_bytes(b'demo')
        (target_parent / 'other').mkdir()
        link = self.root / 'site-link'
        self.create_symlink(link, target, is_directory=True)
        (self.root / 'other').mkdir()
        for suffix in ('', '/', '//', '/.', '//.', '/..', '/../other'):
            with self.subTest(suffix=suffix):
                self.assert_preflight_rejects_root_link(str(link) + suffix)

    def test_max_folder_bytes_rejects_windows_root_spellings(self):
        link = r'C:\artifacts\site-link'

        def lstat(path):
            mode = stat.S_IFDIR
            if path.replace('/', '\\') == link:
                mode = stat.S_IFLNK
            return SimpleNamespace(st_mode=mode)

        for suffix in ('\\', '//', '\\\\.', '/.', '\\..', '/..\\other'):
            with self.subTest(suffix=suffix):
                with (mock.patch.multiple(hf.os, path=ntpath, sep='\\', altsep='/'),
                      mock.patch.object(hf.os, 'lstat', side_effect=lstat),
                      mock.patch.object(hf.os, 'walk', return_value=[])):
                    self.assert_preflight_rejects_root_link(link + suffix)

    def test_max_folder_bytes_accepts_real_directory_with_dot_suffix(self):
        (self.folder / 'index.html').write_bytes(b'demo')
        folder = str(self.folder) + '/.'
        with self.assertRaisesRegex(ValueError, 'Folder size 4 bytes exceeds.*limit 3 bytes'):
            run_deploy(self.api, folder=folder, max_folder_bytes=3)
        self.assertEqual(self.api.mock_calls, [])
        run_deploy(self.api, folder=folder, max_folder_bytes=4)
        self.assertEqual(self.api.upload_folder.call_args.kwargs['folder_path'], str(self.folder))

    def test_max_folder_bytes_measures_home_relative_folder_that_upload_uses(self):
        (self.folder / 'index.html').write_bytes(b'demo')
        with mock.patch.dict(os.environ, {'HOME': str(self.root), 'USERPROFILE': str(self.root)}):
            with self.assertRaisesRegex(ValueError, 'Folder size 4 bytes exceeds.*limit 3 bytes'):
                run_deploy(self.api, folder='~/site', max_folder_bytes=3)
            self.assertEqual(self.api.mock_calls, [])
            for folder in ('~/site', './~/site'):
                with self.subTest(folder=folder):
                    self.api.reset_mock()
                    run_deploy(self.api, folder=folder, max_folder_bytes=4)
                    self.assertEqual(
                        self.api.upload_folder.call_args.kwargs['folder_path'], str(self.folder))

    def assert_preflight_rejects_root_link(self, folder):
        api = mock.Mock()
        with self.assertRaisesRegex(ValueError, r"^Deploy folder contains a symlink at '\.'$"):
            run_deploy(api, folder=folder, max_folder_bytes=250_000_000)
        self.assertEqual(api.mock_calls, [])

    def test_max_folder_bytes_rejects_walk_errors(self):
        denied = self.folder / 'denied'

        def failed_walk(folder, *, followlinks=False, onerror=None):
            if onerror is not None:
                onerror(PermissionError(13, 'Permission denied', denied))
            yield folder, [], []

        with mock.patch.object(hf.os, 'walk', side_effect=failed_walk):
            with self.assertRaisesRegex(ValueError, 'denied'):
                self.deploy(max_folder_bytes=10)
        self.assertEqual(self.api.mock_calls, [])

    def test_max_folder_bytes_rejects_stat_errors(self):
        vanished = self.folder / 'vanished'
        vanished.touch()
        real_lstat = os.lstat

        def failed_lstat(path, *args, **kwargs):
            if Path(path) == vanished:
                raise FileNotFoundError(2, 'No such file or directory', path)
            return real_lstat(path, *args, **kwargs)

        with mock.patch.object(hf.os, 'lstat', side_effect=failed_lstat):
            with self.assertRaisesRegex(ValueError, 'vanished'):
                self.deploy(max_folder_bytes=10)
        self.assertEqual(self.api.mock_calls, [])

    def create_symlink(self, link, target, *, is_directory):
        try:
            link.symlink_to(target, target_is_directory=is_directory)
        except OSError as error:
            if getattr(error, 'winerror', None) == 1314:
                self.skipTest('Creating symlinks requires Windows developer mode or privilege')
            raise

    def deploy(self, **options):
        run_deploy(self.api, folder=self.folder, squash_history=True, **options)


class StorageWarningTest(unittest.TestCase):
    def test_used_storage_warning_logs_for_camel_and_snake_case(self):
        for info, expected_mb in (
                (SimpleNamespace(usedStorage=750_000_000), '750.0'),
                (SimpleNamespace(used_storage=951_000_000), '951.0'),
                (SimpleNamespace(used_storage=True, usedStorage=750_000_000), '750.0')):
            with self.subTest(info=info):
                api = mock.Mock()
                api.repo_info.return_value = info
                log = mock.Mock()
                run_deploy(api, squash_history=True, log=log)
                log.assert_called_once_with(
                    f'repo_info: Space usedStorage is {expected_mb} MB (limit 1000.0 MB)',
                    file=sys.stderr)
                api.upload_folder.assert_called_once()
                api.super_squash_history.assert_called_once()

    def test_below_threshold_and_invalid_storage_do_not_warn(self):
        for info in (SimpleNamespace(usedStorage=749_999_999),
                     SimpleNamespace(used_storage=True), SimpleNamespace(usedStorage=-1),
                     SimpleNamespace(usedStorage='750000000'), mock.Mock()):
            with self.subTest(info=info):
                api = mock.Mock()
                api.repo_info.return_value = info
                log = mock.Mock()
                run_deploy(api, log=log)
                log.assert_not_called()
                api.upload_folder.assert_called_once()


class DiagnosticScopeTest(unittest.TestCase):
    def test_import_leaves_host_log_record_factory_unused(self):
        factory = logging.getLogRecordFactory()

        def named_factory(name, *args, **kwargs):
            if name is None:
                raise ValueError('logger name required by host factory')
            return factory(name, *args, **kwargs)

        with mock.patch.object(logging, '_logRecordFactory', wraps=named_factory) as host:
            runpy.run_path(hf.__file__)
            host.assert_not_called()

    def test_nested_scope_and_failure_restore_streams_and_hooks(self):
        output, errors = StringIO(), StringIO()
        logger = logging.getLogger('app.scope')
        orphan = logging.Logger('orphan')
        orphan.propagate = False
        early = logging.StreamHandler(output)
        fallback = logging.StreamHandler(errors)
        logger.addHandler(early)
        self.addCleanup(logger.removeHandler, early)
        hooks = logging.getLogRecordFactory(), logging.Logger.makeRecord, warnings.showwarning
        filters = warnings.filters[:]
        with redirect_stdout(output), redirect_stderr(errors), mock.patch.object(logging, 'lastResort', fallback):
            with self.assertRaisesRegex(RuntimeError, 'outer failure'), hf._redact_hub_diagnostics():
                outer = sys.stdout, sys.stderr
                self.assertIs(early.stream, outer[0])
                self.assertIs(fallback.stream, outer[1])
                orphan.warning('last resort https://inert.invalid/AUDIT_FALLBACK')
                late = logging.StreamHandler()
                logger.addHandler(late)
                self.addCleanup(logger.removeHandler, late)
                self.assertEqual(
                    (logging.getLogRecordFactory(), logging.Logger.makeRecord, warnings.showwarning), hooks)
                logger.warning('outer first https://inert.invalid/AUDIT_OUTER_FIRST')
                with self.assertRaisesRegex(RuntimeError, 'inner failure'), hf._redact_hub_diagnostics():
                    logger.warning('inner https://inert.invalid/AUDIT_INNER')
                    raise RuntimeError('inner failure')
                self.assertEqual((sys.stdout, sys.stderr), outer)
                self.assertIs(early.stream, outer[0])
                self.assertIs(late.stream, outer[1])
                logger.warning('outer last https://inert.invalid/AUDIT_OUTER_LAST')
                raise RuntimeError('outer failure')
            self.assertEqual((sys.stdout, sys.stderr), (output, errors))
            self.assertIs(early.stream, output)
            self.assertIs(late.stream, errors)
            self.assertIs(fallback.stream, errors)
            self.assertIn('last resort', errors.getvalue())
            for stream in (output, errors):
                self.assertNotIn('AUDIT_', stream.getvalue())
                self.assertIn('outer first', stream.getvalue())
                self.assertIn('inner', stream.getvalue())
                self.assertIn('outer last', stream.getvalue())
            logger.warning('outside scope')
            self.assertIn('outside scope', output.getvalue())
        self.assertEqual((logging.getLogRecordFactory(), logging.Logger.makeRecord, warnings.showwarning), hooks)
        self.assertEqual(warnings.filters, filters)

    def test_close_flushes_partial_output_and_leaves_original_open(self):
        output = StringIO()
        handler = logging.StreamHandler(output)
        with redirect_stdout(output), hf._redact_hub_diagnostics():
            self.assertIs(handler.stream, sys.stdout)
            sys.stdout.write('partially buffered sig=AUDIT_CLOSE')
            self.assertEqual(output.getvalue(), '')
            sys.stdout.close()
            self.assertIn('partially buffered', output.getvalue())
            self.assertNotIn('AUDIT_CLOSE', output.getvalue())
        self.assertIs(handler.stream, output)
        self.assertFalse(output.closed)

    def test_late_hook_and_stream_replacements_survive_scope_exit(self):
        output, errors, replacement = StringIO(), StringIO(), StringIO()
        logger = logging.getLogger('app.replacements')
        handler = logging.StreamHandler(output)
        logger.addHandler(handler)
        self.addCleanup(logger.removeHandler, handler)
        factory = logging.getLogRecordFactory()
        make_record = logging.Logger.makeRecord
        show_warning = warnings.showwarning
        with (redirect_stdout(output), redirect_stderr(errors),
              mock.patch.object(logging, '_logRecordFactory', wraps=factory) as early_factory,
              mock.patch.object(logging.Logger, 'makeRecord', make_record),
              mock.patch.object(warnings, 'showwarning', show_warning)):
            with hf._redact_hub_diagnostics():
                self.assertIs(logging.getLogRecordFactory(), early_factory)
                self.assertIs(logging.Logger.makeRecord, make_record)
                late_factory = mock.Mock(wraps=factory)
                late_make_record = mock.Mock(wraps=make_record)
                late_show_warning = mock.Mock(wraps=show_warning)
                logging.setLogRecordFactory(late_factory)
                logging.Logger.makeRecord = late_make_record
                warnings.showwarning = late_show_warning
                sys.stdout = replacement
                handler.setStream(replacement)
            self.assertIs(logging.getLogRecordFactory(), late_factory)
            self.assertIs(logging.Logger.makeRecord, late_make_record)
            self.assertIs(warnings.showwarning, late_show_warning)
            self.assertIs(sys.stdout, replacement)
            self.assertIs(sys.stderr, errors)
            self.assertIs(handler.stream, replacement)

    def test_worker_that_emits_after_scope_exit_uses_restored_handler(self):
        output = StringIO()
        logger = logging.getLogger('app.worker')
        handler = logging.StreamHandler(output)
        logger.addHandler(handler)
        self.addCleanup(logger.removeHandler, handler)
        reached, resume = Event(), Event()
        make_record = logging.Logger.makeRecord

        def waiting_make_record(*args, **kwargs):
            reached.set()
            resume.wait(5)
            return make_record(*args, **kwargs)

        with redirect_stderr(output), mock.patch.object(logging.Logger, 'makeRecord', waiting_make_record):
            worker = Thread(target=logger.warning, args=('worker outside scope',))
            try:
                with hf._redact_hub_diagnostics():
                    worker.start()
                    self.assertTrue(reached.wait(5))
            finally:
                resume.set()
                worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(output.getvalue(), 'worker outside scope\n')


class CliTest(unittest.TestCase):
    def test_cli_redacts_sdk_and_transport_diagnostics(self):
        runner = r'''
import logging
import runpy
import sys
import traceback
from types import ModuleType
from urllib.parse import quote
import warnings
from unittest import mock

from test_hf_space_deploy import SensitiveHttpError, ROOT, hf

def signed(label):
    return f'https://example.invalid/asset?X-Amz-Signature=AUDIT_{label}'

logging.basicConfig(stream=sys.stderr, format='%(message)s')
logging.raiseExceptions = True
logger = logging.getLogger('huggingface_hub.audit')
early = logging.StreamHandler(sys.stdout)
logger.addHandler(early)

class Formatted:
    def __str__(self):
        return 'brace object {}'.format(signed('BRACE_OBJECT'))

class BadMessage:
    def __str__(self):
        raise ValueError('broken string conversion ' + signed('BAD_MESSAGE'))

def make_client(**kwargs):
    url = SensitiveHttpError.signed_url
    handler = logging.StreamHandler()
    for name in ('huggingface_hub', 'urllib3', 'requests'):
        logging.getLogger(name).addHandler(handler)
        child = logging.getLogger(f'{name}.late.child')
        try:
            raise RuntimeError(url('exception'))
        except RuntimeError:
            child.warning(f'HTTP 503 PUT {url("message")} then %s',
                          url('argument'), exc_info=True)
    logging.getLogger('urllib3.connectionpool').warning(
        'PUT %s HTTP/1.1 503', '/asset?X-Amz-Signature=relative')
    warnings.warn(f'SDK upload warning {url("warning")}')
    logging.getLogger().warning('root record %s', url('root'))
    logging.getLogger('py.warnings').addHandler(logging.StreamHandler())
    logging.captureWarnings(True)
    warnings.warn(f'captured warning {url("captured")}')
    logging.captureWarnings(False)
    extra_handler = logging.StreamHandler(sys.stdout)
    extra_handler.setFormatter(logging.Formatter('extra %(target)s'))
    extra_logger = logging.getLogger('app.extra')
    extra_logger.addHandler(extra_handler)
    extra_logger.warning('extra field', extra={'target': url('extra')})
    logging.getLogger('app').warning(
        'encoded https%3A%2F%2Fexample.invalid%2Fe%3FX-Amz-Signature%3Dencoded '
        'and url=/asset?X-Amz-Signature=equals')
    logging.makeLogRecord({})
    logger.warning('percent HTTP %(status)d PUT %(url)s', {'status': 503, 'url': signed('MAPPING')})
    logger.warning(Formatted())
    key, signature = signed('SPLIT_ADJACENT').split('=', 1)
    logger.warning('split adjacent %s=%s', key, signature)
    key, signature = signed('SPLIT_WHITESPACE').split('=', 1)
    logger.warning('HTTP 503 PUT URL %s= signature %s retry 1/5', key, signature)
    logger.warning('non-string %s', RuntimeError(signed('OBJECT_ARGUMENT')))
    logger.warning('upper scheme %s', signed('LOWERCASE').replace('https', 'HTTPS').replace('X-Amz', 'x-amz'))
    logger.warning('legacy %s&Expires=123', signed('LEGACY').replace('X-Amz-Signature', 'Signature'))
    logger.warning('encoded values %s', signed('ENCODED_VALUES').replace('Signature', '%53ignature') + '%2F%2B')
    logger.warning('encoded relative /asset%%3FX-Amz-Signature%%3D%s', 'AUDIT_ENCODED_QUERY')
    logger.warning('fully encoded relative %s', quote('/asset?other=AUDIT_ENCODED_RELATIVE', safe=''))
    logger.warning('fully encoded absolute %s', quote(signed('ENCODED_ABSOLUTE'), safe=''))
    logger.warning('relative legacy %s HTTP/1.1', '/asset?Signature=AUDIT_RELATIVE')
    logger.warning('py warnings follow')
    logging.getLogger('py.warnings').warning('direct warning record %s', signed('PY_WARNINGS'))
    logger.warning('broken braces {}', signed('BAD_BRACE_ARGS'))
    logger.warning('broken format %d', signed('BAD_PERCENT_ARGS'))
    logger.warning(BadMessage())
    logger.warning('no active exception %s', signed('NO_EXCEPTION'), exc_info=True)
    with mock.patch.object(logger, 'findCaller', return_value=('fixture.py', 5, 'fixture',
            'test stack: ' + signed('STACK'))):
        logger.warning('stack record', stack_info=True)
    populated = logging.makeLogRecord({'name': logger.name, 'msg': 'rebuilt record %s',
                                      'args': (signed('REBUILT'),), 'levelno': logging.WARNING})
    logger.handle(populated)
    for target in ({'url': signed('DICT')}, [signed('LIST')], Formatted()):
        extra_logger.warning('structured extra', extra={'target': target})
    fields = logging.StreamHandler(sys.stdout)
    fields.setFormatter(logging.Formatter('standard fields %(name)s %(pathname)s %(funcName)s %(message)s'))
    field_logger = logging.getLogger(signed('NAME'))
    field_logger.addHandler(fields)
    with mock.patch.object(field_logger, 'findCaller', return_value=(signed('PATH'), 5, signed('FUNC'), None)):
        field_logger.warning('standard message %s', signed('MESSAGE'))
    for stream in (sys.stdout, sys.stderr):
        print('standalone signing fields X-Amz-Credential=AUDIT_AWS sIg%3Daudit_encoded '
              'Expires=AUDIT_EXPIRY SIGNATURE=AUDIT_LEGACY_FIELD X-Goog-Signature=AUDIT_GOOGLE retry 2/5',
              file=stream)
        stream.write('fragmented http')
        stream.write('s://example.invalid/AUDIT_SPLIT\n')
        stream.write('flush sig=AUDIT_FLUSH')
        stream.flush()
        stream.write('\n')
        try:
            raise RuntimeError(signed('PRINTED_TRACEBACK'))
        except RuntimeError:
            traceback.print_exc(file=stream)
        stream.write('scope exit sig=AUDIT_SCOPE_EXIT')
    return mock.Mock()

def on_import(name):
    if name == 'HfApi':
        logger.warning('SDK import %s', signed('IMPORT'))
        logging.getLogger().warning('SDK verbosity warning %s', signed('IMPORT_ROOT'))
        return make_client
    raise AttributeError(name)

hub = ModuleType('huggingface_hub')
hub.__getattr__ = on_import
script = ROOT / 'tool/ci/hf_space_deploy.py'
sys.argv = [str(script), '--repo', 'org/space', '--folder', 'build',
            '--commit-message', 'msg', '--delete-pattern', '*']
logger.warning('before CLI http://outside.invalid/preinstalled')
with mock.patch.dict(sys.modules, {'huggingface_hub': hub}):
    runpy.run_path(str(script), run_name='__main__')
api = mock.Mock()
api.upload_folder.side_effect = lambda **kwargs: logger.warning('direct deploy http://outside.invalid/direct')
hf.deploy(api, 'org/space', 'build', 'msg', ['*'], False)
api.upload_folder.assert_called_once()
'''
        result = subprocess.run(
            [sys.executable, '-B', '-c', runner], cwd=Path(__file__).parent,
            env={**os.environ, 'HF_TOKEN': 'mock-token'},
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HTTP/1.1 503', result.stderr)
        self.assertIn('SDK upload warning', result.stderr)
        self.assertIn('root record', result.stderr)
        self.assertIn('captured warning', result.stderr)
        self.assertIn('direct warning record', result.stderr)
        self.assertIn('test stack:', result.stderr)
        self.assertIn('broken string conversion', result.stderr)
        self.assertIn('SDK verbosity warning', result.stderr)
        self.assertIn('standard fields', result.stdout)
        self.assertIn('extra ', result.stdout)
        for name, stream in (('stdout', result.stdout), ('stderr', result.stderr)):
            with self.subTest(stream=name):
                self.assertIn('SDK import', stream)
                self.assertIn('HTTP 503 PUT', stream)
                self.assertIn('retry 1/5', stream)
                self.assertIn('retry 2/5', stream)
                self.assertIn('rebuilt record', stream)
                self.assertIn('scope exit', stream)
                self.assertIn('before CLI http://outside.invalid/preinstalled', stream)
                self.assertIn('direct deploy http://outside.invalid/direct', stream)
                self.assertNotIn('AUDIT_', stream)
                self.assertNotIn('audit_encoded', stream)
                self.assertNotIn('stand-in', stream)
                self.assertNotIn('example.invalid', stream)

    def test_cli_redacts_unhandled_sdk_initialization_traceback(self):
        runner = '''
import runpy
import sys
from unittest import mock

from test_hf_space_deploy import ROOT

class FatalSdkError(BaseException):
    pass

failure = FatalSdkError if sys.argv[1] == 'FatalSdkError' else RuntimeError

def make_client(**kwargs):
    raise failure('SDK initialization failed https://inert.invalid/asset?sig=AUDIT_INIT')

script = ROOT / 'tool/ci/hf_space_deploy.py'
sys.argv = [str(script), '--repo', 'org/space', '--folder', 'build',
            '--commit-message', 'msg', '--delete-pattern', '*']
with mock.patch.dict(sys.modules, {'huggingface_hub': mock.Mock(HfApi=make_client)}):
    runpy.run_path(str(script), run_name='__main__')
'''
        for failure in ('RuntimeError', 'FatalSdkError'):
            with self.subTest(failure=failure):
                result = subprocess.run(
                    [sys.executable, '-B', '-c', runner, failure],
                    cwd=Path(__file__).parent,
                    env={**os.environ, 'HF_TOKEN': 'mock-token'},
                    capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('Traceback (most recent call last)', result.stderr)
                self.assertIn(f'{failure}: SDK initialization failed', result.stderr)
                for stream in (result.stdout, result.stderr):
                    self.assertNotIn('inert.invalid', stream)
                    self.assertNotIn('AUDIT_INIT', stream)

    def test_cli_redacts_an_interrupted_upload(self):
        runner = '''
import runpy
import sys
from unittest import mock

from test_hf_space_deploy import SensitiveHttpError, ROOT

def make_client(**kwargs):
    api = mock.Mock()
    def interrupted_upload(**kwargs):
        try:
            raise ConnectionError(SensitiveHttpError.signed_url('connection'))
        except ConnectionError:
            raise KeyboardInterrupt
    api.upload_folder.side_effect = interrupted_upload
    return api

script = ROOT / 'tool/ci/hf_space_deploy.py'
sys.argv = [str(script), '--repo', 'org/space', '--folder', 'build',
            '--commit-message', 'msg', '--delete-pattern', '*']
with mock.patch.dict(sys.modules, {'huggingface_hub': mock.Mock(HfApi=make_client)}):
    runpy.run_path(str(script), run_name='__main__')
'''
        result = subprocess.run(
            [sys.executable, '-B', '-c', runner], cwd=Path(__file__).parent,
            env={**os.environ, 'HF_TOKEN': 'mock-token'},
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertIn('KeyboardInterrupt', result.stderr)
        for stream in (result.stdout, result.stderr):
            self.assertNotIn('X-Amz-Signature', stream)
            self.assertNotIn('example.invalid', stream)

    def test_cli_redacts_retry_logs_from_offline_hub_wheel(self):
        wheel = os.environ.get('LLAMADART_HF_HUB_WHEEL')
        if not wheel or not Path(wheel).is_file():
            self.skipTest('Set LLAMADART_HF_HUB_WHEEL to a local SDK 0.36.2 wheel')
        runner = '''
import os
import runpy
import sys
import time
from unittest import mock

from test_hf_space_deploy import SensitiveHttpError, ROOT

def block_network(event, args):
    if event.startswith('socket.'):
        raise AssertionError('Network is disabled in the offline SDK test')

sys.addaudithook(block_network)
sys.path.insert(0, os.path.abspath(os.environ['LLAMADART_HF_HUB_WHEEL']))
from huggingface_hub import __version__
from huggingface_hub.utils import http_backoff
import requests

assert __version__ == '0.36.2', __version__
signed_url = SensitiveHttpError.signed_url('put')
response = requests.Response()
response.status_code = 503
response.url = signed_url
response._content = b'{}'

def upload(**kwargs):
    try:
        http_backoff('PUT', signed_url)
    except requests.HTTPError as error:
        raise RuntimeError('LFS upload failed') from error

api = mock.Mock()
api.upload_folder.side_effect = upload
script = ROOT / 'tool/ci/hf_space_deploy.py'
sys.argv = [str(script), '--repo', 'org/space', '--folder', 'build',
            '--commit-message', 'msg', '--delete-pattern', '*']
with (mock.patch('huggingface_hub.HfApi', return_value=api),
      mock.patch.object(requests.Session, 'request', return_value=response) as request,
      mock.patch.object(time, 'sleep') as sleep):
    try:
        runpy.run_path(str(script), run_name='__main__')
    finally:
        assert request.call_count == 6, request.call_count
        assert sleep.call_args_list == [mock.call(n) for n in (1, 2, 4, 8, 8)], sleep.call_args_list
'''
        result = subprocess.run(
            [sys.executable, '-B', '-c', runner], cwd=Path(__file__).parent,
            env={**os.environ, 'LLAMADART_HF_HUB_WHEEL': str(Path(wheel).resolve()),
                 'HF_TOKEN': 'mock-token', 'HF_HUB_VERBOSITY': 'warning'},
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.count('HTTP Error 503 thrown while requesting PUT'), 6,
                         result.stderr)
        self.assertTrue(result.stderr.endswith('upload_folder: failed (HTTP 503, RuntimeError)\n'),
                        result.stderr)
        self.assertNotIn('X-Amz-Signature', result.stderr)
        self.assertNotIn('example.invalid', result.stderr)

    def test_upload_failure_omits_provider_details_in_outer_handler(self):
        for status, retry_after, retries in TERMINAL_CASES:
            for chain in ('cause', 'context'):
                with self.subTest(status=status, retry_after=retry_after, chain=chain):
                    api = mock.Mock()
                    api.upload_folder.side_effect = SensitiveHttpError(status, retry_after, chain)
                    try:
                        run_deploy(api, squash_history=True)
                    except Exception as error:
                        diagnostic = '\n'.join((str(error), repr(error), repr(error.args),
                                                traceback.format_exc()))
                        self.assertNotIn('X-Amz-Signature', diagnostic)
                        self.assertEqual(
                            str(error), f'upload_folder: failed (HTTP {status}, SensitiveHttpError)')
                        self.assertIsNone(error.__cause__)
                        self.assertIsNone(error.__context__)
                    else:
                        self.fail('Expected upload failure')
                    self.assertEqual(api.upload_folder.call_count, retries + 1)
                    api.super_squash_history.assert_not_called()

    def test_cli_terminal_hub_errors_omit_provider_details(self):
        runner = '''
import runpy
import sys
import time
from unittest import mock

from test_hf_space_deploy import SensitiveHttpError, missing_space_api, ROOT

operation, status, retry_after = sys.argv[1:]
api = missing_space_api() if operation == 'create_repo' else mock.Mock()
getattr(api, operation).side_effect = SensitiveHttpError(int(status), retry_after, 'cause')
hub = mock.Mock()
hub.HfApi.return_value = api
script = ROOT / 'tool/ci/hf_space_deploy.py'
sys.argv = [str(script), '--repo', 'org/space', '--folder', 'build',
            '--commit-message', 'msg', '--delete-pattern', '*', '--squash-history']
with mock.patch.dict(sys.modules, {'huggingface_hub': hub}), mock.patch.object(time, 'sleep'):
    runpy.run_path(str(script), run_name='__main__')
'''
        for operation in ('repo_info', 'create_repo', 'upload_folder', 'super_squash_history'):
            for status, retry_after, retries in TERMINAL_CASES:
                with self.subTest(operation=operation, status=status, retry_after=retry_after):
                    result = subprocess.run(
                        [sys.executable, '-B', '-c', runner, operation, str(status), retry_after],
                        cwd=Path(__file__).parent, env={**os.environ, 'HF_TOKEN': 'mock-token'},
                        capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr.splitlines(), [
                        f'{operation}: HTTP 429 on attempt {attempt}/{hf.MAX_ATTEMPTS}; retrying in 0s'
                        for attempt in range(1, retries + 1)
                    ] + [f'{operation}: failed (HTTP {status}, SensitiveHttpError)'])

    def test_cli_parses_squash_history_and_max_folder_bytes(self):
        hub = mock.Mock()
        with (mock.patch.dict(sys.modules, {'huggingface_hub': hub}),
              mock.patch.dict(os.environ, {'HF_TOKEN': 'mock-token'}),
              mock.patch.object(hf, 'deploy') as deploy):
            hf.main(['--repo', 'org/space', '--folder', 'build', '--commit-message', 'msg',
                     '--delete-pattern', '*', '--public', '--squash-history',
                     '--max-folder-bytes', '250000000'])
        deploy.assert_called_once_with(
            hub.HfApi.return_value, 'org/space', 'build', 'msg', ['*'], True,
            squash_history=True, max_folder_bytes=250_000_000)


if __name__ == '__main__':
    unittest.main()
