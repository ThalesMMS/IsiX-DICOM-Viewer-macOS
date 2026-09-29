#!/usr/bin/env python3
"""Compile the production main-window observer with controlled screen/window peers.

ThumbnailsListPanel is Swift since #714: the observer is taken from the Swift
source (tests/sources.py) and compiled with Swift peers of the same shape."""
from pathlib import Path
import subprocess,tempfile,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
root=Path(__file__).resolve().parents[1]
path=sources.source_path('ThumbnailsListPanel')
s=(subprocess.check_output(['git','show',sys.argv[1]+':'+str(path.relative_to(root))]).decode('utf-8') if len(sys.argv)>1 else sources.source_text('ThumbnailsListPanel'))
a=s.index('@objc(windowDidBecomeMain:)');method=s[a:s.index('@objc(thumbnailsListWillClose:)',a)]
code=r'''
import Foundation
func check(_ c: Bool, _ what: String) { if !c { print("FAIL: \(what)"); exit(1) } }
class NSScreen: NSObject {
 static var screens: [NSScreen] = []
}
class NSWindow: NSObject {
 struct Level: Equatable { var rawValue: Int; static let normal = Level(rawValue: 0) }
 enum OrderingMode { case above, below }
 var screen: NSScreen?
 var windowController: AnyObject?
 var isVisible = false
 var level = Level.normal
 var windowNumber = 0
 var frame = NSZeroRect
 var activations = 0
 func makeKeyAndOrderFront(_ sender: Any?) { activations += 1; isVisible = true }
 func orderOut(_ sender: Any?) { isVisible = false }
 func order(_ place: OrderingMode, relativeTo number: Int) { isVisible = true }
 func setFrame(_ frame: NSRect, display: Bool) { self.frame = frame }
}
class ViewerController: NSObject {
 var window: NSWindow?
}
class Panel: NSObject {
 var viewer: ViewerController?
 var screen = 0
 var window: NSWindow?
METHOD
}
// The harness is a bare executable named "test", whose persistent defaults are
// ~/Library/Preferences/test.plist, shared with every other harness of that
// name; one running alongside could change the preference between two checks
// (#874). The argument domain is this process's own and read first.
func floating(_ on: Bool) {
 UserDefaults.standard.setVolatileDomain(["UseFloatingThumbnailsList": on], forName: UserDefaults.argumentDomain)
}
floating(true)
let a = NSScreen(), b = NSScreen(); NSScreen.screens = [a, b]
let owner = ViewerController(), other = ViewerController(); owner.window = NSWindow(); other.window = NSWindow()
owner.window!.screen = a; owner.window!.isVisible = true; owner.window!.windowNumber = 1; owner.window!.windowController = owner
other.window!.screen = b; other.window!.isVisible = true; other.window!.windowController = other
let panel = Panel(); panel.viewer = owner; panel.screen = 0; panel.window = NSWindow(); panel.window!.isVisible = true
let foreign = Notification(name: Notification.Name("main"), object: other.window)
panel.windowDidBecomeMain(foreign); check(panel.window!.isVisible && owner.window!.activations == 0, "foreign-screen focus hides the panel or activates its owner")
panel.windowDidBecomeMain(Notification(name: Notification.Name("main"), object: owner.window)); check(panel.window!.isVisible, "same-screen owner focus hides the panel")
owner.window!.isVisible = false; panel.windowDidBecomeMain(foreign); check(!panel.window!.isVisible, "hidden owner keeps the panel")
owner.window!.isVisible = true; panel.window!.isVisible = true; owner.window!.screen = b; panel.windowDidBecomeMain(foreign); check(!panel.window!.isVisible, "owner moved away keeps the panel")
owner.window!.screen = a; panel.window!.isVisible = true; other.window!.level = NSWindow.Level(rawValue: 1); panel.windowDidBecomeMain(foreign); check(panel.window!.isVisible, "auxiliary window changes the panel"); other.window!.level = .normal
panel.windowDidBecomeMain(Notification(name: Notification.Name("main"), object: panel.window)); check(owner.window!.activations == 1, "panel activation does not activate its owner")
floating(false); panel.windowDidBecomeMain(foreign); check(!panel.window!.isVisible, "disabled preference keeps the panel")
floating(true)
NSScreen.screens = []; panel.window!.isVisible = true; panel.windowDidBecomeMain(foreign); check(!panel.window!.isVisible, "no screens keeps the panel")
NSScreen.screens = [a, b]; panel.screen = -1; panel.window!.isVisible = true; panel.windowDidBecomeMain(foreign); check(!panel.window!.isVisible, "removed screen keeps the panel")
print("PASS: foreign-screen focus preserved; same-screen/panel activation, hidden/moved owner, auxiliary window, disabled preference and removed screen")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-thumbnail-focus-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-swift-version','5',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
