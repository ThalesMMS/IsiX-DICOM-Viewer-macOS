#!/usr/bin/env python3
"""Each displayed series has one colour across its windows and thumbnails.

A series takes the first free colour, shared by its windows until the last
one closes or changes series. Other series keep their identities. The
palette stays clear of the thumbnails' orange (this window's
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

final class ViewerController: NSObject {
    var series: NSObject?
    func currentSeries() -> NSObject? { series }
}

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

    for viewer in [one, three, four] { ViewerWindowColors.release(viewer) }
    let a = ViewerController(), duplicateA = ViewerController(), b = ViewerController()
    let loading = ViewerController()
    _ = ViewerWindowColors.color(for: loading)
    a.series = NSString(string: "study-a/series-a")
    duplicateA.series = NSString(string: "study-a/series-a")
    b.series = NSString(string: "study-a/series-b")
    check(ViewerWindowColors.number(for: a) == 1, "first series identity")
    check(ViewerWindowColors.number(for: duplicateA) == 1, "duplicate shares number")
    check(ViewerWindowColors.color(for: a) == ViewerWindowColors.color(for: duplicateA), "duplicate shares colour")
    check(ViewerWindowColors.number(for: b) == 2, "duplicate does not consume another slot")
    loading.series = b.series
    check(ViewerWindowColors.number(for: loading) == 2, "loading window joins the series without reserving a new slot")
    ViewerWindowColors.release(loading)
    ViewerWindowColors.release(a)
    let c = ViewerController()
    c.series = NSString(string: "study-b/series-a")
    check(ViewerWindowColors.number(for: c) == 3, "remaining duplicate reserves slot; other study remains distinct")
    check(ViewerWindowColors.number(for: duplicateA) == 1, "closing original preserves duplicate identity")
    duplicateA.series = b.series
    check(ViewerWindowColors.number(for: duplicateA) == 2, "changing to an open series shares its identity")
    check(ViewerWindowColors.number(for: b) == 2, "series change leaves other identities stable")
    let d = ViewerController()
    d.series = NSString(string: "study-a/series-d")
    check(ViewerWindowColors.number(for: d) == 1, "last user leaving a series frees its slot")
    duplicateA.series = NSString(string: "study-a/series-e")
    check(ViewerWindowColors.number(for: duplicateA) == 4, "split from duplicate gets a free slot")
    check(ViewerWindowColors.number(for: b) == 2, "split keeps remaining duplicate's identity")
    weak var released: ViewerController?
    autoreleasepool {
        let temporary = ViewerController()
        temporary.series = NSString(string: "temporary")
        released = temporary
        check(ViewerWindowColors.number(for: temporary) == 5, "temporary identity")
    }
    check(released == nil, "registry does not retain a viewer")
    let replacement = ViewerController()
    replacement.series = NSString(string: "replacement")
    check(ViewerWindowColors.number(for: replacement) == 5, "deallocated owner frees slot")
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


# DCMView is Swift: its class and its extensions, and the C of DCMView+CAPI.m.
view = '\n'.join(path.read_text() for path in sorted((root / 'Horos/Sources').glob('DCMView*.swift'))) + \
    (root / 'Horos/Sources/DCMView+CAPI.m').read_bytes().decode('latin1')
# The frame is drawn by DCMView+Drawing.swift.
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
frame = between(drawing, '@objc(drawFrame:)', 'PlanarFrameGraphics.enterImage(rotation:')
if 'PlanarFrameGraphics.drawWindowBorder(size:' not in frame or 'color: ViewerWindowColors.color(for: viewer)' not in frame:
    fail("the image is not framed in its window's colour")
border = frame[frame.index('ViewerController.numberOf2DViewer() > 1'):frame.index('PlanarFrameGraphics.drawWindowBorder(size:')]
if 'isKeyView &&' in border:
    fail('only the key view is framed')
if 'drawKeyViewBorderSize:' in view or 'drawKeyViewBorder(' in drawing:
    fail('the red key-view border is still drawn')

controller = (((root / 'Horos/Sources/ViewerController.m').read_text()) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
if '- (void) buildMatrixPreview: (BOOL) showSelected' in controller:
    matrix = between(controller, '- (void) buildMatrixPreview: (BOOL) showSelected', '- (void) matrixPreviewSelectCurrentSeries')
    # The Comparatives button, after the cells, keeps its own yellow.
    cells = matrix[:matrix.index('@finally')]
    framings = matrix.count('HorosSetThumbnailFrame(')
    popup = between(controller, '- (void) buildSeriesPopup', '- (void) loadSelectedSeries:')
    menu_framed = 'seriesWindowColors objectForKey: curSeries' in popup
else:
    # The list and the menu are Swift (ViewerController+SeriesThumbnails.swift,
    # +SeriesPopup.swift).
    thumbnails = (root / 'Horos/Sources/ViewerController+SeriesThumbnails.swift').read_text()
    matrix = between(thumbnails, 'func buildMatrixPreview(_ showSelected: Bool)', 'func matrixPreviewSelectCurrentSeries()')
    cells = matrix[:matrix.index('// The comparatives button')]
    framings = matrix.count('setThumbnailFrame(')
    popup = between((root / 'Horos/Sources/ViewerController+SeriesPopup.swift').read_text(), 'func buildSeriesPopup()', 'func loadSelectedSeries(')
    menu_framed = 'seriesWindowColors?.object(forKey: curSeries)' in popup
if '_openItemColor' in cells or 'getDisplayedSeries' in cells:
    fail('the thumbnail column still paints open series yellow')
if framings < 3:
    fail('the thumbnails are not reset and framed with the window colours')
if '_openItemColor' in popup or not menu_framed:
    fail('the series menu still paints open series yellow')
if '- (void)windowWillClose:(NSNotification *)notification' in controller:
    close = between(controller, '- (void)windowWillClose:(NSNotification *)notification', '\n}\n')
    load = between(controller, '- (void)windowDidLoad', '\n}\n')
    released, taken = 'releaseViewer: self', 'colorForViewer: self'
else:
    # The window's life is Swift since ViewerController+WindowLifecycle.swift.
    lifecycle = (root / 'Horos/Sources/ViewerController+WindowLifecycle.swift').read_text()
    close = between(lifecycle, '    func windowWillClose(_ notification: Notification) {', '\n    }\n')
    load = between(lifecycle, '    override func windowDidLoad() {', '\n    }\n')
    released, taken = 'ViewerWindowColors.release(self)', 'ViewerWindowColors.color(for: self)'
if released not in close:
    fail('a closing window keeps its colour')
if taken not in load:
    fail('a window does not take its colour as it opens')
colors = (root / 'Horos/Sources/ViewerWindowColors.swift').read_text()
if '@discardableResult\n    @objc(colorForViewer:)' not in colors:
    fail('taking the colour at windowDidLoad leaves a result the compiler warns about (-Wunused-result)')

cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()
stored = re.findall(r'^\s*(?:private |public |@objc )*(?:var|let) (\w+)\s*(?::\s*([\w?<>\[\]]+))?\s*=', cell, re.M)
for name, kind in stored:
    if kind and kind.rstrip('?') not in ('Bool', 'CGFloat', 'Float', 'Double', 'Int'):
        fail(f'the cell stores an object, {name}: {kind}, which a bitwise copy does not retain')
if 'framed' not in cell or 'frameRed' not in cell:
    fail('the cell does not keep the frame colour')
print('ok: window colours assigned, kept and freed; drawn on images, thumbnails and the series menu')
