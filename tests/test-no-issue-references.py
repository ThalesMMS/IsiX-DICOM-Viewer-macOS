#!/usr/bin/env python3
"""Code, comments, scripts, tests, tools, resources, README and NOTICE do not
cite issues of this project, by number (#770) or by link.

A comment says what the code does and why; an issue number sends the reader
to a tracker the public checkout does not have. Not references, and allowed:
hexadecimal colours, HTML entities, references to other projects' trackers
written with their owner (horosproject/horos#531), and the upstream Horos
release notes kept in Binaries/Splash/releasenotes.html.

`<git revision>` as an optional argument checks that revision instead, the
negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

SCOPE = ['Horos', 'Nitrogen', 'DCM Framework', 'script', 'tools', 'tests', 'README.md', 'NOTICE', 'Binaries']
# Upstream Horos's own release history, with the numbers of its own tracker.
ALLOWED_FILES = {'Binaries/Splash/releasenotes.html'}
PATTERNS = [
    r'(?<![&\w/])#\d{2,4}(?!\w)',
    r'(?i)\bissues?[-_ /]#?\d{2,4}\b',
    r'(?i)github\.com/ThalesMMS/(?:horos|horos-workbench)/(?:issues|pull)/\d+',
]

command = ['git', '-C', str(root), 'grep', '-n', '-I', '-P', '-e', PATTERNS[0], '-e', PATTERNS[1], '-e', PATTERNS[2]]
if revision:
    command.append(revision)
command += ['--', *SCOPE]
output = subprocess.run(command, capture_output=True).stdout.decode('utf-8', 'replace')

hits = []
for line in output.splitlines():
    path = line.split(':', 2)[1] if revision else line.split(':', 1)[0]
    if path in ALLOWED_FILES or path == 'tests/test-no-issue-references.py':
        continue
    text = line.split(':', 3 if revision else 2)[-1]
    # A hexadecimal colour (#fff, #a0a0a0) is not a number of four digits or less
    # unless it is all digits; those with a letter never match \d{2,4}(?!\w).
    if re.search(r'#[0-9]{3}(?:[0-9]{3})?\b', text) and re.search(r'(?i)(colou?r|rgb|fill|stroke|background)', text):
        continue
    hits.append(line)

for hit in hits[:20]:
    print(f'FAIL: {hit[:200]}')
if hits:
    print(f'FAIL: {len(hits)} issue reference(s)')
    sys.exit(1)
print('PASS: no issue references in code, comments, scripts, tests, tools, resources, README or NOTICE')
