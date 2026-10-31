#!/usr/bin/env python3
"""A disc scan marks its source as detected from the main run loop.

The Sources table shows `arrangedObjects.description` through its bindings, and
`description` follows `available`, which follows `detected`. KVO runs on the
thread that writes, so a scan that wrote `detected` on its own thread ran the
table's binder there. The binder asks the table for its prepared rect, and
`+[CATransaction lock]` gives the thread that asks an implicit Core Animation
transaction. The change of the row stays in that transaction, with the main
thread idle and unaware of it. When the thread exits, the thread-specific data of
Core Animation commits the transaction, which draws the table on the exiting
thread. `tableView(_:willDisplayCell:for:row:)` belongs to the main actor, so the
app stopped there in every browse of a disc and every copy that kept it mounted.

Traced in the app with a breakpoint on `CA::Transaction::create()`, the one
transaction made off the main thread came from that write, in Debug and Release,
before and after the scan took the copy over.

What must stay true:

- `volumeScanThread` writes `detected` only inside its hop to the main run loop;
- a real thread that writes a value a table shows through bindings draws that
  table off the main thread, which is why the hop exists: when this stops being
  so the test says so, and the hop can be revisited;
- the same write through `onMainRunLoopSync`, from a real thread, draws the
  table only on the main thread.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

PROGRAM = r'''
import AppKit

final class Node: NSObject {
    @objc dynamic var label = "before"
}

final class Watcher: NSObject, NSTableViewDelegate {
    var onMain = 0, offMain = 0
    let lock = NSLock()

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        lock.lock(); defer { lock.unlock() }
        if Thread.isMainThread { onMain += 1 } else { offMain += 1 }
    }
}

func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView?.wantsLayer = true
let scroll = NSScrollView(frame: window.contentView!.bounds)
let table = NSTableView(frame: scroll.bounds)
let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
column.width = 200
table.addTableColumn(column)
let watcher = Watcher()
table.delegate = watcher
scroll.documentView = table
window.contentView?.addSubview(scroll)
let node = Node()
let rows = NSArrayController(content: NSMutableArray(array: [node]))
column.bind(.value, to: rows, withKeyPath: "arrangedObjects.label", options: nil)
window.orderFrontRegardless()
window.displayIfNeeded()
spin(0.5)

func drawn(by write: @escaping @Sendable () -> Void) -> [String: Int] {
    watcher.lock.lock(); watcher.onMain = 0; watcher.offMain = 0; watcher.lock.unlock()
    Thread { write() }.start()
    spin(1)
    watcher.lock.lock(); defer { watcher.lock.unlock() }
    return ["main": watcher.onMain, "off main": watcher.offMain]
}

nonisolated(unsafe) let shared = node
let onThread = drawn { shared.label = "on the thread" }
let hopped = drawn { onMainRunLoopSync { shared.label = "from the main run loop" } }
let answer = try! JSONSerialization.data(withJSONObject: ["on the thread": onThread, "hopped": hopped])
print(String(decoding: answer, as: UTF8.self))
'''

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


def code_of(text):
    return re.sub(r'//[^\n]*', '', text)


def drawings():
    with tempfile.TemporaryDirectory() as folder:
        program = Path(folder) / 'main.swift'
        program.write_text(PROGRAM)
        built = Path(folder) / 'program'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(program), str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                        '-o', str(built)], check=True, capture_output=True, text=True, timeout=240)
        return json.loads(subprocess.run([str(built)], check=True, capture_output=True, text=True, timeout=30).stdout)


scan_thread = code_of(body(source_text('BrowserController+Sources'), 'func volumeScanThread()'))
check(scan_thread, 'volumeScanThread not found')
hop = body(scan_thread, 'onMainRunLoopSync {')
check('.detected = true' in hop, 'the scan does not mark its source from the main run loop')
outside = scan_thread.replace(hop, '') if hop else scan_thread
check(not re.search(r'\bdetected\s*=', outside), 'the scan writes detected on its own thread')

seen = drawings()
if not sum(seen['on the thread'].values()) and not sum(seen['hopped'].values()):
    print(f'skipped: no table was drawn, so there is no window server here: {seen}')
    sys.exit(2)
check(seen['on the thread']['off main'] > 0,
      f'a write on a thread no longer draws the table there: the hop can be revisited: {seen}')
check(seen['hopped']['off main'] == 0, f'a write through the hop drew the table off the main thread: {seen}')
check(seen['hopped']['main'] > 0, f'a write through the hop did not reach the table: {seen}')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print(f'ok: the scan marks its source from the main run loop, and the table draws there: {seen}')
