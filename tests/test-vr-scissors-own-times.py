#!/usr/bin/env python3
"""The scissors of a 3D window cut every time of the window's own volume.

The cut went through the times of the 2D viewer (-maxMovieIndex of
-viewer2D). A 3D window without a 2D viewer, as a plugin opens it, has none:
the loop ran no time and the scissors cut nothing. And after the 2D viewer
loaded a series of another number of times the window still held its own
volumes: -setMovieFrame: wrapped around, some times were cut twice and others
not at all. The loop is bounded by the window's own count
(VRController.maxMovieIndex), the one -setMovieFrame: and -curPixList follow.

    python3 tests/test-vr-scissors-own-times.py [<git revision>]

A revision reads the source from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/VRView+Scissors.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
if revision:
    source = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{PATH}'], capture_output=True, check=True).stdout.decode('utf-8')
else:
    source = (ROOT / PATH).read_text(encoding='utf-8')
code = '\n'.join(line for line in source.splitlines() if not line.strip().startswith('//'))

failures = []
loops = re.findall(r'while m < Int\(([^\n]*)\) \{\s*controller\.setMovieFrame\(m\)', code)
if len(loops) != 1:
    failures.append(f'the cut goes through the times in {len(loops)} loops; the test needs a new look')
elif loops[0] != 'controller.maxMovieIndex':
    failures.append(f'the cut goes through {loops[0]} times, not the times of the window\'s own volume')
if re.search(r'viewer2D\(\)\?\.maxMovieIndex\(\)', code):
    failures.append('the scissors count the times of the 2D viewer, which a window without one does not have')
controller = (ROOT / 'Horos/Sources/VRController.swift').read_text(encoding='utf-8')
if not re.search(r'final var maxMovieIndex: Int16', controller):
    failures.append('VRController no longer holds its own count of times; the test needs a new look')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the scissors cut every time of the 3D window\'s own volume, with or without a 2D viewer')
