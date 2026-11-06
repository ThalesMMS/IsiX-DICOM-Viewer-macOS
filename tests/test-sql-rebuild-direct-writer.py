#!/usr/bin/env python3
"""What adds files directly while the SQL file is rebuilt waits, and is kept.

The rebuild of the SQL file (Rebuild SQL File) dumps the index with sqlite3,
loads the dump into a new file and moves the former one to the backups. It held
only the lock of the INCOMING folder import; the shared database's SEND, the
compression and the plugins' adapter call -addFilesAtPaths: directly, on an
independent database over the coordinator of the former file. Such a write
after the dump went into the file on its way to the backups, and its rows were
lost.

This compiles the real N2ManagedDatabase (tests/n2_database_harness.py) and
pastes, as they are in the checkout and in the previous revision read from git,
-addFilesDescribedInDictionaries:, DatabaseRebuildService.rebuildSqlFile and
what the import asks of it inside the gate, into stand-ins over a disposable
SQLite store; indexing one file is a double that makes its study, series and image.
The dump is a double too: sqlite3 copies the index, the writer is let in for a
moment, and the files are swapped as the rebuild swaps them. Core Data's
multithreading assertions are on.

During the dump an independent database adds one image; after the rebuild the
same database adds another. The previous revision must leave the first out of
the new index, in the retired file. The checkout must keep both and the seed in
the new index, with the first written after the swap: the writer waited at the
gate and came in over the new index. A writer on the main database, whose
context is nil during the dump, must wait too and land in the new index. Built
with DEBUG, the checkout must not say that the main-queue context of the main
database was used off the main thread: it is saved from the main run loop, and
the former one is released there.

What the doubles do not show is read from the source: the gate is held from
before the context is let go until the new one is set, a former main-queue
context is given back outside it, both rebuilds are listed for quitting, and
the Quit command asks before closing anything.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import history_reference  # noqa: E402
import indexer_paste  # noqa: E402
import n2_database_harness as harness  # noqa: E402

REBUILD = 'Horos/Sources/DatabaseRebuildService.swift'
MARKER = 'databaseWriterGate.retire('
REPLACED = 'static func contextWasReplaced('
REBUILD_SQL = 'func rebuildSqlFile() {'
FILE_NUMBER = 'private func fileNumber(atPath path: String) -> Int? {'
SAVE = 'private func saveOnTheThreadOfTheContext() {'
RELEASE = 'private func releaseOnTheMainThread(_ context: inout NSManagedObjectContext?) {'
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
    """The last revision whose SQL rebuild did not hold the writer gate."""
    head = subprocess.run(['git', '-C', str(root), 'show', 'HEAD:' + REBUILD], capture_output=True, text=True)
    if head.returncode == 0 and MARKER not in head.stdout:
        return 'HEAD'
    return history_reference.before_text_added(REBUILD, MARKER)


DRIVER = r'''
import AppKit
import CoreData
import IsiXDatabase
import IsiXPreferences

// What the pasted methods use from the rest of the application.

extension Thread {
    @objc var status: String? { get { nil } set {} }
    @objc var progress: CGFloat { get { 0 } set {} }
}
enum ActivityProgressCount { static func set(done: Int, total: Int, on thread: Thread) {} }
enum ImportShortfall { static func progressDone(index: Int, total: Int) -> Int { index } }
func DicomDatabaseUndefinedStudyDate() -> Date { Date(timeIntervalSince1970: 0) }
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
    static func log(_ exception: NSException, stack: Bool, _ function: String) { emit("raised", exception.reason ?? "") }
    static func localizedFileCount(_ count: Int) -> String { "\(count) files" }
}
extension DicomStudy {
    func noFiles() -> NSNumber? { rawNoFiles() }
    func reapplyAnnotationsFromDICOMSR() {}
}
struct DatabaseModelUpgrade {
    init(database: ImportDatabase, processGraph: Int) {}
    var indexAwaitsUpgrade: Bool { false }
}

/// Events the threads wait for, each with a timeout.
final class Script: @unchecked Sendable {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func count(_ event: String) {
        condition.lock(); defer { condition.unlock() }
        counts[event, default: 0] += 1
        condition.broadcast()
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
}

class ImportDatabase: N2ManagedDatabase {
    let databaseWriterGate: DatabaseWriterGate
    var importFilesFromIncomingDirLock: NSRecursiveLock? = nil
    override init!(path p: String!, context c: NSManagedObjectContext!, mainDatabase m: N2ManagedDatabase!) {
        databaseWriterGate = (m as? ImportDatabase)?.databaseWriterGate ?? DatabaseWriterGate()
        super.init(path: p, context: c, mainDatabase: m)
    }
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
    func studyEntity() -> NSEntityDescription! { entity(forName: "Study") }
    func dataDirPath() -> String? { nil }
    func reportsDirPath() -> String? { nil }
    func errorsDirPath() -> String? { nil }
    func cleanForFreeSpace() {}
    func alertRejectedReports(_ count: Int) {}
    func checkForCorrectContextThreadIfDeclared() {}
    func checkReportsConsistencyWithDICOMSR() {}
    func publish(_ added: DicomDatabaseImportBatch, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) {}

    /// What findStudy and indexImages do with the study list.
    func indexFile(_ curDict: NSMutableDictionary?, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                   studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: any ImportStudyUIDList, modifiedStudiesArray: NSMutableArray,
                   defaultDate: Date, today: Date, dataDirPath: String?, reportsDirPath: String?, errorsDirPath: String?,
                   settings: DicomDatabaseImportSettings, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool,
                   preparedReportPath: inout String?) {
        guard let context = self.managedObjectContext else {
            NSException(name: .genericException, reason: "no context to index into", userInfo: nil).raise()
            return
        }
        let uid = curDict!.object(forKey: "studyID") as! String
        let index = studiesArrayStudyInstanceUID.place(of: uid)
        let study: DicomStudy
        if index != NSNotFound {
            study = studiesArray.object(at: index) as! DicomStudy
        } else {
            study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
            study.studyInstanceUID = uid
            studiesArray.add(study)
            studiesArrayStudyInstanceUID.remember(uid)
        }
        if !modifiedStudiesArray.contains(study) { modifiedStudiesArray.add(study) }
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
        series.setValue(study, forKey: "study")
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        image.setValue(curDict!.object(forKey: "SOPUID") as! String, forKey: "sopInstanceUID")
        image.setValue(series, forKey: "series")
        added.addedImageObjects?.add(image)
    }

    /// The dump: sqlite3 copies the index, a writer that is not kept out
    /// writes into the former file meanwhile, and the files are swapped.
    func dumpSqlFile() {
        let path: String = sqlFilePath
        let folder = (path as NSString).deletingLastPathComponent
        let copy = folder + "/Dumped.sql"
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [path, ".backup '\(copy)'"]
        try! sqlite.run()
        sqlite.waitUntilExit()
        Script.count("dumped")
        Script.wait("independent-written", 1, 1.5)
        let retired = folder + "/Retired"
        try! FileManager.default.createDirectory(atPath: retired, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try! FileManager.default.moveItem(atPath: path + suffix, toPath: retired + "/Database.sql" + suffix)
        }
        try! FileManager.default.moveItem(atPath: copy, toPath: path)
        Script.count("swapped")
    }
}

typealias DicomDatabase = ImportDatabase
final class DatabaseRebuildService {
    let database: ImportDatabase
    let processGraph = 0
    init(database: ImportDatabase) { self.database = database }
    func present(_ error: NSError) { emit("presented", error.localizedDescription) }
}

// The methods as they are in the revision under test.
//@PASTE@

func files(_ study: String, _ names: [String]) -> [NSMutableDictionary] {
    names.map { NSMutableDictionary(dictionary: ["studyID": study, "SOPUID": $0, "filePath": "/nowhere/" + $0]) }
}

func add(_ database: ImportDatabase, _ study: String, _ name: String) {
    N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
        _ = database.addFilesDescribed(inDictionaries: files(study, [name]), postNotifications: false, rereadExistingItems: false,
                                       generatedByOsiriX: false, importedFiles: false, returnArray: true)
    }
}

let arguments = CommandLine.arguments
let folder = arguments[1], mainWriter = arguments[2] == "with-main-writer"
let main: ImportDatabase = ImportDatabase(path: folder + "/Database.sql", context: nil, mainDatabase: nil)
add(main, "1.1", "seed")
let writer = main.privateQueueIndependentDatabase() as! ImportDatabase
let ended = DispatchSemaphore(value: 0)
var threads = 2

Thread {
    DatabaseRebuildService(database: main).rebuildSqlFile()
    ended.signal()
}.start()
Thread {
    Script.wait("dumped", 1, 10)
    add(writer, "2.2", "during")
    emit("during_after_swap", String(Script.value("swapped")))
    Script.count("independent-written")
    ended.signal()
}.start()
if mainWriter {
    threads += 1
    Thread {
        Script.wait("dumped", 1, 10)
        add(main, "3.3", "main-during")
        emit("main_during_after_swap", String(Script.value("swapped")))
        ended.signal()
    }.start()
}

let deadline = Date(timeIntervalSinceNow: 30)
var done = 0
while done < threads && Date() < deadline {
    if ended.wait(timeout: .now()) == .success { done += 1 } else { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
}
emit("threads_ended", String(done))

// A database kept from before the rebuild, as a client connection keeps one.
add(writer, "2.2", "after")
func coordinator(_ database: ImportDatabase) -> NSPersistentStoreCoordinator? {
    var answer: NSPersistentStoreCoordinator? = nil
    let context = database.managedObjectContext
    N2ManagedObjectContextPerformAndWait(context) { answer = context?.persistentStoreCoordinator }
    return answer
}
emit("writer_follows", coordinator(writer) != nil && coordinator(writer) === coordinator(main) ? "1" : "0")
fflush(stdout)
exit(0)
'''


def images(path):
    if not path.exists():
        return []
    connection = sqlite3.connect('file:%s?mode=ro' % path, uri=True)
    try:
        return sorted(row[0] for row in connection.execute('SELECT ZSOPINSTANCEUID FROM ZIMAGE'))
    finally:
        connection.close()


def run_revision(label, import_source, rebuild_source, scenario, swift_flags=()):
    # The import's gated methods, on the database or on the indexer (tests/indexer_paste.py).
    pasted = indexer_paste.pasted(import_source)
    pasted += '\nextension DatabaseRebuildService {\n' + method(rebuild_source, REBUILD_SQL) + '\n\n' \
        + method(rebuild_source, FILE_NUMBER)
    for helper in (REPLACED, SAVE, RELEASE):
        if helper in rebuild_source:
            pasted += '\n\n' + method(rebuild_source, helper)
    pasted += '\n}\n'
    work = Path(tempfile.mkdtemp(prefix='horos-sql-rebuild-writer-'))
    try:
        binary, _, error = harness.build(DRIVER.replace('//@PASTE@', pasted), swift_sources=['Horos/Sources/MainActorCallbacks.swift'],
                                         work=work / 'build', swift_flags=swift_flags)
        if error:
            failures.append('%s: %s' % (label, error))
            return {}
        store = work / 'store'
        store.mkdir()
        try:
            status, values, _, stderr = harness.run(binary, [str(store), scenario], timeout=60)
        except subprocess.TimeoutExpired:
            status, values, stderr = 'hung', {}, ''
        values['status'] = status
        values['index'] = images(store / 'Database.sql')
        values['retired'] = images(store / 'Retired' / 'Database.sql')
        values['off_main'] = [line for line in stderr.splitlines() if 'is used off the main thread' in line]
        print('%s: %s' % (label, values))
        if status != 0:
            print(stderr[-2000:])
        return values
    finally:
        shutil.rmtree(work, ignore_errors=True)


revision = previous_revision()
if revision is None:
    print('skipped: the history does not reach the revision before the SQL rebuild held the gate')
    sys.exit(2)
sys.stdout.reconfigure(line_buffering=True)

# --- the previous revision loses the row --------------------------------------
old = run_revision('previous (%s)' % revision[:9], indexer_paste.source_at(revision),
                   history_reference.show(revision, REBUILD).decode(), 'independent-only')
check(old.get('status') == 0, 'the previous revision did not finish: %s' % old.get('status'))
check(old.get('during_after_swap') == '0', 'the previous revision did not write during the dump, so this no longer reproduces it')
check('seed' in old.get('index', []) and 'during' not in old.get('index', []),
      'the previous revision kept the image written during the dump: %s' % old.get('index'))
check('during' in old.get('retired', []), 'the previous revision did not write into the retired file: %s' % old.get('retired'))
check(old.get('off_main'), 'the previous revision did not say it saved the main-queue context off the main thread, '
      'so the check of the checkout no longer sees it')

# --- the checkout keeps it ------------------------------------------------------
# Built with DEBUG, where the end of a context and its use through
# N2ManagedObjectContextPerformAndWait say when one of the main queue is off the main thread.
new = run_revision('checkout', indexer_paste.current(), (root / REBUILD).read_text(), 'with-main-writer',
                   swift_flags=['-D', 'DEBUG'])
check(new.get('status') == 0 and new.get('threads_ended') == '3', 'the checkout did not finish: %s' % new)
check(new.get('during_after_swap') == '1', 'the writer did not wait for the swap: %s' % new.get('during_after_swap'))
check(new.get('main_during_after_swap') == '1', 'the writer on the main database did not wait for the swap')
check(new.get('index') == ['after', 'during', 'main-during', 'seed'],
      'the new index does not hold every image: %s' % new.get('index'))
check(not set(new.get('retired', [])) - {'seed'}, 'something was written into the retired file: %s' % new.get('retired'))
check(new.get('writer_follows') == '1', 'the database kept from before the rebuild is not over the new index')
check('raised' not in new, 'an import raised: %s' % new.get('raised'))
check(new.get('off_main') == [], 'the main-queue context was saved or released off the main thread: %s'
      % new.get('off_main'))

# --- what the doubles do not see ----------------------------------------------
rebuild = (root / REBUILD).read_text()
sql = method(rebuild, REBUILD_SQL)
gate = sql.find('databaseWriterGate.withExclusiveWrite')
check(0 <= gate < sql.find('database.managedObjectContext = nil') < sql.find('database.dumpSqlFile()')
      < sql.find('database.managedObjectContext = database.context(atPath:') < sql.find('if let givenBack'),
      'the SQL rebuild does not hold the gate from letting the context go to setting the new one, then give back the former')
check(sql.find('if let givenBack') < sql.find('checkReportsConsistencyWithDICOMSR'),
      'the reports are checked inside the gate')
for name, signature in (('the SQL rebuild', REBUILD_SQL), ('the rebuild', 'func rebuild(complete: Bool) {')):
    body = method(rebuild, signature)
    check('IndexRebuildsUnderWay.shared.begin()' in body and 'IndexRebuildsUnderWay.shared.end()' in body,
          '%s is not listed for quitting' % name)
window = (root / 'Horos/Sources/BrowserController+Window.swift').read_text()
terminate = method(window, 'func shouldTerminate(_ sender: Any!) -> Bool {')
check(0 <= terminate.find('DatabaseRebuildService.waitForRebuildsBeforeQuitting()') < terminate.find('ViewerController.closeAllWindows()'),
      'quitting closes the viewers before it waits for the rebuilds')
wait = method(rebuild, 'static func waitForRebuildsBeforeQuitting() -> Bool {')
check('IndexRebuildsUnderWay.shared' in wait and '.stopModal(withCode: .OK)' in wait and '.modalPanel' in wait,
      'the alert of quitting does not close by itself once the rebuilds have ended')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the previous revision loses what is added during the SQL rebuild; the checkout waits for the swap and '
      'writes it, and what came after, into the new index')
