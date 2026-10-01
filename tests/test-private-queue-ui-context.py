#!/usr/bin/env python3
"""The UI context has the main queue, the other consumers queues of their own (#966).

-[N2ManagedDatabase contextAtPath:] gives the database a context with
NSMainQueueConcurrencyType when it is made on the main thread, a private queue
elsewhere. The saves of other contexts are merged into it on the main queue.
The consumers that worked on a confined context of their thread (the web
portal, the shared-database server, the DICOM listener, the log, the scans,
the imports of generated files) now run their work inside the queue of a
private-queue context: the portal and the shared-database server around a
whole request, entering several queues in turn.

This compiles the real N2ManagedDatabase.mm (tests/n2_database_harness.py) and
checks, with Core Data's multithreading assertions on:

- the database made on the main thread has a main-queue context, one made on
  another thread a private queue; renewing the main-queue one in the turn that
  opened the database (as the browser does) leaves nothing on the main queue
  that crashes (the store is added before the context gets its coordinator);
- the UI context used from another thread runs on the main thread;
- a background private-queue database saves, and the change reaches the UI
  context on the main thread, merged there;
- one thread entering three private queues in turn reads objects of each, and
  an exception inside the innermost comes out, raised again, outside all of
  them, and the contexts go on working.

The source check confirms that the application's consumers no longer make
confined independent contexts (the deprecated BrowserController methods keep
the selector plug-ins call) and that the adapters are in place.
"""
from pathlib import Path
import re
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import n2_database_harness as harness  # noqa: E402

root = Path(__file__).resolve().parents[1]
failures = []


def read(relative):
    return (root / relative).read_bytes().decode('latin1')


# Residual context/database locking must not return to application consumers
# (#1038). Named NSLocks (dbModifyLock, readContextLock, drawLock...) and the
# persistent-store coordinator's distinct compatibility API are not contexts.
context_lock = re.compile(r"\b(?:[A-Za-z_]*[Cc]ontext|moc|[A-Za-z_]*[Dd]atabase)\??\.(?:lock|unlock|tryLock)\(")
objc_context_lock = re.compile(r"\[(?:[^\n;]*managedObjectContext\]?|[A-Za-z_]*[Cc]ontext|moc|[A-Za-z_]*[Dd]atabase) (?:lock|unlock|tryLock)\]")
for path in sorted((root / 'Horos/Sources').glob('*')):
    if path.suffix not in ('.swift', '.m', '.mm'):
        continue
    code = re.sub(r'/\*.*?\*/', '', path.read_bytes().decode('latin1'), flags=re.S)
    for line in code.splitlines():
        line = line.split('//')[0]
        if context_lock.search(line) or objc_context_lock.search(line):
            failures.append('%s still locks a context/database: %s' % (path.name, line.strip()))

# Source: no confined independent context left in the application's consumers.
confined = re.compile(r'\bindependentDatabase\(\)|\bindependentContext\(\)|\bindependentDatabase\]|\bindependentContext\]')
for path in sorted((root / 'Horos/Sources').glob('*')):
    if path.suffix not in ('.swift', '.m', '.mm'):
        continue
    for number, line in enumerate(path.read_bytes().decode('latin1').splitlines(), 1):
        code = line.split('//')[0]
        # The deprecated BrowserController methods keep the selector plug-ins call.
        if confined.search(code) and 'privateQueueIndependent' not in code \
                and 'independentContext:independentContext]' not in code:
            failures.append('%s:%d still makes a confined independent context: %s'
                            % (path.relative_to(root), number, line.strip()))

# No confined context is made by the application (#967).
creation = re.compile(r'concurrencyType\s*:\s*NSConfinementConcurrencyType|\.confinementConcurrencyType\)|NSManagedObjectContext\(\)|\[\[NSManagedObjectContext alloc\] init\]')
for folder in ('Horos/Sources', 'Nitrogen/Sources'):
    for path in sorted((root / folder).glob('*')):
        if path.suffix not in ('.swift', '.m', '.mm'):
            continue
        for number, line in enumerate(path.read_bytes().decode('latin1').splitlines(), 1):
            if creation.search(line.split('//')[0]):
                failures.append('%s:%d makes a confined context: %s' % (path.relative_to(root), number, line.strip()))

for relative, needle, why in (
        ('Nitrogen/Sources/N2ManagedDatabase.mm', 'return [NSThread isMainThread] ? NSMainQueueConcurrencyType : NSPrivateQueueConcurrencyType;', 'the UI context has no main queue'),
        ('Horos/Sources/WebPortalConnection.swift', 'self.withConnectionDatabases {', 'the portal requests do not run inside their databases\' queues'),
        ('Horos/Sources/WebPortal.swift', 'func threadDicomDatabase()', 'the portal code has no database of its thread'),
        ('Horos/Sources/BonjourPublisher.swift', '_onRequestDatabaseQueue { try _handleIndexRequest() }', 'the shared-database requests do not run inside the index queue'),
        ('Horos/Sources/OsiriXSCPDataHandler.mm', 'N2ManagedObjectContextPerformAndWait(context, ^{ cond = [self _prepareFindForDataSet:dataset]; });', 'the listener\'s find does not run inside its context queue'),
        ('Horos/Sources/LogManager.swift', 'privateQueueIndependentDatabase()', 'the log does not write on a private-queue database'),
        ('Horos/Sources/DCMPix.m', 'privateQueueIndependentDatabase]', 'DCMPix reads its image outside the image context queue'),
        ('Horos/Sources/BrowserController.m', '- (NSManagedObjectContext*)localManagedObjectContextIndependentContext:(BOOL)independentContext', 'the deprecated selector plug-ins call is gone')):
    if needle not in read(relative):
        failures.append(why)

DRIVER = r'''
let path = CommandLine.arguments[1]
let ui = TestDatabase(path: path)!
_ = ui.save()
// The browser renews the default database's context in the turn that opened
// it; the context it drops must not leave the main queue a block that crashes.
ui.renewManagedObjectContext()
let uiType: String
switch ui.managedObjectContext.concurrencyType {
case .mainQueueConcurrencyType: uiType = "main"
case .privateQueueConcurrencyType: uiType = "private"
default: uiType = "confined"
}
emit("ui.type", uiType)
// The selectors plug-ins call give private-queue contexts (#967).
emit("independent.type", ui.independentContext()?.concurrencyType == .privateQueueConcurrencyType ? "private" : "other")
emit("independentDatabase.type", (ui.independentDatabase() as? TestDatabase)?.managedObjectContext.concurrencyType == .privateQueueConcurrencyType ? "private" : "other")

final class Box: @unchecked Sendable { var value = "no" }

// A UI object, registered in the main-queue context before the background save.
let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: ui.managedObjectContext)
study.setValue("before", forKey: "studyInstanceUID")
_ = ui.save()
let studyID = study.objectID

let changedOnMain = Box()
let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextObjectsDidChange,
                                                      object: ui.managedObjectContext, queue: nil) { _ in
    changedOnMain.value = Thread.isMainThread ? "main" : "other"
}

let background = Box(), uiFromThread = Box(), nested = Box(), nestedException = Box(), afterException = Box()
let finished = Box()
Thread {
    autoreleasepool {
        // Made on this thread: a private queue.
        let other = TestDatabase(path: path + "-other.sql")!
        background.value = other.managedObjectContext.concurrencyType == .privateQueueConcurrencyType ? "private" : "other"

        // A background worker changes the study the UI shows.
        let worker = ui.privateQueueIndependentDatabase() as! TestDatabase
        worker.performBlockAndWait {
            let object = try? worker.managedObjectContext.existingObject(with: studyID)
            object?.setValue("after", forKey: "studyInstanceUID")
            _ = worker.save()
        }

        // The UI context from this thread: on the main thread.
        N2ManagedObjectContextPerformAndWait(ui.managedObjectContext) {
            uiFromThread.value = Thread.isMainThread ? "main" : "this thread"
        }

        // Three queues entered in turn, as a portal request does.
        let first = ui.privateQueueIndependentDatabase() as! TestDatabase
        let second = ui.privateQueueIndependentDatabase() as! TestDatabase
        let third = other.privateQueueIndependentDatabase() as! TestDatabase
        third.performBlockAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: third.managedObjectContext).setValue("third", forKey: "studyInstanceUID")
            _ = third.save()
        }
        func uids(_ db: TestDatabase) -> String {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
            let objects = (try? db.managedObjectContext.fetch(request)) ?? []
            return objects.compactMap { $0.value(forKey: "studyInstanceUID") as? String }.sorted().joined(separator: ",")
        }
        N2ManagedObjectContextPerformAndWait(first.managedObjectContext) {
            N2ManagedObjectContextPerformAndWait(second.managedObjectContext) {
                N2ManagedObjectContextPerformAndWait(third.managedObjectContext) {
                    nested.value = [uids(first), uids(second), uids(third)].joined(separator: "|")
                }
            }
        }
        do {
            try HorosObjCException.perform {
                N2ManagedObjectContextPerformAndWait(first.managedObjectContext) {
                    N2ManagedObjectContextPerformAndWait(second.managedObjectContext) {
                        N2ManagedObjectContextPerformAndWait(third.managedObjectContext) {
                            NSException(name: NSExceptionName("ProbeFailure"), reason: "innermost", userInfo: nil).raise()
                        }
                    }
                }
            }
            nestedException.value = "not raised"
        } catch {
            nestedException.value = (error as NSError).localizedFailureReason ?? (error as NSError).domain
        }
        N2ManagedObjectContextPerformAndWait(first.managedObjectContext) {
            N2ManagedObjectContextPerformAndWait(third.managedObjectContext) {
                afterException.value = uids(first) + "|" + uids(third)
            }
        }
    }
    finished.value = "yes"
}.start()

// The main thread serves its queue while the thread works.
let deadline = Date().addingTimeInterval(30)
while finished.value != "yes" && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
NotificationCenter.default.removeObserver(observer)

emit("finished", finished.value)
emit("background.type", background.value)
emit("merge.value", (study.value(forKey: "studyInstanceUID") as? String) ?? "nil")
emit("merge.thread", changedOnMain.value)
emit("ui.fromThread", uiFromThread.value)
emit("nested.read", nested.value)
emit("nested.exception", nestedException.value)
emit("nested.after", afterException.value)
emit("end", "yes")
'''

EXPECTED = {
    'ui.type': 'main',
    'independent.type': 'private',
    'independentDatabase.type': 'private',
    'finished': 'yes',
    'background.type': 'private',
    'merge.value': 'after',
    'merge.thread': 'main',
    'ui.fromThread': 'main',
    'nested.read': 'after|after|third',
    'nested.exception': 'ProbeFailure',
    'nested.after': 'after|third',
    'end': 'yes',
}

binary, work, error = harness.build(DRIVER)
try:
    if error:
        failures.append(error)
    else:
        status, results, stdout, stderr = harness.run(binary, [str(work / 'store' / 'Database.sql')])
        if status != 0:
            failures.append('the process ended (status %d) after %r:\n%s'
                            % (status, stdout.splitlines()[-1:] or '', stderr[-2000:]))
        for key, value in EXPECTED.items():
            if results.get(key) != value:
                failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))
finally:
    shutil.rmtree(work, ignore_errors=True)

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: the UI context has the main queue and the other consumers work inside queues of their own')
