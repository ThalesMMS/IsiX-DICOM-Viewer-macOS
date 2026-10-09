#!/usr/bin/env python3
"""The Dock icon shows how far the running activities are, as a clock sector.

DockProgress.swift is compiled as it is, with doubles for the activity list
(ThreadsManager) and for Nitrogen's subthreadsAwareProgress, and driven in
an application process:
- aggregate: the mean of the known progress values; an unknown one
  (negative), one that is not a number, and nothing at all give no value; a
  value above 1 counts as 1. The percentage is rounded down.
- tile: a percentage puts the drawing on the Dock tile, the same percentage
  again does not redraw it, a change does, and no percentage gives the plain
  icon back; the badge set by the import stays.
- refresh: finished tasks and tasks with an unknown progress are left out of
  the activity list's mean.
- drawing: at 25 % the sector covers the quarter from twelve to three o'clock
  of the disc in the lower right corner, and not the others; the icon stays
  visible elsewhere.
- wiring: the application starts it when it has finished launching.

`<git revision>` as an optional argument reads AppController.swift from
that revision, the negative control for the wiring.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

if revision:
    app = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/AppController.swift']).decode()
else:
    app = (root / 'Horos/Sources/AppController.swift').read_text()
launch = re.search(r'func applicationDidFinishLaunching\(.*?\n    \}\n', app, re.S)
if not launch or 'DockProgress.shared.start()' not in launch.group(0):
    print('FAIL: the application must start the Dock progress when it has finished launching')
    sys.exit(1)

DOUBLES = r'''
import Foundation
import ObjectiveC

nonisolated(unsafe) private var progressKey: UInt8 = 0
extension Thread {
    @objc var subthreadsAwareProgress: CGFloat {
        get { CGFloat((objc_getAssociatedObject(self, &progressKey) as? NSNumber)?.doubleValue ?? -1) }
        set { objc_setAssociatedObject(self, &progressKey, NSNumber(value: Double(newValue)), .OBJC_ASSOCIATION_RETAIN) }
    }
}

final class ThreadsManager: NSObject {
    nonisolated(unsafe) static var list: [Thread] = []
    nonisolated(unsafe) static let instance = ThreadsManager()
    static func `default`() -> ThreadsManager! { instance }
    func threads() -> NSArray! { ThreadsManager.list as NSArray }
}
'''

DRIVER = r'''
import AppKit

@main @MainActor struct Harness {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        typealias D = DockProgress

        // aggregate and percent
        precondition(D.aggregate([]) == nil)
        precondition(D.aggregate([-1, -1]) == nil)
        precondition(D.aggregate([.nan, -0.5]) == nil)
        precondition(D.aggregate([0.5]) == 0.5)
        precondition(D.aggregate([0.5, -1, 0.25]) == 0.375)
        precondition(D.aggregate([2, 0]) == 0.5)
        precondition(D.percent(0.999) == 99 && D.percent(1) == 100 && D.percent(-3) == 0 && D.percent(0.375) == 37)

        // the tile
        let dock = D.shared
        let tile = app.dockTile
        tile.badgeLabel = "12"
        precondition(dock.displayedPercent == nil && tile.contentView == nil, "plain icon at start")
        dock.show(percent: 25)
        precondition(dock.displayedPercent == 25 && tile.contentView === dock.tileView, "25 % drawn")
        dock.show(percent: 25)
        precondition(dock.displayedPercent == 25, "the same percentage stays")
        dock.show(percent: 60)
        precondition(dock.displayedPercent == 60, "a change is drawn")
        dock.show(percent: nil)
        precondition(dock.displayedPercent == nil && tile.contentView == nil, "the plain icon comes back")
        precondition(tile.badgeLabel == "12", "the import badge stays")

        // refresh from the activity list
        let running = Thread(), unknown = Thread(), finished = Thread { }
        running.subthreadsAwareProgress = 0.5
        unknown.subthreadsAwareProgress = -1
        finished.start()
        while !finished.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        finished.subthreadsAwareProgress = 1
        ThreadsManager.list = [running, unknown, finished]
        dock.refresh()
        precondition(dock.displayedPercent == 50, "running only: \(String(describing: dock.displayedPercent))")
        ThreadsManager.list = [unknown]
        dock.refresh()
        precondition(dock.displayedPercent == nil, "only an unknown progress: plain icon")
        ThreadsManager.list = []
        dock.refresh()
        precondition(dock.displayedPercent == nil, "no task: plain icon")

        // the drawing: a grey icon, 25 %
        let side = 128
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1).setFill(); rect.fill(); return true
        }
        app.applicationIconImage = icon
        dock.show(percent: 25)
        let view = dock.tileView
        view.frame = NSRect(x: 0, y: 0, width: side, height: side)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        func white(_ x: CGFloat, _ y: CGFloat) -> Bool {
            // View coordinates are points; bitmap rows are pixels from the top.
            let c = rep.colorAt(x: Int(x * scaleX), y: rep.pixelsHigh - 1 - Int(y * scaleY))!.usingColorSpace(.deviceRGB)!
            return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
        }
        func green(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let c = rep.colorAt(x: Int(x * scaleX), y: rep.pixelsHigh - 1 - Int(y * scaleY))!.usingColorSpace(.deviceRGB)!
            return c.greenComponent > 0.5 && c.redComponent < 0.3
        }
        let w = CGFloat(side), d = w * 0.44, inset = w * 0.04
        let cx = w - inset - d / 2, cy = inset + d / 2, r = d * 0.25
        precondition(white(cx + r, cy + r), "twelve to three o'clock must be filled at 25 %")
        precondition(!white(cx - r, cy + r), "nine to twelve must not be filled at 25 %")
        precondition(!white(cx + r, cy - r) && !white(cx - r, cy - r), "the lower half must not be filled at 25 %")
        precondition(green(10, w - 10) && green(10, 10), "the icon must stay visible outside the disc")
        print("PASS: mean of known progress, rounded down; tile follows the percentage, plain icon back without a value, badge kept; finished and unknown tasks left out; the sector fills clockwise from twelve; started at launch")
        exit(0)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-dock-progress-') as directory:
    p = Path(directory)
    (p / 'doubles.swift').write_text(DOUBLES)
    (p / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(root / 'Horos/Sources/DockProgress.swift'),
                    str(p / 'doubles.swift'), str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=120)
