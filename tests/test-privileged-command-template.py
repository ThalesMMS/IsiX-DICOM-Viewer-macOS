#!/usr/bin/env python3
"""The shell command that runs a privileged tool redirects its stderr only where
the caller asked for it.

AuthorizationExecuteWithPrivilegesStdErrAndPid runs the tool through
`/bin/sh -c <template> "" <tool> <arguments...>`. The template used to end in
`2>1` whenever the caller passed the same pipe for both streams, which every
caller did by passing none: the root shell then wrote a file named "1" in its
current directory, which the function had just set to the user's temporary
folder, and a clean-up removed any file named "1" there afterwards, a user's
own included. In a read-only directory that redirection would also keep the
tool from running.

Checked here, on any machine with a C compiler:
- the template function, compiled from the source, gives no redirection
  without an error pipe, `2>&1` for one pipe shared by both streams, and the
  fifo path for a separate error pipe;
- each template, run by /bin/sh with a tool that writes to both streams,
  runs the tool, puts the pid first on stdout, and leaves no file named "1";
  in a read-only directory (when not running as root, which ignores the
  permission) the tool still runs;
- the function creates and opens the error fifo only for a separate error
  pipe, no longer deletes a file named "1", and no longer changes the
  process's current directory.
"""
from pathlib import Path
import os
import shutil
import stat
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BLAuthentication+CAPI.m').read_bytes().decode('latin-1')
failures = []

# --- the function, as the source has it -----------------------------------------
start = source.find('static const char *IsiXPrivilegedCommandTemplate(')
end = source.find('\n}\n', start)
if start < 0 or end < 0:
    print('FAIL: IsiXPrivilegedCommandTemplate is not in BLAuthentication+CAPI.m')
    sys.exit(1)
function = source[start:end + 3]

body = source[source.find('OSStatus AuthorizationExecuteWithPrivilegesStdErrAndPid ('):]
if '2>1"' in source:
    failures.append('a command template still redirects stderr to a file named "1"')
if '@"1"' in body:
    failures.append('the function still deletes a file named "1" from the current directory')
if 'changeCurrentDirectoryPath' in body:
    failures.append('the function still changes the current directory of the whole process')
if 'IsiXPrivilegedCommandTemplate(errPipe != 0, errPipe != 0 && errPipe == communicationsPipe)' not in body:
    failures.append('the command template is not chosen from the pipes the caller passed')
for opening in ('if (separateErrorPipe) {\n        stderrfd = mkstemps', 'if (separateErrorPipe) {\n        stderrfd = open('):
    if opening not in body:
        failures.append('the error fifo is made or opened for other than a separate error pipe: ' + opening.split('\n')[0])

compiler = shutil.which('cc') or shutil.which('clang')
command = [compiler] if compiler else (['xcrun', 'clang'] if shutil.which('xcrun') else None)
if command is None:
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print('skipped: needs a C compiler to compile the template function', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
#include <stdio.h>
%s
int main(void) {
    printf("%%s\n%%s\n%%s\n", IsiXPrivilegedCommandTemplate(0, 0), IsiXPrivilegedCommandTemplate(1, 1),
           IsiXPrivilegedCommandTemplate(1, 0));
    return 0;
}
''' % function

with tempfile.TemporaryDirectory(prefix='horos-privileged-template-') as directory:
    work = Path(directory)
    (work / 'main.c').write_text(DRIVER)
    subprocess.run([*command, '-std=c11', '-Wall', '-Werror', str(work / 'main.c'), '-o', str(work / 'templates')],
                   check=True)
    none, shared, separate = subprocess.check_output([str(work / 'templates')], text=True).splitlines()
    if none != 'echo $$; "$@"':
        failures.append('without an error pipe the template is %r' % none)
    if shared != 'echo $$; "$@" 2>&1':
        failures.append('with one pipe for both streams the template is %r' % shared)
    if separate != 'echo $$; "$@" 2>%s':
        failures.append('with a separate error pipe the template is %r' % separate)

    # A tool that says where it ran and writes to both streams.
    tool = work / 'tool.sh'
    tool.write_text('#!/bin/sh\necho "ran $1"\necho "complaint" >&2\n')
    tool.chmod(0o755)

    def run(template, cwd, fifo=None):
        script = template % fifo if '%s' in template else template
        return subprocess.run(['/bin/sh', '-c', script, '', str(tool), 'argument'], cwd=cwd,
                              capture_output=True, text=True, timeout=30)

    for name, template in (('no error pipe', none), ('one shared pipe', shared)):
        cwd = work / name.replace(' ', '-')
        cwd.mkdir()
        outcome = run(template, cwd)
        lines = outcome.stdout.splitlines()
        if outcome.returncode or len(lines) < 2 or not lines[0].isdigit() or lines[1] != 'ran argument':
            failures.append('%s: the tool did not run after the pid line: %r' % (name, outcome.stdout + outcome.stderr))
        if (cwd / '1').exists():
            failures.append('%s: the command wrote a file named "1"' % name)
        if name == 'one shared pipe' and 'complaint' not in outcome.stdout:
            failures.append('one shared pipe: stderr did not join stdout')
        if name == 'no error pipe' and 'complaint' not in outcome.stderr:
            failures.append('no error pipe: stderr was not left as it is')

    separate_cwd = work / 'separate'
    separate_cwd.mkdir()
    errors = work / 'errors.txt'
    outcome = run(separate, separate_cwd, fifo=str(errors))
    if outcome.returncode or 'ran argument' not in outcome.stdout or errors.read_text().strip() != 'complaint':
        failures.append('a separate error pipe did not receive stderr: %r' % (outcome.stdout + outcome.stderr))

    # Where the shell's directory is read-only, as / is on current macOS, the
    # tool must still run. Root ignores the permission, so only a user checks it.
    if os.geteuid() != 0:
        locked = work / 'read-only'
        locked.mkdir()
        locked.chmod(stat.S_IRUSR | stat.S_IXUSR)
        try:
            outcome = run(none, locked)
            if 'ran argument' not in outcome.stdout:
                failures.append('in a read-only directory the tool did not run: %r' % (outcome.stdout + outcome.stderr))
            outcome = run('echo $$; "$@" 2>1', locked)
            if 'ran argument' in outcome.stdout:
                print('note: this shell ran the tool despite the failed "2>1" redirection')
        finally:
            locked.chmod(stat.S_IRWXU)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the privileged command redirects stderr only into the pipe the caller asked for, runs the tool '
      'where its directory is read-only, and leaves no file named "1"')
