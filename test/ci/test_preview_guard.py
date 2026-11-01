"""Causal live-state, provider ordering and same-run preview provenance checks."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tool/ci'))
import preview_guard as guard
from hf_space_deploy import with_retry


class PreviewGuardTest(unittest.TestCase):
    def setUp(self):
        self.pr = dict(number=7, state='open', closed_at=None, draft=False,
                       labels=[], user=dict(login='maintainer'),
                       head=dict(sha='a'*40, repo=dict(full_name='leehack/llamadart')),
                       base=dict(sha='b'*40, ref='main', repo=dict(full_name='leehack/llamadart')))
        self.event = dict(action='synchronize', repository=dict(full_name='leehack/llamadart'),
                          pull_request=copy.deepcopy(self.pr))
        self.env = patch.dict(os.environ, GITHUB_REPOSITORY='leehack/llamadart',
                              GITHUB_EVENT_NAME='pull_request')
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_live_head_eligibility_and_close_generation(self):
        self.assertEqual(guard.live_action(self.event, self.pr, ['lib/llamadart.dart']), 'build')
        for field, value in [('state', 'closed'), ('draft', True)]:
            live = copy.deepcopy(self.pr)
            live[field] = value
            self.assertEqual(guard.live_action(self.event, live, ['lib/llamadart.dart']), 'skip')
        self.assertEqual(guard.live_action(self.event, self.pr, ['README.md']), 'skip')
        for location in [('head', 'sha', 'c'*40), ('base', 'ref', 'other')]:
            live = copy.deepcopy(self.pr)
            live[location[0]][location[1]] = location[2]
            self.assertEqual(guard.live_action(self.event, live, ['lib/llamadart.dart']), 'skip')
        live = copy.deepcopy(self.pr)
        live['draft'] = True
        live['labels'] = [dict(name='preview')]
        self.assertEqual(guard.live_action(self.event, live, ['README.md']), 'build')
        self.event['action'] = 'closed'
        self.event['pull_request']['closed_at'] = '2026-11-01T00:00:00Z'
        live['state'] = 'closed'
        live['closed_at'] = '2026-11-01T00:00:00Z'
        self.assertEqual(guard.live_action(self.event, live, []), 'cleanup')
        live['state'] = 'open'
        self.assertEqual(guard.live_action(self.event, live, []), 'skip')
        live['state'] = 'closed'
        live['closed_at'] = '2026-11-01T00:01:00Z'
        self.assertEqual(guard.live_action(self.event, live, []), 'skip')

    def test_same_run_attempt_repo_head_digest_binding(self):
        args = dict(artifact_id=11, digest='d'*64, run_id=22, sha='a'*40,
                    repository_id=33, name='chat-app-preview-7-1')
        metadata = dict(id=11, expired=False, digest='sha256:'+'d'*64,
                        name=args['name'], workflow_run=dict(id=22, head_sha='a'*40,
                        repository_id=33, head_repository_id=33, head_branch='topic'))
        guard.verify_preview_artifact(metadata, **args)
        for field, bad in [('id', 12), ('expired', True), ('digest', 'sha256:'+'e'*64),
                           ('name', 'chat-app-preview-7-2')]:
            changed = copy.deepcopy(metadata)
            changed[field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                guard.verify_preview_artifact(changed, **args)
        for field, bad in [('id', 23), ('head_sha', 'c'*40), ('repository_id', 34),
                           ('head_repository_id', 34)]:
            changed = copy.deepcopy(metadata)
            changed['workflow_run'][field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                guard.verify_preview_artifact(changed, **args)

    def test_artifact_download_checks_archive_tree_and_stamp(self):
        preview, read = self.preview()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stamp = dict(commit='a'*40, tree='c'*40, base_href='/',
                         target='lib/main.dart', flutter_version='3.47.1')
            original = Path.cwd()
            try:
                os.chdir(root)
                for bad in [True, False]:
                    current = dict(stamp, tree='f'*40) if bad else stamp
                    with zipfile.ZipFile('input.zip', 'w') as bundle:
                        bundle.writestr('index.html', '<base href="/">')
                        bundle.writestr('llamadart-build.json', json.dumps(current))
                    data = Path('input.zip').read_bytes()
                    digest = hashlib.sha256(data).hexdigest()
                    read.return_value = dict(id=11, name='chat-app-preview-7-1', expired=False,
                        digest='sha256:'+digest, workflow_run=dict(id=22, head_sha='a'*40,
                        repository_id=33, head_repository_id=33))
                    def run(args, **kw):
                        if args[0] == 'gh':
                            kw['stdout'].write(data)
                    with patch.dict(os.environ, ARTIFACT_ID='11', ARTIFACT_DIGEST=digest,
                                    GITHUB_RUN_ID='22', GITHUB_REPOSITORY_ID='33', GITHUB_RUN_ATTEMPT='1'), patch.object(
                            guard.subprocess, 'check_call', side_effect=run) as calls, patch.object(
                            guard.subprocess, 'check_output', side_effect=['c'*40, '3.47.1']):
                        if bad:
                            with self.assertRaises(ValueError):
                                preview.artifact()
                            self.assertEqual(calls.call_count, 1)
                        else:
                            preview.artifact()
                            self.assertEqual(calls.call_args.args[0], ['bash',
                                'scripts/validate_chat_app_web_build.sh', 'preview-artifact'])
                            self.assertEqual(Path('preview-artifact/index.html').read_text(), '<base href="/">')
                    import shutil
                    shutil.rmtree('preview-artifact')
            finally:
                os.chdir(original)

    def preview(self):
        live = Mock(return_value=copy.deepcopy(self.pr))
        return guard.Preview(self.event, read=live), live

    def test_create_then_upload_each_recheck_live_state(self):
        preview, read = self.preview()
        api = Mock()
        calls = []
        api.create_repo.side_effect = lambda **kw: calls.append('create')
        api.upload_folder.side_effect = lambda **kw: calls.append('upload')
        with patch.object(guard.subprocess, 'check_call'), patch.object(
                guard.subprocess, 'check_output', return_value=b'M\0lib/llamadart.dart\0'):
            preview.mutate('build', api, 'owner/space', 'folder')
        self.assertEqual(calls, ['create', 'upload'])
        self.assertEqual(read.call_count, 4)
        self.assertEqual(api.upload_folder.call_args.kwargs['delete_patterns'], ['*', '**/*'])
        # Closing between create and upload prevents the second mutation.
        closed = copy.deepcopy(self.pr)
        closed['state'] = 'closed'
        read.side_effect = [self.pr, self.pr, closed]
        api.reset_mock()
        with patch.object(guard.subprocess, 'check_call'), patch.object(
                guard.subprocess, 'check_output', return_value=b'M\0lib/llamadart.dart\0'):
            with self.assertRaises(guard.Superseded):
                preview.mutate('build', api, 'owner/space', 'folder')
        api.create_repo.assert_called_once()
        api.upload_folder.assert_not_called()

    def test_api_error_and_stale_close_perform_no_mutation(self):
        preview, read = self.preview()
        read.side_effect = RuntimeError('API unavailable')
        api = Mock()
        with self.assertRaises(RuntimeError):
            preview.mutate('build', api, 'owner/space', 'folder')
        api.assert_not_called()
        api.create_repo.assert_not_called()
        self.event['action'] = 'closed'
        self.event['pull_request']['closed_at'] = 'original-close'
        preview, read = self.preview()
        with self.assertRaises(guard.Superseded):
            preview.mutate('cleanup', api, 'owner/space', 'folder')
        api.delete_repo.assert_not_called()

    def test_rate_limit_retry_rechecks_instead_of_writing_after_close(self):
        preview, read = self.preview()
        closed = copy.deepcopy(self.pr)
        closed['state'] = 'closed'
        read.side_effect = [self.pr, self.pr, closed]
        error = RuntimeError('rate limited')
        error.response = Mock(status_code=429, headers={'Retry-After': '0'})
        api = Mock()
        api.create_repo.side_effect = error
        with patch.object(guard.subprocess, 'check_call'), patch.object(
                guard.subprocess, 'check_output', return_value=b'M\0lib/llamadart.dart\0'), patch.object(
                guard, 'with_retry', side_effect=lambda *a, **kw: with_retry(
                    *a, **kw, sleep=lambda delay: None)):
            with self.assertRaises(guard.Superseded):
                preview.mutate('build', api, 'owner/space', 'folder')
        api.create_repo.assert_called_once()
        api.upload_folder.assert_not_called()

    def test_comment_rechecks_after_comment_listing(self):
        preview, read = self.preview()
        live = copy.deepcopy(self.pr)
        live['state'] = 'closed'
        read.return_value = live
        with patch.object(guard.subprocess, 'check_output', return_value=b'[[]]'), patch.object(
                guard.subprocess, 'check_call'), patch.object(guard.subprocess, 'run') as write:
            with self.assertRaises(guard.Superseded):
                preview.comment('build', 'body')
        write.assert_not_called()


if __name__ == '__main__':
    unittest.main()
