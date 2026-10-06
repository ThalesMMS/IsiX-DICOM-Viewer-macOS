#!/usr/bin/env python3
"""A key-window change must hand the shared list to its viewer on that screen.

ThumbnailsListPanel is Swift: the observer is taken from the Swift
source (tests/sources.py) and compiled with Swift peers of the same shape."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

source = sources.source_text('ThumbnailsListPanel')
start = source.index('@objc(windowDidBecomeKey:)')
method = source[start:source.index('@objc(windowDidResignMain:)', start)]
code = r'''
import Foundation
func check(_ c: Bool, _ what: String) { if !c { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); exit(1) } }
class NSWindow: NSObject {
    enum OrderingMode { case above, below }
    var screen: AnyObject?
    var windowController: AnyObject?
    var isVisible = false
    var windowNumber = 0
    func makeKeyAndOrderFront(_ sender: Any?) {}
    func order(_ place: OrderingMode, relativeTo number: Int) { isVisible = true }
    func orderOut(_ sender: Any?) { isVisible = false }
}
class ViewerController: NSObject {
    var window: NSWindow?
    var list: AnyObject?
    func previewMatrixScrollView() -> AnyObject? { return list }
}
var panels: [NSNumber: Panel] = [:]
class AppController: NSObject {
    class func thumbnailsListPanel(for screen: AnyObject?) -> Panel? { return (screen as? NSNumber).flatMap { panels[$0] } }
}
class Panel: NSObject {
    var viewer: ViewerController?
    var window: NSWindow?
    var list: AnyObject?
    var attachments = 0
    func setThumbnailsView(_ list: AnyObject?, viewer owner: ViewerController?) { self.list = list; viewer = owner; attachments += 1 }
METHOD
}
let defaults = UserDefaults.standard
defaults.setVolatileDomain(["UseFloatingThumbnailsList": true], forName: UserDefaults.argumentDomain)
let a = Panel(), b = Panel(), spare = Panel(); panels = [0: a, 1: b]
a.window = NSWindow(); b.window = NSWindow(); spare.window = NSWindow()
let first = ViewerController(), second = ViewerController()
first.window = NSWindow(); second.window = NSWindow()
first.window!.windowController = first; second.window!.windowController = second
first.window!.screen = NSNumber(value: 0); second.window!.screen = NSNumber(value: 1)
first.window!.isVisible = true; second.window!.isVisible = true
first.list = NSObject(); second.list = NSObject()
let one = Notification(name: Notification.Name("key"), object: first.window)
let two = Notification(name: Notification.Name("key"), object: second.window)
for panel in [a, b, spare] { panel.windowDidBecomeKey(one) }
check(a.viewer === first && a.list === first.list && a.attachments == 1, "a->viewer==first && a.list==first.previewMatrixScrollView && a.attachments==1")
check(b.attachments == 0 && spare.attachments == 0, "b.attachments==0 && spare.attachments==0")
for panel in [a, b, spare] { panel.windowDidBecomeKey(two) }
check(a.viewer === first && b.viewer === second && b.attachments == 1 && spare.attachments == 0, "a->viewer==first && b->viewer==second && b.attachments==1 && spare.attachments==0")
second.window!.screen = NSNumber(value: 0); a.windowDidBecomeKey(two) // same-screen focus, no main notification
check(a.viewer === second && a.list === second.list && a.attachments == 2, "a->viewer==second && a.list==second.previewMatrixScrollView && a.attachments==2")
second.window!.isVisible = false; a.windowDidBecomeKey(two); check(a.attachments == 2, "hidden viewer: a.attachments==2")
second.window!.isVisible = true
defaults.setVolatileDomain(["UseFloatingThumbnailsList": false], forName: UserDefaults.argumentDomain)
a.windowDidBecomeKey(two); check(a.attachments == 2, "disabled mode: a.attachments==2")
print("PASS: key-only focus hands off the list; other screens, spare panels, hidden viewers and disabled mode stay untouched")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-thumbnail-key-') as folder:
    folder = Path(folder); (folder/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder/'main.swift'), '-o', str(folder/'test')], check=True)
    subprocess.run([str(folder/'test')], check=True)
