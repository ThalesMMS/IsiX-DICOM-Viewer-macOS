#!/usr/bin/env python3
"""The square magnifier of a 2D view: where it goes, what it draws, its switch.

A measurement's endpoint is placed under a magnifier that follows the pointer
or, by preference, waits in the view's lower right corner. In the corner it
must not cover the point being placed, and around the pointer its sight must
leave the pointed pixel visible. The measurement's magnifier and the Shift lens
have a switch each, and the corner one serves both. The two new preferences
have to be registered off and bound once in every localization of the Viewer
pane.
"""
import re
import private_tmpdir  # noqa: F401  - its TMPDIR holds the harness preference domains
import harness_defaults
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
KEY = 'magnifyingLensInCorner'
MEASURING = 'magnifyingLensWhileMeasuring'

driver = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
}

let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
let side = MagnifierPresentation.side

// Around the pointer.
var frame = MagnifierPresentation.frame(inBounds: bounds, cursor: NSPoint(x: 300, y: 200), side: side, inCorner: false, flipped: false)
check(frame == NSRect(x: 300 - side / 2, y: 200 - side / 2, width: side, height: side), "centred frame \(frame)")

// In the lower right corner, whatever the view's orientation.
frame = MagnifierPresentation.frame(inBounds: bounds, cursor: NSPoint(x: 300, y: 200), side: side, inCorner: true, flipped: false)
check(frame.maxX == 788 && frame.minY == 12 && frame.width == side, "corner frame \(frame)")
frame = MagnifierPresentation.frame(inBounds: bounds, cursor: NSPoint(x: 300, y: 200), side: side, inCorner: true, flipped: true)
check(frame.maxX == 788 && frame.maxY == 588, "flipped corner frame \(frame)")

// The pointer in or near that corner sends it to the lower left.
for cursor in [NSPoint(x: 700, y: 60), NSPoint(x: 520, y: 290)] {
    frame = MagnifierPresentation.frame(inBounds: bounds, cursor: cursor, side: side, inCorner: true, flipped: false)
    check(frame.minX == 12 && frame.minY == 12 && !frame.contains(cursor), "corner swap at \(cursor): \(frame)")
}
frame = MagnifierPresentation.frame(inBounds: bounds, cursor: NSPoint(x: 400, y: 330), side: side, inCorner: true, flipped: false)
check(frame.maxX == 788, "pointer away from the corner keeps it right: \(frame)")

// A smaller view gets a smaller magnifier, and a thumbnail none.
frame = MagnifierPresentation.frame(inBounds: NSRect(x: 0, y: 0, width: 300, height: 250), cursor: .zero, side: side, inCorner: true, flipped: false)
check(frame.width == 125 && frame.height == 125, "small view \(frame)")
frame = MagnifierPresentation.frame(inBounds: NSRect(x: 0, y: 0, width: 110, height: 110), cursor: .zero, side: side, inCorner: false, flipped: false)
check(frame == .zero, "thumbnail \(frame)")

// In a tiled view both lower corners can cover the point. Suppress the
// magnifier rather than hide the point being placed, in either orientation.
for flipped in [false, true] {
    let tiled = NSRect(x: 0, y: 0, width: 240, height: 240)
    let cursor = NSPoint(x: 120, y: flipped ? 180 : 60)
    frame = MagnifierPresentation.frame(inBounds: tiled, cursor: cursor, side: side, inCorner: true, flipped: flipped)
    check(frame == .zero || !frame.contains(cursor), "tiled magnifier covers cursor \(cursor): \(frame)")
}
frame = MagnifierPresentation.frame(inBounds: NSRect(x: 0, y: 0, width: 240, height: 240),
                                    cursor: NSPoint(x: 100, y: 60), side: side, inCorner: true, flipped: false)
check(frame != .zero && !frame.contains(NSPoint(x: 100, y: 60)), "safe right corner suppressed: \(frame)")

// Pixels: BGRA in, opaque ARGB out, framed and sighted, the centre untouched.
for scale in [1, 2] {
    let n = 160 * scale
    var bgra = Data(count: n * n * 4)
    for i in 0..<(n * n) { bgra[4 * i] = 10; bgra[4 * i + 1] = 20; bgra[4 * i + 2] = 30; bgra[4 * i + 3] = 7 }
    guard let argb = MagnifierPresentation.squareARGB(fromBGRA: bgra, side: n, scale: scale, segments: [
        // A ROI line from far outside the picture towards its centre, along a sight arm...
        [-50000, n / 2, n / 2 - 4 * scale, n / 2, 0, 255, 0, 2 * scale],
        // ...and one that leaves through the frame.
        [n / 4, n / 4, n / 4, 3 * n, 255, 0, 0, 2 * scale],
    ].map { $0.map { NSNumber(value: $0) } }) else { check(false, "no picture"); exit(1) }
    let p = argb.bytes.assumingMemoryBound(to: UInt8.self)
    func pixel(_ x: Int, _ y: Int) -> [UInt8] { (0..<4).map { p[4 * (y * n + x) + $0] } }
    let picture: [UInt8] = [255, 30, 20, 10]
    check(pixel(n / 3, n / 4) == picture, "picture \(pixel(n / 3, n / 4))")
    check(pixel(n / 2, n / 2) == picture, "the pointed pixel is covered: \(pixel(n / 2, n / 2))")
    check(pixel(0, n / 3) == [255, 0, 0, 0] && pixel(n - 1, n / 3) == [255, 0, 0, 0], "outer frame")
    check(pixel(scale, n / 3) == [255, 230, 230, 230] && pixel(n / 3, n - 1 - scale) == [255, 230, 230, 230], "inner frame")
    let yellow: [UInt8] = [255, 255, 255, 0]
    // The measured line shows over the sight and up to the frame, not over it.
    check(pixel(n / 2 - 10 * scale, n / 2) == [255, 0, 255, 0], "the line is under the sight: \(pixel(n / 2 - 10 * scale, n / 2))")
    check(pixel(3 * scale, n / 2) == [255, 0, 255, 0], "the line stops short of the frame")
    check(pixel(n / 4, n - 1 - 3 * scale) == [255, 255, 0, 0], "the second line misses the picture's edge")
    check(pixel(n / 4, n - 1) == [255, 0, 0, 0] && pixel(n / 4, n - 1 - scale) == [255, 230, 230, 230], "a line is drawn over the frame")
    for (x, y) in [(n / 2 + 10 * scale, n / 2), (n / 2, n / 2 - 10 * scale), (n / 2, n / 2 + 10 * scale)] {
        check(pixel(x, y) == yellow, "sight arm at \(x), \(y): \(pixel(x, y))")
    }
    check(pixel(n / 2 + 3 * scale, n / 2) == picture, "the sight closes on the centre")
}
check(MagnifierPresentation.squareARGB(fromBGRA: Data(count: 8), side: 160, scale: 1, segments: []) == nil, "short picture accepted")

// The keys: right and left step the zoom between twice and twenty times, up and down the size.
var zoom: Float = 4
check(MagnifierPresentation.zoomFactor(zoom, steppedIn: false) == 4, "zoom steps out past its widest")
for _ in 0..<20 { zoom = MagnifierPresentation.zoomFactor(zoom, steppedIn: true) }
check(abs(zoom - 2.2) < 0.001, "closest zoom \(zoom)")
check(MagnifierPresentation.zoomFactor(0.4, steppedIn: false) > 2.3, "a factor below the closest zoom does not need stepping back through")
check(MagnifierPresentation.zoomFactor(3, steppedIn: true) < 3 && MagnifierPresentation.zoomFactor(3, steppedIn: false) > 3, "zoom direction")
check(MagnifierPresentation.sizeFactor(1, steppedUp: true) == 1.25 && MagnifierPresentation.sizeFactor(3, steppedUp: true) == 3
      && MagnifierPresentation.sizeFactor(0.5, steppedUp: false) == 0.5, "size steps")

// The factors the keys set are kept, within the steps' range, for the next view.
let suite = harnessDomainName("horos-magnifier-check-\(ProcessInfo.processInfo.processIdentifier)")
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(MagnifierPresentation.storedZoomFactor(in: defaults) == 3 && MagnifierPresentation.storedSizeFactor(in: defaults) == 1,
      "factors before any key")
MagnifierPresentation.store(zoomFactor: 2.4, sizeFactor: 1.5625, in: defaults)
check(MagnifierPresentation.storedZoomFactor(in: defaults) == 2.4 && MagnifierPresentation.storedSizeFactor(in: defaults) == 1.5625,
      "stored factors")
defaults.set(9, forKey: MagnifierPresentation.zoomDefaultsKey)
defaults.set("x", forKey: MagnifierPresentation.sizeDefaultsKey)
check(MagnifierPresentation.storedZoomFactor(in: defaults) == 4 && MagnifierPresentation.storedSizeFactor(in: defaults) == 1,
      "out of range or foreign stored factors")
check(MagnifierPresentation.cornerDefaultsKey == "KEY", "defaults key")
check(MagnifierPresentation.measurementDefaultsKey == "MEASURING", "measurement defaults key")
print("PASS: magnifier frame around the pointer and in the corner, corner swap, small views, frame, sight and ROI line pixels, key steps, kept factors")
'''.replace('MEASURING', MEASURING).replace('KEY', KEY)

with tempfile.TemporaryDirectory(prefix='horos-magnifier-') as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(harness_defaults.DOMAINS + driver)
    binary = Path(folder) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'),
                    str(root / 'Horos/Sources/MagnifierPresentation.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# The switches: registered off, and bound once in each localization of the pane.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
assert defaults.get(KEY) == '0', 'the corner default is not registered off'
assert defaults.get(MEASURING) == '0', 'the measurement magnifier is not registered off'
assert defaults.get('magnifyingLens') == '1', 'the Shift lens default changed'
panes = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
panes += [root / 'Horos/Resources' / f'{language}.lproj'
          for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]
for pane in panes:
    tree = ET.parse(pane / 'OSIViewerPreferencePanePref.xib')
    box = tree.find('.//box[@id="100"]/view/rect')
    for key, control in ((KEY, 'magnifier-corner-control'), (MEASURING, 'measurement-magnifier-control')):
        assert len(tree.findall(f'.//binding[@keyPath="values.{key}"]')) == 1, (pane.name, key)
        button = tree.find(f'.//button[@id="{control}"]')
        frame = button.find('rect')
        assert float(frame.get('y')) + float(frame.get('height')) <= float(box.get('height')), pane.name
        assert button.find('buttonCell').get('title'), pane.name
        assert button.find('connections/binding').get('keyPath') == f'values.{key}', (pane.name, control)
    titles = {tree.find(f'.//button[@id="{c}"]/buttonCell').get('title') for c in ('measurement-magnifier-control', '415')}
    assert len(titles) == 2, f'{pane.name}: the two magnifier switches read alike'

# The view draws it when the lens is not up. The measurement's magnifier, its
# cursor and its keys follow their own switch; the Shift lens keeps its own.
# The drawing, the lens and the magnifier are Swift (DCMView+Drawing.swift),
# and so are the keys (DCMView+Keyboard.swift).
view = (root / 'Horos/Sources/DCMView.swift').read_text(encoding='utf-8')
keyboard = (root / 'Horos/Sources/DCMView+Keyboard.swift').read_text(encoding='utf-8')
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text(encoding='utf-8')
assert '} else {\n                self.horosDrawMeasurementMagnifier()' in drawing, 'the frame does not draw the measurement magnifier'
def body(selector):
    start = drawing.index('@objc(' + selector + ')')
    return drawing[start:drawing.index('\n    }\n', start)]
for selector in ('horosDrawMeasurementMagnifier', 'horosMeasurementMagnifierHoldsKeys'):
    assert 'MagnifierPresentation.measurementDefaultsKey' in body(selector), f'{selector} ignores its own switch'
    assert '"magnifyingLens"' not in body(selector), f'{selector} still follows the Shift lens switch'
assert 'self.horosHideCursor(forMagnifier: shown' in body('horosDrawMeasurementMagnifier'), 'the cursor no longer follows the magnifier'
assert '!UserDefaults.standard.bool(forKey: "magnifyingLens")' in body('computeMagnifyLens:'), 'the Shift lens lost its switch'
assert 'measurementDefaultsKey' not in body('computeMagnifyLens:'), 'the Shift lens follows the measurement switch'
assert 'segments: (self.horosROISegments(forMagnifierSide:' in drawing, 'the magnifier no longer draws the ROI lines'
assert 'self.horosDrawSquareMagnifier(inCorner:' in body('drawMagnifyingLens'), 'the Shift lens is not the square magnifier'
print(f'PASS: {KEY} and {MEASURING} registered off and bound in {len(panes)} localizations; DCMView draws the magnifier, each lens behind its own switch')

# The factors come from the defaults when a view opens, when the lens shows and
# when the magnifier draws, and the keys store what they step.
assert not re.search(r'horos_lensZoomFactor = 3(\.0)?\b', view), 'a new view resets the magnifier zoom'
assert view.count('self.horosLoadMagnifierFactors()') + drawing.count('self.horosLoadMagnifierFactors()') + \
    keyboard.count('self.horosLoadMagnifierFactors()') >= 4, 'a magnifier path does not read the kept factors'
keys = keyboard[keyboard.index('if self.horos_lensActive || self.horosMeasurementMagnifierHoldsKeys() {'):]
keys = keys[:keys.index('return')]
store = keys.index('MagnifierPresentation.store(zoomFactor: self.horos_lensZoomFactor, sizeFactor: self.horos_lensSizeFactor')
# Recomputing the lens reads the kept factors back: a size step stored after it is lost.
assert store < keys.index('self.computeMagnifyLens('), 'the size key recomputes the lens before keeping its step'
