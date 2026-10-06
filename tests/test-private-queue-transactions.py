#!/usr/bin/env python3
"""Writes and transactions run on the private queue of their context.

The importers, the conversions, the copies, the clean-up and the routing now
work on -[N2ManagedDatabase privateQueueIndependentDatabase], a database whose
context has its own private queue, inside -performBlockAndWait:. And
N2ManagedObjectContext runs save:, rollback, reset, existingObjectWithID:, its
fetches and performAtomicChanges:error: on the context's queue whichever
thread asks, catching an exception there and raising it again outside.

This compiles the real N2ManagedDatabase.mm (tests/n2_database_harness.py) and
drives it from a background thread while the main thread waits without a run
loop, with Core Data's multithreading assertions on:

- the private-queue database: its context, its main database, a direct
  -performBlockAndWait: on a confined database;
- a transaction that commits: the rows are in the store, the action for the
  next successful save ran - on the queue, reading an object of the context -
  and the action for discarded changes did not;
- a transaction whose changes give up: nothing written, the discard action
  ran, the save action did not, the error says the changes were not committed;
- an exception inside the transaction: rolled back, raised to the caller, and
  the same context commits the next transaction;
- a save that fails (the store has been removed): an error, no save action,
  and the prepared changes stay for a later rollback;
- an importer's shape: a save inside -performBlockAndWait: publishing through
  -performAfterNextSuccessfulSave: only after the commit.

The source check confirms that the application's writers use the private-queue
database.
"""
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import n2_database_harness as harness  # noqa: E402

root = Path(__file__).resolve().parents[1]
failures = []


def read(relative):
    return (root / relative).read_bytes().decode('latin1')


managed = read('Nitrogen/Sources/N2ManagedDatabase.mm')
for needle, why in (
        ('- (id)privateQueueIndependentDatabase', 'the private-queue independent database is gone'),
        ('- (void)performBlockAndWait:', 'the database no longer runs work on its context queue'),
        ('N2ManagedObjectContextPerformAndWait(self, ^{', 'the context no longer moves its operations onto its queue')):
    if needle not in managed:
        failures.append(why)

for forbidden in ('[self lock];', '[self unlock];', '[context lock];', '[context unlock];'):
    if forbidden in managed:
        failures.append('N2 internal operation still uses legacy context locking: ' + forbidden)

database = read('Horos/Sources/DicomDatabase.mm')
for needle, why in (
        ('DicomDatabase *worker = self.privateQueueIndependentDatabase;', 'the INCOMING importer does not use a private-queue database'),
        ('self.isMainDatabase ? self.privateQueueIndependentDatabase : self;', 'the conversion workers do not use a private-queue database'),
        ('DicomDatabase *idatabase = self.privateQueueIndependentDatabase;', 'the copy importer does not use a private-queue database')):
    if needle not in database:
        failures.append(why)
if 'independentDatabase' in database.replace('privateQueueIndependentDatabase', '').replace('// is independentDatabase', ''):
    failures.append('DicomDatabase.mm still makes a confined independent database')
for relative, needle in (('Horos/Sources/DicomDatabase+Clean.swift', 'privateQueueIndependentDatabase()'),
                         ('Horos/Sources/DicomDatabase+Routing.swift', 'privateQueueIndependentDatabase()'),
                         ('Horos/Sources/XMLRPCMethods.mm', 'privateQueueIndependentDatabase]'),
                         ('Horos/Sources/WebPortalConnection+Data.swift', 'privateQueueIndependentDatabase()'),
                         ('Horos/Sources/BrowserController+Sources+Copy.swift', 'privateQueueIndependentDatabase()')):
    if needle not in read(relative):
        failures.append('%s does not write on a private-queue database' % relative)

DRIVER = r'''
let path = CommandLine.arguments[1]
let database = TestDatabase(path: path)!
_ = database.save()

var direct = false
database.performBlockAndWait { direct = true }
emit("confined.direct", direct ? "yes" : "no")

func storedStudies(_ db: N2ManagedDatabase) -> Int {
    // A new private context reads only what was committed.
    let reader = db.privateQueueContext()!
    var n = -1
    reader.performAndWait { n = (try? reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? -1 }
    return n
}

final class Box: @unchecked Sendable { var value = "no" }

let done = DispatchSemaphore(value: 0)
Thread {
    autoreleasepool {
        let worker = database.privateQueueIndependentDatabase() as! TestDatabase
        let context = worker.managedObjectContext as! N2ManagedObjectContext
        emit("worker.type", context.concurrencyType == .privateQueueConcurrencyType ? "private" : "other")
        emit("worker.main", worker.mainDatabase as AnyObject === database ? "yes" : "no")
        emit("worker.coordinator", context.persistentStoreCoordinator === database.managedObjectContext.persistentStoreCoordinator ? "shared" : "other")

        // Commits: no outer perform, the context moves the batch onto its queue.
        let saved = Box(), discarded = Box()
        do {
            try context.performAtomicChanges { _ in
                let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
                study.setValue("A", forKey: "studyInstanceUID")
                context.perform(afterNextSuccessfulSave: { saved.value = (study.value(forKey: "studyInstanceUID") as? String) ?? "nil" })
                context.perform(afterDiscardingChanges: { discarded.value = "yes" })
                return true
            }
            emit("commit", "yes")
        } catch { emit("commit", "\(error)") }
        emit("commit.saveAction", saved.value)
        emit("commit.discardAction", discarded.value)
        emit("commit.stored", "\(storedStudies(database))")

        // Reentrant queue work and post-save callbacks may save again.
        let nested = Box()
        worker.performBlockAndWait {
            context.perform(afterNextSuccessfulSave: {
                context.perform(afterNextSuccessfulSave: { nested.value = "yes" })
                do { try context.save() } catch { nested.value = "failed" }
            })
            _ = worker.save()
        }
        emit("save.reentrant", nested.value)

        // SDK adapters remain recursive and a successful tryLock balances unlock.
        worker.performBlockAndWait {
            context.lock()
            let acquired = context.tryLock()
            if acquired { context.unlock() }
            context.unlock()
            emit("compat.recursive", acquired ? "yes" : "no")
        }

        // Database lookup methods enter the queue and return live values.
        let rows = worker.objects(forEntity: "Study")!
        emit("lookup.count", "\(worker.countObjects(forEntity: "Study"))")
        var ids: [NSManagedObjectID] = []
        worker.performBlockAndWait { ids = rows.map { ($0 as! NSManagedObject).objectID } }
        emit("lookup.ids", "\(worker.objects(withIDs: ids)!.count)")

        // Gives up: rolled back.
        let saved2 = Box(), discarded2 = Box()
        do {
            try context.performAtomicChanges { _ in
                NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("B", forKey: "studyInstanceUID")
                context.perform(afterNextSuccessfulSave: { saved2.value = "yes" })
                context.perform(afterDiscardingChanges: { discarded2.value = "yes" })
                return false
            }
            emit("giveup", "committed")
        } catch { emit("giveup", "\((error as NSError).domain) \((error as NSError).code)") }
        emit("giveup.saveAction", saved2.value)
        emit("giveup.discardAction", discarded2.value)
        emit("giveup.stored", "\(storedStudies(database))")
        var dirty = true
        worker.performBlockAndWait { dirty = context.hasChanges }
        emit("giveup.clean", dirty ? "dirty" : "clean")

        // An exception inside: rolled back and raised here, off the queue.
        do {
            try HorosObjCException.perform {
                _ = try? context.performAtomicChanges { _ in
                    NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("C", forKey: "studyInstanceUID")
                    NSException(name: NSExceptionName("ProbeFailure"), reason: "inside the transaction", userInfo: nil).raise()
                    return true
                }
            }
            emit("exception", "not raised")
        } catch { emit("exception", (error as NSError).localizedFailureReason ?? (error as NSError).domain) }
        emit("exception.stored", "\(storedStudies(database))")
        do {
            try context.performAtomicChanges { _ in
                NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("D", forKey: "studyInstanceUID")
                return true
            }
            emit("after.exception", "committed")
        } catch { emit("after.exception", "\(error)") }
        emit("after.exception.stored", "\(storedStudies(database))")

        // An importer: prepared, saved on the queue, published only after the commit.
        let published = Box()
        worker.performBlockAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("E", forKey: "studyInstanceUID")
            context.perform(afterNextSuccessfulSave: { published.value = "after commit, stored \(storedStudies(database))" })
            emit("import.beforeSave", published.value)
            _ = worker.save()
        }
        emit("import.published", published.value)
        let found = Box()
        worker.performBlockAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
            request.predicate = NSPredicate(format: "studyInstanceUID == %@", "E")
            if let study = (try? context.fetch(request))?.first,
               let again = try? context.existingObject(with: study.objectID) {
                found.value = (again.value(forKey: "studyInstanceUID") as? String) ?? "nil"
            }
        }
        emit("import.readBack", found.value)

        // A save that fails: an error, no save action, the changes kept.
        let failing = TestDatabase(path: path + "-failing.sql")!
        _ = failing.save()
        let failingWorker = failing.privateQueueIndependentDatabase() as! TestDatabase
        let failingContext = failingWorker.managedObjectContext as! N2ManagedObjectContext
        let saved3 = Box()
        var saveError: NSError? = nil
        failingWorker.performBlockAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: failingContext)
            failingContext.perform(afterNextSuccessfulSave: { saved3.value = "yes" })
        }
        let coordinator = failingContext.persistentStoreCoordinator!
        coordinator.performAndWait { for store in coordinator.persistentStores { try? coordinator.remove(store) } }
        do {
            try HorosObjCException.perform {
                do { try failingContext.save() } catch { saveError = error as NSError }
            }
        } catch { saveError = error as NSError }
        emit("failed.error", saveError == nil ? "none" : "yes")
        emit("failed.saveAction", saved3.value)
        var kept = false
        failingWorker.performBlockAndWait { kept = failingContext.hasChanges }
        emit("failed.kept", kept ? "yes" : "no")
        failingContext.rollback()
        failingWorker.performBlockAndWait { kept = failingContext.hasChanges }
        emit("failed.rolledBack", kept ? "no" : "yes")
    }
    done.signal()
}.start()
emit("finished", done.wait(timeout: .now() + 30) == .success ? "yes" : "no")
emit("end", "yes")
'''

EXPECTED = {
    'confined.direct': 'yes',
    'worker.type': 'private',
    'worker.main': 'yes',
    'worker.coordinator': 'shared',
    'commit': 'yes',
    'commit.saveAction': 'A',
    'commit.discardAction': 'no',
    'commit.stored': '1',
    'save.reentrant': 'yes',
    'compat.recursive': 'yes',
    'lookup.count': '1',
    'lookup.ids': '1',
    'giveup': 'N2AtomicChanges 2',
    'giveup.saveAction': 'no',
    'giveup.discardAction': 'yes',
    'giveup.stored': '1',
    'giveup.clean': 'clean',
    'exception': 'ProbeFailure',
    'exception.stored': '1',
    'after.exception': 'committed',
    'after.exception.stored': '2',
    'import.beforeSave': 'no',
    'import.published': 'after commit, stored 3',
    'import.readBack': 'E',
    'failed.error': 'yes',
    'failed.saveAction': 'no',
    'failed.kept': 'yes',
    'failed.rolledBack': 'yes',
    'finished': 'yes',
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
print('ok: writes, transactions and their callbacks run on the private queue of their context')
