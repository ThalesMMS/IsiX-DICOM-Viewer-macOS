#!/usr/bin/env python3
"""The repair of the dates lost to fractional times leaves the UI context alone.

A local database opened on the main thread has the UI's context, on the main
queue. Opening it starts DatabaseStartupRepairs.repairDatesLostToFractionalTimes
UnlessDone, which reads the headers of its undated images again on a thread of
its own. The browser then renews the context of the database it shows. If that
thread read the database's context (the getter of an optimized build can leave
it in the thread's autorelease pool), the replaced UI context went away when
the thread's pool drained, off the main thread, and Debug builds said "the
main-queue context ... is used off the main thread".

This compiles the date repair of Horos/Sources/DatabaseStartupRepairs.swift
(the part before its series identifier repair) with the real N2ManagedDatabase
(tests/n2_database_harness.py), optimized as the application's Debug build is
and with DEBUG set, against small doubles of DicomDatabase, DicomFile, the
preferences, the browser and ActivityThread, and runs it with Core Data's
multithreading assertions on:

- a database made on the main thread, with a study of two series of undated
  images whose files carry a study date, starts the repair; the main thread
  renews the database's context, as the browser does, while the repair thread
  has done its work and before its pool drains; the database is given up while
  the thread runs;
- nothing says that a main-queue context was used off the main thread, and the
  replaced UI context and the database go on the main thread;
- the images, series and study got the date their files carry, the change was
  merged into the database's context, the run was recorded as done once for
  the database file, and a second start does not start another thread.
"""
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import n2_database_harness as harness  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
REPAIRS = ROOT / 'Horos/Sources/DatabaseStartupRepairs.swift'

# What the date repair uses from the rest of the application.
DOUBLES = r'''
import CoreData
import Foundation
import IsiXDICOMFile

nonisolated(unsafe) var events: [String] = []
let eventsLock = NSLock()
func note(_ s: String) { eventsLock.lock(); events.append(s); eventsLock.unlock() }
func noted() -> [String] { eventsLock.lock(); defer { eventsLock.unlock() }; return events }

func repairModel() -> NSManagedObjectModel {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a
    }
    func relation(_ name: String, _ to: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
        let r = NSRelationshipDescription(); r.name = name; r.destinationEntity = to; r.isOptional = true
        r.minCount = 0; r.maxCount = many ? 0 : 1; r.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule; return r
    }
    let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = "DicomStudy"
    let series = NSEntityDescription(); series.name = "Series"; series.managedObjectClassName = "DicomSeries"
    let image = NSEntityDescription(); image.name = "Image"; image.managedObjectClassName = "DicomImage"
    let studySeries = relation("series", series, many: true), seriesStudy = relation("study", study, many: false)
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    let seriesImages = relation("images", image, many: true), imageSeries = relation("series", series, many: false)
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("studyInstanceUID", .stringAttributeType), attribute("date", .dateAttributeType), studySeries]
    series.properties = [attribute("date", .dateAttributeType), attribute("dateAdded", .dateAttributeType), seriesStudy, seriesImages]
    image.properties = [attribute("sopInstanceUID", .stringAttributeType), attribute("date", .dateAttributeType), imageSeries]
    let m = NSManagedObjectModel(); m.entities = [study, series, image]; return m
}
let repairSharedModel = repairModel()

final class RepairContext: N2ManagedObjectContext {
    deinit {
        if concurrencyType == .mainQueueConcurrencyType {
            note("main-queue context gone on " + (Thread.isMainThread ? "main" : "another thread"))
        }
    }
}

class DicomDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { repairSharedModel }
    override func saveModel() -> Bool { false }
    override func nsManagedObjectContextClass() -> AnyClass! { RepairContext.self }
    func isLocal() -> Bool { true }
    deinit { if isMainDatabase() { note("database gone on " + (Thread.isMainThread ? "main" : "another thread")) } }
}

extension DicomImage {
    // The double keeps the file's path in sopInstanceUID.
    @objc func completePathWithNoDownloadAndLocalOnly() -> String! { value(forKey: "sopInstanceUID") as? String }
}

/// A file holding its study date as YYYYMMDD.
final class DicomFile {
    let text: String
    init?(_ path: String, dicomOnly: Bool) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        self.text = text
    }
    func element(forKey key: String) -> Any? {
        guard key == "studyDate", let day = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return DICOMCalendarDate(year: day / 10000, month: UInt((day / 100) % 100), day: UInt(day % 100), hour: 0, minute: 0, second: 0, timeZone: nil)
    }
}

enum DicomDatabaseObjC {
    static func log(_ exception: NSException, stack: Bool, _ function: String) { note("exception: \(exception.reason ?? "")") }
}

/// Preferences in memory. The repair records itself done through `set`, on its
/// thread, after its work: there the double waits until the test lets it go on.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var store: [String: Any] = [:]
    private let lock = NSLock()
    nonisolated(unsafe) var beforeSet: (() -> Void)? = nil
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return store[key] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func set(_ value: Any?, forKey key: String) {
        beforeSet?()
        lock.lock(); store[key] = value; lock.unlock()
    }
}

final class BrowserController {
    var database: DicomDatabase?
    func refreshDatabase(_ sender: Any?) { note("browser refreshed") }
}

final class ProcessGraph: @unchecked Sendable {
    static let process = ProcessGraph()
    let preferences: UserDefaults = MemoryDefaults(suiteName: "isix.test.date-repair.never-written")!
    nonisolated(unsafe) var currentBrowser: BrowserController? = nil
}

enum ActivityThread {
    @discardableResult
    static func startUnlisted(name: String, configure: (Thread) -> Void = { _ in },
                              _ body: @escaping @Sendable (_ listInActivity: @Sendable () -> Void) -> Void) -> Thread {
        note("thread started")
        let thread = Thread {
            body { note("listed in Activity") }
            note("thread ended")
        }
        thread.name = name
        configure(thread)
        thread.start()
        return thread
    }
}
'''

DRIVER = r'''
let base = CommandLine.arguments[1]
let files = (base as NSString).appendingPathComponent("files")
try? FileManager.default.createDirectory(atPath: files, withIntermediateDirectories: true)
let sqlPath = ((base as NSString).appendingPathComponent("db") as NSString).appendingPathComponent("Database.sql")
let graph = ProcessGraph.process
let defaults = graph.preferences as! MemoryDefaults

func spin(until done: () -> Bool, seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

// A database made on the main thread, with undated rows whose files carry a date.
var made: DicomDatabase? = nil
autoreleasepool {
    let db = DicomDatabase(path: sqlPath)!
    emit("queue", db.managedObjectContext.concurrencyType == .mainQueueConcurrencyType ? "main" : "private")
    db.performBlockAndWait {
        let study = db.newObject(forEntity: "Study") as! NSManagedObject
        study.setValue("1.2.3", forKey: "studyInstanceUID")
        for s in 1...2 {
            let series = db.newObject(forEntity: "Series") as! NSManagedObject
            series.setValue(Date(), forKey: "dateAdded")
            series.setValue(study, forKey: "study")
            for i in 1...3 {
                let path = (files as NSString).appendingPathComponent("S\(s)-\(i).dcm")
                try? "20261106".write(toFile: path, atomically: true, encoding: .utf8)
                let image = db.newObject(forEntity: "Image") as! NSManagedObject
                image.setValue(path, forKey: "sopInstanceUID")
                image.setValue(series, forKey: "series")
            }
        }
    }
    emit("seeded", db.save() ? "yes" : "no")
    let browser = BrowserController(); browser.database = db
    graph.currentBrowser = browser
    made = db
}

// The repair thread, its work done, waits before it records itself done until
// the main thread has renewed the context of the database and given it up.
let worked = DispatchSemaphore(value: 0), renewed = DispatchSemaphore(value: 0)
defaults.beforeSet = {
    worked.signal()
    _ = renewed.wait(timeout: .now() + 20)
}
autoreleasepool {
    DatabaseStartupRepairs(database: made!, processGraph: graph).repairDatesLostToFractionalTimesUnlessDone()
}
var reached = false
spin(until: { reached = worked.wait(timeout: .now()) == .success; return reached }, seconds: 30)
emit("repair worked", reached ? "yes" : "no")

// As the browser does when it shows the database, then leaves it.
autoreleasepool {
    made!.renewManagedObjectContext()
}
var merged = -1
autoreleasepool {
    // What the database's context sees once the main queue has merged the repair's save.
    spin(until: { false }, seconds: 0.5)
    made!.performBlockAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
        request.predicate = NSPredicate(format: "date != nil")
        merged = (try? made!.managedObjectContext.count(for: request)) ?? -1
    }
}
emit("dated images seen by the database", "\(merged)")
let path = made!.sqlFilePath!
autoreleasepool {
    graph.currentBrowser = nil
    made = nil
}
renewed.signal()
spin(until: { noted().contains("thread ended") && noted().contains { $0.hasPrefix("database gone") } }, seconds: 30)
spin(until: { false }, seconds: 0.5)

let all = noted()
emit("thread ended", all.contains("thread ended") ? "yes" : "no")
emit("listed in Activity", all.contains("listed in Activity") ? "yes" : "no")
// The one the browser replaced, and the one the database had when it went.
emit("main-queue contexts gone on main", "\(all.filter { $0 == "main-queue context gone on main" }.count)")
emit("main-queue contexts gone on another thread", "\(all.filter { $0 == "main-queue context gone on another thread" }.count)")
emit("database gone", all.first { $0.hasPrefix("database gone") } ?? "never")
emit("exceptions", "\(all.filter { $0.hasPrefix("exception") }.count)")

// What the index holds, read by a database of its own.
autoreleasepool {
    let reader = DicomDatabase(path: sqlPath)!
    reader.performBlockAndWait {
        // The day the files carry, in local time as the importer reads it.
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6))! as NSDate
        let next = day.addingTimeInterval(36 * 3600) as NSDate
        func count(_ entity: String) -> Int {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "date >= %@ AND date < %@", day, next)
            return (try? reader.managedObjectContext.count(for: request)) ?? -1
        }
        emit("images dated 2026-11-06", "\(count("Image"))")
        emit("series dated 2026-11-06", "\(count("Series"))")
        emit("studies dated 2026-11-06", "\(count("Study"))")
    }
    let done = defaults.stringArray(forKey: "DatabasesWithFractionalTimeDatesRepaired") ?? []
    emit("recorded done", "\(done.filter { $0 == path }.count)")
    // Done: a second start starts nothing.
    let started = noted().filter { $0 == "thread started" }.count
    DatabaseStartupRepairs(database: reader, processGraph: graph).repairDatesLostToFractionalTimesUnlessDone()
    emit("second start", noted().filter { $0 == "thread started" }.count == started ? "nothing" : "a thread")
}
emit("end", "yes")
'''

EXPECTED = {
    'queue': 'main',
    'seeded': 'yes',
    'repair worked': 'yes',
    'dated images seen by the database': '6',
    'thread ended': 'yes',
    'listed in Activity': 'yes',
    'main-queue contexts gone on main': '2',
    'main-queue contexts gone on another thread': '0',
    'database gone': 'database gone on main',
    'exceptions': '0',
    'images dated 2026-11-06': '6',
    'series dated 2026-11-06': '2',
    'studies dated 2026-11-06': '1',
    'recorded done': '1',
    'second start': 'nothing',
    'end': 'yes',
}


def date_repair_source():
    """DatabaseStartupRepairs.swift without the repairs after the dates (they
    use the application's entities and windows): the struct closes where the
    series identifier repair began, and what follows the struct stays."""
    text = REPAIRS.read_text(encoding='utf-8')
    start = text.index('    // MARK: - Series identifiers')
    end = re.compile(r'^\}[ \t]*$', re.M).search(text, start)
    if not end:
        raise ValueError('DatabaseStartupRepairs.swift: no end of the struct after the series identifiers')
    return text[:start] + text[end.start():]


failures = []
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)
work = Path(tempfile.mkdtemp(prefix='horos-date-repair-')).resolve()
try:
    (work / 'DatabaseStartupRepairs.swift').write_text(date_repair_source(), encoding='utf-8')
    (work / 'Doubles.swift').write_text(DOUBLES, encoding='utf-8')
    # The repair also imports IsiXDICOMFile (DICOMCalendarDate) and IsiXImaging,
    # built beside the IsiXDatabase of the harness.
    dicom_file = [flag for flag in isix_modules.module_flags('IsiXDICOMFile', work / 'modules') if flag.startswith('-l')]
    binary, work, error = harness.build(DRIVER, swift_sources=[str(work / 'DatabaseStartupRepairs.swift'), str(work / 'Doubles.swift')],
                                        work=work, swift_flags=['-O', '-D', 'DEBUG'] + dicom_file, objc_flags=['-O0'])
    if error:
        failures.append(error)
    else:
        status, results, stdout, stderr = harness.run(binary, [str(work / 'stores')], timeout=180)
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
print('ok: the date repair works in a private-queue context made before its thread, and the UI context and '
      'the database it repaired go on the main thread')
