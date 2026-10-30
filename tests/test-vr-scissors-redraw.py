#!/usr/bin/env python3
"""The 3D scissors show their cut at once, without moving the camera.

-[VRView deleteRegion:::], which Return (include), Delete (exclude) and Tab
(restore) run with the scissors tool, draws a frame before cutting and asked
for the cut one with -setNeedsDisplay:. The picture layer presents with the
Core Animation transaction, and a frame drawn in the display pass of the
transaction that already holds a presented frame does not reach the screen:
the outline went away with the overlay, but the volume stayed uncut until the
camera moved. Of two frames drawn with -display in one transaction, the last
one is shown.

Checked in the sources:
- the picture layer of VRView presents with the transaction (the premise);
- -deleteRegion::: still draws the frame before the cut;
- after the outline is deleted, it draws the cut frame with -display, and does
  not leave the frame to -setNeedsDisplay: after the cut.

`<git revision>` as an optional argument reads that revision, the negative
control.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('latin1')


def body(text, signature):
    """The braces of the method whose line starts with `signature`, without them; None if absent."""
    at = text.find('\n' + signature)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    return None


def code(text):
    """`text` without its // comments."""
    return '\n'.join(line.split('//', 1)[0] for line in text.splitlines())


try:
    view = read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift).
    view = ''

# The picture layer is Swift (VRView+Render.swift), an extension of VRView.
view_render = read('Horos/Sources/VRView+Render.swift')
picture_layer = view_render[view_render.find('func horosPictureLayer() -> CAMetalLayer?'):]
if 'created.presentsWithTransaction = true' not in picture_layer[:picture_layer.find('\n    }\n')]:
    failures.append('the picture layer no longer presents with the transaction: the premise of this check changed')

cut = body(view, '- (void) deleteRegion:(int) c :(NSArray*) pxList :(BOOL) blendedSeries')
display, cleared_text, redraw = '[self display]', '[ROIPoints removeAllObjects]', 'setNeedsDisplay'
if cut is None and '- (void) deleteRegion:' not in view:
    # The cut is Swift (VRView+Scissors.swift), an extension of VRView.
    cut = body(read('Horos/Sources/VRView+Scissors.swift'), '    func deleteRegion(_ c: Int32, _ pxList: NSArray, _ blendedSeries: Bool)')
    display, cleared_text, redraw = 'display()', 'horos_ROIPoints?.removeAllObjects()', 'needsDisplay'
if cut is None:
    failures.append('-[VRView deleteRegion:::] not found')
else:
    cut = code(cut)
    loop = cut.find('waitUntilAllOperationsAreFinished')
    cleared = cut.find(cleared_text)
    if loop < 0 or cleared < 0:
        failures.append('the cut loop or the outline deletion of -deleteRegion::: not found')
    else:
        if display not in cut[:loop]:
            failures.append('-deleteRegion::: no longer draws the frame before the cut')
        if display not in cut[cleared:]:
            failures.append('-deleteRegion::: does not draw the cut frame with -display after deleting the outline')
        if redraw in cut[loop:]:
            failures.append('-deleteRegion::: leaves the cut frame to -setNeedsDisplay:, which the screen never shows')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the scissors draw the cut frame with -display after deleting the outline')
