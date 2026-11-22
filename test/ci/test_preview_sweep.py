"""Offline tests for preview discovery and guarded Space deletion."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tool/ci'))
import preview_sweep as sweep


class PreviewSweepTest(unittest.TestCase):
    @staticmethod
    def response(status, *, number=7, state='closed', merged=False):
        body = json.dumps({'number': number, 'state': state, 'merged': merged}).encode()
        return subprocess.CompletedProcess(
            args=['gh'], returncode=0 if status == 200 else 1,
            stdout=f'HTTP/2.0 {status} Reason\r\nHeader: value\r\n\r\n'.encode() + body,
            stderr=b'private token and signed URL')

    @staticmethod
    def http_error(status):
        error = RuntimeError('private token and signed URL')
        error.response = SimpleNamespace(status_code=status)
        return error

    def test_only_exact_ids_for_closed_prs_are_listed(self):
        api = Mock()
        api.list_spaces.return_value = iter(SimpleNamespace(id=space) for space in [
            'leehack/llamadart', 'leehack/llamadart-chat-pr-0',
            'leehack/llamadart-chat-pr-01', 'leehack/llamadart-chat-pr-7-extra',
            'leehack/llamadart-chat-pr-7\n', 'other/llamadart-chat-pr-7',
            'leehack/llamadart-chat-pr-7', 'leehack/llamadart-chat-pr-8',
            'leehack/llamadart-chat-pr-9', 'leehack/llamadart-chat-pr-10',
            'leehack/llamadart-chat-pr-7',
        ])
        responses = [
            self.response(200), self.response(200, number=8, state='open'),
            self.response(404, number=9), self.response(200, number=10, merged=True),
        ]
        with patch.object(sweep.subprocess, 'run', side_effect=responses) as run:
            self.assertEqual(sweep.list_closed_previews(api), ['7', '10'])
        api.list_spaces.assert_called_once_with(author='leehack')
        self.assertEqual(run.call_args_list, [
            call(['gh', 'api', '--include', f'repos/leehack/llamadart/pulls/{pr}'],
                 capture_output=True, timeout=30)
            for pr in (7, 8, 9, 10)
        ])
        api.delete_repo.assert_not_called()

    def test_empty_matrix_is_written_to_workflow_output(self):
        api = Mock()
        api.list_spaces.return_value = []
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'output'
            with patch.dict(os.environ, {
                    'GITHUB_REPOSITORY': 'leehack/llamadart',
                    'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'schedule',
                    'GITHUB_OUTPUT': str(output), 'HF_TOKEN': 'secret-token'}), patch.dict(
                    sys.modules, huggingface_hub=SimpleNamespace(HfApi=Mock(return_value=api))):
                sweep.main(['list'])
            self.assertEqual(output.read_text(), 'prs=[]\n')

    def test_only_trusted_main_dispatch_or_schedule_can_run(self):
        env = {'GITHUB_REPOSITORY': 'leehack/llamadart', 'GITHUB_REF': 'refs/heads/main',
               'GITHUB_EVENT_NAME': 'workflow_dispatch', 'HF_TOKEN': 'secret-token'}
        client = Mock()
        for key, value in [('GITHUB_REPOSITORY', 'other/llamadart'),
                           ('GITHUB_REF', 'refs/heads/topic'),
                           ('GITHUB_EVENT_NAME', 'pull_request')]:
            for action in ('list', 'delete'):
                with self.subTest(key=key, action=action), patch.dict(
                        os.environ, {**env, key: value}), patch.dict(
                        sys.modules, huggingface_hub=SimpleNamespace(HfApi=client)):
                    with self.assertRaises(SystemExit):
                        sweep.main([action])
        client.assert_not_called()

    def test_delete_validates_the_pr_number_before_any_api_call(self):
        api = Mock()
        with patch.object(sweep.subprocess, 'run') as read:
            for number in ('0', '01', '7-extra', '7\n', 'leehack/llamadart', ''):
                with self.subTest(number=number), self.assertRaises(ValueError):
                    sweep.delete_closed_preview(api, number)
        read.assert_not_called()
        api.delete_repo.assert_not_called()

    def test_reopen_after_listing_skips_the_delete(self):
        api = Mock()
        api.list_spaces.return_value = [SimpleNamespace(id='leehack/llamadart-chat-pr-7')]
        responses = [self.response(200), self.response(200, state='open')]
        with patch.object(sweep.subprocess, 'run', side_effect=responses) as read:
            [number] = sweep.list_closed_previews(api)
            sweep.delete_closed_preview(api, number)
        api.delete_repo.assert_not_called()
        self.assertEqual(read.call_count, 2)

    def test_missing_pr_at_delete_time_skips_the_delete(self):
        api = Mock()
        with patch.object(sweep.subprocess, 'run', return_value=self.response(404)):
            sweep.delete_closed_preview(api, '7')
        api.delete_repo.assert_not_called()

    def test_delete_uses_exact_id_and_missing_space_is_success(self):
        for error in (None, self.http_error(404)):
            with self.subTest(error=type(error).__name__):
                api = Mock()
                api.delete_repo.side_effect = error
                with patch.object(sweep.subprocess, 'run', return_value=self.response(200)):
                    sweep.delete_closed_preview(api, '7')
                api.delete_repo.assert_called_once_with(
                    repo_id='leehack/llamadart-chat-pr-7', repo_type='space')

    def test_failures_exit_with_only_safe_diagnostics(self):
        env = {'GITHUB_REPOSITORY': 'leehack/llamadart', 'GITHUB_REF': 'refs/heads/main',
               'GITHUB_EVENT_NAME': 'workflow_dispatch', 'HF_TOKEN': 'secret-token',
               'PREVIEW_PR_NUMBER': '7'}

        def broken_listing():
            yield SimpleNamespace(id='leehack/llamadart-chat-pr-7')
            raise self.http_error(429)

        for action, response, expected in [
            ('list', self.response(200), 'list_spaces leehack HTTP 429 RuntimeError'),
            ('delete', self.response(403),
             'read_pr leehack/llamadart-chat-pr-7 HTTP 403 CalledProcessError'),
            ('delete', self.response(200),
             'delete_repo leehack/llamadart-chat-pr-7 HTTP 500 RuntimeError'),
        ]:
            api = Mock()
            api.list_spaces.return_value = broken_listing()
            api.delete_repo.side_effect = self.http_error(500)
            stdout = io.StringIO()
            with (
                self.subTest(expected=expected),
                patch.dict(os.environ, env),
                patch.dict(sys.modules, huggingface_hub=SimpleNamespace(HfApi=Mock(return_value=api))),
                patch.object(sweep.subprocess, 'run', return_value=response),
                redirect_stdout(stdout),
                self.assertRaises(SystemExit) as caught,
            ):
                sweep.main([action])
            self.assertEqual(str(caught.exception), expected)
            self.assertEqual(stdout.getvalue(), '')
            if response.returncode:
                api.delete_repo.assert_not_called()
