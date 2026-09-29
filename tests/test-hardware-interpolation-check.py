#!/usr/bin/env python3
"""The 32-bit pipeline check compares two captures, not one capture with nothing.

`-[AppController verifyHardwareInterpolation]` draws the same 2 x 2 image twice,
once without interpolation and once with it, and keeps the 32-bit pipeline only
when the two captures differ. Both captures were written into `gray_1`, and
`gray_2`, the one it was compared with, was never written: uninitialised memory
in Objective-C, zeros in the Swift translation (#839). The result said nothing
about the interpolation. The second capture now fills `gray_2`.

The method needs a window, a DCMView and the defaults of a running app, so the
source is read: each capture writes its own buffer, and the comparison reads
both.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

application = sources.source_text('AppController')
failures = []

start = application.find('@objc func verifyHardwareInterpolation() {')
if start < 0:
    sys.exit('FAIL: -verifyHardwareInterpolation is gone from AppController.swift')
body = application[start:application.index('\n    }\n', start)]

first_at = body.find('// pix 1: no interpolation')
second_at = body.find('// pix 2: interpolation')
eval_at = body.find('// eval results')
if min(first_at, second_at, eval_at) < 0 or not first_at < second_at < eval_at:
    sys.exit('FAIL: the two captures and the comparison are no longer where the test looks')

declarations = body[:first_at]
first = body[first_at:second_at]
second = body[second_at:eval_at]
comparison = body[eval_at:]

if 'var gray_2' not in declarations:
    failures.append('gray_2 is a constant, so nothing can fill it')

if '"NOINTERPOLATION")' not in first or 'set(true, forKey: "NOINTERPOLATION")' not in first:
    failures.append('the first capture is no longer the one without interpolation')
if 'set(false, forKey: "NOINTERPOLATION")' not in second:
    failures.append('the second capture is no longer the one with interpolation')

for text, own, other, what in ((first, 'gray_1[i] =', 'gray_2[i] =', 'first'),
                               (second, 'gray_2[i] =', 'gray_1[i] =', 'second')):
    if 'getRawPixelsViewWidth' not in text:
        failures.append('the %s capture is gone' % what)
    if own not in text:
        failures.append('the %s capture does not fill %s' % (what, own.split('[')[0]))
    if other in text:
        failures.append('the %s capture overwrites %s' % (what, other.split('[')[0]))

if 'gray_1[i]' not in comparison or 'gray_2[i]' not in comparison:
    failures.append('the comparison no longer reads both captures')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the 32-bit pipeline check compares the capture without interpolation with the one with it')
