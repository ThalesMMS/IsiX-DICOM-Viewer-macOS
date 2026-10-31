#!/usr/bin/env python3
"""A shared database's update timer is invalidated on the main thread.

The update timer of a shared database is added to the main run loop by
-updateOnMainThread:. A timer is invalidated on the thread it was scheduled on,
but the last release of the database, and the deinit it ends in, may come from
any thread. The deinit used to invalidate the timer wherever it ran, and the
timer pointed at the database without retaining it: a firing that met the
deinit called a database being deallocated.

Compiled from the real sources - the creation of the timer in
-updateOnMainThread:, the timer's action and the deinit of
RemoteDicomDatabase.swift - with stand-ins for the rest of the class, a shared
database with a running timer is released:
- the timer fires while the database lives, and does not keep it alive;
- released on the main thread, its timer is invalidated there at once;
- released on another thread while the main thread is busy, the release
  returns without waiting for the main thread, and the timer is not
  invalidated on that thread but on the main one, once it runs again;
- the database is never called back once its deinit has begun, also when the
  timer was overdue as the main thread came back.
No app, no network and no database file are needed.
"""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Horos/Sources/RemoteDicomDatabase.swift'
SKIPPED = 2
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def member(source, signature, start=0):
    """Swift from `signature` (the first after `start`) through the brace that
    closes the first one it opens."""
    at = source.index(signature, start)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


HARNESS = r'''
import AppKit

nonisolated(unsafe) var events: [String] = []
let eventsLock = NSLock()
func record(_ event: String) { eventsLock.lock(); events.append(event); eventsLock.unlock() }
func recorded() -> [String] { eventsLock.lock(); defer { eventsLock.unlock() }; return events }

func check(_ ok: Bool, _ message: String) {
    print((ok ? "ok: " : "FAIL: ") + message)
    fflush(stdout)
    if !ok { exit(1) }
}

/// The refresh interval the harness's timers use.
let interval = 0.05

enum DatabasePreferences { static let databaseRefreshInterval = 0 }
struct Preferences { subscript(_ key: Int) -> Double { interval } }
struct PreferencesSource {
    let preferences = Preferences()
    static let process = PreferencesSource()
}

enum DicomDatabaseRegistry {
    static func leave(_ database: AnyObject) { record("deinit " + ((database as? RemoteDicomDatabase)?.label ?? "?")) }
}

final class RemoteDicomDatabaseDirectoryRemoval {
    init(path: String) {}
}

class DicomDatabase: NSObject {
    func isMainDatabase() -> Bool { false }
}

final class RemoteDicomDatabase: DicomDatabase {
    private var _baseBaseDirPath: String? = nil
    private var _sqlFileName: String? = nil
    private var _address: String? = nil
    private var _port: Int = 0
    private var _host: Host? = nil
    private var _updateLock: NSRecursiveLock? = NSRecursiveLock()
    var _updateTimer: Timer? = nil
    private var _password: String? = nil
    private var _baseBaseDirRemoval: RemoteDicomDatabaseDirectoryRemoval? = nil
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    @objc func _updateTimerCallback() { record("fired " + label) }

CALLBACK_CLASS

    func startUpdateTimer() {
TIMER_CREATION
    }

DEINIT
}

/// Records on which thread each tracked timer is invalidated.
nonisolated(unsafe) var tracked: [ObjectIdentifier: String] = [:]
func trackInvalidation(of timer: Timer) {
    tracked[ObjectIdentifier(timer)] = ""
    let selector = #selector(Timer.invalidate)
    guard let method = class_getInstanceMethod(object_getClass(timer), selector) else {
        check(false, "the timer's class has -invalidate")
        return
    }
    typealias Invalidate = @convention(c) (AnyObject, Selector) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Invalidate.self)
    let replacement: @convention(block) (AnyObject) -> Void = { object in
        if let label = tracked[ObjectIdentifier(object)] {
            record("invalidated " + label + (Thread.isMainThread ? " on the main thread" : " on another thread"))
        }
        original(object, selector)
    }
    if tracked.count == 1 {
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

func runMainLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func after(_ first: String, none prefix: String) -> Bool {
    let all = recorded()
    guard let start = all.firstIndex(of: first) else { return false }
    return !all[start...].contains { $0.hasPrefix(prefix) }
}

check(Thread.isMainThread, "the harness runs on the main thread")

// Released on the main thread.
weak var weakMain: RemoteDicomDatabase?
var mainTimer: Timer?
do {
    let database = RemoteDicomDatabase(label: "main")
    weakMain = database
    database.startUpdateTimer()
    mainTimer = database._updateTimer
    check(mainTimer?.isValid == true, "the update timer is scheduled")
    trackInvalidation(of: mainTimer!)
    tracked[ObjectIdentifier(mainTimer!)] = "main"
    runMainLoop(interval * 5)
    check(recorded().contains("fired main"), "the timer fires while the database lives")
}
check(weakMain == nil, "the timer does not keep a database it fires for alive")
check(recorded().contains("invalidated main on the main thread"), "released on the main thread, its timer is invalidated there at once")
check(mainTimer?.isValid == false, "and is no longer valid")
runMainLoop(interval * 4)
check(after("deinit main", none: "fired main"), "the database released on the main thread is not called back")

// Released on another thread while the main thread does something else.
var backgroundTimer: Timer?
let handed: Unmanaged<RemoteDicomDatabase>
do {
    let database = RemoteDicomDatabase(label: "background")
    database.startUpdateTimer()
    backgroundTimer = database._updateTimer
    trackInvalidation(of: backgroundTimer!)
    tracked[ObjectIdentifier(backgroundTimer!)] = "background"
    runMainLoop(interval * 5)
    check(recorded().contains("fired background"), "the timer of the second database fires while it lives")
    handed = Unmanaged.passRetained(database)
}
let released = DispatchSemaphore(value: 0)
Thread {
    handed.release()
    record("released")
    released.signal()
}.start()
// The main thread is busy: its run loop does not turn until the release returned.
check(released.wait(timeout: .now() + 5) == .success, "the last release on another thread returns without waiting for the main thread")
check(recorded().contains("deinit background"), "its deinit ran")
check(!recorded().contains("invalidated background on another thread"), "the timer is not invalidated on the releasing thread")
// Long enough for the timer to be overdue when the main run loop turns again.
Thread.sleep(forTimeInterval: interval * 4)
runMainLoop(interval * 6)
check(recorded().contains("invalidated background on the main thread"), "the timer is invalidated on the main thread once it runs again")
check(backgroundTimer?.isValid == false, "and is no longer valid")
check(after("deinit background", none: "fired background"), "the database released on another thread is never called back after its deinit began")
print("done")
'''


def sources():
    """(the timer's former action, the creation of the timer, the deinit)."""
    swift = SOURCE.read_text(encoding='utf-8', errors='replace')
    start = swift.index('class RemoteDicomDatabase: DicomDatabase {')
    callback = member(swift, '@objc(_updateTimerCallbackClass:)', start)
    update = member(swift, 'func updateOnMainThread(_ path: String?)', start)
    creation = member(update, 'if self._updateTimer == nil {')
    return callback, creation, member(swift, 'deinit {', start)


def main():
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return SKIPPED
    callback, creation, deinit = sources()
    swift = (HARNESS.replace('CALLBACK_CLASS', callback).replace('TIMER_CREATION', creation)
             .replace('DEINIT', deinit))
    with tempfile.TemporaryDirectory(prefix='horos-remote-update-timer-') as directory:
        work = Path(directory)
        (work / 'main.swift').write_text(swift)
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5',
                                '-module-cache-path', str(work / 'cache'),
                                str(work / 'main.swift'), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            print('the harness did not compile:\n' + built.stderr[-4000:])
            return 1
        ran = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=120)
        print(ran.stdout, end='')
        if ran.returncode != 0 or not ran.stdout.rstrip().endswith('done'):
            print(ran.stderr[-3000:], file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
