#!/usr/bin/env python3
"""A wait panel gives the keyboard back to the window it took it from.

The «Reslicing...» panel of a change of plane, and the other wait panels,
make themselves key while they show. Ordered out, they left the application
without a key window unless a modal session had been opened: the system then
chose the next one, which could be the database window instead of the viewer
the user was working in.

KeyWindowReturn.swift is compiled alone and run against windows that record
what they are sent (a process that is not the active application has no key
window to observe):
- the window noted is made key before the panel is ordered out, and is not
  reordered;
- a panel that is no longer key, a window that was closed or hidden, and a
  panel shown again while key give the expected result;
- the end of the modal session runs after the panel is ordered out.
And Wait.swift and WaitRendering.swift note the key window before showing and
order out through it.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/KeyWindowReturn.swift'

DRIVER = r'''
import AppKit

nonisolated(unsafe) var log: [String] = []

final class Recorded: NSWindow {
    var name = ""
    var key = false
    var shown = true
    override var isKeyWindow: Bool { key }
    override var isVisible: Bool { shown }
    override var canBecomeKey: Bool { true }
    override func makeKey() { log.append("makeKey \(name)"); key = true }
    override func orderOut(_ sender: Any?) { log.append("orderOut \(name)"); shown = false; key = false }
    override func orderFront(_ sender: Any?) { log.append("orderFront \(name)") }
    override func makeKeyAndOrderFront(_ sender: Any?) { log.append("makeKeyAndOrderFront \(name)") }
}

@MainActor func window(_ name: String, key: Bool = false) -> Recorded {
    let w = Recorded(contentRect: NSMakeRect(0, 0, 10, 10), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.name = name
    w.key = key
    return w
}

nonisolated(unsafe) var failures = 0
func expect(_ title: String, _ expected: [String]) {
    if log != expected {
        failures += 1
        print("FAIL: \(title): \(log) instead of \(expected)")
    }
    log = []
}

@MainActor func run() {
    _ = NSApplication.shared

    // The panel takes the keyboard from the viewer and gives it back.
    do {
        let viewer = window("viewer", key: true), panel = window("panel")
        var back = KeyWindowReturn()
        back.remember(viewer, before: panel)
        viewer.key = false; panel.key = true
        back.orderOut(panel) { log.append("session ended") }
        expect("return", ["makeKey viewer", "orderOut panel", "session ended"])
        if !viewer.key { failures += 1; print("FAIL: the viewer is not key after the panel went") }
        // Nothing is kept for a second closing.
        back.orderOut(panel)
        expect("second closing", ["orderOut panel"])
    }
    // The end of the session took the keyboard away again: it comes back.
    do {
        let viewer = window("viewer", key: true), panel = window("panel")
        var back = KeyWindowReturn()
        back.remember(viewer, before: panel)
        viewer.key = false; panel.key = true
        back.orderOut(panel) { viewer.key = false }
        expect("return after the session", ["makeKey viewer", "orderOut panel", "makeKey viewer"])
    }
    // The keyboard went elsewhere while the panel showed: it stays there.
    do {
        let viewer = window("viewer", key: true), panel = window("panel")
        var back = KeyWindowReturn()
        back.remember(viewer, before: panel)
        viewer.key = false; panel.key = false
        back.orderOut(panel)
        expect("panel not key", ["orderOut panel"])
    }
    // The window was hidden meanwhile.
    do {
        let viewer = window("viewer", key: true), panel = window("panel")
        var back = KeyWindowReturn()
        back.remember(viewer, before: panel)
        viewer.key = false; viewer.shown = false; panel.key = true
        back.orderOut(panel)
        expect("hidden window", ["orderOut panel"])
    }
    // The window was deallocated meanwhile.
    do {
        let panel = window("panel")
        var back = KeyWindowReturn()
        autoreleasepool {
            let viewer = window("viewer", key: true)
            back.remember(viewer, before: panel)
        }
        panel.key = true
        back.orderOut(panel)
        expect("deallocated window", ["orderOut panel"])
    }
    // Shown again while key: the window noted first is kept. No key window: nothing.
    do {
        let viewer = window("viewer", key: true), panel = window("panel")
        var back = KeyWindowReturn()
        back.remember(viewer, before: panel)
        viewer.key = false; panel.key = true
        back.remember(panel, before: panel)
        back.remember(nil, before: panel)
        back.orderOut(panel)
        expect("shown twice", ["makeKey viewer", "orderOut panel"])

        var none = KeyWindowReturn()
        none.remember(nil, before: panel)
        panel.key = true
        none.orderOut(panel)
        expect("no key window", ["orderOut panel"])
    }
}

MainActor.assumeIsolated { run() }
exit(failures == 0 ? 0 : 1)
'''

failures = []

with tempfile.TemporaryDirectory() as work:
    driver = Path(work) / 'main.swift'
    driver.write_text(DRIVER, encoding='utf-8')
    binary = Path(work) / 'key-window-return'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-o', str(binary), str(source), str(driver)],
                           capture_output=True, text=True)
    if built.returncode != 0:
        print(built.stdout + built.stderr, file=sys.stderr)
        print('FAIL: KeyWindowReturn.swift does not compile alone', file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    if ran.returncode != 0:
        failures.append((ran.stdout + ran.stderr).strip() or f'the driver exited with {ran.returncode}')

for name in ('Wait.swift', 'WaitRendering.swift'):
    text = (root / 'Horos/Sources' / name).read_text(encoding='utf-8')
    code = '\n'.join(line.split('//')[0] for line in text.split('\n'))
    remember = code.find('keyWindowReturn.remember(NSApp.keyWindow, before: self.window)')
    shown = code.find('super.showWindow(sender)')
    if remember < 0 or shown < 0 or remember > shown:
        failures.append(f'{name}: the key window is not noted before the panel shows')
    if 'keyWindowReturn.orderOut(self.window)' not in code:
        failures.append(f'{name}: the panel is not ordered out through the key window return')
    if 'self.window?.orderOut(self)' in code:
        failures.append(f'{name}: the panel is still ordered out directly')
    if code.find('NSApp.endModalSession(session)') < code.find('keyWindowReturn.orderOut(self.window)'):
        failures.append(f'{name}: the modal session does not end after the panel is ordered out')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: a wait panel gives the keyboard back to the window it took it from')
