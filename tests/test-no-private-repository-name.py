#!/usr/bin/env python3
"""Nothing that goes to the public checkout names the development repository.

The public tree is this one without the internal documentation, the local
validation folder and the files that configure the development agents. Every
other file, tracked or about to be, is read for the repository's name in any
case. A guard that has to refuse the name puts it together from parts, as this
test does, so that no file carries it.

The test first proves that its search finds the name in a file that has it.

`<git revision>` as an optional argument checks that revision instead, the
negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

NAME = '-'.join(('horos', 'work' + 'bench'))
# What the public checkout does not receive.
PRIVATE_PATHS = ['docs', 'local-validation', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'HANDOFF.md',
                 '.claude', '.codegraph', '.codex', '.cursor', '.gemini']


def search(arguments, cwd):
    result = subprocess.run(['git', 'grep', '-n', '-I', '-i', '-F', '-e', NAME, *arguments],
                            cwd=cwd, capture_output=True)
    if result.returncode not in (0, 1):
        print('FAIL: git grep: ' + result.stderr.decode('utf-8', 'replace').strip())
        sys.exit(1)
    return result.stdout.decode('utf-8', 'replace').splitlines()


with tempfile.TemporaryDirectory() as scratch:
    Path(scratch, 'clean.txt').write_text('git clone https://example.invalid/owner/viewer.git\n')
    Path(scratch, 'named.txt').write_text('cd ~/%s && make\n' % NAME.upper())
    control = search(['--no-index', '--', '.'], scratch)
    if len(control) != 1 or not control[0].startswith('named.txt:1:'):
        print('FAIL: the search does not find the name in a file that has it: %r' % control)
        sys.exit(1)

arguments = [revision] if revision else ['--untracked']
arguments += ['--', '.'] + [':(exclude,top)' + path for path in PRIVATE_PATHS]
hits = search(arguments, root)

for hit in hits[:20]:
    print('FAIL: ' + hit[:200].replace(NAME, '<name>'))
if hits:
    print('FAIL: %d line(s) of the public file set name the development repository' % len(hits))
    sys.exit(1)
print('PASS: no file outside %s names the development repository' % ', '.join(PRIVATE_PATHS))
