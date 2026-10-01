#!/usr/bin/env python3
"""The receiving icon keeps a thread only while that thread is receiving.

`-[AppController _receivingIconSet:]` counts, per thread, how many receptions
are running, and shows the download icon while any count is above zero. The
dictionary is keyed by the thread's address, and every call retained the
thread to make that key (`CFBridgingRetain`) without ever releasing it: each
DICOM reception leaked two retains of its thread, and the thread with them
(#842). The thread is now retained once when it gets an entry and released
when the entry goes.

The method is compiled from AppController.swift with `swiftc`, in a stand-in
AppController with a stand-in N2MutableUInteger, and the retain count of the
calling thread is read around the calls.
"""
from pathlib import Path
import subprocess
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

application = sources.source_text('AppController')

# nonisolated since #1004: the listener threads call it.
found = re.search(r'@objc\(_receivingIconSet:\) (?:nonisolated )?func _receivingIconSet\(_ flag: Bool\) \{', application)
start = found.start() if found else -1
if start < 0:
    sys.exit('FAIL: -_receivingIconSet: is gone from AppController.swift')
method = application[start:application.index('\n    }\n', start) + len('\n    }\n')]

main = r'''import Foundation

final class N2MutableUInteger: NSObject {
    var unsignedIntegerValue: UInt
    init(_ value: UInt) { unsignedIntegerValue = value }
    static func mutableUInteger(with value: UInt) -> N2MutableUInteger { N2MutableUInteger(value) }
    func increment() { unsignedIntegerValue += 1 }
    func decrement() { unsignedIntegerValue -= 1 }
}

final class AppController: NSObject {
    enum State { static var receivingDict: NSMutableDictionary? = nil }
    @objc func _receivingIconUpdate() {}
%s
}

// The main thread is never deallocated and does not count its retains, so the
// receptions run on threads of their own.
let app = AppController()
func set(_ flag: Bool) { autoreleasepool { app._receivingIconSet(flag) } }
func entries() -> Int { AppController.State.receivingDict?.count ?? 0 }
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
''' % method

failures = []
with tempfile.TemporaryDirectory(prefix='horos-receiving-icon-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['swiftc', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr.strip()[-2000:])
        sys.exit('FAIL: -_receivingIconSet: did not compile')
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip()[-2000:])
    if run.returncode:
        failures.append('-_receivingIconSet: does not give back the retains of the thread')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the receiving icon does not leak its threads')
