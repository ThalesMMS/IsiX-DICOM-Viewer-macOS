#!/usr/bin/env python3
"""The real window override must not reattach a list during detach or on a spare panel.

ThumbnailsListNSWindow is Swift since #714: the override is taken from the
Swift source (tests/sources.py) and compiled with Swift peers of the same shape."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

source = sources.source_text('ThumbnailsListNSWindow')
start = source.index('@objc public func hideForReconfiguration()')
methods = source[start:source.index('public override func animationResizeTime(', start)]
code = r'''
import Foundation
func check(_ c: Bool, _ what: String) { if !c { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); exit(1) } }
var hides = 0, orders = 0, attachments = 0, updateDepth = 0
func NSDisableScreenUpdates() { updateDepth += 1 }
func NSEnableScreenUpdates() { updateDepth -= 1 }
class WindowBase: NSObject {
    enum OrderingMode { case above, below }
    var screen: AnyObject?
    var windowController: AnyObject?
    var windowNumber = 0
    func orderOut(_ sender: Any?) { hides += 1 }
    func order(_ place: OrderingMode, relativeTo number: Int) { orders += 1 }
}
class ThumbnailsListPanel: NSObject {
    var window: WindowBase?
    func setThumbnailsView(_ view: AnyObject?, viewer: ViewerController?) { attachments += 1 }
}
var front: ViewerController?
class ViewerController: NSObject {
    var window: WindowBase?
    var list: AnyObject?
    func previewMatrixScrollView() -> AnyObject? { return list }
    class func frontMostDisplayed2DViewer(for screen: AnyObject?) -> ViewerController? { return front }
}
var registered: ThumbnailsListPanel?
class AppController: NSObject {
    class func thumbnailsListPanel(for screen: AnyObject?) -> ThumbnailsListPanel? { return registered }
}
class ThumbnailsListNSWindow: WindowBase {
METHODS
}
let defaults = UserDefaults.standard
defaults.setVolatileDomain(["SeriesListVisible": true, "UseFloatingThumbnailsList": true], forName: UserDefaults.argumentDomain)
let window = ThumbnailsListNSWindow()
registered = ThumbnailsListPanel(); registered!.window = window; window.windowController = registered
front = ViewerController(); front!.window = WindowBase(); front!.window!.windowNumber = 2
front!.list = NSObject()
window.hideForReconfiguration()
check(hides == 1 && attachments == 0 && orders == 0 && updateDepth == 0, "hides==1 && attachments==0 && orders==0 && updateDepth==0")
window.orderOut(nil)
check(hides == 1 && attachments == 1 && orders == 1 && updateDepth == 0, "ordinary fallback preserved") // ordinary fallback preserved
let spare = ThumbnailsListNSWindow()
spare.screen = window.screen; spare.windowController = ThumbnailsListPanel()
spare.orderOut(nil)
check(hides == 2 && attachments == 1 && orders == 1 && updateDepth == 0, "spare panel stays hidden")
registered = nil; window.orderOut(nil) // screen removed or mapping replaced
check(hides == 3 && attachments == 1, "unmapped panel stays hidden")
registered = ThumbnailsListPanel(); registered!.window = window
defaults.setVolatileDomain(["SeriesListVisible": true, "UseFloatingThumbnailsList": false], forName: UserDefaults.argumentDomain)
window.orderOut(nil); check(hides == 4 && attachments == 1, "docked list: hides==4 && attachments==1")
defaults.setVolatileDomain(["SeriesListVisible": false, "UseFloatingThumbnailsList": true], forName: UserDefaults.argumentDomain)
window.orderOut(nil); check(hides == 5 && attachments == 1, "hidden list: hides==5 && attachments==1")
print("PASS: explicit detach cannot reattach; spare/unmapped panels remain hidden; ordinary owner fallback and disabled preferences preserved")
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='horos-thumbnail-hide-') as folder:
    folder = Path(folder); (folder/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder/'main.swift'), '-o', str(folder/'test')], check=True)
    subprocess.run([str(folder/'test')], check=True)
