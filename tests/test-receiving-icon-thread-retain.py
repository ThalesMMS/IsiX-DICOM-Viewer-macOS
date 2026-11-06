#!/usr/bin/env python3
"""The receiving icon keeps a thread only while that thread is receiving.

The Dock's receiving arrow shows while any thread runs a reception. The
listener and import threads start and end them through
`ProcessGraph.showReceiving` and `-[AppController setReceivingIcon]` /
`-unsetReceivingIcon`, which go to `ReceivingIndicator.showReceiving`, which
counts them per thread in IsiXInstallation's `ReceivingThreadCounter`. A
thread is counted under its identity: the counter keeps it while it has an
entry, so that identity cannot go to a new thread, and lets it go with its last
reception. Before, every call retained the thread to make its key without ever
releasing it: each DICOM reception leaked two retains of its thread, and the
thread with them.

The counter is compiled from its module source with `swiftc`, and the retain
count of the calling thread is read around the calls; the wiring is read in
the app sources.
"""
from pathlib import Path
import subprocess
import re
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import sources

counter_source = root / 'Modules/IsiXInstallation/Sources/ReceivingThreadCounter.swift'
if not counter_source.is_file():
    sys.exit('FAIL: ReceivingThreadCounter.swift is gone from IsiXInstallation')

failures = []
application = sources.source_text('AppController')
indicator = sources.source_text('ReceivingIndicator')
graph = sources.source_text('ProcessGraph')
# Every way in reaches the one counter.
if not re.search(r'func setReceivingIcon\(\) \{\s*receivingIndicator\.showReceiving\(true\)\s*\}', application) \
        or not re.search(r'func unsetReceivingIcon\(\) \{\s*receivingIndicator\.showReceiving\(false\)\s*\}', application):
    failures.append('-setReceivingIcon / -unsetReceivingIcon do not go to the receiving indicator')
if 'receivingIndicator.showReceiving(receiving)' not in graph:
    failures.append('ProcessGraph.showReceiving does not go to the receiving indicator')
show = re.search(r'nonisolated func showReceiving\(_ receiving: Bool\) \{.*?\n    \}\n', indicator, re.S)
if not show or 'receptions.begin()' not in show.group(0) or 'receptions.end()' not in show.group(0):
    failures.append('ReceivingIndicator.showReceiving does not count the calling thread in its ReceivingThreadCounter')

main = r'''import Foundation

// The main thread is never deallocated and does not count its retains, so the
// receptions run on threads of their own.
let counter = ReceivingThreadCounter()
func set(_ flag: Bool) { autoreleasepool { if flag { counter.begin() } else { counter.end() } } }
func entries() -> Int { counter.receivingThreads }
func onThread(_ body: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    Thread { body(); done.signal() }.start()
    done.wait()
}

onThread {
    // Each count is read into a constant before it is checked: a closure that
    // captured the thread, such as the message of a precondition, would hold
    // a retain of its own while it runs.
    let thread = Thread.current
    var n: CFIndex = 0, e = 0
    func read() { n = CFGetRetainCount(thread); e = entries() }

    set(true); set(false)
    read()
    let base = n
    precondition(base > 0 && e == 0, "the retain count of a thread cannot be read")

    // A reception that starts and ends gives back what it took.
    for _ in 0..<50 { set(true); set(false) }
    read()
    precondition(n == base && e == 0, "\(n - base) retains left after 50 receptions")

    // While the thread receives it is kept, once, however many receptions it runs.
    set(true)
    read()
    precondition(e == 1 && n == base + 1, "\(n - base) retains for one reception")
    set(true); set(true)
    read()
    precondition(e == 1 && n == base + 1, "\(n - base) retains for three receptions")
    set(false); set(false)
    read()
    precondition(e == 1 && n == base + 1, "released before the last reception ended")

    // Another thread gets its own entry, and leaves nothing behind.
    onThread {
        let other = Thread.current
        var m: CFIndex = 0
        let otherBase = CFGetRetainCount(other)
        set(true)
        m = CFGetRetainCount(other)
        let both = entries()
        precondition(both == 2 && m == otherBase + 1, "\(both) entries and \(m - otherBase) retains with two threads receiving")
        set(false)
        m = CFGetRetainCount(other)
        precondition(m == otherBase, "the other thread kept \(m - otherBase) retains")
    }
    read()
    precondition(e == 1 && n == base + 1, "the other thread changed this one's entry")

    set(false)
    read()
    precondition(e == 0 && n == base, "\(n - base) retains after the last reception")

    // An end without a start changes nothing.
    set(false)
    read()
    precondition(e == 0 && n == base, "an end without a start changed the count")
}

print("PASS: a thread is retained once while it receives, and released when it stops")
'''

with tempfile.TemporaryDirectory(prefix='horos-receiving-icon-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(counter_source), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr.strip()[-2000:])
        sys.exit('FAIL: ReceivingThreadCounter did not compile')
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip()[-2000:])
    if run.returncode:
        failures.append('ReceivingThreadCounter does not give back the retains of the thread')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the receiving icon does not leak its threads')
