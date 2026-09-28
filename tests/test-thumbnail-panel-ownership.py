#!/usr/bin/env python3
"""Compile the production detach/deinit methods with real NSView ownership.

ThumbnailsListPanel is Swift since #714: the methods (and the file's
associatedScreen dictionary and its key) are taken from the Swift source
(tests/sources.py). The former manual retain/release is ARC there: the probe
viewer checks, as it is released, that the list is back in its own view."""
from pathlib import Path
import subprocess,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
s=sources.source_text('ThumbnailsListPanel')
g=s.index('fileprivate var associatedScreen');globals_=s[g:s.index('///',s.index('fileprivate func pointerKey',g))]
a=s.index('@objc public func prepareForScreenReconfiguration()');methods=s[a:s.index('@objc(windowDidResignKey:)',a)]
code=r'''
import AppKit
func check(_ c: Bool, _ what: String) { if !c { print("failed: \(what)"); exit(1) } }
var viewerDeallocs = 0, windowHides = 0
GLOBALS
final class ViewerProbe: NSObject {
 var parent: NSView?
 weak var expected: NSView?
 deinit { check(expected?.superview === parent, "expected.superview==parent"); viewerDeallocs += 1 }
}
final class ThumbnailsListNSWindow: NSObject {
 func hideForReconfiguration() { windowHides += 1 }
}
let sharedWindow = ThumbnailsListNSWindow()
final class PanelProbe: NSObject {
 var thumbnailsView: NSView?
 weak var superView: NSView?
 var viewer: ViewerProbe?
 var isWindowLoaded: Bool { return true }
 var window: AnyObject? { return sharedWindow }
METHODS
}
func attach(_ thumbnail: NSView) -> PanelProbe {
 let panel = PanelProbe(); let viewer = ViewerProbe(); viewer.parent = NSView(); viewer.expected = thumbnail
 panel.viewer = viewer; panel.superView = viewer.parent; panel.thumbnailsView = thumbnail
 associatedScreen!.setObject(1, forKey: pointerKey(thumbnail))
 return panel
}
autoreleasepool {
 associatedScreen = NSMutableDictionary(); let thumbnail = NSView(), floatingContent = NSView()
 floatingContent.addSubview(thumbnail); var panel: PanelProbe? = attach(thumbnail)
 UserDefaults.standard.set(false, forKey: "UseFloatingThumbnailsList")
 panel!.prepareForScreenReconfiguration(); check(viewerDeallocs == 1, "viewerDeallocs==1"); check(panel!.viewer == nil && panel!.thumbnailsView == nil && panel!.superView == nil, "detached"); check(associatedScreen!.count == 0, "associatedScreen.count==0")
 panel!.prepareForScreenReconfiguration(); panel = nil; check(viewerDeallocs == 1, "idempotent")
 floatingContent.addSubview(thumbnail); panel = attach(thumbnail); panel = nil; check(viewerDeallocs == 2 && associatedScreen!.count == 0, "deinit cleanup")
 panel = PanelProbe(); panel = nil; check(viewerDeallocs == 2, "empty panel"); check(windowHides == 5, "windowHides==5")
 UserDefaults.standard.removeObject(forKey: "UseFloatingThumbnailsList")
 print("PASS: view returned before owner release; disabled-preference detach, idempotence, deinit cleanup and empty panels")
}
'''.replace('GLOBALS',globals_).replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='horos-thumbnail-ownership-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-swift-version','5',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
