#!/usr/bin/env python3
"""Imports that overlap each write their rows, and make one study of one UID.

An independent database has a context of its own, and a context sees only what
was saved. Two imports over the same store used to overlap between reading the
studies and saving, with two results:

- the second one to reach the save found a process-wide flag set by the first
  and skipped its save, on the belief that the first save would write its rows.
  It writes only its own context: the skipped rows stayed unsaved until the
  database was released;
- neither saw the other's new study, so a study that arrived from two sources
  at once was made twice with the same Study Instance UID.

This compiles the real N2ManagedDatabase and N2ManagedObjectContext
(tests/n2_database_harness.py), and pastes -addFilesDescribedInDictionaries: and
indexDescribedFiles as they are in the checkout and in the previous revision,
read from git, into a stand-in over a disposable SQLite store: indexing one file
is a double that does what findStudy does with the study list. Two private
contexts run on two threads with Core Data's multithreading assertions on, and
hooks at the fetch, before the save and in the save make them overlap where the
code lets them, and time out where it does not.

The previous revision must show the skipped save and the duplicate; the checkout
must show neither, and also:

- an import nested on the same thread does not stop, as when indexing a file
  archives the study's annotations;
- a save that fails, a save that raises, and an exception before the save each
  let the gate go, so the next import from another thread saves;
- a worker that calls a main-queue context off the main thread, as a plugin can,
  while the main thread waits for the gate, does not hold the gate waiting for
  the main thread: the import enters the context's queue first.

What the double cannot show is read from the source: the gate is shared with the
independent databases, and -publish stays out of it.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import history_reference  # noqa: E402
import indexer_paste  # noqa: E402
import n2_database_harness as harness  # noqa: E402

# The flag lived in DicomDatabase+Import.swift, the file of the import before the
# indexer became a type of its own (tests/indexer_paste.py).
IMPORT = indexer_paste.FORMER
FLAG = 'protectionAgainstReentry'
# Asked inside the gate whether the context was replaced while the import
# waited (see test-sql-rebuild-direct-writer.py).
REBUILD = 'Horos/Sources/DatabaseRebuildService.swift'
REPLACED = 'static func contextWasReplaced('
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def method(source, signature):
    start = source.index(signature)
    depth, index = 0, source.index('{', start)
    while True:
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1


def previous_revision():
    """The last revision of the import with the process-wide flag."""
    head = subprocess.run(['git', '-C', str(root), 'show', 'HEAD:' + IMPORT], capture_output=True, text=True)
    if head.returncode == 0 and FLAG in head.stdout:
        return 'HEAD'
    return history_reference.before_text_removed(IMPORT, FLAG)


DRIVER = r'''
import AppKit
import CoreData
import IsiXDatabase
import IsiXPreferences

// What the pasted methods use from the rest of the application.

extension Thread {
    @objc var status: String? {
        get { nil }
        set { if newValue == NSLocalizedString("Synchronizing database...", comment: "") { Script.beforeSave() } }
    }
    @objc var progress: CGFloat { get { 0 } set {} }
}
enum ActivityProgressCount { static func set(done: Int, total: Int, on thread: Thread) {} }
enum ImportShortfall { static func progressDone(index: Int, total: Int) -> Int { index } }
func DicomDatabaseUndefinedStudyDate() -> Date { Script.afterFetch(); return Date(timeIntervalSince1970: 0) }
func DicomDatabaseCleanReportExtractionParent(_ path: String?) {}
func associateCloudReports(_ files: NSArray, _ studies: NSArray, _ context: NSManagedObjectContext?) {}
final class DicomDatabaseImportCursor {}
struct DicomDatabaseImportSettings {
    let combineProjectionSeries: Bool, combineProjectionSeriesMode: Int, commentsAutoFill: Bool, deleteFileListener: Bool
    let commentField: String?, commentsAutoFillSeriesLevel: Bool, commentsAutoFillStudyLevel: Bool
}
final class DicomDatabaseImportBatch {
    var rejectedReports = 0
    let addedImageObjects: NSMutableArray? = NSMutableArray()
    init(returnArray: Bool, capacity: Int) {}
}
enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? {
        do { try HorosObjCException.perform(body) } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }
    static func log(_ exception: NSException, stack: Bool, _ function: String) { Script.count("raised") }
    static func localizedFileCount(_ count: Int) -> String { "\(count) files" }
}
extension DicomStudy {
    func noFiles() -> NSNumber? {
        if Script.raiseBeforeSave { Script.raiseBeforeSave = false; NSException(name: .genericException, reason: "before the save", userInfo: nil).raise() }
        return rawNoFiles()
    }
    func reapplyAnnotationsFromDICOMSR() {}
}

/// Events the threads wait for, each with a timeout: where the gate keeps a
/// thread out, the other goes on when the wait ends.
final class Script: @unchecked Sendable {
    nonisolated(unsafe) static var overlap = false
    nonisolated(unsafe) static var raiseBeforeSave = false
    nonisolated(unsafe) static var saveFault = ""
    nonisolated(unsafe) static var holdInLoop: TimeInterval = 0
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    @discardableResult static func count(_ event: String) -> Int {
        condition.lock(); defer { condition.unlock() }
        counts[event, default: 0] += 1
        condition.broadcast()
        return counts[event]!
    }
    static func value(_ event: String) -> Int {
        condition.lock(); defer { condition.unlock() }
        return counts[event, default: 0]
    }
    static func wait(_ event: String, _ wanted: Int, _ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock(); defer { condition.unlock() }
        while counts[event, default: 0] < wanted, condition.wait(until: deadline) {}
    }
    static func afterFetch() {
        guard overlap else { return }
        count("fetched")
        wait("fetched", 2, 1)
    }
    /// The first import goes on to save; the second comes here while it saves.
    static func beforeSave() {
        guard overlap else { return }
        if count("synchronizing") == 2 { wait("saving", 1, 1) }
    }
    static func inSave() {
        guard overlap else { return }
        if count("saving") == 1 { wait("imported", 1, 1) }
    }
}

final class ScriptedContext: N2ManagedObjectContext {
    override func save() throws {
        let fault = Script.saveFault
        if !fault.isEmpty {
            Script.saveFault = ""
            if fault == "fails" { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "scripted failure"]) }
            NSException(name: .genericException, reason: "scripted raise", userInfo: nil).raise()
        }
        try super.save()
    }
}

class ImportDatabase: N2ManagedDatabase {
    let databaseWriterGate: DatabaseWriterGate
    override init!(path p: String!, context c: NSManagedObjectContext!, mainDatabase m: N2ManagedDatabase!) {
        databaseWriterGate = (m as? ImportDatabase)?.databaseWriterGate ?? DatabaseWriterGate()
        super.init(path: p, context: c, mainDatabase: m)
    }
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
    override func nsManagedObjectContextClass() -> AnyClass! { ScriptedContext.self }
    func studyEntity() -> NSEntityDescription! { entity(forName: "Study") }
    func dataDirPath() -> String? { nil }
    func reportsDirPath() -> String? { nil }
    func errorsDirPath() -> String? { nil }
    func cleanForFreeSpace() {}
    func alertRejectedReports(_ count: Int) {}
    func checkForCorrectContextThreadIfDeclared() {}
    func publish(_ added: DicomDatabaseImportBatch, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) {}

    /// What findStudy and indexImages do with the study list.
    func indexFile(_ curDict: NSMutableDictionary?, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                   studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: NSMutableArray, modifiedStudiesArray: NSMutableArray,
                   defaultDate: Date, today: Date, dataDirPath: String?, reportsDirPath: String?, errorsDirPath: String?,
                   settings: DicomDatabaseImportSettings, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool,
                   preparedReportPath: inout String?) {
        let context = self.managedObjectContext!
        let uid = curDict!.object(forKey: "studyID") as! String
        let index = studiesArrayStudyInstanceUID.index(of: uid)
        let study: DicomStudy
        if index != NSNotFound {
            study = studiesArray.object(at: index) as! DicomStudy
        } else {
            study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
            study.studyInstanceUID = uid
            studiesArray.add(study)
            studiesArrayStudyInstanceUID.add(uid)
        }
        if !modifiedStudiesArray.contains(study) { modifiedStudiesArray.add(study) }
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
        series.setValue(study, forKey: "study")
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        image.setValue(curDict!.object(forKey: "SOPUID") as! String, forKey: "sopInstanceUID")
        image.setValue(series, forKey: "series")
        added.addedImageObjects?.add(image)
        if Script.holdInLoop > 0 { Thread.sleep(forTimeInterval: Script.holdInLoop) }
        if let nested = curDict!.object(forKey: "nested") as? String {
            // As -archiveAnnotationsAsDICOMSR indexes the archive it writes.
            let database = self.privateQueueIndependentDatabase() as! ImportDatabase
            N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
                _ = database.addFilesDescribed(inDictionaries: [files(uid, [nested])[0]], postNotifications: false, rereadExistingItems: true,
                                               generatedByOsiriX: true, importedFiles: false, returnArray: true)
            }
        }
    }
}

// The methods as they are in the revision under test.
//@PASTE@

func files(_ study: String, _ names: [String]) -> [NSMutableDictionary] {
    names.map { NSMutableDictionary(dictionary: ["studyID": study, "SOPUID": $0, "filePath": "/nowhere/" + $0]) }
}

/// An import on a thread of its own, on the queue of the context, as the
/// importers run; waits for nothing.
func importOnThread(_ database: ImportDatabase, _ items: [NSMutableDictionary], onQueue: Bool = true, done: DispatchSemaphore) {
    let thread = Thread {
        autoreleasepool {
            let run = {
                _ = database.addFilesDescribed(inDictionaries: items, postNotifications: false, rereadExistingItems: false,
                                               generatedByOsiriX: false, importedFiles: false, returnArray: true)
            }
            if onQueue { N2ManagedObjectContextPerformAndWait(database.managedObjectContext, run) } else { run() }
            Script.count("imported")
        }
        done.signal()
    }
    thread.start()
}

func stored(_ main: ImportDatabase) -> (studies: Int, uids: Int, images: Int) {
    let context = main.privateQueueContext()!
    var answer = (studies: 0, uids: 0, images: 0)
    context.performAndWait {
        let studies = (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? []
        answer.studies = studies.count
        answer.uids = Set(studies.compactMap { $0.value(forKey: "studyInstanceUID") as? String }).count
        answer.images = (try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Image"))) ?? -1
    }
    return answer
}

let arguments = CommandLine.arguments
let scenario = arguments[1], folder = arguments[2]
let main: ImportDatabase = ImportDatabase(path: folder + "/Database.sql", context: nil, mainDatabase: nil)
let done = DispatchSemaphore(value: 0)
let rounds = 15
func finish() {
    let result = stored(main)
    emit("studies", String(result.studies)); emit("uids", String(result.uids)); emit("images", String(result.images))
    emit("raised", String(Script.value("raised")))
    fflush(stdout)
    exit(0)
}

switch scenario {
case "overlap":
    Script.overlap = true
    NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { _ in Script.inSave() }
    var first: ImportDatabase? = main.privateQueueIndependentDatabase() as? ImportDatabase
    var second: ImportDatabase? = main.privateQueueIndependentDatabase() as? ImportDatabase
    autoreleasepool {
        importOnThread(first!, files("1.2.3", ["a1", "a2", "a3"]), done: done)
        importOnThread(second!, files("1.2.3", ["b1", "b2"]), done: done)
    }
    done.wait(); done.wait()
    Script.overlap = false
    let saved = stored(main)
    emit("saved_studies", String(saved.studies)); emit("saved_images", String(saved.images))
    var unsaved = false
    for database in [first!, second!] {
        let context = database.managedObjectContext!
        context.performAndWait { unsaved = unsaved || context.hasChanges }
    }
    emit("unsaved_rows", unsaved ? "1" : "0")
    // The rows a skipped save left are written when the database goes.
    first = nil; second = nil
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    finish()
case "nested":
    let database = main.privateQueueIndependentDatabase() as! ImportDatabase
    let item = files("1.2.3", ["a1"])[0]
    item.setObject("nested1", forKey: "nested" as NSString)
    importOnThread(database, [item], done: done)
    done.wait()
    finish()
case "fails", "raises", "before-save":
    if scenario == "before-save" { Script.raiseBeforeSave = true } else { Script.saveFault = scenario }
    let bad = main.privateQueueIndependentDatabase() as! ImportDatabase
    let good = main.privateQueueIndependentDatabase() as! ImportDatabase
    importOnThread(bad, files("1.2.3", ["a1"]), done: done)
    done.wait()
    // Another thread, which the gate of a recursive lock would keep out.
    importOnThread(good, files("4.5.6", ["b1"]), done: done)
    done.wait()
    finish()
case "main-waits":
    // A worker holds the gate, and a second worker calls the main-queue context
    // off the main thread while the main thread comes to the gate. Were that
    // caller to take the gate before the queue it would hold it waiting for the
    // main thread; which waiter gets the gate varies, so this repeats.
    Script.holdInLoop = 0.03
    let worker = main.privateQueueIndependentDatabase() as! ImportDatabase
    let deadline = Date(timeIntervalSinceNow: 40)
    for round in 0..<rounds {
        importOnThread(worker, files("1.2.\(round)", ["a\(round)-1", "a\(round)-2", "a\(round)-3"]), done: done)
        Thread.sleep(forTimeInterval: 0.02)
        importOnThread(main, files("7.8.\(round)", ["c\(round)"]), onQueue: false, done: done)
        Thread.sleep(forTimeInterval: 0.02)
        _ = main.addFilesDescribed(inDictionaries: files("4.5.\(round)", ["b\(round)"]), postNotifications: false, rereadExistingItems: false,
                                   generatedByOsiriX: false, importedFiles: false, returnArray: true)
        while Script.value("imported") < 2 * (round + 1) && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
    emit("workers_ended", String(Script.value("imported")))
    finish()
default:
    exit(3)
}
'''


def run_revision(label, source):
    pasted = indexer_paste.pasted(source)
    rebuild = (root / REBUILD).read_text()
    if REPLACED in rebuild:
        pasted += ('typealias DicomDatabase = ImportDatabase\nenum DatabaseRebuildService {\n'
                   + method(rebuild, REPLACED) + '\n}\n')
    if FLAG in source:
        pasted = 'nonisolated(unsafe) private var %s = false\n' % FLAG + pasted
    work = Path(tempfile.mkdtemp(prefix='horos-writer-gate-'))
    try:
        binary, _, error = harness.build(DRIVER.replace('//@PASTE@', pasted), work=work / 'build')
        if error:
            failures.append('%s: %s' % (label, error))
            return {}
        results = {}
        for scenario in ('overlap', 'nested', 'fails', 'raises', 'before-save', 'main-waits'):
            store = work / scenario
            store.mkdir()
            try:
                if scenario == 'main-waits':
                    # A caller off the queue reads its results off the queue
                    # afterwards, which the assertions stop; this one is about
                    # the wait.
                    result = subprocess.run([str(binary), scenario, str(store)], capture_output=True, text=True, timeout=60)
                    status, stderr = result.returncode, result.stderr
                    values = dict(line.split('\t', 1) for line in result.stdout.splitlines() if '\t' in line)
                else:
                    status, values, _, stderr = harness.run(binary, [scenario, str(store)], timeout=60)
            except subprocess.TimeoutExpired:
                status, values, stderr = 'hung', {}, ''
            values['status'] = status
            values['skipped'] = 'another import is saving' in stderr
            results[scenario] = values
            print('%s %s: %s' % (label, scenario, values))
            if status != 0:
                print(stderr[-1500:])
        return results
    finally:
        shutil.rmtree(work, ignore_errors=True)


revision = previous_revision()
if revision is None:
    print('skipped: the history does not reach the revision before the gate')
    sys.exit(2)
sys.stdout.reconfigure(line_buffering=True)
current = indexer_paste.current()
head_is_previous = revision == 'HEAD'
previous = subprocess.run(['git', '-C', str(root), 'show', '%s:%s' % (revision, IMPORT)], capture_output=True,
                          text=True, check=True).stdout

# --- the previous revision shows the defect ---------------------------------
old = run_revision('previous (%s)' % revision[:9], previous)
overlap = old.get('overlap', {})
check(overlap.get('status') == 0, 'the previous revision did not finish the overlap: %s' % overlap.get('status'))
check(overlap.get('skipped'), 'the previous revision did not skip the second save, so this no longer reproduces it')
check(overlap.get('saved_images') in ('2', '3'), 'the previous revision wrote %s of 5 images before the databases went, '
      'where a skipped save leaves those of one import' % overlap.get('saved_images'))
check(overlap.get('unsaved_rows') == '1', 'the previous revision left no rows in the second context')
check(overlap.get('studies') == '2' and overlap.get('uids') == '1',
      'the previous revision did not make the same study twice: %s studies, %s UIDs' % (overlap.get('studies'), overlap.get('uids')))

# --- the checkout does not ---------------------------------------------------
new = run_revision('checkout', current)
overlap = new.get('overlap', {})
check(overlap.get('status') == 0, 'the overlap did not finish: %s' % overlap.get('status'))
check(not overlap.get('skipped'), 'an import still skips its save')
check(overlap.get('saved_images') == '5', 'overlapping imports wrote %s of 5 images' % overlap.get('saved_images'))
check(overlap.get('saved_studies') == '1' and overlap.get('studies') == '1',
      'overlapping imports made %s studies of one UID' % overlap.get('studies'))
check(overlap.get('unsaved_rows') == '0', 'an import left rows unsaved in its context')
nested = new.get('nested', {})
check(nested.get('status') == 0 and nested.get('images') == '2',
      'an import nested on the same thread did not end with both images: %s' % nested)
for scenario, wanted, raised in (('fails', '1', '0'), ('raises', '1', '1'), ('before-save', '1', '1')):
    values = new.get(scenario, {})
    check(values.get('status') == 0, '%s: the next import did not end: %s' % (scenario, values.get('status')))
    check(values.get('images') == wanted, '%s: the next import wrote %s images, wanted %s' % (scenario, values.get('images'), wanted))
    check(values.get('raised') == raised, '%s: %s exceptions reached the log of the import, wanted %s' % (scenario, values.get('raised'), raised))
waits = new.get('main-waits', {})
check(waits.get('status') == 0 and waits.get('workers_ended') == '30' and waits.get('images') == '75',
      'a worker off the queue of the main-queue context while the main thread waited for the gate: %s' % waits)

# --- what the double does not see --------------------------------------------
gate_text = (root / 'Modules/IsiXDatabase/Sources/DatabaseWriterGate.swift').read_text()
check('NSRecursiveLock' in gate_text, 'the gate is not recursive, and a nested import would stop on itself')
check(FLAG not in current, 'the process-wide flag is back')
database = (root / 'Horos/Sources/DicomDatabase.swift').read_text()
assignment = database.find('databaseWriterGate = (main as? DicomDatabase)?.databaseWriterGate ?? DatabaseWriterGate()')
check(0 <= assignment < database.find('super.init(path: sqlFilePath, context: c, mainDatabase: main)'),
      'an independent database does not take the gate of its main database')
add, index_body = indexer_paste.gated(current)
gate = add.find('withExclusiveWrite')
queue = add.find('N2ManagedObjectContextPerformAndWait(database.managedObjectContext)')
index = add.find('self.indexDescribedFiles(')
publish = add.find('self.publish(')
check(0 <= queue < gate < index, 'the import does not enter its context, then the gate, then index')
check(index < publish and add.rfind('}', index, publish) >= 0 and add.find('if let raised', index) < publish,
      'publishing moved into the gate')
check(current.count('indexDescribedFiles(') == 2, 'something else calls the indexing outside the gate')
check('database.objects(forEntity: database.studyEntity())' in index_body and 'try context?.save()' in index_body,
      'the study list and the save left the gated method')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the previous revision skips the save and duplicates the study; the checkout writes both imports into one '
      'study, and the gate survives nesting, failed and raising saves')
