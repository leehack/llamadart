"""Behavioral checks for the Hugging Face Space deploy retry policy."""
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import hf_space_deploy as hf


class HttpError(Exception):
    def __init__(self, status, headers=None):
        super().__init__(f'HTTP {status}')
        self.response = mock.Mock(status_code=status, headers=headers or {})


def run_deploy(api, **options):
    sleeps = []
    hf.deploy(api, 'org/space', 'build', 'msg', ['*'], True,
              sleep=sleeps.append, jitter=lambda: 1.0, log=lambda *a, **k: None, **options)
    return sleeps


class RetryTest(unittest.TestCase):
    def test_recovers_from_429_on_create_and_upload(self):
        api = mock.Mock()
        api.create_repo.side_effect = [HttpError(429), HttpError(429), None]
        api.upload_folder.side_effect = [HttpError(429), None]
        sleeps = run_deploy(api)
        self.assertEqual(api.create_repo.call_count, 3)
        self.assertEqual(api.upload_folder.call_count, 2)
        self.assertEqual(sleeps, [5.0, 10.0, 5.0])

    def test_retry_after_overrides_backoff(self):
        api = mock.Mock()
        api.create_repo.side_effect = [HttpError(429, {'Retry-After': '7'}), None]
        self.assertEqual(run_deploy(api), [7.0])

    def test_exhausted_attempts_fail_with_the_429(self):
        api = mock.Mock()
        api.create_repo.side_effect = HttpError(429)
        with self.assertRaises(HttpError):
            run_deploy(api)
        self.assertEqual(api.create_repo.call_count, hf.MAX_ATTEMPTS)
        api.upload_folder.assert_not_called()

    def test_retry_after_beyond_budget_fails_without_sleeping(self):
        api = mock.Mock()
        api.create_repo.side_effect = HttpError(429, {'Retry-After': str(hf.MAX_TOTAL_WAIT + 1)})
        sleeps = []
        with self.assertRaises(HttpError):
            hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                      log=lambda *a, **k: None)
        self.assertEqual(sleeps, [])

    def test_non_retryable_errors_fail_immediately(self):
        for status in (400, 401, 403, 404, 409, 422, 500, 503, None):
            for step in ('create_repo', 'upload_folder'):
                api = mock.Mock()
                getattr(api, step).side_effect = (
                    HttpError(status) if status else ValueError('bad'))
                sleeps = []
                with self.assertRaises(Exception):
                    hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=sleeps.append,
                              log=lambda *a, **k: None)
                self.assertEqual(getattr(api, step).call_count, 1, (status, step))
                self.assertEqual(sleeps, [], (status, step))

    def test_logs_never_include_the_token(self):
        api = mock.Mock()
        api.create_repo.side_effect = [HttpError(429), None]
        lines = []
        hf.deploy(api, 'r', 'f', 'm', ['*'], False, sleep=lambda s: None,
                  log=lambda line, **k: lines.append(line))
        self.assertTrue(lines)
        self.assertNotIn('hf_', ''.join(lines))


class DeployCallTest(unittest.TestCase):
    def test_public_flag_and_arguments_reach_the_api(self):
        api = mock.Mock()
        run_deploy(api)
        api.create_repo.assert_called_once_with(
            repo_id='org/space', repo_type='space', space_sdk='static', exist_ok=True,
            private=False)
        api.upload_folder.assert_called_once_with(
            repo_id='org/space', repo_type='space', folder_path='build', revision='main',
            delete_patterns=['*'], commit_message='msg')

    def test_private_is_omitted_without_public(self):
        api = mock.Mock()
        hf.deploy(api, 'r', 'f', 'm', ['*'], False)
        self.assertNotIn('private', api.create_repo.call_args.kwargs)


if __name__ == '__main__':
    unittest.main()
