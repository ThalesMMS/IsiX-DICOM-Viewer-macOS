#!/usr/bin/env python3
"""The convolution workers run off the main thread without touching the viewer.

-[ViewerController applyConvolutionOnSource:], which the 3D viewers' "Apply a
filter" menu and the question about raw data before a 3D reconstruction run,
starts -applyConvolutionXYThread: and -applyConvolutionZThread: on worker
threads (NSThread). ViewerController is a window controller, isolated to the
main actor; the two methods, in a Swift extension, were isolated too, and the
Swift runtime checks the executor on entry: the first worker stopped the app
(dispatch_assert_queue in swift_task_isCurrentExecutor).

Checked in the sources of ViewerController+Convolution.swift:
- the two worker methods are nonisolated;
- their bodies read their dictionary only: no `self.`, no viewer accessor;
- applyConvolutionOnSource: fills the dictionaries with the pixel lists, the
  volumes and the lock (workerDictionary) on the main thread.

`<git revision>` as an optional argument reads that revision, the negative
control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
path = 'Horos/Sources/ViewerController+Convolution.swift'


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8')


def method(text, selector):
    """The declaration line and the braces of the @objc(selector) method; None if absent."""
    at = text.find(f'@objc({selector})')
    if at < 0:
        return None, None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[at:opening], text[opening + 1:index]
    return None, None


source = read(path)
for selector in ('applyConvolutionXYThread:', 'applyConvolutionZThread:'):
    declaration, body = method(source, selector)
    if body is None:
        failures.append(f'{selector} not found')
        continue
    if not re.search(r'\bnonisolated\s+func\b', declaration):
        failures.append(f'{selector} is isolated to the main actor, and runs on a worker thread')
    if re.search(r'(?<![.\w])self\b|\bhoros_', body):
        failures.append(f'{selector} reads the viewer from its worker thread')

_, start = method(source, 'applyConvolutionOnSource:')
if start is None or start.count('workerDictionary(self)') != 2:
    failures.append('applyConvolutionOnSource: does not hand both passes their dictionary')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the convolution workers are nonisolated and read only their dictionary')
