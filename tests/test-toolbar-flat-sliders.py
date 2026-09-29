#!/usr/bin/env python3
"""Toolbar items stay flat and the cell-drawn sliders keep their contract.

Three rules live in Swift and are exercised here on the real sources:

* `ToolbarPolicy.flatten` clears `bordered` on every item, and the policy
  re-applies it after insertion because macOS 26 turns it back on for
  view-backed items when the toolbar inserts them.
* `HorosCellSlider` maps a point to a value along its track, snaps to tick
  marks, and repaints without the NSSlider visual provider.
* `HorosImageNavigationSlider` records every index it is set to, resets when
  the controller sets a new tick count, and maps clicks to whole images.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Horos/Sources/HorosCellSlider.swift',
    root / 'Horos/Sources/ImageNavigationSlider.swift',
    root / 'Horos/Sources/ToolbarPolicy.swift',
    root / 'Horos/Sources/ToolbarImage.swift',
    root / 'Horos/Sources/ToolbarMenuBridge.swift',
]
for source in sources:
    assert source.is_file(), f'missing {source}'

policy = (root / 'Horos/Sources/ToolbarPolicy.swift').read_text()
assert 'NSToolbar.willAddItemNotification' in policy, 'flattening must run again after insertion'
assert 'flatten(item)' in policy, 'prepare must flatten every item'

# ToolBarNSWindow is Swift since #714.
window = source_text('ToolBarNSWindow')
assert '@objc(_hasActiveAppearance)' in window, 'the panel must report the viewer key state for drawing'
assert 'override var isKeyWindow' not in window, 'isKeyWindow does not change the drawing on macOS 26'

for xib in (root / 'Horos/Resources/en.lproj/Viewer.xib', root / 'Horos/Resources/ja-JP.lproj/Viewer.xib'):
    text = xib.read_text()
    assert 'customClass="HorosImageNavigationSlider"' in text and 'id="11"' in text, f'{xib}: viewport slider is not the navigation bar'

# The 3D MPR's toolbar sliders (LOD, Thick Slab, movie rate and position,
# Fusion) would otherwise draw as the stock macOS 26 slider.
for xib in (root / 'Horos/Resources/en.lproj/MPR.xib', root / 'Horos/Resources/ja-JP.lproj/MPR.xib'):
    text = xib.read_text()
    for slider in ('653', '663', '846', '847', '859'):
        tag = next(line for line in text.splitlines() if '<slider ' in line and f'id="{slider}"' in line)
        assert 'customClass="HorosCellSlider"' in tag, f'{xib}: toolbar slider {slider} is a stock NSSlider'

# The other 3D viewers' toolbar sliders (#704): the views each controller puts
# in its toolbar, by the outlet it passes to -setView:.
toolbar_sliders = {
    'VR.xib': ('352', '388', '465', '466', '2272'),
    'CPR.xib': ('653', '663', '846', '847', '859', '1166', '1570'),
    'Endoscopy.xib': ('314',),
    'PETCT.xib': ('70', '220', '222'),
    'OrthogonalMPR.xib': ('145', '279', '281'),
}
for name, sliders in toolbar_sliders.items():
    for language in ('en', 'ja-JP'):
        xib = root / 'Horos/Resources' / f'{language}.lproj' / name
        lines = xib.read_text().splitlines()
        for slider in sliders:
            at = next(i for i, line in enumerate(lines) if '<slider ' in line and f'id="{slider}"' in line)
            cell = next(line for line in lines[at:at + 8] if '<sliderCell' in line)
            assert 'customClass="HorosCellSlider"' in lines[at] and 'customClass="HorosCellSliderCell"' in cell, \
                f'{xib}: toolbar slider {slider} is a stock NSSlider'

code = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

_ = NSApplication.shared

// Flattening: creation and post-insertion.
class Delegate: NSObject, NSToolbarDelegate {
    let ids = ["img", "view"].map { NSToolbarItem.Identifier($0) }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "view" {
            item.view = NSSlider(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        } else {
            item.image = NSImage(named: NSImage.folderName)
            item.isBordered = true
        }
        ToolbarPolicy.prepare(item)
        check(!item.isBordered, "prepare must clear bordered on \(id.rawValue)")
        return item
    }
}
let delegate = Delegate()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let toolbar = NSToolbar(identifier: "flat-probe")
toolbar.delegate = delegate
window.toolbarStyle = .expanded
window.toolbar = toolbar
window.orderFront(nil)
window.displayIfNeeded()
let until = Date(timeIntervalSinceNow: 0.5)
while until.timeIntervalSinceNow > 0 {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
for item in toolbar.items {
    check(!item.isBordered, "\(item.itemIdentifier.rawValue) is bordered again after insertion")
}
window.isReleasedWhenClosed = false
window.close()

// Cell-drawn slider geometry.
let slider = HorosCellSlider(frame: NSRect(x: 0, y: 0, width: 213, height: 16))
slider.minValue = 0
slider.maxValue = 100
slider.numberOfTickMarks = 101
slider.allowsTickMarkValuesOnly = true
slider.controlSize = .mini
check(slider.trackRect.width == 213 - slider.knobDiameter, "track is inset by the knob")
check(slider.value(at: NSPoint(x: -50, y: 8)) == 0, "left of the track clamps to min")
check(slider.value(at: NSPoint(x: 500, y: 8)) == 100, "right of the track clamps to max")
let mid = slider.value(at: NSPoint(x: slider.trackRect.midX, y: 8))
check(mid == 50, "middle of the track is the middle value, got \(mid)")
slider.allowsTickMarkValuesOnly = false
let free = slider.value(at: NSPoint(x: slider.trackRect.minX + slider.trackRect.width * 0.333, y: 8))
check(abs(free - 33.3) < 0.2, "free values are not snapped, got \(free)")
slider.intValue = 40
check(slider.doubleValue == 40, "intValue reaches the cell")
check(abs(slider.fraction - 0.4) < 0.001, "fraction follows the value")

// Drawing must not touch the visual provider: render into a bitmap.
func render(_ view: NSView) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
}
render(slider)

// Tick marks on the side the xib asks for, as seen on screen (#987).
func tickRows(_ position: NSSlider.TickMarkPosition) -> (upper: Bool, lower: Bool) {
    let ticked = HorosCellSlider(frame: NSRect(x: 0, y: 0, width: 120, height: 16))
    ticked.controlSize = .mini
    ticked.minValue = 0; ticked.maxValue = 10; ticked.doubleValue = 0
    ticked.numberOfTickMarks = 11
    ticked.tickMarkPosition = position
    let rep = ticked.bitmapImageRepForCachingDisplay(in: ticked.bounds)!
    ticked.cacheDisplay(in: ticked.bounds, to: rep)
    let scale = CGFloat(rep.pixelsHigh) / ticked.bounds.height
    let x = Int(ticked.trackRect.midX * scale)
    // Bitmap rows run from the top of the screen image.
    func inked(_ rows: ClosedRange<CGFloat>) -> Bool {
        (Int(rows.lowerBound * scale)..<Int(rows.upperBound * scale)).contains { y in
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
        }
    }
    return (inked(0...4), inked(12...16))
}
let below = tickRows(.below), above = tickRows(.above)
check(below.lower && !below.upper, "ticks set below are drawn \(below.upper ? "above" : "nowhere")")
check(above.upper && !above.lower, "ticks set above are drawn \(above.lower ? "below" : "nowhere")")

// Navigation bar: visited set, reset, click mapping.
let bar = ImageNavigationSlider(frame: NSRect(x: 0, y: 0, width: 600, height: 15))
bar.minValue = 0
bar.maxValue = 59
bar.numberOfTickMarks = 60
bar.allowsTickMarkValuesOnly = true
check(bar.imageCount == 60, "image count follows the tick count")
bar.intValue = 0
bar.intValue = 1
bar.intValue = 2
bar.intValue = 10
check(bar.visitedIndexes == IndexSet([0, 1, 2, 10]), "visited indexes follow the controller, got \(Array(bar.visitedIndexes))")
check(bar.value(at: NSPoint(x: 0, y: 7)) == 0, "clicking the left edge selects the first image")
check(bar.value(at: NSPoint(x: 599, y: 7)) == 59, "clicking the right edge selects the last image")
let half = bar.value(at: NSPoint(x: 300, y: 7))
check(half == 30, "clicking the middle selects image 30, got \(half)")
bar.doubleValue = half
check(bar.visitedIndexes.contains(30), "a click records the image as visited")
render(bar)
bar.maxValue = 24
bar.numberOfTickMarks = 25
check(bar.visitedIndexes.isEmpty, "a new series clears the visited band")
check(bar.imageCount == 25, "image count follows the new series")
// Mouse tracking: a click on the track moves the value and fires the action,
// with the toolbar panel never being the key window.
class Target: NSObject {
    var calls = 0
    var last = -1.0
    @objc func act(_ sender: Any?) { calls += 1; last = (sender as! NSSlider).doubleValue }
}
let target = Target()
let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
let tracked = HorosCellSlider(frame: NSRect(x: 20, y: 10, width: 213, height: 16))
tracked.minValue = 0; tracked.maxValue = 100; tracked.numberOfTickMarks = 101; tracked.allowsTickMarkValuesOnly = true
tracked.target = target; tracked.action = #selector(Target.act(_:)); tracked.isContinuous = true
host.contentView!.addSubview(tracked)
host.orderFront(nil)
check(tracked.acceptsFirstMouse(for: nil), "the first click on the floating panel must act")
let clickX = tracked.frame.minX + tracked.trackRect.midX
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: clickX, y: 18), modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: clickX, y: 18), modifierFlags: [], timestamp: 0.1, windowNumber: host.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
NSApp.postEvent(up, atStart: false)
tracked.mouseDown(with: down)
check(tracked.doubleValue == 50, "a click on the middle of the track moves the knob there, got \(tracked.doubleValue)")
check(target.calls == 1 && target.last == 50, "a continuous slider sends its action once for one click, got \(target.calls)")
host.isReleasedWhenClosed = false
host.close()

print("PASS: flat toolbar items, cell-drawn slider geometry, navigation bar visited set, click tracking")
'''

with tempfile.TemporaryDirectory(prefix='horos-toolbar-flat-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5',
        *[str(s) for s in sources], str(folder / 'main.swift'),
        '-framework', 'AppKit',
        '-o', str(folder / 'test'),
    ], check=True)
    subprocess.run([str(folder / 'test')], check=True)

print('PASS: toolbar flattening survives insertion; sliders keep their value, geometry and visited contract')
