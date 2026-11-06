#!/usr/bin/env python3
"""The convolution's shares run off the main thread without touching the viewer.

"Apply on source" of the 2D viewer (-[ViewerController applyConvolutionOnSource:],
which the 3D viewers' "Apply a filter" menu and the question about raw data
before a 3D reconstruction run) filters every slice on several cores. It once
started worker threads on ViewerController, a window controller isolated to the
main actor: the Swift runtime checks the executor on entry, and the first
worker stopped the app (dispatch_assert_queue in swift_task_isCurrentExecutor).
The work now goes to IsiXImaging's SeriesConvolution, whose shares run at once
and return together.

Checked in the sources:
- SeriesConvolution.perform takes a @Sendable body, which the compiler keeps
  off the main actor;
- the body ViewerColourTables.applyFilterToPixels hands it reads only the
  slices it was given (the Sendable snapshot made on the main thread): no
  `self`, no `viewer`;
- no worker thread or condition lock is left in the viewer's convolution.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def read(path):
    return (root / path).read_text(encoding='utf-8')


def braces(text, start):
    """The text between the brace at or after `start` and its partner."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    return None


series = read('Modules/IsiXImaging/Sources/BufferOperations/SeriesConvolution.swift')
if not re.search(r'func perform\(over count: Int, _ body: @Sendable \(Range<Int>\) -> Void\)', series):
    failures.append('SeriesConvolution.perform does not take a @Sendable body')

tables = read('Horos/Sources/ViewerColourTables.swift')
at = tables.find('func applyFilterToPixels(')
if at < 0:
    failures.append('ViewerColourTables.applyFilterToPixels not found')
else:
    method = braces(tables, at)
    call = method.find('.perform(over:')
    if call < 0:
        failures.append('applyFilterToPixels does not hand the slices to SeriesConvolution')
    else:
        body = braces(method, call)
        if re.search(r'(?<![.\w])(self|viewer)\b|\bhoros_', body):
            failures.append('the shares of apply on source read the viewer off the main thread')
        if 'slices.frames' not in body:
            failures.append('the shares of apply on source do not read their snapshot of the slices')

for path in ('Horos/Sources/ViewerColourTables.swift', 'Horos/Sources/ViewerController+Convolution.swift',
             'Horos/Sources/ViewerController+ProcessingState.swift'):
    text = read(path)
    if re.search(r'\bNSConditionLock\b.*conv|convThread|detachNewThread|applyConvolution(XY|Z)Thread', text):
        failures.append(f'{path} still has a convolution worker thread or its lock')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the convolution shares are Sendable and read only their snapshot of the slices')
