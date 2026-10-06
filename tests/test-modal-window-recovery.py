#!/usr/bin/env python3
"""Exercise production recovery selection, including borderless modal panels.

-recoverWindowsAfterScreenChange is in the preview window policy block of
BrowserController, a Swift extension
(BrowserController+Preview.swift). The production method is
compiled with xcrun swiftc against stand-ins for the windows, the application
and the placement it calls, as the Objective-C version was with clang. An
optional git revision reads the Swift file of that revision.
"""
from pathlib import Path
import subprocess, tempfile, sys
root = Path(__file__).resolve().parents[1]
path = 'Horos/Sources/BrowserController+Preview.swift'
s = (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1]+':'+path]) if len(sys.argv)>1 else (root/path).read_bytes()).decode('utf-8')
a=s.index('    @objc(recoverWindowsAfterScreenChange)\n')
method=s[a:s.index('    @objc(previewMatrixScrollViewFrameDidChange:)',a)]
code=r'''
import Foundation
import CoreGraphics
class NSWindow: NSObject {
 struct StyleMask: OptionSet { let rawValue: UInt; static let titled = StyleMask(rawValue: 1) }
 var styleMask: StyleMask = []
 var isVisible = false, isMiniaturized = false
 var frame = CGRect.zero
}
class NSPanel: NSWindow {}
class App: NSObject {
 var windows: [NSWindow] = []
 var modalWindow: NSWindow?
}
let NSApp = App()
var restored: [NSWindow] = []
class NSScreen: NSObject { static var screens: [NSScreen] { return [] } }
enum DatabaseWindowPlacement {
 static func restore(_ window: NSWindow, savedFrame: CGRect) { restored.append(window) }
}
enum ToolbarPanelController { static func checkForValidToolbar() {} }
class ViewerController: NSObject {
 static func frontMostDisplayed2DViewer(for screen: NSScreen) -> ViewerController? { return nil }
 func redrawToolbar() {}
}
func objcTry(_ body: () -> Void) -> NSException? { body(); return nil }
func _N2LogExceptionImpl(_ e: NSException, _ fatal: Bool, _ where: String) {}
class Browser: NSObject {
 var window: NSWindow?
METHOD
}
func check(_ c: Bool, _ what: String) { if !c { print("FAIL: \(what)"); exit(1) } }
let b=Browser()
let db=NSWindow(),viewer=NSWindow(),hidden=NSWindow(),mini=NSWindow(),borderless=NSWindow()
let modal=NSPanel(),utility=NSPanel()
for w in [db,viewer,hidden,mini,utility] { w.styleMask = .titled }
for w in [viewer,modal,utility,borderless] { w.isVisible = true }
mini.isMiniaturized=true;b.window=db
NSApp.windows=[db,viewer,hidden,mini,modal,utility,borderless];NSApp.modalWindow=modal
b.recoverWindowsAfterScreenChange()
check(restored.elementsEqual([db,viewer,mini,modal], by: ===), "restored == [db,viewer,mini,modal]")
restored.removeAll();NSApp.modalWindow=nil;b.recoverWindowsAfterScreenChange()
check(restored.elementsEqual([db,viewer,mini], by: ===), "restored == [db,viewer,mini]")
NSLog("PASS: active borderless modal, normal/miniaturized/database windows; utility and hidden windows preserved")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-modal-recovery-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
