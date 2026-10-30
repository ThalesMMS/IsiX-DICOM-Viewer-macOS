#!/usr/bin/env python3
"""-[DCMView mouseDown:] gives the draw lock back on every way out.

The view's draw lock is one NSRecursiveLock shared by every DCMView and taken
by other threads too. -mouseDown: takes it before the click on the images is
handled; a double-click that a hot key takes ends the handling early. If that
way out kept the lock, the main thread would still enter it (it is recursive)
and every other thread would wait on it for good.

The lock block of -mouseDown: and the hot-key dispatch of the double-click
(DCMView+Mouse.swift) are compiled as they are, with xcrun swiftc, in a
stand-in view, and run for a single click, a double-click with and without a
hot key (plain, Command and Option) and a click that raises; after each, another
thread must obtain the lock.

    python3 tests/test-mouse-down-draw-lock.py [REVISION]

REVISION reads DCMView+Mouse.swift from git instead of the tree: the negative
control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path  # noqa: E402

root = Path(__file__).resolve().parents[1]
path = source_path('DCMView+Mouse')
if len(sys.argv) > 1:
    mouse = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + str(path.relative_to(root))],
                           capture_output=True, text=True, check=True).stdout
else:
    mouse = path.read_text(encoding='utf-8')


def braced(text, start):
    """The text from `start` to the brace that closes the first one after it."""
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1


down = braced(mouse, mouse.index('    public override dynamic func mouseDown(with event: NSEvent) {'))
lock_block = braced(down, down.index('        if self.horos_dcmPixList != nil {'))
signature = re.search(r'    private func mouseDownWithImages\(_ event: NSEvent\)( -> Bool)? \{', mouse)
if not signature:
    sys.exit('FAIL: no mouseDownWithImages(_:) in DCMView+Mouse.swift')
handling = braced(mouse, signature.start())
# The double-click's dispatch: from the modifier flags to the end of its
# if/else chain, the statement before the crosshair's.
start = handling.index('        let currentFlags = ')
dispatch = handling[start:handling.index('        self.horos_crossMove = -1', start)]
if dispatch.count('self.actionForHotKey(') != 3:
    sys.exit('FAIL: the double-click no longer dispatches the three hot keys')
returns_bool = signature.group(1) is not None

code = r'''
import Foundation

struct Flags: OptionSet { let rawValue: Int; static let command = Flags(rawValue: 1); static let option = Flags(rawValue: 2) }
struct Event { var modifierFlags: Flags }
final class Application { var currentEvent: Event? = nil }
enum NSApplication { static let shared = Application() }
final class Browser { var window: AnyObject? = nil; func matrixDoublePressed(_ sender: Any?) {} }
enum BrowserController { static func currentBrowser() -> Browser? { nil } }

/// An Objective-C exception, as HorosObjCPerformFunction catches it.
struct Raised: Error {}
func inputCatch(_ body: () throws -> Void) -> NSException? {
    do { try body() } catch { return NSException(name: .genericException, reason: "raised", userInfo: nil) }
    return nil
}
func inputLogException(_ exception: NSException?, _ function: String) {}

final class DCMView {
    nonisolated(unsafe) static var horos_static_drawLock: NSRecursiveLock? = NSRecursiveLock()
    var horos_dcmPixList: [Int]? = [1]
    var window: AnyObject? = NSObject()
    var stringID: String? = nil
    var hotKeys: Set<String> = []
    var raises = false
    var finished = false

    func actionForHotKey(_ key: String) -> Bool { hotKeys.contains(key) }

    func mouseDownWithImages(_ event: Int) throws RESULT {
        if raises { throw Raised() }
        let clickCount = event
        let roiHit = false
DISPATCH
        finished = true
        RETURN
    }

    func mouseDown(_ event: Int) {
LOCKBLOCK
    }
}

/// Whether another thread obtains the lock now.
func otherThreadLocks() -> Bool {
    var obtained = false
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        if DCMView.horos_static_drawLock!.try() {
            obtained = true
            DCMView.horos_static_drawLock!.unlock()
        }
        done.signal()
    }
    done.wait()
    return obtained
}

var failures = 0
let cases: [(String, Int, Flags, Set<String>, Bool, Bool)] = [
    ("single click", 1, [], [], false, true),
    ("double-click, no hot key", 2, [], [], false, true),
    ("double-click, hot key", 2, [], ["dbl-click"], false, false),
    ("double-click + Command, hot key", 2, [.command], ["dbl-click + cmd"], false, false),
    ("double-click + Option, hot key", 2, [.option], ["dbl-click + alt"], false, false),
    ("click that raises", 1, [], [], true, false),
]
for (name, clicks, flags, keys, raises, finishes) in cases {
    let view = DCMView()
    view.hotKeys = keys
    view.raises = raises
    NSApplication.shared.currentEvent = Event(modifierFlags: flags)
    view.mouseDown(clicks)
    if view.finished != finishes {
        print("FAIL: \(name): the click \(view.finished ? "went on" : "stopped"), expected it to \(finishes ? "go on" : "stop")")
        failures += 1
    }
    if !otherThreadLocks() {
        print("FAIL: \(name): another thread cannot obtain the draw lock after -mouseDown:")
        failures += 1
        // Give it back, so that the next case starts from a free lock.
        DCMView.horos_static_drawLock = NSRecursiveLock()
    }
}
exit(failures == 0 ? 0 : 1)
'''
call = 'self.mouseDownWithImages(event)'
if call not in lock_block:
    sys.exit('FAIL: the lock block of -mouseDown: does not hand the click to mouseDownWithImages(_:)')
# The stand-in throws where the Objective-C raised.
lock_block = lock_block.replace(call, 'try ' + call)
code = (code.replace('RESULT', '-> Bool' if returns_bool else '')
        .replace('RETURN', 'return false' if returns_bool else '')
        .replace('DISPATCH', dispatch)
        .replace('LOCKBLOCK', lock_block))

with tempfile.TemporaryDirectory() as work:
    source = Path(work) / 'probe.swift'
    source.write_text(code)
    binary = Path(work) / 'probe'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the probe does not compile:\n' + built.stderr[-4000:])
    try:
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        sys.exit('FAIL: the probe did not end in 60 s')
print(run.stdout, end='')
if run.returncode:
    sys.exit(1)
print('PASS: -mouseDown: gives the draw lock back after a click, a hot-key double-click and an exception')
