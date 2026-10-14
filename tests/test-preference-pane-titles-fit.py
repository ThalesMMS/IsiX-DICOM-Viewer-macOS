#!/usr/bin/env python3
"""Every title of a preference pane fits its control, in every language of the pane.

Titles of the preference panes were cut with an ellipsis or lost their end, in
English and more in the translations: in the Listener pane the C-GET and C-FIND
checkboxes both read "Активировать поддержку…" in Russian. A pane keeps one
geometry for every language, so a fix widens controls where the pane has room,
moves some to make it, and shortens (or corrects) the translations that still
do not fit.

Each variant of a pane is compiled and loaded (tests/pane_titles.py) without its
bindings, so that controls a binding hides are measured too, except for the
text a binding provides. A label on one line fits when it needs at most 3
points more than its frame, the padding AppKit counts in, and a button,
checkbox or radio button when it needs no more than its frame; a wrapped label
fits when its lines, and its longest word, fit the frame. The radio buttons of
a matrix are measured in their cells, and a box's title in the box. Two
controls of the same view may not overlap in what they draw.

PANES lists the panes whose titles have been made to fit.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_titles  # noqa: E402

# Controls in one place that the pane shows one at a time, in code: CIALayoutController
# shows "Same as Default" for a modality and "Reset" for the default layout.
ALTERNATES = {
    'OSICustomImageAnnotations.xib': [{'495', '586'}],
}

PANES = [
    'OSIListenerPreferencePanePref.xib',
    'OSIHotKeysPref.xib',
    'OSIHangingPreferencePanePref.xib',
    'OSIAutoroutingPreferencePanePref.xib',
    'OSICDPreferencePanePref.xib',
    'OSICustomImageAnnotations.xib',
    'OSIGeneralPreferencePanePref.xib',
    'OSI3DPreferencePanePref.xib',
    'OSIPACSOnDemand.xib',
    'AYDicomPrintPref.xib',
    'OSIPETPreferencePanePref.xib',
    'OSILocationsPreferencePanePref.xib',
    'OSIWebSharingPreferencePanePref.xib',
    'OSIViewerPreferencePanePref.xib',
    'OSIDatabasePreferencePanePref.xib',
]

if not pane_titles.available():
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(2)

failures, counted = [], 0
for name in PANES:
    variants = pane_titles.variants(name)
    measured = [item for item in pane_titles.measure(variants)
                if not ('overlap' in item and set(item['overlap']) in ALTERNATES.get(name, []))]
    counted += len(measured)
    failures += [f'{name}: {failure}' for failure in pane_titles.misfits(measured)]
    languages = {item['language'] for item in measured}
    if len(languages) != len(variants):
        failures.append(f'{name}: only {sorted(languages)} of its {len(variants)} variants were measured')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: {counted} titles fit their controls in every language of {len(PANES)} preference panes')
