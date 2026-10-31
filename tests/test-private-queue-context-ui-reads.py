#!/usr/bin/env python3
"""Contexts made for other threads do not read the database's UI context.

A database opened on the main thread has the UI's context, on the main queue.
-privateQueueIndependentContext, -privateQueueContext and
-privateQueueIndependentDatabase are asked from other threads (the web portal,
file conversion, startup repairs, plug-ins) and need only the coordinator of
that context. Read through the -managedObjectContext getter, an optimized build
can leave the UI context in the asking thread's autorelease pool; when the
browser renews the context meanwhile, the one it replaced goes when that pool
drains, off the main thread.

This compiles the real N2ManagedDatabase (tests/n2_database_harness.py),
optimized as the application's Debug build is and with DEBUG set, and runs it
with Core Data's multithreading assertions on:

- a database made on the main thread has a main-queue context;
- another thread asks it for the three, inside a pool it keeps open until the
  main thread has renewed the database's context and let the database go;
- the three are private-queue contexts on the database's coordinator, the
  replaced UI context and the one it had at the end go on the main thread, and
  nothing says that a main-queue context was used off the main thread.
"""
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import n2_database_harness as harness  # noqa: E402

DRIVER = r'''
let base = CommandLine.arguments[1]
let sqlPath = ((base as NSString).appendingPathComponent("db") as NSString).appendingPathComponent("Database.sql")

let goneLock = NSLock()
nonisolated(unsafe) var gone: [String] = []

final class TrackedContext: N2ManagedObjectContext {
    deinit {
        if concurrencyType == .mainQueueConcurrencyType {
            goneLock.lock(); gone.append(Thread.isMainThread ? "main" : "other"); goneLock.unlock()
        }
    }
}

final class UIDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
    override func nsManagedObjectContextClass() -> AnyClass! { TrackedContext.self }
}

func spin(until done: () -> Bool, seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

var database: UIDatabase? = nil
var coordinator: NSPersistentStoreCoordinator? = nil
autoreleasepool {
    let db = UIDatabase(path: sqlPath)!
    emit("queue", db.managedObjectContext.concurrencyType == .mainQueueConcurrencyType ? "main" : "private")
    coordinator = db.managedObjectContext.persistentStoreCoordinator
    database = db
}

let asked = DispatchSemaphore(value: 0), renewed = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
nonisolated(unsafe) var answers: [String] = []
nonisolated(unsafe) let handed = Unmanaged.passRetained(database!)
let coordinatorID = ObjectIdentifier(coordinator!)
Thread {
    autoreleasepool {
        let db = handed.takeUnretainedValue()
        func describe(_ context: NSManagedObjectContext?) -> String {
            guard let context else { return "nil" }
            let queue = context.concurrencyType == .privateQueueConcurrencyType ? "private" : "main"
            let same = context.persistentStoreCoordinator.map { ObjectIdentifier($0) == coordinatorID } ?? false
            return queue + (same ? " same store" : " other store")
        }
        answers.append(describe(db.privateQueueIndependentContext()))
        answers.append(describe(db.privateQueueContext()))
        answers.append(describe((db.privateQueueIndependentDatabase() as? N2ManagedDatabase)?.managedObjectContext))
        asked.signal()
        _ = renewed.wait(timeout: .now() + 20)
    }
    handed.release()
    ended.signal()
}.start()

var reached = false
spin(until: { reached = asked.wait(timeout: .now()) == .success; return reached }, seconds: 30)
emit("asked", reached ? "yes" : "no")
emit("independent context", answers.count > 0 ? answers[0] : "none")
emit("private-queue context", answers.count > 1 ? answers[1] : "none")
emit("independent database context", answers.count > 2 ? answers[2] : "none")

// As the browser does when it shows the database, then leaves it.
autoreleasepool { database!.renewManagedObjectContext() }
spin(until: { false }, seconds: 0.3)
autoreleasepool {
    coordinator = nil
    database = nil
}
renewed.signal()
var finished = false
spin(until: { finished = ended.wait(timeout: .now()) == .success; return finished }, seconds: 30)
spin(until: { false }, seconds: 0.5)
emit("thread ended", finished ? "yes" : "no")

goneLock.lock(); let all = gone; goneLock.unlock()
emit("main-queue contexts gone on main", "\(all.filter { $0 == "main" }.count)")
emit("main-queue contexts gone on another thread", "\(all.filter { $0 == "other" }.count)")
emit("end", "yes")
'''

EXPECTED = {
    'queue': 'main',
    'asked': 'yes',
    'independent context': 'private same store',
    'private-queue context': 'private same store',
    'independent database context': 'private same store',
    'thread ended': 'yes',
    'main-queue contexts gone on main': '2',
    'main-queue contexts gone on another thread': '0',
    'end': 'yes',
}

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)

failures = []
binary, work, error = harness.build(DRIVER, swift_flags=['-O', '-D', 'DEBUG'], objc_flags=['-O0'])
try:
    if error:
        failures.append(error)
    else:
        status, results, stdout, stderr = harness.run(binary, [str(work / 'stores')], timeout=120)
        if status != 0:
            failures.append('the process ended (status %d) after %r:\n%s'
                            % (status, stdout.splitlines()[-1:] or '', stderr[-2000:]))
        for key, value in EXPECTED.items():
            if results.get(key) != value:
                failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))
        for line in stderr.splitlines():
            if 'off the main thread' in line:
                failures.append('said: ' + line.strip()[:300])
finally:
    shutil.rmtree(work, ignore_errors=True)

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: contexts made for other threads leave the UI context alone, which goes on the main thread')
