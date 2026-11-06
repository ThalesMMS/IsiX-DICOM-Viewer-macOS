#!/usr/bin/env python3
"""A database whose UI context is released off the main thread waits for nothing.

The context a database makes on the main thread is the UI's, on the main queue.
When the last release of such a database comes on another thread - a shared
database given up by the thread that updated it, a block released when its
thread ends - its deinit saves the unsaved changes of that context. Reading
that context from the releasing thread waits for the main thread; while the
main thread waits for the releasing thread, neither goes on.

This compiles the real N2ManagedDatabase (tests/n2_database_harness.py), in
Debug, with Core Data's multithreading assertions on, and checks:

- a database made on the main thread, with an unsaved study, is released on
  another thread while the main thread waits for that thread without serving
  its queue: the release returns, and nothing says that the main-queue context
  was used off the main thread;
- the context lives on until the main queue is served; then the study is saved
  there, the subclass's follow-up of the save (N2ManagedDatabaseSaveFollowUp)
  runs there after it, and the context is deallocated there;
- a database with a private-queue context released on another thread still
  saves its unsaved study before its release returns.
"""
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import n2_database_harness as harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

DRIVER = r'''
let base = CommandLine.arguments[1]
func path(_ name: String) -> String { ((base as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("Database.sql") }

nonisolated(unsafe) var contextGone: String? = nil
nonisolated(unsafe) var followUp = "not run"

final class TrackedContext: N2ManagedObjectContext {
    deinit { contextGone = Thread.isMainThread ? "main" : "other" }
}

final class DeallocDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
    override func nsManagedObjectContextClass() -> AnyClass! { TrackedContext.self }
}

FOLLOW_UP

func studies(_ p: String) -> String {
    var count = -1
    autoreleasepool {
        let db = DeallocDatabase(path: p)!
        db.performBlockAndWait { count = Int(db.countObjects(forEntity: "Study")) }
    }
    return "\(count)"
}

func addStudy(_ db: N2ManagedDatabase, _ uid: String) {
    db.performBlockAndWait {
        let study = db.newObject(forEntity: "Study") as? NSManagedObject
        study?.setValue(uid, forKey: "studyInstanceUID")
    }
}

/// Releases `handed` on a thread of its own; whether the release returned
/// within five seconds, the calling thread waiting without serving its queue.
func releaseOnAnotherThread(_ handed: Unmanaged<DeallocDatabase>) -> Bool {
    let released = DispatchSemaphore(value: 0)
    Thread {
        autoreleasepool { handed.release() }
        released.signal()
    }.start()
    return released.wait(timeout: .now() + 5) == .success
}

// The UI's context, released off the main thread.
do {
    let p = path("ui")
    var handed: Unmanaged<DeallocDatabase>! = nil
    autoreleasepool {
        let db = DeallocDatabase(path: p)!
        emit("ui.queue", db.managedObjectContext.concurrencyType == .mainQueueConcurrencyType ? "main" : "private")
        addStudy(db, "UI")
        handed = Unmanaged.passRetained(db)
    }
    emit("ui.returned", releaseOnAnotherThread(handed) ? "yes" : "no")
    emit("ui.context.before", contextGone ?? "alive")
    let deadline = Date().addingTimeInterval(20)
    while contextGone == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    emit("ui.context.gone", contextGone ?? "never")
    emit("ui.followUp", followUp)
    emit("ui.saved", studies(p))
}

// A private-queue context, released off the main thread.
do {
    let p = path("private")
    var handed: Unmanaged<DeallocDatabase>! = nil
    let made = DispatchSemaphore(value: 0)
    Thread {
        autoreleasepool {
            let db = DeallocDatabase(path: p)!
            emit("private.queue", db.managedObjectContext.concurrencyType == .mainQueueConcurrencyType ? "main" : "private")
            addStudy(db, "P")
            handed = Unmanaged.passRetained(db)
        }
        made.signal()
    }.start()
    _ = made.wait(timeout: .now() + 10)
    emit("private.returned", releaseOnAnotherThread(handed) ? "yes" : "no")
    emit("private.saved", studies(p))
}
emit("end", "yes")
'''

FOLLOW_UP = r'''
extension DeallocDatabase: N2ManagedDatabaseSaveFollowUp {
    func saveFollowUpWithoutDatabase() -> @Sendable (NSManagedObjectContext) -> Void {
        return { context in followUp = (Thread.isMainThread ? "main" : "other") + (context.hasChanges ? " unsaved" : " saved") }
    }
}
'''

EXPECTED = {
    'ui.queue': 'main',
    'ui.returned': 'yes',
    'ui.context.before': 'alive',
    'ui.context.gone': 'main',
    'ui.followUp': 'main saved',
    'ui.saved': '1',
    'private.queue': 'private',
    'private.returned': 'yes',
    'private.saved': '1',
    'end': 'yes',
}

failures = []
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)
source = (ROOT / 'Nitrogen/Sources/N2ManagedDatabase.swift').read_text(encoding='utf-8')
follow_up = FOLLOW_UP if 'protocol N2ManagedDatabaseSaveFollowUp' in source else ''
if not follow_up:
    failures.append('N2ManagedDatabase.swift declares no N2ManagedDatabaseSaveFollowUp')
binary, work, error = harness.build(DRIVER.replace('FOLLOW_UP', follow_up), swift_flags=['-Onone', '-D', 'DEBUG'],
                                    objc_flags=['-O0'])
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
print('ok: the release of a database off the main thread waits for nothing; the UI context saves and goes on the main queue')
