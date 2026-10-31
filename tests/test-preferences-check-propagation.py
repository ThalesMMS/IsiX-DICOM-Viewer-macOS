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
marks = (root / 'Modules/IsiXPreferences/Sources/PreferenceChange.swift').read_text()
responder = (root / 'Horos/Sources/PreferenceChangeResponder.swift').read_text()


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


def code(text):
    return '\n'.join(line for line in text.splitlines() if not line.strip().startswith('//'))


if not re.search(r'if change\.viewerRefresh \|\| change\.viewerReload \{[^}]*viewer\.needsDisplayUpdate\(\)', responder, re.S):
    fail('the preferences check no longer refreshes the viewers at all')
for text, name in ((marks, 'PreferenceChange'), (responder, 'PreferenceChangeResponder')):
    if re.search(r'COPYSETTINGS|\.copySettings\b', code(text)):
        fail(f'{name} still reacts to COPYSETTINGS')
if re.search(r'previous\[[^\]]*\] as\? NSNumber', marks):
    fail('a numeric preference is read with a typed cast, nil when registered as text')
for key in ('roiLengthUnit', 'roiLengthDecimals', 'roiLabelBackgroundOpacity', 'labelFONTSIZE'):
    if f'numberChanged(ViewerPreferences.{key})' not in marks:
        fail(f'{key} is not compared by value')
import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
if default_preferences.registered().get('ROILengthUnit') != '0':
    print('note: ROILengthUnit is no longer registered as text; the comparison by value still holds')
refresh = marks[marks.index('viewerRefresh = compared'):]
refresh = refresh[:refresh.index('viewerRedraw =')]
for key in ('noInterpolation', 'softwareInterpolation', 'roiTextNameOnly'):
    if f'ViewerPreferences.{key})' not in refresh:
        fail(f'{key} no longer refreshes the viewers')
print('ok: COPYSETTINGS and unchanged numeric preferences leave the viewers alone; drawn preferences still refresh them')
