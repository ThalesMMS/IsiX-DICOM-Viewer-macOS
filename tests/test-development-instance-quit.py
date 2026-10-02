#!/usr/bin/env python3
"""One development instance per checkout, however it was launched.

`script/build_and_run.sh` quits the previous development instance before it
builds, so the isolated bundle and its private database have one process, and
`--verify` reports that process afterwards. `ps` reports the executable as it
was invoked: an instance started with a relative path
(`build/Development/...`) never equalled the absolute path, and two development
instances then ran at once with their panels tiled over the same screen.
Matching the last path components instead found the relative launch, but every
worktree ends in those same components, so the launcher of one checkout quit the
development instance of another and `--verify` accepted a foreign process.

The lookup therefore compares the file each process actually runs. This starts
four synthetic processes named as the bundles are -

- this checkout's bundle, by its absolute path;
- this checkout's bundle, by a relative path from the checkout;
- the development bundle of another worktree;
- an installed Isis DICOM Viewer.app -

and requires `list` to name exactly the first two, `quit` to end exactly those,
and the other worktree and the installed application to keep running. Both
launcher lookups and tools/native_app.py must go through this one lookup.
"""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
helper = root / 'script/development_process.py'
launcher = (root / 'script/build_and_run.sh').read_text()
failures = []


def report(condition, message):
    if not condition:
        failures.append(message)


report(launcher.count('script/development_process.py" quit "$DEV_APP/Contents/MacOS/$APP_NAME"') == 1,
       'the quit before the build does not use the checkout-specific lookup')
report(launcher.count('script/development_process.py" list "$DEV_APP/Contents/MacOS/$APP_NAME"') == 1,
       '--verify does not use the checkout-specific lookup')
report("split('/')[-4:]" not in launcher and "split('/')[-4:]" not in (root / 'tools/native_app.py').read_text(),
       'a process lookup still compares path components shared by every worktree')
report('development_process.development_processes(' in (root / 'tools/native_app.py').read_text(),
       'tools/native_app.py does not use the checkout-specific lookup')

BUNDLE = 'build/Development/HorosDevelopment.app/Contents/MacOS/Isis DICOM Viewer'
with tempfile.TemporaryDirectory(prefix='horos-development-process-') as directory:
    folder = Path(directory).resolve()
    source = folder / 'wait.c'
    source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
    program = folder / 'wait'
    subprocess.run(['xcrun', 'clang', str(source), '-o', str(program)], check=True, timeout=60)
    own = folder / 'checkout' / BUNDLE
    other = folder / 'other worktree' / BUNDLE
    installed = folder / 'Applications/Isis DICOM Viewer.app/Contents/MacOS/Isis DICOM Viewer'
    for executable in (own, other, installed):
        executable.parent.mkdir(parents=True)
        executable.write_bytes(program.read_bytes())
        executable.chmod(0o755)
    def start(command, cwd=None):
        # As the application is: not a child of whoever looks for it. A child
        # that ended would linger unreaped and still answer to its PID.
        output = subprocess.check_output(['/bin/sh', '-c', '"$0" >/dev/null 2>&1 & echo $!', command],
                                         cwd=cwd, text=True, timeout=30)
        return int(output)

    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    processes = {
        'absolute': start(str(own)),
        'relative': start(BUNDLE, cwd=str(folder / 'checkout')),
        'other worktree': start(str(other)),
        'installed': start(str(installed)),
    }
    try:
        time.sleep(0.5)
        commands = subprocess.check_output(['/bin/ps', '-o', 'comm=', '-p', str(processes['relative'])], text=True)
        report(commands.strip() == BUNDLE, 'the relative launch is not reported by its relative spelling: %r' % commands)

        listed = subprocess.run([sys.executable, str(helper), 'list', str(own)], capture_output=True, text=True, timeout=30)
        named = sorted(int(line.split(':')[1]) for line in listed.stdout.splitlines())
        report(listed.returncode == 0 and named == sorted(processes[name] for name in ('absolute', 'relative')),
               'list names %s, not this checkout\'s two instances' % named)
        # The same lookup from the other worktree names only its own instance.
        foreign = subprocess.run([sys.executable, str(helper), 'list', str(other)], capture_output=True, text=True, timeout=30)
        report(foreign.stdout.split() == ['Development', 'process:', str(processes['other worktree'])],
               'the other worktree does not find exactly its own instance: %r' % foreign.stdout)
        absent = subprocess.run([sys.executable, str(helper), 'list', str(folder / 'third' / BUNDLE)],
                                capture_output=True, text=True, timeout=30)
        report(absent.returncode == 1 and not absent.stdout, 'a checkout without an instance reports one')

        stopped = subprocess.run([sys.executable, str(helper), 'quit', str(own)], capture_output=True, text=True, timeout=60)
        report(stopped.returncode == 0, 'quit failed: ' + stopped.stderr)
        for name in ('absolute', 'relative'):
            report(not alive(processes[name]), 'the %s launch of this checkout survived the quit' % name)
        for name in ('other worktree', 'installed'):
            report(alive(processes[name]), 'quit ended the %s instance' % name)
        again = subprocess.run([sys.executable, str(helper), 'list', str(own)], capture_output=True, text=True, timeout=30)
        report(again.returncode == 1, 'an instance of this checkout is still listed after the quit')
    finally:
        for pid in processes.values():
            if alive(pid):
                os.kill(pid, signal.SIGKILL)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: absolute and relative launches of this checkout are found and quit; another worktree\'s '
      'development instance and the installed application are left running')
