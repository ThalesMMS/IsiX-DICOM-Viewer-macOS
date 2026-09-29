#!/usr/bin/env python3
"""Exercise production recovery with real AppKit split views and saved preferences."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
import harness_defaults  # the harness's preferences stay in its own process (#923)

# NSSplitView (Defaults) is NSSplitViewSave.swift since #714. -spaceEvenly: and
# -restoreWindowState: are in the toolbar block of BrowserController, and
# -drawerToggle: and -splitView:resizeSubviewsWithOldSize: in its
# NSSplitViewDelegate block: Swift extensions since #831
# (BrowserController+Toolbar.swift, BrowserController+SplitView.swift). The
# production methods are compiled with xcrun swiftc into a probe that owns the
# same split views, as the Objective-C methods were with clang.
split_save = sources.source_path('NSSplitViewSave')
toolbar = sources.source_text('BrowserController+Toolbar')
split = sources.source_text('BrowserController+SplitView')
a = toolbar.index('    @objc(spaceEvenly:)')
layout = toolbar[a:toolbar.index('    @objc(toolbarDefaultItemIdentifiers:)', a)]
a = split.index('    @objc(drawerToggle:)')
toggle = split[a:split.index('    @objc(splitView:constrainMinCoordinate:ofSubviewAt:)', a)]
a = split.index('    @objc(splitView:resizeSubviewsWithOldSize:)\n    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {')
b = split.index('        if sender === horos_splitComparative {', a)
resize = split[a:b] + '        sender.adjustSubviews()\n    }\n'
# [[split subviews] objectAtIndex:], as the production file spells it.
a = split.index('fileprivate func objcSubview(')
subview = split[a:split.index('\n}\n', a) + 3]
code = r"""
import AppKit
SUBVIEW
func check(_ c: Bool, _ what: String = "", line: Int = #line) { precondition(c, "failed at line \(line) \(what)") }
class BrowserProbe: NSObject, NSSplitViewDelegate {
 var horos_splitDrawer, horos_splitAlbums, horos_splitViewHorz, horos_splitComparative, horos_splitViewVert: NSSplitView?
 var horos_splitViewVertDividerRatio: CGFloat = 0
LAYOUT
TOGGLE
RESIZE
}
func split(_ vertical: Bool, _ width: CGFloat, _ height: CGFloat, _ count: Int) -> NSSplitView {
 let v = NSSplitView(frame: NSMakeRect(0, 0, width, height))
 v.isVertical = vertical
 for _ in 0..<count {
   let child = NSView(frame: .zero); child.isHidden = true; v.addSubview(child)
 }
 return v
}
func visible(_ v: NSSplitView) {
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
autoreleasepool {
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
 }
 b.spaceEvenly(split(true, 0, 0, 0))
 for key in ["SplitDrawer", "SplitAlbums", "SplitHorz2", "SplitComparative", "SplitVert2", "SplitDrawerHidden", "SplitComparativeHidden"] {
  defaults.removeObject(forKey: key)
 }
 NSLog("PASS: horizontal/vertical hidden and collapsed panes, 640/1600 widths, toggle from zero, saved layout, visibility flags, empty split")
}
""".replace('SUBVIEW', subview).replace('LAYOUT', layout).replace('TOGGLE', toggle).replace('RESIZE', resize)
with tempfile.TemporaryDirectory(prefix='horos-layout-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(harness_defaults.SWIFT + code)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'DatabaseLayoutProbe',
                    str(root / 'Horos/Sources/DatabaseBrowserLayout.swift'), str(split_save),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
