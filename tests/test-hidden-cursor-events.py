#!/usr/bin/env python3
"""Exercise the production cursor gate for all four viewer mouse handlers.

-mouseUp:, -mouseDown: and the gate's helper are Swift, in DCMView+Mouse.swift;
-mouseMoved: in DCMView+MouseTracking.swift; -mouseDragged: in
DCMView+MouseDragging.swift. Each handler's gate line and the helper are
compiled as they are, with xcrun swiftc, in a stand-in view, and run for every
combination of cursor visibility, loupe, view window and event window.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

mouse = source_text('DCMView+Mouse')
tracking = source_text('DCMView+MouseTracking')
dragging = source_text('DCMView+MouseDragging')
for text in (mouse, tracking, dragging):
    assert 'CGCursorIsVisible()' not in text, 'production routing must not use unsupported global cursor visibility'

start = mouse.index('    @objc(shouldIgnoreHiddenCursorEvent:)\n')
helper = mouse[start:mouse.index('\n    }\n', start) + 7]
helper = helper.replace('    @objc(shouldIgnoreHiddenCursorEvent:)\n', '').replace('public dynamic func', 'func').replace('NSEvent', 'Event')

handlers = []
for i, (text, marker) in enumerate(((mouse, '    @objc(mouseUp:)'), (tracking, '    @objc(mouseMoved:)'),
                                    (mouse, '    @objc(mouseDown:)'), (dragging, '    @objc(mouseDragged:)'))):
    a = text.index(marker)
    gate = next(line for line in text[a:].splitlines() if 'if self.shouldIgnoreHiddenCursorEvent(' in line)
    handlers.append(f'    func handler{i}(_ event: Event) {{\n        let theEvent = event\n        _ = theEvent\n{gate}\n        delivered += 1\n    }}\n')

code = r'''
import Foundation
final class Event {
    var window: NSObject?
}
final class View {
    var horos_lensActive = false
    var window: NSObject?
    var delivered = 0
HELPER
HANDLERS
}
var failures = 0
for visible in [false, true] { for lens in [false, true] { for receiver in [false, true] { for destination in 0..<3 {
    let v = View()
    v.window = receiver ? NSObject() : nil
    let e = Event()
    e.window = destination == 0 ? nil : (destination == 1 ? v.window : NSObject())
    v.horos_lensActive = lens
    // Visibility of the hardware cursor no longer decides anything.
    _ = visible
    let accept = lens || (receiver && destination == 1)
    v.handler0(e); v.handler1(e); v.handler2(e); v.handler3(e)
    if v.delivered != (accept ? 4 : 0) {
        print("FAIL: visible \(visible) lens \(lens) receiver \(receiver) destination \(destination): \(v.delivered) delivered")
        failures += 1
    }
} } } }
if failures > 0 { exit(1) }
print("PASS: down/up/move/drag, visible/hidden cursor, local/foreign/missing windows independent of visibility, loupe compatibility")
'''.replace('HELPER', helper).replace('HANDLERS', ''.join(handlers))

with tempfile.TemporaryDirectory(prefix='horos-cursor-events-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
