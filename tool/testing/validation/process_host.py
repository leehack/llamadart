"""Bounded subprocess host. No shell, credentials, or command text in errors."""
import ctypes
import os
import signal
import shutil
import subprocess
import sys
import threading
import time


def main():
    terminated = threading.Event()
    def request_stop(signum, frame):
        terminated.set()
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    seconds = float(sys.argv[1])
    arguments = sys.argv[2:]
    job = None
    kernel = None
    if os.name == 'nt':
        # A job retains descendants even when the immediate launcher exits.
        from ctypes import wintypes
        class Basic(ctypes.Structure):
            _fields_ = [('PerProcessUserTimeLimit', ctypes.c_longlong), ('PerJobUserTimeLimit', ctypes.c_longlong),
                        ('LimitFlags', wintypes.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                        ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wintypes.DWORD),
                        ('Affinity', ctypes.c_size_t), ('PriorityClass', wintypes.DWORD), ('SchedulingClass', wintypes.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in ('ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount', 'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]
        class Limits(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', Basic), ('IoInfo', IO), ('ProcessMemoryLimit', ctypes.c_size_t), ('JobMemoryLimit', ctypes.c_size_t), ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        job = kernel.CreateJobObjectW(None, None)
        limits = Limits()
        limits.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        if not job or not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise RuntimeError('Cannot establish subprocess job')
        # Flutter/Gradle/gcloud are batch launchers on Windows. Resolve PATHEXT
        # first, quote every argument, and reject cmd expansion syntax.
        arguments[0] = shutil.which(arguments[0]) or arguments[0]
        if arguments[0].lower().endswith(('.bat', '.cmd')):
            if any(any(c in arg for c in ('"', '%', '!', '\r', '\n')) for arg in arguments):
                raise ValueError('Unsafe Windows batch argument')
            quoted = ' '.join('"' + arg + '"' for arg in arguments)
            arguments = '"' + os.environ.get('COMSPEC', 'cmd.exe') + '" /d /v:off /s /c "' + quoted + '"'
    child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=os.name != 'nt')
    if job and not kernel.AssignProcessToJobObject(job, int(child._handle)):
        child.kill()
        child.wait()
        kernel.CloseHandle(job)
        raise RuntimeError('Cannot contain subprocess descendants')
    overflow = threading.Event()
    def copy(stream, sink):
        total = 0
        while True:
            chunk = stream.read(4096)
            if not chunk:
                return
            total += len(chunk)
            if total > 8 * 1024 * 1024:
                overflow.set()
                return
            sink.buffer.write(chunk)
            sink.buffer.flush()
    readers = [threading.Thread(target=copy, args=(child.stdout, sys.stdout), daemon=True),
               threading.Thread(target=copy, args=(child.stderr, sys.stderr), daemon=True)]
    for reader in readers:
        reader.start()
    deadline = time.monotonic() + seconds
    code = 125
    try:
        while child.poll() is None or any(reader.is_alive() for reader in readers):
            if terminated.is_set():
                return 143
            if overflow.is_set():
                return 125
            if time.monotonic() >= deadline:
                return 124
            time.sleep(0.02)
        code = child.returncode
        return code
    finally:
        if job:
            kernel.CloseHandle(job)
        elif os.name != 'nt':
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif child.poll() is None:
            child.kill()
        child.wait(timeout=5)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Subprocess host failed (' + type(error).__name__ + ')', file=sys.stderr)
        sys.exit(125)
