#!/usr/bin/env python3
"""Exercise production recovery with real AppKit split views and saved preferences."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
import harness_defaults  # the harness's preferences stay in its own process

# NSSplitView (Defaults) is NSSplitViewSave.swift. -spaceEvenly: and
# -restoreWindowState: are in the toolbar block of BrowserController, and
# -drawerToggle: and -splitView:resizeSubviewsWithOldSize: in its
# NSSplitViewDelegate block: Swift extensions
# (BrowserController+Toolbar.swift, BrowserController+SplitView.swift). The
# production methods are compiled with xcrun swiftc into a probe that owns the
# same split views, as the Objective-C methods were with clang.
split_save = sources.source_path('NSSplitViewSave')
toolbar = sources.source_text('BrowserController+Toolbar')
split = sources.source_text('BrowserController+SplitView')
a = toolbar.index('    @objc(spaceEvenly:)')
layout = toolbar[a:toolbar.index('    @objc(toolbarDefaultItemIdentifiers:)', a)]
a = split.index('    @objc(comparativeToggle:)')
toggle = split[a:split.index('    @objc(splitView:constrainMinCoordinate:ofSubviewAt:)', a)]
a = split.index('    @objc(splitView:resizeSubviewsWithOldSize:)\n    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {')
b = split.index('        if sender === horos_splitViewVert {', a)
resize = split[a:b] + '        sender.adjustSubviews()\n    }\n'
a = split.index('    @objc(splitViewDidResizeSubviews:)')
b = split.index('        if (notification.object as AnyObject?) === horos_splitViewVert {', a)
save = split[a:b] + '    }\n'
# [[split subviews] objectAtIndex:], as the production file spells it.
a = split.index('fileprivate func objcSubview(')
subview = split[a:split.index('\n}\n', a) + 3]
code = r"""
import AppKit
SUBVIEW
func check(_ c: Bool, _ what: String = "", line: Int = #line) { precondition(c, "failed at line \(line) \(what)") }
enum BrowserController {
 @MainActor static var horizontal = false
 @MainActor static func horizontalHistory() -> Bool { horizontal }
}
let MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ: CGFloat = 50
// The browser's layout is the main actor's.
@MainActor class BrowserProbe: NSObject, NSSplitViewDelegate {
 var horos_splitDrawer, horos_splitAlbums, horos_splitViewHorz, horos_splitComparative, horos_splitViewVert: NSSplitView?
 var horos_splitViewVertDividerRatio: CGFloat = 0
LAYOUT
TOGGLE
RESIZE
SAVE
}
@MainActor func split(_ vertical: Bool, _ width: CGFloat, _ height: CGFloat, _ count: Int) -> NSSplitView {
 let v = NSSplitView(frame: NSMakeRect(0, 0, width, height))
 v.isVertical = vertical
 for _ in 0..<count {
   let child = NSView(frame: .zero); child.isHidden = true; v.addSubview(child)
 }
 return v
}
@MainActor func visible(_ v: NSSplitView) {
 check(!v.isHidden)
 for child in v.subviews {
   check(!child.isHidden); check(child.frame.size.width > 0); check(child.frame.size.height > 0)
   check(NSContainsRect(v.bounds, child.frame))
 }
 for i in 1..<max(1, v.subviews.count) {
   let previous = v.subviews[i-1].frame, current = v.subviews[i].frame
   check(v.isVertical ? NSMaxX(previous) <= NSMinX(current) : NSMaxY(previous) <= NSMinY(current))
 }
}
MainActor.assumeIsolated { autoreleasepool {
 _ = NSApplication.shared
 let b = BrowserProbe()
 let defaults = UserDefaults.standard
 for w in [640.0, 1600.0] as [CGFloat] {
  b.horos_splitDrawer = split(true, w, 600, 2); b.horos_splitDrawer!.delegate = b
  b.horos_splitAlbums = split(false, 192, 600, 3)
  b.horos_splitViewHorz = split(false, w - 192, 600, 2)
  b.horos_splitComparative = split(true, w - 192, 300, 2)
  b.horos_splitViewVert = split(true, w - 192, 300, 2)
  defaults.set(true, forKey: "SplitDrawerHidden")
  defaults.set(true, forKey: "SplitComparativeHidden")
  b.restoreWindowState(nil)
  for v in [b.horos_splitDrawer!, b.horos_splitAlbums!, b.horos_splitViewHorz!, b.horos_splitComparative!, b.horos_splitViewVert!] { visible(v) }
  check(b.horos_splitDrawer!.subviews[0].frame.size.width == 192)
  check(!defaults.bool(forKey: "SplitDrawerHidden"))
  check(!defaults.bool(forKey: "SplitComparativeHidden"))
  let reloaded = split(true, w, 600, 2)
  for v in reloaded.subviews { v.isHidden = false }
  reloaded.restoreDefault("SplitDrawer"); visible(reloaded)
  check(reloaded.subviews[0].frame.size.width == 192)
  b.drawerToggle(nil); check(b.horos_splitDrawer!.subviews[0].isHidden)
  check(b.horos_splitDrawer!.subviews[0].frame.size.width == 0)
  b.drawerToggle(nil); visible(b.horos_splitDrawer!)
  check(b.horos_splitDrawer!.subviews[0].frame.size.width == 192)
  // Also recover a dragged-to-zero pane that was never marked hidden.
  b.horos_splitDrawer!.subviews[0].frame = .zero
  b.drawerToggle(nil); visible(b.horos_splitDrawer!)
  // A width the user chose stays through a resize of the window, within limits.
  let drawer = b.horos_splitDrawer!
  let available = w - drawer.dividerThickness
  let cap = min(max(160, min(400, available - 400)), available / 2)
  drawer.subviews[0].frame.size.width = 300
  drawer.resizeSubviews(withOldSize: drawer.bounds.size)
  check(drawer.subviews[0].frame.size.width == min(300, cap), "kept \(drawer.subviews[0].frame.size.width)")
  check(drawer.subviews[1].frame.size.width >= min(400, available / 2))
  drawer.subviews[0].frame.size.width = 900
  drawer.resizeSubviews(withOldSize: drawer.bounds.size)
  check(drawer.subviews[0].frame.size.width == cap, "capped \(drawer.subviews[0].frame.size.width)")
  drawer.subviews[0].frame.size.width = 0
  drawer.resizeSubviews(withOldSize: drawer.bounds.size)
  check(drawer.subviews[0].frame.size.width == 192, "a width that is not one is the default")
  // Hidden and shown again, the sidebar comes back at the width it had.
  drawer.subviews[0].frame.size.width = min(250, cap)
  b.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: drawer))
  b.drawerToggle(nil); check(drawer.subviews[0].isHidden)
  b.drawerToggle(nil); visible(drawer)
  check(drawer.subviews[0].frame.size.width == min(250, cap), "reopened at \(drawer.subviews[0].frame.size.width)")
 }
 // A fresh controller restores the independent width even if generic split
 // restoration first produces a different frame and a resize notification.
 let historyKey = DatabaseBrowserLayout.historyWidthDefaultsKey
 defaults.set(280.0, forKey: historyKey)
 @MainActor func newHistory(_ width: CGFloat, hidden: Bool = false) -> NSSplitView {
  let v = split(true, width, 300, 2)
  b.horos_splitComparative = v
  v.delegate = b
  for pane in v.subviews { pane.isHidden = false }
  v.subviews[0].frame = NSMakeRect(0, 0, width - 192 - v.dividerThickness, 300)
  v.subviews[1].frame = NSMakeRect(width - 192, 0, 192, 300)
  v.subviews[1].isHidden = hidden
  DatabaseBrowserLayout.prepareColumns(drawer: nil, comparative: v)
  b.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: v))
  DatabaseBrowserLayout.restoreHistoryWidth(in: v)
  return v
 }
 var comparative = newHistory(1200)
 check(comparative.subviews[1].frame.width == 280, "startup retains saved width")
 comparative.subviews[1].frame.size.width = 310
 b.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: comparative))
 check(defaults.double(forKey: historyKey) == 310, "delegate saves width")
 b.comparativeToggle(nil)
 check(comparative.subviews[1].isHidden && comparative.subviews[1].frame.width == 0)
 b.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: comparative))
 check(defaults.double(forKey: historyKey) == 310, "hiding does not save zero")
 b.comparativeToggle(nil); visible(comparative)
 check(comparative.subviews[1].frame.width == 310)
 comparative = newHistory(1200, hidden: true)
 check(defaults.double(forKey: historyKey) == 310, "relaunch while hidden retains width")
 b.comparativeToggle(nil)
 check(comparative.subviews[1].frame.width == 310, "hidden relaunch expands at saved width")
 comparative = newHistory(500)
 check(comparative.subviews[1].frame.width == 150, "smaller window clamps width")
 for value in [0.0, -20, Double.nan, Double.infinity, 900, 25] {
  defaults.set(value, forKey: historyKey)
  comparative = newHistory(1200)
  let expected: CGFloat = value.isFinite && value > 0 ? min(400, max(150, CGFloat(value))) : 192
  check(comparative.subviews[1].frame.width == expected, "invalid or out-of-range preference")
 }
 defaults.set(310.0, forKey: historyKey)
 comparative = newHistory(1200)
 b.restoreWindowState(nil)
 check(defaults.double(forKey: historyKey) == 192, "reset clears saved custom width")
 check(comparative.subviews[1].frame.width == 192)
 // Height changes in the horizontal History mode cannot change its vertical width.
 BrowserController.horizontal = true
 let horizontal = split(false, 1200, 600, 2)
 b.horos_splitComparative = horizontal
 DatabaseBrowserLayout.prepareColumns(drawer: nil, comparative: horizontal)
 DatabaseBrowserLayout.restoreHistoryWidth(in: horizontal)
 b.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: horizontal))
 b.restoreWindowState(nil)
 check(defaults.double(forKey: historyKey) == 192, "horizontal mode preserves width preference")
 BrowserController.horizontal = false
 // The divider limits leave the study list its room.
 let limits = DatabaseBrowserLayout.sidebarDividerLimits(available: 1600)
 check(limits.location == 160 && limits.location + limits.length == 400)
 let history = DatabaseBrowserLayout.historyDividerLimits(available: 1600)
 check(history.location == 1200 && history.location + history.length == 1450)
 let narrow = DatabaseBrowserLayout.historyDividerLimits(available: 500)
 check(narrow.location == 350 && narrow.length == 0)
 b.spaceEvenly(split(true, 0, 0, 0))
 for key in ["SplitDrawer", "SplitAlbums", "SplitHorz2", "SplitComparative", "SplitVert2", "SplitDrawerHidden", "SplitComparativeHidden", "DatabaseSidebarWidth", historyKey] {
  defaults.removeObject(forKey: key)
 }
 NSLog("PASS: horizontal/vertical hidden and collapsed panes, 640/1600 widths, toggle from zero, saved layout, visibility flags, empty split")
} }
""".replace('SUBVIEW', subview).replace('LAYOUT', layout).replace('TOGGLE', toggle).replace('RESIZE', resize).replace('SAVE', save)
with tempfile.TemporaryDirectory(prefix='horos-layout-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(harness_defaults.SWIFT + code)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'DatabaseLayoutProbe',
                    str(root / 'Horos/Sources/DatabaseBrowserLayout.swift'), str(split_save),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
