#!/usr/bin/env python3
"""Verify production fullscreen forwarding and preservation of the windowed frame.

-fullScreenMenu:, -windowWillEnterFullScreen: and the frame -browserPrepareForClose
saves are BrowserController+Window.swift; they are compiled here against a
stand-in window and browser with the same members.
"""
from pathlib import Path
import subprocess, tempfile
import harness_defaults  # the harness's preferences stay in its own process

root = Path(__file__).resolve().parents[1]
s = (root / 'Horos/Sources/BrowserController+Window.swift').read_text()


def closing(source, start):
    depth = 0
    for i in range(start, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    raise SystemExit('FAIL: unbalanced braces')


def function(signature):
    at = s.index(signature)
    return s[at:closing(s, s.index('{', at))]


methods = function('func fullScreenMenu(_ sender: Any!)') + '\n' + function('func windowWillEnterFullScreen(_ notification: Notification!)')
a = s.index('        var savedFrame = window?.frame ?? .zero')
save = s[a:s.index('\n', s.index('forKey: "DBWindowFrame")', a))]
code = harness_defaults.SWIFT + r'''
import AppKit
func check(_ c: Bool, _ what: String) { if !c { print("failed: " + what); exit(1) } }
final class WindowProbe: NSObject {
    var frame = NSRect.zero
    var styleMask: NSWindow.StyleMask = []
    var sender: AnyObject?
    func toggleFullScreen(_ sender: Any?) { self.sender = sender as AnyObject? }
}
final class BrowserProbe: NSObject {
    var window: WindowProbe?
    var horos_databaseWindowedFrame = NSRect.zero
    METHODS
    func saveFrame() { let defaults = UserDefaults.standard
SAVE
    }
}
let browser = BrowserProbe(); browser.window = WindowProbe()
let original = NSRect(x: -1000, y: 40, width: 900, height: 700); browser.window?.frame = original
let sender = NSObject(); browser.fullScreenMenu(sender); check(browser.window?.sender === sender, "forwarded")
browser.windowWillEnterFullScreen(Notification(name: Notification.Name("enter"), object: browser.window))
browser.window?.frame = NSRect(x: 0, y: 0, width: 1700, height: 1100); browser.window?.styleMask = .fullScreen
browser.windowWillEnterFullScreen(Notification(name: Notification.Name("other"), object: WindowProbe()))
browser.saveFrame(); check(NSRectFromString(UserDefaults.standard.string(forKey: "DBWindowFrame") ?? "") == original, "windowed frame saved")
browser.window?.styleMask = []; browser.window?.frame = NSRect(x: 20, y: 40, width: 800, height: 600); browser.saveFrame()
check(NSRectFromString(UserDefaults.standard.string(forKey: "DBWindowFrame") ?? "") == browser.window!.frame, "frame after exit saved")
UserDefaults.standard.removeObject(forKey: "DBWindowFrame")
print("PASS: native toggle forwarding, own-window notification, normal geometry saved while fullscreen and updated after exit")
'''.replace('METHODS', methods).replace('SAVE', save)
with tempfile.TemporaryDirectory(prefix='horos-database-fullscreen-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-o', str(p / 'test'), str(p / 'main.swift')], check=True, timeout=300)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
