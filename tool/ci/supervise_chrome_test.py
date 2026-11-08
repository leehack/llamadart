"""Linux CI diagnostics for one browser-test command; reporter text is not a verdict."""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


SUMMARY_PATTERN = rb'All tests passed!|\d+ tests? passed[.,]'
ECHO_DESCRIPTORS = {'stdout': 1, 'stderr': 2}


def echo(name, chunk):
    # The job log is best effort: a stalled log pipe must not delay deadlines.
    try:
        os.set_blocking(ECHO_DESCRIPTORS[name], False)
        os.write(ECHO_DESCRIPTORS[name], chunk)
    except OSError:
        pass


def process_table():
    """Read identity/ancestry and wait state, never argv, environment or paths."""
    table = {}
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            raw = (directory / 'stat').read_text()
            end = raw.rindex(')')
            fields = raw[end + 2:].split()
            pid = int(directory.name)
            try:
                wait = (directory / 'wchan').read_text().strip()
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                wait = 'unavailable'
            table[pid] = {
                'pid': pid, 'ppid': int(fields[1]), 'pgid': int(fields[2]),
                'sid': int(fields[3]), 'state': fields[0],
                'start_ticks': int(fields[19]),
                'comm': re.sub(r'[^a-zA-Z0-9:._-]', '?', raw[raw.index('(') + 1:end])[:64],
                'wchan': re.sub(r'[^a-zA-Z0-9_]', '?', wait)[:64],
            }
        except (FileNotFoundError, ProcessLookupError):
            # A process reaped mid-read raises ESRCH rather than ENOENT.
            continue
    return table


def owned_processes(table, leader, known):
    """Subreaper adoption retains descendants that leave the command's session."""
    selected = {}
    changed = True
    while changed:
        changed = False
        for pid, row in table.items():
            identity = (pid, row['start_ticks'])
            if pid in selected or pid == os.getpid():
                continue
            if (pid == leader or row['ppid'] == os.getpid()
                    or row['ppid'] in selected or identity in known):
                selected[pid] = row
                known.add(identity)
                changed = True
    return selected


def deliver(row, number):
    # A pidfd plus the recorded birth identity avoids signalling a recycled PID.
    try:
        descriptor = os.pidfd_open(row['pid'])
    except ProcessLookupError:
        return False
    try:
        current = process_table().get(row['pid'])
        if current is not None and current['start_ticks'] == row['start_ticks']:
            signal.pidfd_send_signal(descriptor, number)
            return True
    except ProcessLookupError:
        pass
    finally:
        os.close(descriptor)
    return False


def observe_exit(pid):
    # Keep the leader reserved until all final child/cleanup observations finish.
    result = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is None:
        return None
    return (result.si_status if result.si_code == os.CLD_EXITED
            else 128 + result.si_status)


def supervise(command, output, timeout, shutdown, cleanup, snapshot_interval):
    if sys.platform != 'linux':
        raise RuntimeError('Linux /proc and pidfd support are required')
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        raise RuntimeError('Linux pidfd support is required')
    # Chrome crash handlers may create their own session; process groups alone
    # cannot prove that those children exited after the launcher exits.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise RuntimeError('Cannot establish child subreaper')
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    stopped = []
    previous = {}
    echo_blocking = {}
    for descriptor in ECHO_DESCRIPTORS.values():
        try:
            echo_blocking[descriptor] = os.get_blocking(descriptor)
        except OSError:
            pass
    for number in (signal.SIGINT, signal.SIGTERM):
        previous[number] = signal.signal(number, lambda number, frame: stopped.append(number))
    child = None
    known = set()
    forced = False
    failure = None
    cli_exit = None
    remaining = {}
    stdout_eof = stderr_eof = False
    with (output / 'events.jsonl').open('w') as events, \
            (output / 'processes.jsonl').open('w') as snapshots, \
            (output / 'stdout.log').open('wb') as stdout, \
            (output / 'stderr.log').open('wb') as stderr, \
            selectors.DefaultSelector() as selector:
        def record(kind, **values):
            events.write(json.dumps({
                'event': kind, 'utc': datetime.now(timezone.utc).isoformat(),
                'elapsed_seconds': round(time.monotonic() - started, 3), **values,
            }) + '\n')
            events.flush()

        def snapshot(reason, reserved=True):
            rows = owned_processes(process_table(), child.pid if reserved else None, known)
            snapshots.write(json.dumps({
                'reason': reason, 'elapsed_seconds': round(time.monotonic() - started, 3),
                'processes': list(rows.values()),
            }) + '\n')
            snapshots.flush()
            return rows

        try:
            child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True, bufsize=0)
            record('command_started', pid=child.pid, pgid=child.pid)
            for name, stream, sink in [('stdout', child.stdout, stdout), ('stderr', child.stderr, stderr)]:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, (name, sink))
            remaining = snapshot('command_started')
            next_snapshot = time.monotonic() + snapshot_interval
            shutdown_deadline = None
            cleanup_deadline = None
            kill_at = None
            totals = {'stdout': 0, 'stderr': 0}
            tails = {'stdout': b'', 'stderr': b''}
            reported = False
            delivered = set()
            while True:
                now = time.monotonic()
                if cli_exit is None:
                    cli_exit = observe_exit(child.pid)
                    if cli_exit is not None:
                        record('cli_exit', exit_code=cli_exit)
                        shutdown_deadline = now + shutdown
                        remaining = snapshot('cli_exit')
                remaining = owned_processes(process_table(), child.pid, known)
                # Reap adopted descendants only; the CLI reservation stays held.
                for pid, row in list(remaining.items()):
                    if pid != child.pid and row['state'] == 'Z':
                        try:
                            os.waitpid(pid, os.WNOHANG)
                        except ChildProcessError:
                            pass
                live = [row for row in remaining.values() if row['state'] != 'Z']
                if now >= next_snapshot:
                    remaining = snapshot('periodic')
                    next_snapshot = now + snapshot_interval
                if failure is None:
                    if stopped:
                        failure = 'supervisor_signal'
                    elif cli_exit is None and now - started >= timeout:
                        failure = 'command_timeout'
                    elif shutdown_deadline is not None and now >= shutdown_deadline:
                        failure = 'shutdown_timeout'
                    if failure is not None:
                        record('failure', reason=failure)
                if failure is not None and cleanup_deadline is None:
                    remaining = snapshot('before_cleanup')
                    forced = bool(live or selector.get_map())
                    record('cleanup_started', forced=forced)
                    cleanup_deadline = now + cleanup
                    kill_at = now + cleanup / 2
                if cleanup_deadline is not None:
                    for row in live:
                        number = signal.SIGKILL if now >= kill_at else signal.SIGTERM
                        delivery = (row['pid'], row['start_ticks'], number)
                        if delivery not in delivered:
                            if deliver(row, number):
                                record('cleanup_signal', pid=row['pid'], signal=number)
                            delivered.add(delivery)
                    if now >= cleanup_deadline:
                        remaining = snapshot('cleanup_deadline')
                        break
                if cli_exit is not None and not selector.get_map() and not live:
                    remaining = snapshot('owned_children_exited')
                    record('owned_children_exited')
                    break
                for key, _ in selector.select(0.05):
                    name, sink = key.data
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        if name == 'stdout':
                            stdout_eof = True
                        else:
                            stderr_eof = True
                        record('output_eof', stream=name)
                        continue
                    totals[name] += len(chunk)
                    if totals[name] > 8 * 1024 * 1024:
                        if failure is None:
                            failure = 'output_limit'
                            record('failure', reason=failure)
                        continue
                    sink.write(chunk)
                    sink.flush()
                    echo(name, chunk)
                    tails[name] = (tails[name] + chunk)[-1024:]
                    if not reported and re.search(SUMMARY_PATTERN, tails[name]):
                        reported = True
                        record('reporter_summary_observed', stream=name)
                        snapshot('reporter_summary_observed')
        except Exception as error:
            failure = failure or 'supervisor_error'
            record('supervisor_error', error_type=type(error).__name__)
            if child is not None:
                forced = True
                deadline = time.monotonic() + cleanup
                while time.monotonic() < deadline:
                    remaining = snapshot('error_cleanup')
                    live = [row for row in remaining.values() if row['state'] != 'Z']
                    if not live:
                        break
                    for row in live:
                        deliver(row, signal.SIGKILL)
                    time.sleep(0.05)
        finally:
            if child is not None:
                if cli_exit is None:
                    cli_exit = observe_exit(child.pid)
                    if cli_exit is not None:
                        record('cli_exit', exit_code=cli_exit)
                remaining = snapshot('final')
                if cli_exit is not None:
                    child.wait()
                for pid in remaining:
                    if pid != child.pid:
                        try:
                            os.waitpid(pid, os.WNOHANG)
                        except ChildProcessError:
                            pass
                remaining = snapshot('after_reap', reserved=cli_exit is None)
                child.stdout.close()
                child.stderr.close()
            for number, handler in previous.items():
                signal.signal(number, handler)
            # O_NONBLOCK lives on the open file description shared with the caller.
            for descriptor, blocking in echo_blocking.items():
                try:
                    os.set_blocking(descriptor, blocking)
                except OSError:
                    pass
        survivors = [row['pid'] for row in remaining.values() if row['state'] != 'Z']
        if stopped:
            exit_code = 128 + stopped[0]
        elif failure == 'command_timeout':
            exit_code = 124
        elif failure is not None or forced or survivors or not (stdout_eof and stderr_eof):
            exit_code = 125
        else:
            exit_code = cli_exit if cli_exit is not None else 125
        result = {
            'exit_code': exit_code, 'cli_exit_code': cli_exit,
            'stdout_eof': stdout_eof, 'stderr_eof': stderr_eof,
            'forced_cleanup': forced, 'owned_processes_remaining': survivors,
            'failure_reason': failure, 'passed': exit_code == 0,
        }
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        record('supervisor_exit', **result)
        return exit_code


def positive_seconds(text):
    value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError('Use a finite positive duration')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=positive_seconds, default=180)
    parser.add_argument('--shutdown-seconds', type=positive_seconds, default=5)
    parser.add_argument('--cleanup-seconds', type=positive_seconds, default=5)
    parser.add_argument('--snapshot-seconds', type=positive_seconds, default=10)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A command after -- is required')
    try:
        return supervise(command, args.output_dir, args.timeout_seconds,
                         args.shutdown_seconds, args.cleanup_seconds, args.snapshot_seconds)
    except Exception:
        # A stalled CI output pipe must not delay failure or process retirement.
        return 125


if __name__ == '__main__':
    sys.exit(main())
