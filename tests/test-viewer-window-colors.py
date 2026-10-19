#!/usr/bin/env python3
"""Each 2D window has a colour, on its image and on its series' thumbnails.

A window takes the first colour no other open window has, as it opens, and
keeps it until it closes; closing one frees its colour without moving the
others'. The palette stays clear of the thumbnails' orange (this window's
series) and green (the fused series) and of the key-image yellow.
HorosViewerWindowColors itself is compiled and asked.

In the viewer: with more than one window, every window's image is framed in
its colour, thick on the key view of the frontmost one, in place of the red
border the frontmost window alone used to have. In the thumbnail column, the
series a window shows is framed in that window's colour instead of yellow; this
window's own series keeps its orange; a collapsed study takes the colour of
its first series that is shown; the series menu uses the colour as the
background the yellow was. The thumbnail cell keeps the colour as numbers: it
is copied bitwise and must hold no object of its own.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

driver = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
}
func distance(_ a: NSColor, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    let c = a.usingColorSpace(.genericRGB)!
    return sqrt(pow(c.redComponent - r, 2) + pow(c.greenComponent - g, 2) + pow(c.blueComponent - b, 2))
}

check(ViewerWindowColors.firstFreeSlot(among: []) == 0, "first slot")
check(ViewerWindowColors.firstFreeSlot(among: [0, 1, 3]) == 2, "a hole is filled first")

MainActor.assumeIsolated {
    let one = NSObject(), two = NSObject(), three = NSObject()
    check(ViewerWindowColors.slot(for: one) == 0, "the first window")
    check(ViewerWindowColors.slot(for: two) == 1, "the second window")
    check(ViewerWindowColors.slot(for: three) == 2, "the third window")
    check(ViewerWindowColors.slot(for: one) == 0 && ViewerWindowColors.slot(for: two) == 1, "colours are kept")
    ViewerWindowColors.release(two)
    let four = NSObject()
    check(ViewerWindowColors.slot(for: four) == 1, "a closed window's colour is taken by the next")
    check(ViewerWindowColors.slot(for: one) == 0 && ViewerWindowColors.slot(for: three) == 2, "the others do not move")
    let ordered = ViewerWindowColors.viewersInColorOrder([three, one, four])
    check(ordered[0] === one && ordered[1] === four && ordered[2] === three, "colour order")
    check(ViewerWindowColors.color(for: one) == ViewerWindowColors.palette[0], "the colour is the slot's")

    let palette = ViewerWindowColors.palette
    check(palette.count >= 6, "a palette of \(palette.count)")
    for (i, color) in palette.enumerated() {
        check(distance(color, 252 / 255, 177 / 255, 141 / 255) > 0.3, "colour \(i) near the selection orange")
        check(distance(color, 195 / 255, 249 / 255, 145 / 255) > 0.3, "colour \(i) near the fusion green")
        check(distance(color, 249 / 255, 240 / 255, 140 / 255) > 0.3, "colour \(i) near the open-series yellow")
        check(distance(color, 1, 1, 0) > 0.3, "colour \(i) near the key-image yellow")
        for other in palette[(i + 1)...] {
            let o = other.usingColorSpace(.genericRGB)!
            check(distance(color, o.redComponent, o.greenComponent, o.blueComponent) > 0.3, "two colours alike at \(i)")
        }
    }
}
print("ok")
'''

with tempfile.TemporaryDirectory() as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(driver)
    binary = Path(folder) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(Path(folder) / 'modules'),
                    str(root / 'Horos/Sources/ViewerWindowColors.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]


view = (root / 'Horos/Sources/DCMView.m').read_text()
frame = between(view, '- (void) drawFrame:(NSRect)aRect', '[HorosPlanarFrameGraphics enterImageRotation:')
if 'drawWindowBorderSize:' not in frame or 'colorForViewer: [self windowController]' not in frame:
    fail("the image is not framed in its window's colour")
border = frame[frame.index('[ViewerController numberOf2DViewer] > 1'):frame.index('drawWindowBorderSize:')]
if 'isKeyView &&' in border:
    fail('only the key view is framed')
if 'drawKeyViewBorderSize:' in view:
    fail('the red key-view border is still drawn')

controller = (root / 'Horos/Sources/ViewerController.m').read_text()
matrix = between(controller, '- (void) buildMatrixPreview: (BOOL) showSelected', '- (void) matrixPreviewSelectCurrentSeries')
# The Comparatives button, after the cells, keeps its own yellow.
cells = matrix[:matrix.index('@finally')]
if '_openItemColor' in cells or 'getDisplayedSeries' in cells:
    fail('the thumbnail column still paints open series yellow')
if matrix.count('HorosSetThumbnailFrame(') < 3:
    fail('the thumbnails are not reset and framed with the window colours')
popup = between(controller, '- (void) buildSeriesPopup', '- (void) loadSelectedSeries:')
if '_openItemColor' in popup or 'seriesWindowColors objectForKey: curSeries' not in popup:
    fail('the series menu still paints open series yellow')
close = between(controller, '- (void)windowWillClose:(NSNotification *)notification', '\n}\n')
if 'releaseViewer: self' not in close:
    fail('a closing window keeps its colour')
load = between(controller, '- (void)windowDidLoad', '\n}\n')
if 'colorForViewer: self' not in load:
    fail('a window does not take its colour as it opens')

cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()
stored = re.findall(r'^\s*(?:private |public |@objc )*(?:var|let) (\w+)\s*(?::\s*([\w?<>\[\]]+))?\s*=', cell, re.M)
for name, kind in stored:
    if kind and kind.rstrip('?') not in ('Bool', 'CGFloat', 'Float', 'Double', 'Int'):
        fail(f'the cell stores an object, {name}: {kind}, which a bitwise copy does not retain')
if 'framed' not in cell or 'frameRed' not in cell:
    fail('the cell does not keep the frame colour')
print('ok: window colours assigned, kept and freed; drawn on images, thumbnails and the series menu')
