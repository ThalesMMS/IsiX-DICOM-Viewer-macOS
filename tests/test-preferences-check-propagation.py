#!/usr/bin/env python3
"""A preference that did not change does not refresh the viewers.

Tiling, Sync, fusion and the hanging protocols set COPYSETTINGS around their
own work. The preferences check that follows used to call needsDisplayUpdate
on every 2D viewer for it, which re-applies the window to every image and so
loads, on the main thread, the images of a series still being loaded or
retrieved: a multi-second beachball after tiling a second window during a
DICOMweb retrieve. No viewer draws COPYSETTINGS, so the check leaves it alone;
the preferences that are drawn still refresh the viewers.

ROILengthUnit and ROILengthDecimals are registered as text ("0", "3"); read
with a typed NSNumber cast they were nil, so every check after any preference
was written (a window frame, the tiling) saw them change and refreshed every
viewer, with the same beachball. Numeric preferences are compared by value.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/AppController.swift').read_text()
start = source.index('@objc(runPreferencesUpdateCheck:) public func runPreferencesUpdateCheck(')
check = source[start:source.index('\n    }\n', source.index('v.needsDisplayUpdate()', start))]


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


if 'v.needsDisplayUpdate()' not in check:
    fail('the preferences check no longer refreshes the viewers at all')
for line in check.splitlines():
    if line.strip().startswith('//'):
        continue
    if re.search(r'forKey:\s*"COPYSETTINGS"', line):
        fail('the preferences check still reacts to COPYSETTINGS: ' + line.strip())
for line in check.splitlines():
    if re.search(r'previousDefaults\?\.value\(forKey: [^)]*\) as\? NSNumber', line):
        fail('a numeric preference is read with a typed cast, nil when registered as text: ' + line.strip())
for key in ('LengthPresentation.unitKey', 'LengthPresentation.decimalsKey', 'ROILabelContrast.backgroundOpacityKey', '"LabelFONTSIZE"'):
    if f'numberChanged({key})' not in check:
        fail(f'{key} is not compared by value')
import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
if default_preferences.registered().get('ROILengthUnit') != '0':
    print('note: ROILengthUnit is no longer registered as text; the comparison by value still holds')
for key in ('NOINTERPOLATION', 'SOFTWAREINTERPOLATION', 'ROITEXTNAMEONLY'):
    block = check[check.index(f'forKey: "{key}"'):]
    if 'refreshViewer = true' not in block[:block.index('}')]:
        fail(f'{key} no longer refreshes the viewers')
print('ok: COPYSETTINGS and unchanged numeric preferences leave the viewers alone; drawn preferences still refresh them')
