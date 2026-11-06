#!/usr/bin/env python3
"""No deinit of a database waits for anything while it holds the registry.

The registry of the databases by path (DicomDatabase.swift) holds them without
retaining them. Every -release of a database (DicomDatabase+CAPI.m) takes the
registry's recursive lock, so that the last one, and the deinit it ends in,
remove the database before a lookup can retain it again. Swift runs the deinit
of the most-derived class first: RemoteDicomDatabase's, which waits for an
update of the shared database's index in progress (its update lock), before
DicomDatabase's, which removes the database from the registry and leaves the
lock. While it waited, every other thread that asked the registry
(+allDatabases, a lookup by path, the release of any other database) waited
too; an update that needs the main thread, while the main thread asks the
registry, never ended.

Compiled from the real sources - the registry's lock, its leaving and -release
of DicomDatabase+CAPI.m, the registry, +allDatabases, the lookup by path and the
deinit of DicomDatabase.swift, the deinit of RemoteDicomDatabase.swift - with
stand-ins for the rest of the two classes, a shared database is released on one
thread while an update holds its update lock on another:
- +allDatabases, the lookup by path and the release of another database answer
  on a third thread while the shared database's deinit waits for the update;
- neither finds the shared database being deallocated;
- once the update ends, the deinit goes on: the cleaning and the routing of the
  database are stopped once, after the update, and the registry's lock is left
  exactly once, also for a database that never reached the registry.
No app, no network and no database file are needed.
"""
from pathlib import Path
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
SKIPPED = 2
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8', errors='replace')


def member(source, signature, start=0):
    """A declaration of Swift, from `signature` (the first after `start`)
    through its closing brace."""
    at = source.index(signature, start)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


BRIDGE = r'''
#import <Foundation/Foundation.h>
#pragma clang diagnostic ignored "-Wnullability-completeness"
NS_ASSUME_NONNULL_BEGIN
NSRecursiveLock* DicomDatabaseRegistryLock(void);
void DicomDatabaseRegistryUnlockForDealloc(void);
NS_ASSUME_NONNULL_END
@interface DicomDatabase : NSObject
- (nonnull instancetype)initWithBase:(nonnull NSString*)base;
+ (NSArray*)allDatabases;
@end
'''

DOUBLES = r'''
import Foundation

nonisolated(unsafe) var events: [String] = []
let eventsLock = NSLock()
func record(_ event: String) { eventsLock.lock(); events.append(event); eventsLock.unlock() }
func recorded() -> [String] { eventsLock.lock(); defer { eventsLock.unlock() }; return events }

REGISTRY

@objc @implementation extension DicomDatabase {
    final var storedBaseDirPath: String?
    final var importFilesFromIncomingDirLock: NSRecursiveLock?
    final var processFilesLock: NSRecursiveLock?
    final var mainDatabase: Any? = nil
STATE
    init(base: String) {
        storedBaseDirPath = base
        super.init()
    }
    final var baseDirPath: String? { storedBaseDirPath }
    final func isMainDatabase() -> Bool { true }
    final func deallocClean() { record("clean " + (storedBaseDirPath ?? "?")) }
    final func deallocRouting() { record("routing " + (storedBaseDirPath ?? "?")) }
    final class func register(_ database: DicomDatabase) { knowAbout(database) }
    final class func lookUp(_ path: String) -> DicomDatabase? { registeredDatabase(atBaseDirPath: path) }

MEMBERS
}

final class RemoteDicomDatabaseDirectoryRemoval {
    init(path: String) {}
}

final class RemoteDicomDatabase: DicomDatabase {
    private var _baseBaseDirPath: String? = nil
    private var _sqlFileName: String? = nil
    private var _address: String? = nil
    private var _host: Host? = nil
    private var _updateLock: NSRecursiveLock? = nil
    private var _updateTimer: Timer? = nil
    private var _password: String? = nil
    private var _baseBaseDirRemoval: RemoteDicomDatabaseDirectoryRemoval? = nil

    init(base: String, updateLock: NSRecursiveLock) {
        super.init(base: base)
        _updateLock = updateLock
    }

REMOTE_DEINIT
}
'''

DRIVER = r'''
/// The update lock of the shared database, which says when another thread asks it.
final class ObservedLock: NSRecursiveLock, @unchecked Sendable {
    nonisolated(unsafe) var onAttempt: (() -> Void)?
    override func lock() {
        onAttempt?()
        super.lock()
    }
}

func check(_ ok: Bool, _ message: String) {
    print((ok ? "ok: " : "FAIL: ") + message)
    fflush(stdout)
    if !ok { exit(1) }
}

func onThread(_ body: @escaping () -> Void) {
    Thread(block: body).start()
}

func pointer(_ object: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(object).toOpaque()
}

/// Whether another thread can take the registry's lock now.
func registryIsFree() -> Bool {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var free = false
    onThread {
        let lock = DicomDatabaseRegistryLock()
        free = lock.try()
        if free { lock.unlock() }
        done.signal()
    }
    return done.wait(timeout: .now() + 3) == .success && free
}

let local = DicomDatabase(base: "/harness/local")
DicomDatabase.register(local)

// An update of the shared database's index, in progress on its own thread.
let updateLock = ObservedLock()
let updating = DispatchSemaphore(value: 0)
let finishUpdate = DispatchSemaphore(value: 0)
onThread {
    updateLock.lock()
    updating.signal()
    _ = finishUpdate.wait(timeout: .now() + 30)
    record("update finished")
    updateLock.unlock()
}
check(updating.wait(timeout: .now() + 5) == .success, "an update holds the shared database's update lock")

let handed: Unmanaged<RemoteDicomDatabase>
let remotePointer: UnsafeMutableRawPointer
do {
    let remote = RemoteDicomDatabase(base: "/harness/remote", updateLock: updateLock)
    DicomDatabase.register(remote)
    remotePointer = pointer(remote)
    handed = Unmanaged.passRetained(remote)
}

// The last release of the shared database, on another thread.
let attempting = DispatchSemaphore(value: 0)
updateLock.onAttempt = { attempting.signal() }
let released = DispatchSemaphore(value: 0)
onThread {
    handed.release()
    record("released")
    released.signal()
}
check(attempting.wait(timeout: .now() + 5) == .success, "the shared database's deinit waits for the update")

// Meanwhile, a third thread asks the registry and releases another database.
let answered = DispatchSemaphore(value: 0)
nonisolated(unsafe) var listed: [UnsafeMutableRawPointer] = []
nonisolated(unsafe) var foundByPath = true
onThread {
    listed = (DicomDatabase.allDatabases() ?? []).map { pointer($0 as AnyObject) }
    foundByPath = DicomDatabase.lookUp("/harness/remote") != nil
    do {
        let other = DicomDatabase(base: "/harness/other")
        DicomDatabase.register(other)
    }
    answered.signal()
}
check(answered.wait(timeout: .now() + 3) == .success,
      "allDatabases, the lookup by path and the release of another database answer on another thread while the shared database's deinit waits for its update")
check(listed.contains(pointer(local)) && !listed.contains(remotePointer), "allDatabases lists the local database, not the one being deallocated")
check(!foundByPath, "the lookup by path does not find the database being deallocated")
check(recorded().contains("clean /harness/other"), "the other database was deallocated meanwhile")
check(!recorded().contains("clean /harness/remote"), "the shared database's deinit is still waiting for the update")

finishUpdate.signal()
check(released.wait(timeout: .now() + 5) == .success, "the last release of the shared database returns once the update ends")
let after = recorded()
check(after.filter { $0 == "clean /harness/remote" }.count == 1 && after.filter { $0 == "routing /harness/remote" }.count == 1,
      "its cleaning and its routing are stopped once")
if let update = after.firstIndex(of: "update finished"), let clean = after.firstIndex(of: "clean /harness/remote") {
    check(update < clean, "after the update")
} else {
    check(false, "after the update")
}
check(registryIsFree(), "the registry's lock is left")
check((DicomDatabase.allDatabases() ?? []).count == 1, "the registry holds only the local database")

// A database that never reached the registry leaves the lock once too.
let unregistered = DispatchSemaphore(value: 0)
onThread {
    do { _ = RemoteDicomDatabase(base: "/harness/unregistered", updateLock: ObservedLock()) }
    unregistered.signal()
}
check(unregistered.wait(timeout: .now() + 5) == .success && registryIsFree(), "a database that was never registered leaves the lock once")
withExtendedLifetime(local) {}
print("done")
'''


def sources():
    """(registry declarations, extra stored state, DicomDatabase members, RemoteDicomDatabase's deinit)."""
    database = read('DicomDatabase.swift')
    remote = read('RemoteDicomDatabase.swift')
    registry = [re.search(r'^nonisolated\(unsafe\) private let databasesDictionary = .*$', database, re.M).group(0)]
    if 'enum DicomDatabaseRegistry' in database:
        registry.append(member(database, 'enum DicomDatabaseRegistry'))
    state = '\n'.join(re.findall(r'^\s*final var leftRegistry\b.*$', database, re.M))
    extension = database.index('@objc @implementation extension DicomDatabase {')
    members = [member(database, 'class func allDatabases()'),
               member(database, 'private static func knowAbout('),
               member(database, '@objc(horos_registeredDatabaseAtBaseDirPath:)'),
               member(database, 'deinit {', extension)]
    remote_class = remote.index('class RemoteDicomDatabase: DicomDatabase {')
    return '\n\n'.join(registry), state, '\n\n'.join(members), member(remote, 'deinit {', remote_class)


def objc_registry():
    """The registry's lock, its leaving and -release, from DicomDatabase+CAPI.m."""
    capi = read('DicomDatabase+CAPI.m')
    start = capi.index('NSRecursiveLock* DicomDatabaseRegistryLock(void)')
    category = capi.index('@implementation DicomDatabase (CAPI)', start)
    end = capi.index('@end', category) + len('@end')
    return capi[start:end]


def main():
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
        return SKIPPED
    registry, state, members, remote_deinit = sources()
    swift = (DOUBLES.replace('REGISTRY', registry).replace('STATE', state).replace('MEMBERS', members)
             .replace('REMOTE_DEINIT', remote_deinit)) + DRIVER
    with tempfile.TemporaryDirectory(prefix='horos-registry-release-') as directory:
        work = Path(directory)
        (work / 'Bridge.h').write_text(BRIDGE)
        (work / 'capi.m').write_text('#import "Bridge.h"\n' + objc_registry() + '\n')
        (work / 'main.swift').write_text(swift)
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-w', '-I', str(work), str(work / 'capi.m'),
                                '-o', str(work / 'capi.o')], capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            print('DicomDatabase+CAPI.m did not compile:\n' + built.stderr[-4000:])
            return 1
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-DDEBUG',
                                '-module-cache-path', str(work / 'cache'), '-import-objc-header', str(work / 'Bridge.h'),
                                str(work / 'main.swift'), str(work / 'capi.o'), '-o', str(work / 'check')],
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
