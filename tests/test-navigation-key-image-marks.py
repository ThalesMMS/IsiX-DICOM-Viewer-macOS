#!/usr/bin/env python3
"""The navigation strip above the 2D viewport marks the series' key images.

Finding the key images of a series meant going through it, or stepping with
the next and previous key image buttons. The strip now has a yellow mark at
the place of each key image, taller than the band, under the red marker of
the image shown.

ImageNavigationSlider, compiled with HorosCellSlider and IsiXImaging, whose
KeyImageNavigation.stripMarks is the rule, drawn into a bitmap: a mark at
each key image and nowhere else, above and below the band; the marks run the
other way with flipped data; a strip without key images is drawn as before;
loading a series (the tick count) takes the marks away and asks for them
again. In the sources: the viewer gives the strip the key images when the
frame shown is not the one they were read for, and after each of its own
commands that marks or unmarks; a change of the database makes the strip
ask for them again.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import isix_modules
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []

driver = r'''
import AppKit
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

/// 100 images over a 400 pt bar from x = 1: 4 pt per image.
func strip() -> ImageNavigationSlider {
    let slider = ImageNavigationSlider(frame: NSRect(x: 0, y: 0, width: 402, height: 20))
    slider.minValue = 0
    slider.maxValue = 99
    slider.numberOfTickMarks = 100
    slider.doubleValue = 50
    slider.valueDidChange()
    return slider
}
func drawn(_ slider: ImageNavigationSlider) -> NSBitmapImageRep {
    let bitmap = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)!
    slider.cacheDisplay(in: slider.bounds, to: bitmap)
    return bitmap
}
/// Whether the strip is yellow at image `index`, `offset` points from the band's middle line.
func isYellow(_ bitmap: NSBitmapImageRep, at index: Int, offset: CGFloat = 0) -> Bool {
    let scale = CGFloat(bitmap.pixelsWide) / 402
    let x = Int((1 + 400 * (CGFloat(index) + 0.5) / 100) * scale)
    let y = Int((10 + offset) * scale)
    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
    return c.alphaComponent > 0.9 && c.redComponent > 0.85 && c.greenComponent > 0.6 && c.blueComponent < 0.3
}

let plain = drawn(strip())
let slider = strip()
check(slider.keyImages.isEmpty && slider.keyImagesFrame == -1, "a new strip has key images")
slider.keyImages = IndexSet([5, 20, 50, 99])
slider.keyImagesFrame = 0
var bitmap = drawn(slider)
for index in [5, 20, 99] {
    check(isYellow(bitmap, at: index), "no mark on the band at key image \(index)")
    check(isYellow(bitmap, at: index, offset: 5) && isYellow(bitmap, at: index, offset: -5), "the mark at \(index) is not taller than the band")
}
for index in [0, 4, 7, 19, 22, 60, 97] {
    check(!isYellow(bitmap, at: index) && !isYellow(bitmap, at: index, offset: 5), "a mark at \(index), which is not a key image")
}
// The image shown is a key image: its red marker is in front on the band, the mark shows beyond it.
check(!isYellow(bitmap, at: 50) && isYellow(bitmap, at: 50, offset: 5), "the marker of the image shown is not in front of its mark")

slider.flippedData = true
bitmap = drawn(slider)
for index in [94, 79, 0] { check(isYellow(bitmap, at: index), "flipped data: no mark at \(index)") }
for index in [5, 20, 99] { check(!isYellow(bitmap, at: index), "flipped data: the mark stayed at \(index)") }

// Loading a series: the tick count is set, the marks go and are asked for again.
slider.numberOfTickMarks = 100
check(slider.keyImages.isEmpty && slider.keyImagesFrame == -1, "a series load keeps the key images of the series before")
slider.flippedData = false
slider.doubleValue = 50
slider.valueDidChange()
check(drawn(slider).tiffRepresentation == plain.tiffRepresentation, "a strip without key images is not drawn as before")
print("PASS: a yellow mark at each key image and only there, taller than the band, behind the marker, flipped with the data, gone with the series")
'''

with tempfile.TemporaryDirectory(prefix='horos-key-image-marks-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'driver'
    build = subprocess.run(['xcrun', 'swiftc', '-o', str(binary), str(root / 'Horos/Sources/HorosCellSlider.swift'),
                            str(root / 'Horos/Sources/ImageNavigationSlider.swift'), str(folder / 'main.swift'),
                            *isix_modules.module_flags('IsiXImaging', folder / 'modules')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stdout[-3000:], build.stderr[-3000:])
        failures.append('ImageNavigationSlider does not compile with HorosCellSlider and IsiXImaging')
    else:
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('the marks drawn')

sources = root / 'Horos/Sources'
slider = (sources / 'ImageNavigationSlider.swift').read_text(encoding='utf-8')
if 'KeyImageNavigation.stripMarks(of: keyImages, count: imageCount, flipped: flippedData,' not in slider:
    failures.append("the strip does not draw its marks from KeyImageNavigation.stripMarks")

key_images = (sources / 'ViewerController+KeyImages.swift').read_text(encoding='utf-8')
def body(declaration):
    text = key_images[key_images.index(declaration):]
    return text[:text.index('\n    }\n')]
# -adjustSlider ends in -adjustKeyImage, at every image shown: the controls
# tell the strip of flipped data and read the key images only when it asks.
adjust = body('    func adjustControls() {')
if 'slider.flippedData = viewer.horos_imageView?.flippedData ?? false' not in adjust:
    failures.append('the strip is not told of flipped data when the viewer moves it')
if 'if slider.keyImagesFrame != Int(viewer.horos_curMovieIndex) { refreshStrip() }' not in adjust:
    failures.append('the key images are not read for a new series or another frame, or are read at every image')
navigation = (sources / 'ViewerController+SeriesNavigation.swift').read_text(encoding='utf-8')
if 'viewer.adjustKeyImage()' not in navigation[navigation.index('    func adjustSlider() {\n        if let imageView'):]:
    failures.append('moving the strip does not adjust the key image controls')
for declaration in ('    func checkBoxChanged(_ sender: Any?) {', '    func markImagesWithROIs() {', '    func markEveryImage(asKeyImage key: Bool) {'):
    if 'refreshStrip()' not in body(declaration):
        failures.append(declaration.strip() + ' does not give the strip the key images')
refresh = body('    func refreshStrip() {')
if 'viewer.horos_postprocessed || viewer.horos_displayOnlyKeyImages' not in refresh:
    failures.append('a post processed series or one of key images only gets marks')

if "name: .NSManagedObjectContextObjectsDidChange, object: nil)" not in slider or 'self?.keyImagesFrame = -1' not in slider:
    failures.append('a change of the database does not make the strip ask for the key images again')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the viewer gives the strip the key images of the frame shown')
