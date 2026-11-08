"""Model-free Linux process/pipe fixtures for the production Chrome supervisor."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tool/ci/supervise_chrome_test.py'


def load_supervisor():
    spec = importlib.util.spec_from_file_location('supervise_chrome_test', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProcessTableTest(unittest.TestCase):
    def test_processes_exiting_mid_scan_do_not_abort_the_table(self):
        supervisor = load_supervisor()
        with tempfile.TemporaryDirectory() as temp:
            proc = Path(temp)
            stat_tail = ' '.join(['S', '1', '10', '10'] + ['0'] * 15 + ['4242'])
            for pid in ('100', '101', '102'):
                (proc / pid).mkdir()
                (proc / pid / 'stat').write_text(f'{pid} (worker) {stat_tail}\n')
                (proc / pid / 'wchan').write_text('do_wait')
            vanished = {proc / '101' / 'stat', proc / '102' / 'wchan'}
            read_text = Path.read_text

            def racing_read(path, *args, **kwargs):
                if path in vanished:
                    raise ProcessLookupError(3, 'No such process')
                return read_text(path, *args, **kwargs)

            with mock.patch.object(supervisor, 'Path', lambda _: proc), \
                    mock.patch.object(Path, 'read_text', racing_read):
                table = supervisor.process_table()

        self.assertEqual(sorted(table), [100, 102])
        self.assertEqual(table[100]['wchan'], 'do_wait')
        self.assertEqual(table[102]['wchan'], 'unavailable')
        self.assertEqual(table[102]['start_ticks'], 4242)


@unittest.skipUnless(sys.platform == 'linux', 'Requires Linux /proc and pidfds')
class SupervisorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'diagnostics'

    def command(self, program, timeout=3, shutdown=0.25):
        return [sys.executable, str(SCRIPT), '--output-dir', str(self.output),
                '--timeout-seconds', str(timeout), '--shutdown-seconds', str(shutdown),
                '--cleanup-seconds', '0.5', '--snapshot-seconds', '0.1', '--',
                sys.executable, '-c', program]

    def run_fixture(self, program, **options):
        result = subprocess.run(self.command(program, **options),
                                capture_output=True, timeout=8)
        return result, json.loads((self.output / 'result.json').read_text())

    def events(self):
        return [json.loads(line) for line in (self.output / 'events.jsonl').read_text().splitlines()]

    def assert_clean(self, result):
        self.assertEqual(result['owned_processes_remaining'], [])
        self.assertTrue(result['stdout_eof'])
        self.assertTrue(result['stderr_eof'])
        for line in (self.output / 'processes.jsonl').read_text().splitlines():
            for row in json.loads(line)['processes']:
                try:
                    raw = Path('/proc', str(row['pid']), 'stat').read_text()
                except FileNotFoundError:
                    continue
                start = int(raw[raw.rindex(')') + 2:].split()[19])
                self.assertNotEqual(start, row['start_ticks'], 'Owned process survived supervisor exit')

    def test_real_exit_and_both_eofs_are_required_for_success(self):
        child, result = self.run_fixture(
            "import sys; print('2 tests passed.'); print('diagnostic', file=sys.stderr)")
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertTrue(result['passed'])
        self.assertEqual(result['cli_exit_code'], 0)
        self.assertFalse(result['forced_cleanup'])
        self.assert_clean(result)
        self.assertEqual((self.output / 'stdout.log').read_bytes(), b'2 tests passed.\n')
        self.assertEqual((self.output / 'stderr.log').read_bytes(), b'diagnostic\n')
        self.assertEqual(child.stdout, b'2 tests passed.\n')
        self.assertEqual(child.stderr, b'diagnostic\n')
        kinds = [event['event'] for event in self.events()]
        for kind in ['command_started', 'reporter_summary_observed', 'cli_exit',
                     'output_eof', 'owned_children_exited', 'supervisor_exit']:
            self.assertIn(kind, kinds)

    def test_mixed_pass_fail_summary_is_observed_and_stays_failure(self):
        child, result = self.run_fixture(
            "print('1 test passed, 1 failed.'); raise SystemExit(1)")
        self.assertEqual(child.returncode, 1, child.stderr)
        self.assertFalse(result['passed'])
        self.assertIn('reporter_summary_observed', [event['event'] for event in self.events()])
        self.assertEqual(child.stdout, b'1 test passed, 1 failed.\n')

    def test_stalled_job_log_cannot_block_deadline_or_cleanup(self):
        program = ('import sys,time; sys.stdout.buffer.write(b"x" * (4 * 1024 * 1024)); '
                   'sys.stdout.flush(); time.sleep(5)')
        supervisor = subprocess.Popen(self.command(program, timeout=0.5),
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.addCleanup(supervisor.stdout.close)
        self.assertEqual(supervisor.wait(timeout=8), 124)
        self.assertEqual(json.loads((self.output / 'result.json').read_text())['failure_reason'],
                         'command_timeout')

    def test_reporter_success_does_not_override_a_failing_exit(self):
        child, result = self.run_fixture("print('All tests passed!'); raise SystemExit(7)")
        self.assertEqual(child.returncode, 7, child.stderr)
        self.assertFalse(result['passed'])
        self.assertEqual(result['cli_exit_code'], 7)
        self.assertFalse(result['forced_cleanup'])
        self.assert_clean(result)

    def test_success_text_does_not_end_a_running_command(self):
        child, result = self.run_fixture(
            "import time; print('2 tests passed.', flush=True); time.sleep(5)", timeout=0.25)
        self.assertEqual(child.returncode, 124, child.stderr)
        self.assertEqual(result['failure_reason'], 'command_timeout')
        self.assertTrue(result['forced_cleanup'])
        self.assertFalse(result['passed'])
        self.assert_clean(result)

    def unread_consumer(self, stream):
        payload = b'0123456789abcdef' * 65536
        program = (
            f'import sys,time; sys.{stream}.buffer.write(b"0123456789abcdef" * 65536); '
            f'sys.{stream}.flush(); time.sleep(5)'
        )
        child = subprocess.Popen(self.command(program, timeout=0.5),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # wait(), unlike communicate(), leaves both downstream pipes unread.
            # A forwarding write blocks here once it exceeds the pipe capacity.
            child.wait(timeout=3)
            self.assertEqual(child.returncode, 124)
            result = json.loads((self.output / 'result.json').read_text())
            self.assertEqual(result['failure_reason'], 'command_timeout')
            self.assertTrue(result['forced_cleanup'])
            self.assertFalse(result['passed'])
            self.assertEqual((self.output / f'{stream}.log').read_bytes(), payload)
            self.assert_clean(result)
            forwarded = child.communicate(timeout=2)
            self.assertEqual(forwarded, (b'', b''))
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=2)

    def test_unread_downstream_stdout_cannot_block_deadline_or_cleanup(self):
        self.unread_consumer('stdout')

    def test_unread_downstream_stderr_cannot_block_deadline_or_cleanup(self):
        self.unread_consumer('stderr')

    def test_cli_exit_is_distinct_from_inherited_pipe_eof(self):
        child, result = self.run_fixture(
            "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'])")
        self.assertEqual(child.returncode, 125, child.stderr)
        self.assertEqual(result['cli_exit_code'], 0)
        self.assertEqual(result['failure_reason'], 'shutdown_timeout')
        self.assertTrue(result['forced_cleanup'])
        self.assert_clean(result)
        events = self.events()
        exited = next(i for i, event in enumerate(events) if event['event'] == 'cli_exit')
        eof = [i for i, event in enumerate(events) if event['event'] == 'output_eof']
        self.assertTrue(all(i > exited for i in eof))

    def test_closed_pipes_do_not_hide_a_surviving_child(self):
        child, result = self.run_fixture(
            "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)")
        self.assertEqual(child.returncode, 125, child.stderr)
        self.assertEqual(result['cli_exit_code'], 0)
        self.assertEqual(result['failure_reason'], 'shutdown_timeout')
        self.assertTrue(result['forced_cleanup'])
        self.assert_clean(result)

    def test_subreaper_tracks_children_that_leave_the_command_session(self):
        child, result = self.run_fixture(
            "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],"
            "start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)")
        self.assertEqual(child.returncode, 125, child.stderr)
        self.assertTrue(result['forced_cleanup'])
        self.assert_clean(result)
        snapshots = [json.loads(line) for line in (self.output / 'processes.jsonl').read_text().splitlines()]
        leader = self.events()[0]['pid']
        self.assertTrue(any(row['pid'] != leader and row['sid'] != leader
                            for shot in snapshots for row in shot['processes']))

    def test_natural_child_shutdown_within_the_grace_period_needs_no_cleanup(self):
        child, result = self.run_fixture(
            "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(.15)'])",
            shutdown=1)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertFalse(result['forced_cleanup'])
        self.assert_clean(result)

    def test_term_resistant_command_is_killed_and_stays_failure(self):
        child, result = self.run_fixture(
            'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(5)',
            timeout=0.25)
        self.assertEqual(child.returncode, 124, child.stderr)
        self.assertEqual(result['cli_exit_code'], 137)
        self.assertTrue(result['forced_cleanup'])
        self.assert_clean(result)
        self.assertIn(9, [event['signal'] for event in self.events()
                          if event['event'] == 'cleanup_signal'])

    def test_cleanup_never_targets_an_unrelated_process(self):
        peer = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(5)'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            child, result = self.run_fixture('import time; time.sleep(5)', timeout=0.25)
            self.assertEqual(child.returncode, 124, child.stderr)
            self.assertIsNone(peer.poll())
            self.assert_clean(result)
        finally:
            peer.terminate()
            peer.wait(timeout=3)

    def test_term_interrupt_stays_failure_and_cleans_children(self):
        child = subprocess.Popen(self.command('import time; time.sleep(5)'),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            path = self.output / 'events.jsonl'
            if path.exists() and 'command_started' in path.read_text():
                break
            time.sleep(0.01)
        child.send_signal(signal.SIGTERM)
        stdout, stderr = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 143, (stdout, stderr))
        result = json.loads((self.output / 'result.json').read_text())
        self.assertFalse(result['passed'])
        self.assertTrue(result['forced_cleanup'])
        self.assert_clean(result)

    def test_process_receipts_exclude_command_arguments_and_environment(self):
        marker = 'synthetic-sensitive-argument'
        command = self.command('import time; time.sleep(.15)') + [marker]
        child = subprocess.run(command, capture_output=True, timeout=8,
                               env={**os.environ, 'SYNTHETIC_SECRET': marker})
        self.assertEqual(child.returncode, 0, child.stderr)
        for name in ['events.jsonl', 'processes.jsonl', 'result.json']:
            self.assertNotIn(marker, (self.output / name).read_text())

    def test_invalid_deadlines_do_not_start_the_command(self):
        for seconds in ['nan', 'inf', '0', '-1']:
            command = self.command('raise SystemExit(0)')
            command[command.index('--timeout-seconds') + 1] = seconds
            child = subprocess.run(command, capture_output=True, timeout=3)
            self.assertNotEqual(child.returncode, 0)
            self.assertFalse(self.output.exists())

    def test_output_limit_is_a_failure_even_when_the_command_would_exit_zero(self):
        child, result = self.run_fixture("import sys; sys.stdout.buffer.write(b'x' * (9 * 1024 * 1024))")
        self.assertEqual(child.returncode, 125, child.stderr)
        self.assertEqual(result['failure_reason'], 'output_limit')
        self.assertFalse(result['passed'])
        self.assertLessEqual((self.output / 'stdout.log').stat().st_size, 8 * 1024 * 1024)
        self.assert_clean(result)

    def test_launch_error_keeps_evidence_without_the_secret_bearing_path(self):
        command = self.command('unused')
        command[command.index('--') + 1:] = ['/synthetic-sensitive-path/not-an-executable']
        child = subprocess.run(command, capture_output=True, timeout=3)
        self.assertEqual(child.returncode, 125)
        result = json.loads((self.output / 'result.json').read_text())
        self.assertIsNone(result['cli_exit_code'])
        self.assertEqual(result['failure_reason'], 'supervisor_error')
        self.assertFalse(result['passed'])
        for path in self.output.iterdir():
            self.assertNotIn('synthetic-sensitive-path', path.read_text())


class WorkflowTest(unittest.TestCase):
    def test_model_store_keeps_failure_gates_and_uploads_before_job_cancellation(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        lane = workflow.split('\n  model-store:\n', 1)[1].split('\n  analyze:\n', 1)[0]
        chrome = lane.index('name: Test on Chrome with bounded shutdown diagnostics')
        upload = lane.index('name: Upload Chrome process and phase diagnostics')
        package_gate = lane.index('name: Check the lane leaves the package unchanged')
        self.assertLess(chrome, upload)
        self.assertLess(upload, package_gate)
        self.assertIn('if: always()', lane[upload:package_gate])
        self.assertIn('actions/upload-artifact@v7', lane[upload:package_gate])
        self.assertIn('--timeout-seconds 180 --', lane[chrome:upload])
        self.assertEqual(lane.count('dart test -p chrome test/model_store_web_test.dart'), 1)
        self.assertNotIn('flutter test --platform chrome', lane)
        self.assertIn('timeout-minutes: 20', lane)
        self.assertIn('flutter-version: 3.47.1', lane)
        self.assertNotIn('continue-on-error', lane)
        self.assertNotIn('|| true', lane)


if __name__ == '__main__':
    unittest.main()
