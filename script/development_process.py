#!/usr/bin/env python3
"""Find or quit the development instance that runs from one checkout.

usage: development_process.py list|quit EXECUTABLE

EXECUTABLE is the development executable of the calling checkout, for example
build/Development/HorosDevelopment.app/Contents/MacOS/Horos.

`ps` reports an executable as it was invoked, so an instance started by a
relative path does not equal the absolute one, and every worktree ends in the
same build/Development/... components. Comparing the spelling either misses the
relative launch or takes the instance of another worktree for this one. The
kernel knows which file each process runs: that path, resolved, is compared
with the resolved EXECUTABLE, so only this checkout's bundle matches - not the
installed application and not another checkout's development bundle.

list prints "Development process: PID" per match and exits 1 without one.
quit sends SIGTERM to each match and waits for it to end, exiting 1 if one stays.
"""
import ctypes
import os
import signal
import subprocess
import sys
import time

PROC_PIDPATHINFO_MAXSIZE = 4096
_libc = ctypes.CDLL(None, use_errno=True)


def running_executable(pid):
    """The resolved path of the file PID executes, or None when it cannot be read."""
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = _libc.proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        return None
    return os.path.realpath(os.fsdecode(buffer.raw[:length]))


def development_processes(executable):
    target = os.path.realpath(executable)
    name = os.path.basename(target)
    matches = []
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or os.path.basename(parts[1]) != name:
            continue
        pid = int(parts[0])
        path = running_executable(pid)
        # Without the kernel's answer only the exact absolute spelling is this
        # bundle for certain; a shared suffix is not.
        if path == target or (path is None and parts[1] == target):
            matches.append(pid)
    return matches


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('list', 'quit'):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    matches = development_processes(sys.argv[2])
    if sys.argv[1] == 'list':
        for pid in matches:
            print('Development process:', pid)
        return 0 if matches else 1
    for pid in matches:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            print('Development process did not stop; build not started.', file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
