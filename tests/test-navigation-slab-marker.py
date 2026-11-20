#!/usr/bin/env python3
"""The navigation strip's marker covers a thick slab's images.

The red marker of the current image on the strip above the 2D viewport was
3 pt wide whatever the viewer showed; with a MIP, MinIP, mean or volume
rendering slab of N images the current image stands for N of them, and the
marker covers them: the slab is centred on the current image, with the image
more of an even slab towards the end of the strip, and is kept inside the
series at both ends, so the marker is as wide on every image and stops where
the slab does. The strip is flipped with the data, and so is the slab (DCMPix
turns it the other way when the data is flipped), so in the strip's own order
the slab always goes forward.

ImageNavigationSlider, compiled with HorosCellSlider and IsiXImaging, whose
ThickSlabSpan is the rule: the marker's span for one image, an odd and an
even slab, a slab at either end of the series, a slab of more images than the
series and a single-image series. In the sources: the controller gives the
strip the slab's size whenever it moves the strip, and DCMView's setFusion,
where every change of thick slab mode or thickness ends, moves it.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import isix_modules
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
check(near(slab.lowerBound, 17) && near(slab.upperBound, 27), "a slab of 5: \(slab), not images 8 to 12")
let even = ImageNavigationSlider.markerSpan(index: 10, slab: 4, count: 100, bar: bar)
check(near(even.lowerBound, 19) && near(even.upperBound, 27), "a slab of 4: \(even), not images 9 to 12")
// At either end the slab is kept inside the series: as wide as anywhere, and still while the image goes on.
for index in 97...99 {
    let last = ImageNavigationSlider.markerSpan(index: index, slab: 5, count: 100, bar: bar)
    check(near(last.lowerBound, 191) && near(last.upperBound, 201), "at the end, image \(index): \(last), not images 95 to 99")
}
for index in 0...2 {
    let first = ImageNavigationSlider.markerSpan(index: index, slab: 5, count: 100, bar: bar)
    check(near(first.lowerBound, 1) && near(first.upperBound, 11), "at the start, image \(index): \(first), not images 0 to 4")
}
let widths = (0..<100).map { index -> CGFloat in
    let span = ImageNavigationSlider.markerSpan(index: index, slab: 7, count: 100, bar: bar)
    return span.upperBound - span.lowerBound
}
check(widths.allSatisfy { near($0, 14) }, "a slab of 7 is seven images wide on every image")
let all = ImageNavigationSlider.markerSpan(index: 40, slab: 250, count: 100, bar: bar)
check(near(all.lowerBound, 1) && near(all.upperBound, 201), "more images than the series has: \(all), not the whole strip")
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
print("PASS: one image, an odd and an even slab around it, both ends of the series, the whole series, a narrow slab and a single image")
'''

with tempfile.TemporaryDirectory(prefix='horos-slab-marker-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'driver'
    build = subprocess.run(['xcrun', 'swiftc', '-o', str(binary), str(root / 'Horos/Sources/HorosCellSlider.swift'),
                            str(root / 'Horos/Sources/ImageNavigationSlider.swift'), str(folder / 'main.swift'),
                            *isix_modules.module_flags('IsiXImaging', folder / 'modules')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        failures.append('ImageNavigationSlider does not compile with HorosCellSlider and IsiXImaging')
    else:
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('the marker geometry')

slider = (root / 'Horos/Sources/ImageNavigationSlider.swift').read_text(encoding='utf-8')
if not re.search(r'Self\.markerSpan\(index: Int\(doubleValue\.rounded\(\)\), slab: slabImageCount,', slider):
    failures.append('the strip does not draw its marker from markerSpan')
if 'ThickSlabSpan(images: slab, at: min(max(index, 0), count - 1), of: count, towardsStart: false)' not in slider:
    failures.append("the marker does not cover the images of the slab's own rule, going forward on the strip")
# -adjustSlider is Swift, a façade in ViewerController+SeriesNavigation.swift of
# ViewerSlices.adjustSlider() there; the slab's count is IsiXImaging's
# SliceNavigation.slabImageCount(stack:), at least one image.
viewer = (root / 'Horos/Sources/ViewerController+SeriesNavigation.swift').read_text(encoding='utf-8')
facade = viewer[viewer.index('    @objc(adjustSlider)'):]
facade = facade[:facade.index('\n    }\n')]
adjust = viewer[viewer.index('@MainActor struct ViewerSlices {'):]
adjust = adjust[adjust.index('    func adjustSlider() {'):]
adjust = adjust[:adjust.index('\n    }\n')]
navigation = (root / 'Modules/IsiXImaging/Sources/ViewerNavigation/SliceNavigation.swift').read_text(encoding='utf-8')
slab = navigation[navigation.index('    public static func slabImageCount(stack: Int) -> Int {'):]
slab = slab[:slab.index('\n    }\n')]
if 'ViewerSlices(viewer: self).adjustSlider()' not in facade \
        or 'slider.slabImageCount = SliceNavigation.slabImageCount(stack: Int(viewer.horos_imageView?.curDCM?.stack ?? 0))' not in adjust \
        or 'viewer.horos_slider as? ImageNavigationSlider' not in adjust or 'max(stack, 1)' not in slab:
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
