#!/usr/bin/env python3
"""The orthogonal MPR fuses one thickness in its three views and shows it in millimeters.

The window's slider counted images, 2 to 128 whatever the series, beside a
field that wrote the count, and the three views fused different thicknesses:
the original view the images asked for, cut at the series' end, and the
reformatted ones trunc(N x interval / pixel) rows, with no slice thickness
and no end, by one count for both axes.

Source-level contract:

- -setFusion takes the thickness from the scale of the original view
  (StackFusionScale, two images at least) and gives each reformatted view the
  rows or columns of that thickness (OrthogonalThickSlab.reslicedCount); it
  neither uses -thickSlabDistance nor writes the preference;
- the reslicer has a count for each axis, and -setThickSlab: still sets both;
- the crossing after a change of thickness goes through
  OrthogonalThickSlab.crossIndex, which keeps it inside the series;
- the reslicer's slab ends past the last row or column, and the Y
  reformation's slices are a column apart;
- the window keeps the images asked for, writes them (never 0, never the
  slider's value) to the preference, and its field shows the scale's text;
- the selectors plugins call are still declared.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], check=True, capture_output=True, text=True).stdout
    return (root / path).read_text()


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    depth = 0
    for index in range(text.index('{', at), len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return ''


def check(ok, message):
    if not ok:
        failures.append(message)


controller = code(read('Horos/Sources/OrthogonalMPRController.swift'))
viewer = code(read('Horos/Sources/OrthogonalMPRViewer.swift'))
reslicer = code(read('Horos/Sources/OrthogonalReslice.swift'))
view = code(read('Horos/Sources/OrthogonalMPRView.swift'))

fusion = block(controller, 'public dynamic func setFusion()')
counts = block(controller, 'private func slabCounts()')
scale = block(controller, 'func slabScale()')
apply = block(controller, 'private func applySlab(')
check('thickSlabDistance()' not in fusion + counts + apply, '-setFusion still measures the slab by -thickSlabDistance')
check('stackThicknessOrthogonalMPR' not in fusion, '-setFusion writes the preference, 0 when the slab is off')
check('minimumImages: 2' in scale and 'StackFusionScale(' in scale, 'the slab has no scale of two images at least')
for axis in ('pixelSpacingY', 'pixelSpacingX'):
    check(f'OrthogonalThickSlab.reslicedCount(thickness: thickness, pixelSpacing: pix.{axis})' in counts, f'no count of the thickness along {axis}')
check('setXThickSlab(Int16(truncatingIfNeeded: counts.rows), yThickSlab: Int16(truncatingIfNeeded: counts.columns))' in apply,
      'the reslicer is not given a count for each axis')
check('_originalView?.setThickSlabXY(band(counts.columns), band(counts.rows))' in apply, "the original view's bands do not have the count of their axis")
reslice = block(controller, 'public dynamic func reslice(_ x: Int, _ y: Int, _ sender: OrthogonalMPRView!)')
check('OrthogonalThickSlab.crossIndex(firstImage: first, requestedSlices: Int(curDCM?.stack ?? 0), count: count)' in reslice,
      'the crossing after a change of thickness is not kept inside the series')
check('followSlab()' in reslice, 'a reslice does not follow the slab of the image shown')

check('@objc(setXThickSlab:yThickSlab:)' in reslicer and '@objc public var yThickSlab: Int16' in reslicer, 'the reslicer has no count for each axis')
setter = block(reslicer, '@objc(setThickSlab:) set')
check('_thickSlab = newValue' in setter and '_yThickSlab = newValue' in setter, '-[OrthogonalReslice setThickSlab:] does not set both counts')
check('if maxI > newTotal {' in reslicer and 'maxI = newTotal\n' in reslicer, "the reslicer's slab stops before the last row or column")
check('curPix.sliceInterval = firstPix.pixelSpacingX' in reslicer, "the Y reformation's slices are not a column apart")

setter = block(viewer, 'public dynamic func setThickSlab(_ sender: Any!)')
check('String(format: "%d"' not in setter, '-[OrthogonalMPRViewer setThickSlab:] writes a count of images in the field')
check('slabBar.take(Int(intValueOf(sender)), from: sender, slider: thickSlabSlider' in setter,
      '-[OrthogonalMPRViewer setThickSlab:] no longer takes a sender whose intValue is images')
check('slabBar.requested, for: ReconstructionPreferences.stackThicknessOrthogonalMPR' in setter, 'a thickness picked is not written to the preference')
bar = code(read('Horos/Sources/HorosThickSlabSlider.swift'))
shown = block(bar, 'func show(_ scale: StackFusionScale?')
check('field?.stringValue = scale?.text(requested: requested)' in shown and 'stackScale = scale' in shown,
      "the field and the slider's bubble do not share the scale's text")
check('let asked = max(2, fromSlider ? slider?.integerValue ?? 2 : images)' in block(bar, 'mutating func take('), 'a request is not two images at least')
deinit = block(viewer, 'isolated deinit')
check('thickSlabSlider' not in deinit and 'slabBar.requested, for: ReconstructionPreferences.stackThicknessOrthogonalMPR' in deinit,
      "the window's closing writes the slider's value, not the images asked for")
check('var slabRows: ClosedRange<Int>?' in view, 'the reformatted views cannot be given the rows fused')

for text, names in ((controller, ('@objc(setThickSlab:)', '@objc(thickSlab)', '@objc(maxThickSlab)', '@objc(thickSlabDistance)', '@objc(setFusion)',
                                  '@objc(setThickSlabMode:)')),
                    (view, ('@objc(setThickSlabXY::)',)),
                    (viewer, ('@objc(activateThickSlab:)', '@objc(setThickSlab:)', '@objc(setThickSlabMode:)')),
                    (reslicer, ('@objc public var thickSlab: Int16', '@objc(setThickSlab:)', 'axeReslice', 'func xReslice(', 'func yReslice(', 'func reslice('))):
    for name in names:
        check(name in text, f'{name} is no longer declared')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the orthogonal MPR fuses one thickness by a count for each axis, keeps its crossing inside the series, '
      'takes the last row and column, and shows the images asked for in millimeters')
