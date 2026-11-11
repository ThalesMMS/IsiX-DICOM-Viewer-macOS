#!/usr/bin/env python3
"""The window colours a former plugin may ask for, and the thumbnail cell's scalars.

HorosViewerWindowColors gave each displayed series a colour and a number of
its own, shared by its windows until the last one closed or changed series.
The application no longer uses it: the series are told apart by study, number
and active window (tests/test-series-list-identification.py). The class stays
for the plugins that were linked against it, and is compiled and asked here: a
series takes the first free slot, other series keep theirs, a closed window
frees its own.

The thumbnail cell is copied bitwise by AppKit and must hold no object of its
own: the colour of its frame and of its number are kept as components.
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


# Nothing in the application calls the class any more.
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    if path.name != 'ViewerWindowColors.swift' and 'ViewerWindowColors.' in path.read_text(errors='replace'):
        fail(f'{path.name} still uses the window colours')

cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()
stored = re.findall(r'^\s*(?:private |public |@objc )*(?:var|let) (\w+)\s*(?::\s*([\w?<>\[\]]+))?\s*=', cell, re.M)
for name, kind in stored:
    if kind and kind.rstrip('?') not in ('Bool', 'CGFloat', 'Float', 'Double', 'Int'):
        fail(f'the cell stores an object, {name}: {kind}, which a bitwise copy does not retain')
if 'framed' not in cell or 'frameRed' not in cell:
    fail('the cell does not keep the frame colour')
if 'numberColoured' not in cell or 'numberRed' not in cell:
    fail('the cell does not keep the colour of its number')
print('ok: window colours assigned, kept and freed for former plugins; the thumbnail cell stores scalars only')
