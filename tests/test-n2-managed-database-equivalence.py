#!/usr/bin/env python3
"""N2ManagedDatabase in Swift does what N2ManagedDatabase.mm did.

N2ManagedDatabase, the Core Data base of DicomDatabase, and its context
N2ManagedObjectContext became Swift (Nitrogen/Sources/N2ManagedDatabase*.swift,
N2ManagedObjectContext.swift), with what Swift cannot write in
N2ManagedDatabase+CAPI.m. This builds one Swift driver twice with
tests/n2_database_harness.py: against the checkout, and against
N2ManagedDatabase.mm/.h of the last revision that has them, read from git. The
driver opens, migrates, saves and reads through independent contexts and
databases, and prints what it sees; the two outputs must be the same, in Debug
(-O0 / -Onone with the Debug checks) and in Release (-Os / -O, NDEBUG):

- opening: a new index, its queue, its store and its options, a subclass that
  saves the model without naming it (the opening fails, no context);
- saving: objects made with -newObjectForEntity:, -save:, the fetches and counts
  with a predicate, a limit and sort descriptors, an unknown entity (the error
  of a fetch and of a count), the index opened again;
- migrating: an index of the former model opened with a model that has one
  attribute more, refused when the database does not migrate (no store, the
  file untouched; saving and counting then fail) and migrated when it does;
- independent contexts: the private-queue independent context, its merge into
  the main context, the private-queue context (not merged), the independent
  database and its main database, object IDs by ID, URI, string and object,
  the legacy locks, -renewManagedObjectContext and its KVO notifications;
- the context: atomic changes that commit, give up, are refused, or raise;
  the actions after the next save and after discarding; -reset;
  -existingObjectWithID:error: of a deleted object;
- the end of a database: its unsaved changes saved, its contexts forgetting it.

Exits 2 when the history does not reach a revision with N2ManagedDatabase.mm.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import n2_database_harness as harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Nitrogen/Sources/N2ManagedDatabase.mm'

reference = history_reference.before_removal_no_renames(SOURCE)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{SOURCE}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + SOURCE, file=sys.stderr)
    raise SystemExit(2)

DRIVER = r'''
let base = CommandLine.arguments[1]
func path(_ name: String) -> String { ((base as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("Database.sql") }
func catching(_ body: () -> Void) -> String {
    do { try HorosObjCException.perform(body); return "none" }
    catch { return ((error as NSError).userInfo[HorosObjCExceptionKey] as? NSException)?.name.rawValue ?? "?" }
}
func queue(_ c: NSManagedObjectContext?) -> String {
    guard let c else { return "nil" }
    switch c.concurrencyType {
    case .mainQueueConcurrencyType: return "main"
    case .privateQueueConcurrencyType: return "private"
    default: return "confined"
    }
}
func describe(_ e: Error?) -> String {
    guard let e = e as NSError? else { return "nil" }
    return "\(e.domain)/\(e.code)"
}
func spin() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) }
/// What a context says of itself, asked on its queue (Core Data's assertions are on).
func onQueue<T>(_ c: NSManagedObjectContext, _ body: () -> T) -> T {
    var result: T? = nil
    c.performAndWait { result = body() }
    return result!
}
func counts(_ db: N2ManagedDatabase) -> String {
    return ["Study", "Series", "Image"].map { "\(db.countObjects(forEntity: $0))" }.joined(separator: ",")
}
func value(_ object: Any?, _ key: String) -> String { ((object as? NSManagedObject)?.value(forKey: key) as? String) ?? "nil" }
func fill(_ db: N2ManagedDatabase, studies: Int, prefix: String) {
    for s in 0..<studies {
        let study = db.newObject(forEntity: "Study") as! NSManagedObject
        study.setValue("\(prefix)\(s)", forKey: "studyInstanceUID")
        for r in 0..<2 {
            let series = db.newObject(forEntity: db.entity(forName: "Series")) as! NSManagedObject
            series.setValue("\(prefix)\(s).\(r)", forKey: "seriesDICOMUID")
            series.setValue(study, forKey: "study")
            for i in 0..<2 {
                let image = db.newObject(forEntity: "Image") as! NSManagedObject
                image.setValue("\(prefix)\(s).\(r).\(i)", forKey: "sopInstanceUID")
                image.setValue(series, forKey: "series")
            }
        }
    }
}
/// Runs body on a thread of its own and waits: what opens there says nothing on screen.
func offMain(_ body: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    Thread { autoreleasepool { body() }; done.signal() }.start()
    done.wait()
}

let migratedModel: NSManagedObjectModel = {
    let m = model()
    m.entitiesByName["Series"]!.properties.append(attribute("modality"))
    return m
}()
final class MigratingDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { migratedModel }
    override func saveModel() -> Bool { false }
}
final class FrozenDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { migratedModel }
    override func saveModel() -> Bool { false }
    override func migratePersistentStoresAutomatically() -> Bool { false }
}
final class UnnamedModelDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
}
final class Observer: NSObject {
    var changes: [String] = []
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changes.append(change?[.notificationIsPriorKey] != nil ? "prior" : "after")
    }
}

// --- opening ---------------------------------------------------------------
do {
    let p = path("open")
    let db = TestDatabase(path: p)!
    let context = db.managedObjectContext!
    emit("open.file", FileManager.default.fileExists(atPath: p) ? "yes" : "no")
    emit("open.queue", queue(context))
    emit("open.class", NSStringFromClass(type(of: context)))
    emit("open.main", db.isMainDatabase() ? "yes" : "no")
    emit("open.mainDatabase", db.mainDatabase == nil ? "nil" : "set")
    emit("open.path", db.sqlFilePath == p ? "same" : "other")
    emit("open.undo", context.undoManager == nil ? "nil" : "set")
    emit("open.database", (context as! N2ManagedObjectContext).database === db ? "self" : "other")
    let stores = context.persistentStoreCoordinator?.persistentStores ?? []
    emit("open.stores", "\(stores.count)")
    if let store = stores.first {
        emit("open.type", store.type)
        let options = (store.options ?? [:]).map { "\($0.key)=\(($0.value as AnyObject).description ?? "?")" }.sorted()
        emit("open.options", options.joined(separator: ";").replacingOccurrences(of: "\n", with: " "))
    }
    emit("open.entity", db.entity(forName: "Study")?.name ?? "nil")
    emit("open.entity.unknown", db.entity(forName: "Nope")?.name ?? "nil")
    emit("open.contextClass", NSStringFromClass(db.nsManagedObjectContextClass()))
    emit("open.deleteIfFailed", db.deleteSQLFileIfOpeningFailed() ? "yes" : "no")
    emit("open.migrates", db.migratePersistentStoresAutomatically() ? "yes" : "no")
    emit("open.modelName", catching { _ = N2ManagedDatabase.modelName() })

    let unnamed = UnnamedModelDatabase(path: path("unnamed"))!
    emit("open.unnamed.context", unnamed.managedObjectContext == nil ? "nil" : "set")
    emit("open.unnamed.file", FileManager.default.fileExists(atPath: path("unnamed")) ? "yes" : "no")
    emit("open.empty", db.context(atPath: "") == nil ? "nil" : "set")
}

// --- saving ----------------------------------------------------------------
do {
    let p = path("save")
    let db = TestDatabase(path: p)!
    fill(db, studies: 2, prefix: "S")
    emit("save.changes", db.managedObjectContext.hasChanges ? "yes" : "no")
    var error: NSError? = nil
    emit("save.result", db.save(&error) ? "yes" : "no")
    emit("save.error", describe(error))
    emit("save.changes.after", db.managedObjectContext.hasChanges ? "yes" : "no")
    emit("save.counts", counts(db))
    let newest = db.objects(forEntity: "Study", predicate: nil, error: nil, fetchLimit: 1,
                            sortDescriptors: [NSSortDescriptor(key: "studyInstanceUID", ascending: false)])
    emit("save.sorted", "\(newest?.count ?? -1) \(value(newest?.first, "studyInstanceUID"))")
    let images = db.objects(forEntity: "Image", predicate: NSPredicate(format: "series.study.studyInstanceUID == 'S1'"))
    emit("save.predicate", "\(images?.count ?? -1)")
    emit("save.entity", "\(db.objects(forEntity: db.entity(forName: "Series"))?.count ?? -1)")
    emit("save.throwing", "\((try? db.objects(forEntity: "Study", predicate: NSPredicate(format: "studyInstanceUID == 'S0'"), error: ()))?.count ?? -1)")
    emit("save.count.predicate", "\(db.countObjects(forEntity: "Series", predicate: NSPredicate(format: "study.studyInstanceUID == 'S0'")))")

    var fetchError: NSError? = nil
    let unknown = db.objects(forEntity: "Nope", predicate: nil, error: &fetchError, fetchLimit: 0, sortDescriptors: nil)
    emit("save.unknown.fetch", "\(unknown == nil ? "nil" : "array") \(describe(fetchError)) \((fetchError?.localizedDescription.isEmpty ?? true) ? "silent" : "said")")
    emit("save.unknown.fetch.noerror", db.objects(forEntity: "Nope") == nil ? "nil" : "array")
    var countError: NSError? = nil
    let unknownCount = db.countObjects(forEntity: "Nope", predicate: nil, error: &countError)
    emit("save.unknown.count", "\(unknownCount) \(describe(countError))")
    emit("save.unknown.count.noerror", "\(db.countObjects(forEntity: "Nope"))")

    let again = TestDatabase(path: p)!
    emit("save.reopened", counts(again))
}

// --- migrating -------------------------------------------------------------
do {
    let p = path("migrate")
    autoreleasepool {
        let old = TestDatabase(path: p)!
        fill(old, studies: 1, prefix: "M")
        _ = old.save()
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? -1
    offMain {
        let frozen = FrozenDatabase(path: p)!
        emit("migrate.frozen.context", queue(frozen.managedObjectContext))
        emit("migrate.frozen.stores", "\(frozen.managedObjectContext?.persistentStoreCoordinator?.persistentStores.count ?? -1)")
        let after = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? -2
        emit("migrate.frozen.file", after == size ? "untouched" : "changed")
        var countError: NSError? = nil
        let n = frozen.countObjects(forEntity: "Study", predicate: nil, error: &countError)
        emit("migrate.frozen.count", "\(n == UInt(bitPattern: NSNotFound) ? "NSNotFound" : "\(n)") \(describe(countError))")
        frozen.performBlockAndWait { _ = frozen.newObject(forEntity: "Study") }
        var saveError: NSError? = nil
        emit("migrate.frozen.save", "\(frozen.save(&saveError) ? "yes" : "no") \(describe(saveError))")
    }
    let migrated = MigratingDatabase(path: p)!
    emit("migrate.stores", "\(migrated.managedObjectContext.persistentStoreCoordinator?.persistentStores.count ?? -1)")
    emit("migrate.counts", counts(migrated))
    let series = migrated.objects(forEntity: "Series", predicate: nil, error: nil, fetchLimit: 0,
                                  sortDescriptors: [NSSortDescriptor(key: "seriesDICOMUID", ascending: true)]) ?? []
    emit("migrate.modality", value(series.first, "modality"))
    (series.first as? NSManagedObject)?.setValue("CT", forKey: "modality")
    emit("migrate.save", migrated.save() ? "yes" : "no")
    let reopened = MigratingDatabase(path: p)!
    let again = reopened.objects(forEntity: "Series", predicate: NSPredicate(format: "modality == 'CT'"))
    emit("migrate.reopened", "\(again?.count ?? -1) \(value(again?.first, "seriesDICOMUID"))")
}

// --- independent contexts and databases --------------------------------------
do {
    let p = path("independent")
    let db = TestDatabase(path: p)!
    fill(db, studies: 1, prefix: "A")
    let study = (db.objects(forEntity: "Study")?.first as! NSManagedObject)
    study.setValue("before", forKey: "comment")
    _ = db.save()

    let independent = db.privateQueueIndependentContext()!
    emit("independent.queue", queue(independent))
    emit("independent.class", NSStringFromClass(type(of: independent)))
    emit("independent.coordinator", independent.persistentStoreCoordinator === db.managedObjectContext.persistentStoreCoordinator ? "shared" : "other")
    emit("independent.policy", onQueue(independent) { independent.mergePolicy as AnyObject } === (db.managedObjectContext.mergePolicy as AnyObject) ? "same" : "other")
    emit("independent.database", (independent as! N2ManagedObjectContext).database === db ? "main" : "other")
    let studyID = study.objectID
    independent.performAndWait {
        let mine = independent.object(with: studyID)
        mine.setValue("after", forKey: "comment")
        let other = NSEntityDescription.insertNewObject(forEntityName: "Study", into: independent)
        other.setValue("B", forKey: "studyInstanceUID")
        try? independent.save()
    }
    emit("independent.merge.now", value(study, "comment"))
    spin()
    emit("independent.merge.later", value(study, "comment"))
    emit("independent.counts", counts(db))

    emit("independent.notIndependent", db.independentContext(false) === db.managedObjectContext ? "same" : "other")
    emit("independent.legacy", queue(db.independentContext()))

    let reader = db.privateQueueContext()!
    emit("privateQueue.queue", queue(reader))
    emit("privateQueue.class", NSStringFromClass(type(of: reader)))
    emit("privateQueue.coordinator", reader.persistentStoreCoordinator === db.managedObjectContext.persistentStoreCoordinator ? "shared" : "other")
    reader.performAndWait {
        reader.object(with: studyID).setValue("unmerged", forKey: "comment")
        try? reader.save()
    }
    spin()
    emit("privateQueue.merge", value(study, "comment"))

    let worker = db.privateQueueIndependentDatabase() as! TestDatabase
    emit("worker.main", worker.isMainDatabase() ? "yes" : "no")
    emit("worker.mainDatabase", (worker.mainDatabase as AnyObject) === db ? "db" : "other")
    emit("worker.path", worker.sqlFilePath == db.sqlFilePath ? "same" : "other")
    emit("worker.queue", queue(worker.managedObjectContext))
    emit("worker.database", (worker.managedObjectContext as! N2ManagedObjectContext).database === db ? "main" : "other")
    emit("worker.ofWorker", ((worker.privateQueueIndependentDatabase() as? N2ManagedDatabase)?.mainDatabase as AnyObject) === db ? "main" : "other")
    emit("worker.legacy", ((worker.independentDatabase() as? N2ManagedDatabase)?.mainDatabase as AnyObject) === db ? "main" : "other")
    var workerStudy: NSManagedObject? = nil
    worker.performBlockAndWait {
        let c = worker.newObject(forEntity: "Study") as! NSManagedObject
        c.setValue("C", forKey: "studyInstanceUID")
        _ = worker.save()
        workerStudy = c
    }
    spin()
    emit("worker.counts", counts(db))

    emit("objectWithID.id", db.object(withID: studyID) as AnyObject === study ? "same" : "other")
    emit("objectWithID.uri", db.object(withID: studyID.uriRepresentation()) as AnyObject === study ? "same" : "other")
    emit("objectWithID.string", db.object(withID: studyID.uriRepresentation().absoluteString) as AnyObject === study ? "same" : "other")
    emit("objectWithID.object", value(db.object(withID: workerStudy as Any), "studyInstanceUID"))
    emit("objectWithID.junk", db.object(withID: "not a URI") == nil ? "nil" : "found")
    emit("objectWithID.number", db.object(withID: NSNumber(value: 1)) == nil ? "nil" : "found")
    let found = db.objects(withIDs: [studyID, "junk", studyID.uriRepresentation(), workerStudy as Any]) ?? []
    emit("objectsWithIDs", found.map { value($0, "studyInstanceUID") }.joined(separator: ","))

    db.lock()
    emit("lock.recursive", db.tryLock() ? "yes" : "no")
    db.unlock()
    db.unlock()
    emit("lock.beforeDate", db.lock(before: Date(timeIntervalSinceNow: 1)) ? "yes" : "no")
    db.unlock()
    emit("lock.pastDate", db.lock(before: Date(timeIntervalSinceNow: -1)) ? "yes" : "no")

    let observer = Observer()
    db.addObserver(observer, forKeyPath: "managedObjectContext", options: [.prior], context: nil)
    let previous = db.managedObjectContext
    db.renewManagedObjectContext()
    db.removeObserver(observer, forKeyPath: "managedObjectContext")
    emit("renew.kvo", observer.changes.joined(separator: ","))
    emit("renew.context", db.managedObjectContext === previous ? "same" : "new")
    emit("renew.queue", queue(db.managedObjectContext))
    emit("renew.coordinator", db.managedObjectContext.persistentStoreCoordinator === previous?.persistentStoreCoordinator ? "shared" : "other")
    emit("renew.policy", (db.managedObjectContext.mergePolicy as AnyObject) === (previous?.mergePolicy as AnyObject) ? "same" : "other")
    emit("renew.undo", db.managedObjectContext.undoManager == nil ? "nil" : "set")
    emit("renew.counts", counts(db))
    var reentered = false
    db.performBlockAndWait { db.performBlockAndWait { reentered = true } }
    emit("perform.reentrant", reentered ? "yes" : "no")
    emit("perform.raises", catching { db.performBlockAndWait { NSException(name: NSExceptionName("Inside"), reason: nil, userInfo: nil).raise() } })
}

// --- the context: atomic changes, actions, reset ------------------------------
do {
    let p = path("atomic")
    let db = TestDatabase(path: p)!
    _ = db.save()
    let context = db.privateQueueIndependentContext() as! N2ManagedObjectContext
    func stored() -> String { "\(db.countObjects(forEntity: "Study"))" }
    var log: [String] = []

    do {
        try context.performAtomicChanges { _ in
            let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            s.setValue("T1", forKey: "studyInstanceUID")
            log.append("deferred:\(context.defersSaves)")
            log.append("nested:\((try? context.save()) != nil)")
            context.perform(afterNextSuccessfulSave: { log.append("saved") })
            context.perform(afterDiscardingChanges: { log.append("discarded") })
            return true
        }
        log.append("commit")
    } catch { log.append("commit failed \(describe(error))") }
    emit("atomic.commit", log.joined(separator: ",") + " stored=" + stored())

    log = []
    do {
        try context.performAtomicChanges { _ in
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T2", forKey: "studyInstanceUID")
            context.perform(afterNextSuccessfulSave: { log.append("saved") })
            context.perform(afterDiscardingChanges: { log.append("discarded") })
            return false
        }
        log.append("commit")
    } catch { log.append("gave up \(describe(error)) \((error as NSError).localizedDescription)") }
    emit("atomic.giveUp", log.joined(separator: ",") + " stored=" + stored() + " changes=\(onQueue(context) { context.hasChanges })")

    log = []
    var inner: NSError? = nil
    do {
        try context.performAtomicChanges { error in
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T3", forKey: "studyInstanceUID")
            inner = NSError(domain: "Driver", code: 7)
            error?.pointee = inner
            return false
        }
    } catch { log.append("reported \(describe(error))") }
    emit("atomic.ownError", log.joined(separator: ","))

    log = []
    context.performAndWait { NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("dirty", forKey: "studyInstanceUID") }
    do {
        try context.performAtomicChanges { _ in true }
        log.append("commit")
    } catch { log.append("refused \(describe(error)) \((error as NSError).localizedDescription)") }
    context.rollback()
    emit("atomic.refused", log.joined(separator: ",") + " stored=" + stored())

    log = []
    let raised = catching {
        try? context.performAtomicChanges { _ in
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T4", forKey: "studyInstanceUID")
            context.perform(afterDiscardingChanges: { log.append("discarded") })
            NSException(name: NSExceptionName("InsideBatch"), reason: nil, userInfo: nil).raise()
            return true
        }
    }
    emit("atomic.raised", "\(raised) \(log.joined(separator: ",")) deferred=\(context.defersSaves) changes=\(onQueue(context) { context.hasChanges }) stored=" + stored())
    do {
        try context.performAtomicChanges { _ in
            NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T5", forKey: "studyInstanceUID")
            return true
        }
        emit("atomic.after", "commit stored=" + stored())
    } catch { emit("atomic.after", "failed \(describe(error))") }

    log = []
    context.perform(afterSuccessfulSave: { log.append("outside") })
    context.performAndWait {
        NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T6", forKey: "studyInstanceUID")
        context.perform(afterNextSuccessfulSave: {
            log.append("next")
            context.perform(afterSuccessfulSave: { log.append("during") })
        })
        context.perform(afterDiscardingChanges: { log.append("discarded") })
    }
    var saveError: NSError? = nil
    context.performAndWait {
        do { try context.save() } catch { saveError = error as NSError }
    }
    emit("actions.save", log.joined(separator: ",") + " " + describe(saveError) + " stored=" + stored())

    log = []
    context.performAndWait {
        NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("T7", forKey: "studyInstanceUID")
        context.perform(afterNextSuccessfulSave: { log.append("next") })
        context.perform(afterDiscardingChanges: { log.append("discarded") })
    }
    context.reset()
    try? context.save()
    emit("actions.reset", log.joined(separator: ",") + " changes=\(onQueue(context) { context.hasChanges }) stored=" + stored())

    var deletedID: NSManagedObjectID? = nil
    context.performAndWait {
        let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        try? context.save()
        deletedID = s.objectID
        context.delete(s)
        try? context.save()
    }
    var existingError: NSError? = nil
    context.performAndWait {
        do { _ = try context.existingObject(with: deletedID!) } catch { existingError = error as NSError }
    }
    emit("existing.deleted", describe(existingError))
    var fetched = -1
    context.performAndWait { fetched = (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study")))?.count ?? -2 }
    emit("context.fetch", "\(fetched)")
    var counted = -1
    context.performAndWait { counted = (try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? -2 }
    emit("context.count", "\(counted)")
}

// --- the end of a database ----------------------------------------------------
do {
    let p = path("end")
    var kept: N2ManagedObjectContext? = nil
    var other: N2ManagedObjectContext? = nil
    autoreleasepool {
        let db = TestDatabase(path: p)!
        _ = db.save()
        fill(db, studies: 1, prefix: "E")
        kept = db.managedObjectContext as? N2ManagedObjectContext
        other = db.privateQueueContext()
        emit("end.before", kept?.database === db && other?.database === db ? "db" : "other")
    }
    emit("end.forgotten", "\(kept?.database == nil ? "nil" : "set") \(other?.database == nil ? "nil" : "set")")
    emit("end.saved", counts(TestDatabase(path: p)!))
}
'''


def run(work, flags):
    reference_work, current_work = work / 'reference', work / 'current'
    outputs = []
    for folder, revision, swift_flags, objc_flags in (
            (reference_work, reference, flags['swift'], flags['objc']),
            (current_work, None, flags['swift'] + flags['debug'], flags['objc'])):
        binary, built, error = harness.build(DRIVER, work=folder, revision=revision, swift_flags=swift_flags, objc_flags=objc_flags)
        if error:
            return None, '%s build: %s' % ('reference' if revision else 'current', error)
        store = folder / 'stores'
        status, results, stdout, stderr = harness.run(binary, [str(store)], timeout=120)
        if status != 0:
            return None, '%s run exited %d: %s' % ('reference' if revision else 'current', status, stderr[-2000:])
        outputs.append(results)
    return outputs, None


failures = []
CONFIGURATIONS = {
    'Debug': {'swift': ['-Onone'], 'debug': ['-D', 'DEBUG'], 'objc': ['-O0']},
    'Release': {'swift': ['-O'], 'debug': [], 'objc': ['-Os', '-DNDEBUG']},
}
compared = 0
with tempfile.TemporaryDirectory(prefix='horos-n2-equivalence-') as directory:
    for name, flags in CONFIGURATIONS.items():
        outputs, error = run(Path(directory) / name, flags)
        if error:
            failures.append('%s: %s' % (name, error))
            continue
        old, new = outputs
        if len(old) < 80:
            failures.append('%s: the reference printed only %d values' % (name, len(old)))
        for key in sorted(set(old) | set(new)):
            if old.get(key) != new.get(key):
                failures.append('%s %s: Objective-C %r, Swift %r' % (name, key, old.get(key), new.get(key)))
        compared = len(old)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: N2ManagedDatabase in Swift answers as N2ManagedDatabase.mm of %s did, %d values each in Debug and Release: '
      'opening, saving, migrating, independent contexts and databases, atomic changes and the end of a database'
      % (reference[:10], compared))
