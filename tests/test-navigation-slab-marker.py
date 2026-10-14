#!/usr/bin/env python3
"""The navigation strip's marker covers a thick slab's images.

The red marker of the current image on the strip above the 2D viewport was
3 pt wide whatever the viewer showed; with a MIP, MinIP, mean or volume
rendering slab of N images the current image stands for N of them, and the
marker now covers them: from the current image towards the end of the strip,
as many as the series still has. The strip is flipped with the data, and so
is the slab (DCMPix folds the images below the current one when the data is
flipped), so in the strip's own order the slab always runs forward.

ImageNavigationSlider, compiled with HorosCellSlider: the marker's span for
one image, a slab, a slab at the end of the series and a single-image series.
In the sources: the controller gives the strip the slab's size whenever it
moves the strip, and DCMView's setFusion, where every change of thick slab
mode or thickness ends, moves it.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []

driver = r'''
import AppKit
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
// 100 images over a 200 pt bar from x = 1: 2 pt per image.
let bar = NSRect(x: 1, y: 0, width: 200, height: 6)
let one = ImageNavigationSlider.markerSpan(index: 10, slab: 1, count: 100, bar: bar)
check(near(one.lowerBound, 20.5) && near(one.upperBound, 23.5), "one image: \(one), not 3 pt centred on the image")
let slab = ImageNavigationSlider.markerSpan(index: 10, slab: 5, count: 100, bar: bar)
check(near(slab.lowerBound, 21) && near(slab.upperBound, 31), "a slab of 5: \(slab), not images 10 to 14")
let last = ImageNavigationSlider.markerSpan(index: 98, slab: 5, count: 100, bar: bar)
check(near(last.lowerBound, 197) && near(last.upperBound, 201), "at the end: \(last), not images 98 and 99")
let narrow = ImageNavigationSlider.markerSpan(index: 0, slab: 2, count: 400, bar: bar)
check(near(narrow.upperBound - narrow.lowerBound, 3), "a slab narrower than the marker: \(narrow)")
let single = ImageNavigationSlider.markerSpan(index: 0, slab: 4, count: 1, bar: bar)
check(near(single.lowerBound, 99.5) && near(single.upperBound, 102.5), "a single image: \(single)")
let outside = ImageNavigationSlider.markerSpan(index: 140, slab: 1, count: 100, bar: bar)
check(outside == ImageNavigationSlider.markerSpan(index: 99, slab: 1, count: 100, bar: bar), "an index past the end: \(outside)")
let slider = ImageNavigationSlider(frame: NSRect(x: 0, y: 0, width: 202, height: 20))
check(slider.slabImageCount == 1, "a new strip has a slab")
slider.slabImageCount = 7
check(slider.slabImageCount == 7, "the strip keeps its slab")
print("PASS: one image, a slab, the end of the series, a narrow slab and a single image")
'''

with tempfile.TemporaryDirectory(prefix='horos-slab-marker-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'driver'
    build = subprocess.run(['xcrun', 'swiftc', '-o', str(binary), str(root / 'Horos/Sources/HorosCellSlider.swift'),
                            str(root / 'Horos/Sources/ImageNavigationSlider.swift'), str(folder / 'main.swift')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        failures.append('ImageNavigationSlider does not compile on its own')
    else:
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('the marker geometry')

slider = (root / 'Horos/Sources/ImageNavigationSlider.swift').read_text(encoding='utf-8')
if not re.search(r'Self\.markerSpan\(index: Int\(doubleValue\.rounded\(\)\), slab: slabImageCount,', slider):
    failures.append('the strip does not draw its marker from markerSpan')
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
adjust = viewer[viewer.index('- (void)adjustSlider'):]
adjust = adjust[:adjust.index('\n}')]
if '((HorosImageNavigationSlider*) slider).slabImageCount = MAX( [[imageView curDCM] stack], 1);' not in adjust:
    failures.append('adjustSlider does not give the strip the slab')
fusion = (root / 'Horos/Sources/DCMView+WindowLevel.swift').read_text(encoding='utf-8')
fusion = fusion[fusion.index('public dynamic func setFusion('):]
fusion = fusion[:fusion.index('\n    }\n')]
if 'viewer.imageView() === self' not in fusion or 'viewer.adjustSlider()' not in fusion:
    failures.append('a change of thick slab does not move the strip')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
