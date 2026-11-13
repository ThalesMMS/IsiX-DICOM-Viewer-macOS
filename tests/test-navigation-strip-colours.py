#!/usr/bin/env python3
"""The navigation strip above the 2D viewport is drawn in neutral greys.

The band of the strip showed the images already displayed in the accent
colour, blue. Blue and orange now say, in the list of series, which study a
series is of (the current one, a previous one), so a blue band over a series
of a previous study contradicted them. The band says nothing of the study:
a dark grey for the images not shown yet, a light grey for those shown.

ImageNavigationSlider, compiled with HorosCellSlider, drawn into a bitmap in
a light and in a dark appearance: the part shown and the part not shown are
neutral (no hue), the first clearly lighter than the second, and both the
same in the two appearances; the marker of the current image stays red.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]

driver = r'''
import AppKit
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

/// The strip with images 0 to 39 of 100 shown, drawn in `appearance`.
func drawn(_ appearance: NSAppearance.Name) -> NSBitmapImageRep {
    let slider = ImageNavigationSlider(frame: NSRect(x: 0, y: 0, width: 202, height: 20))
    slider.appearance = NSAppearance(named: appearance)
    slider.minValue = 0
    slider.maxValue = 99
    slider.numberOfTickMarks = 100
    for index in 0..<40 {
        slider.doubleValue = Double(index)
        slider.valueDidChange()
    }
    let bitmap = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)!
    slider.cacheDisplay(in: slider.bounds, to: bitmap)
    return bitmap
}

/// The colour drawn at image `index` of 100, in the middle of the band.
func colour(_ bitmap: NSBitmapImageRep, at index: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let scale = CGFloat(bitmap.pixelsWide) / 202
    let x = Int((1 + 200 * (CGFloat(index) + 0.5) / 100) * scale)
    let c = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
}
func neutral(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool { abs(c.r - c.g) < 0.02 && abs(c.g - c.b) < 0.02 }

var shownInEach: [CGFloat] = [], notShownInEach: [CGFloat] = []
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    let bitmap = drawn(appearance)
    let shown = colour(bitmap, at: 15), notShown = colour(bitmap, at: 80), marker = colour(bitmap, at: 39)
    check(neutral(shown), "\(appearance.rawValue): the images shown are drawn with a hue: \(shown)")
    check(neutral(notShown), "\(appearance.rawValue): the images not shown are drawn with a hue: \(notShown)")
    check(shown.g > 0.6, "\(appearance.rawValue): the images shown are not a light grey: \(shown)")
    check(notShown.g < 0.35, "\(appearance.rawValue): the images not shown are not a dark grey: \(notShown)")
    check(marker.r > 0.7 && marker.b < 0.5 && marker.g < 0.5, "\(appearance.rawValue): the marker of the current image is not red: \(marker)")
    shownInEach.append(shown.g)
    notShownInEach.append(notShown.g)
}
check(abs(shownInEach[0] - shownInEach[1]) < 0.02 && abs(notShownInEach[0] - notShownInEach[1]) < 0.02,
      "the band is not the same in a light and in a dark window: \(shownInEach) \(notShownInEach)")
print("PASS: a dark grey band, light grey where the images were shown, the same in both appearances, with a red marker")
'''

with tempfile.TemporaryDirectory(prefix='horos-strip-colours-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'driver'
    build = subprocess.run(['xcrun', 'swiftc', '-o', str(binary), str(root / 'Horos/Sources/HorosCellSlider.swift'),
                            str(root / 'Horos/Sources/ImageNavigationSlider.swift'), str(folder / 'main.swift')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stdout[-3000:], build.stderr[-3000:])
        sys.exit('FAIL: the strip does not compile')
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode or 'PASS' not in run.stdout:
        print(run.stderr[-2000:])
        sys.exit(1)

source = (root / 'Horos/Sources/ImageNavigationSlider.swift').read_text()
if 'controlAccentColor' in source:
    sys.exit('FAIL: the strip still draws with the accent colour')
