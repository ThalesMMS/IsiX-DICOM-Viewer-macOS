#!/usr/bin/env python3
"""Opening a database leaves one index and a version file that tells the truth about it.

-contextAtPath: reads DB_VERSION, or the preference DATABASEVERSION when there is
no file, and runs the upgrade when they name another model. Two defects shared
that path:

1. With a model the application does not know, the upgrade starts a complete
   rebuild. The rebuild deleted DB_VERSION and opened its new index, the opening
   went back to the preference and ran the upgrade again, without end: the
   process died with thousands of recovery folders and no Database.sql. The
   rebuild now writes the current version in place of the file, because its new
   index is made in the current model, and an opening with no index upgrades
   nothing, whatever the file or the preference say.
2. The opening wrote the current version without looking at what the upgrade
   answered. A rebuild that stopped before it retired the index left the former
   model beside a DB_VERSION that said "current", and the next opening tried
   the current model and set the index aside. The version is now written when
   the upgrade went well and by the rebuild once the former index is retired; an
   index that waits for its upgrade is neither set aside nor migrated by the
   opening, a save with no store open does not record the version, and the next
   opening tries again.

A stop leaves the session with its index closed, and what runs in that session
must keep to it. The rebuild of the menu opens an index only when it replaced
it, from the main run loop: an index that stayed gets no second opening, whose
upgrade and alerts would run inside a block of the main queue. Rebuild SQL File
keeps the model and leaves the upgrade to the next opening: on its thread no alert
can open. The import leaves what arrives in INCOMING: moved to the data folder, a
file would be in no index, and an upgrade that later goes well would not find it.

This compiles the real N2ManagedDatabase (tests/n2_database_harness.py) with the
real DatabaseModelUpgrade, DatabaseRebuildService, IndexRecovery and recovery
snapshot, and the real -contextAtPath:, -save:, the entry of the import and the
methods around them cut from DicomDatabase, with a stand-in for the rest of
DicomDatabase, the scan of the folder included, and runs them on real stores of
the current model, of the former model 2.4 and of a model newer than the
application. The stand-in counts the upgrades and rebuilds and stops the process
at the seventh, which is how the recursion shows; the alerts say where they
opened when that is a place an alert must not open.

The alerts of the upgrade open on the main thread wherever the database opens.
At launch that thread is the one opening, inside the launch, where the main run
loop does not turn: the alert opens there and then, and the answer goes back to
the upgrade. A source chosen in the browser opens on a thread of its own: the
alert opens from the main run loop, and the thread waits for it. With the quit
of the first alert refused, or with no way to end the process, no rebuild starts:
the person did not agree to one, and the index waits for the next opening.

`<git revision>` as an optional argument reads the sources of that revision, the
negative control: before the change the driver stops on the recursion, and the
alerts of a source open off the main thread, with a rebuild after the quit.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import n2_database_harness as harness  # noqa: E402
from isix_modules import former_models  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
UPGRADE = 'Horos/Sources/DatabaseModelUpgrade.swift'
REBUILD = 'Horos/Sources/DatabaseRebuildService.swift'
INSTANCE = 'Horos/Sources/DicomDatabase+Instance.swift'
FORWARDERS = 'Horos/Sources/DicomDatabase+Maintenance.swift'
INCOMING = 'Horos/Sources/IncomingAdmission.swift'
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'
FORMER_MODEL_NAME = 'OsiriXDB_Previous_DataModel2.4.mom'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text()


def method(source, selector):
    """The Swift method declared with `@objc(selector)` in `source`, as it is."""
    found = re.search(r'    @objc\(%s\)\n.*?^    }\n' % re.escape(selector), source, re.S | re.M)
    if not found:
        raise SystemExit('FAIL: %s is not where this test reads it' % selector)
    return found.group(0)


def database_slices():
    """What of DicomDatabase the opening goes through, for the stand-in's body."""
    instance = read(INSTANCE)
    optional = re.search(r'    @objc\(migratePersistentStoresAutomatically\)\n.*?^    }\n', instance, re.S | re.M)
    slices = method(instance, 'deleteSQLFileIfOpeningFailed') + (optional.group(0) if optional else '') + method(instance, 'contextAtPath:') + method(instance, 'save:')
    entry = re.search(r'    func importFolder\(showGUI: NSNumber!, listenerCompressionSettings: Int32\) -> Int \{\n.*?^    }\n', read(INCOMING), re.S | re.M)
    if not entry:
        raise SystemExit('FAIL: the entry of the import is not where this test reads it')
    slices += entry.group(0).replace('database.managedObjectContext', 'self.managedObjectContext').replace('func importFolder(showGUI:', 'func importFiles(fromIncomingDir showGUI:')
    # The preferences of the stand-in, and not those of whoever runs the test.
    return slices.replace('UserDefaults.standard', 'harnessDefaults')


def version_record():
    """What -save: records once the context saved, where it is a type of its own."""
    found = re.search(r'^enum DatabaseVersionRecord \{\n.*?^}\n', read(INSTANCE), re.S | re.M)
    return '\n' + found.group(0) if found else ''


def forwarders():
    """What of DicomDatabase's forwarders the opening goes through, counted."""
    source = read(FORWARDERS)
    blocks = ''.join(method(source, selector) for selector in ('upgradeSqlFileFromModelVersion:', 'rebuild:', 'dumpSqlFile', 'rebuildSqlFile'))
    blocks = blocks.replace('return DatabaseModelUpgrade(database: self)', 'count("upgrades"); return DatabaseModelUpgrade(database: self)')
    blocks = blocks.replace('rebuildService.rebuild(complete: complete)', 'count("rebuilds"); rebuildService.rebuild(complete: complete)')
    return 'extension DicomDatabase {\n' + blocks + '}\n\n' + source[source.rindex('extension DicomDatabase {'):]


DOUBLES = r"""
import AppKit
import CoreData
import Foundation
import IsiXDatabase
import IsiXPreferences

/// The preferences of the stand-in, which leave no file behind. The tool
/// uses them from one thread at a time.
final class HarnessDefaults: PreferenceStore, @unchecked Sendable {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { return values[key] }
    func string(forKey key: String) -> String? { return values[key] as? String }
    func bool(forKey key: String) -> Bool { return values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { return false }
}
nonisolated(unsafe) let harnessDefaults = HarnessDefaults()

final class ProcessGraph {
    static let process = ProcessGraph()
    var preferences: HarnessDefaults { harnessDefaults }
    var databaseIngest: DatabaseIngest { DatabaseIngest() }
}

/// As the real one: the preferences of the graph, for the objects it does not reach.
struct PreferencesSource {
    static let process = PreferencesSource()
    var preferences: HarnessDefaults { ProcessGraph.process.preferences }
}

/// As the real one: the files go to the database, with the rebuild's options.
struct DatabaseIngest {
    struct Folder { let path: String }
    func index(_ paths: [Any]?, preset: Preset, in database: DicomDatabase) {
        _ = database.addFiles(atPaths: paths, postNotifications: false, dicomOnly: harnessDefaults.bool(forKey: "onlyDICOM"),
                              rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
    }
    func admissionFolder(of database: DicomDatabase?) -> Folder { Folder(path: database?.incomingDirPath() ?? "") }
    enum Preset { case rebuild }
}

nonisolated(unsafe) var counters: [String: Int] = [:]
func count(_ name: String) {
    counters[name, default: 0] += 1
    if counters[name]! > 6 {
        print("recursion\t\(name)")
        fflush(stdout)
        exit(3)
    }
}

/// What the person is told: the alerts, written down.
nonisolated(unsafe) var alerts: [String] = []
/// Whether the person answers Quit to the alert that offers it.
nonisolated(unsafe) var answersQuit = false
nonisolated(unsafe) var presented: [String] = []

func insideMainQueue() -> Bool {
    let stack = Thread.callStackSymbols.joined(separator: " ")
    return stack.contains("_dispatch_main_queue") || stack.contains("MAIN_DISPATCH_QUEUE")
}

/// An alert, with where it opened when an alert must not open there: inside a
/// block of the main queue it stops that queue until someone answers, and off the
/// main thread AppKit raises.
func alertOpened(_ title: String?) {
    alerts.append((insideMainQueue() ? "INSIDE THE MAIN QUEUE " : Thread.isMainThread ? "" : "OFF THE MAIN THREAD ") + (title ?? ""))
}

final class HarnessApplication {
    @discardableResult func presentError(_ error: Error) -> Bool {
        presented.append((error as NSError).localizedDescription)
        return true
    }
    /// Back from here is a quit that did not happen.
    func terminate(_ sender: Any?) { alertOpened("terminated") }
}
nonisolated(unsafe) let NSApp = HarnessApplication()

enum HorosAlertPanel {
    static let defaultResponse = 1
    static let alternateResponse = 0
    @discardableResult
    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alertOpened(title)
        return answersQuit && alternateButton != nil ? alternateResponse : defaultResponse
    }
    @discardableResult
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alertOpened(title)
        return defaultResponse
    }
}

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? {
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }
    static func log(_ exception: NSException, stack: Bool, _ function: String) {}
    static func logError(_ message: String?, _ function: String) {}
    static func logStackTrace(_ message: String) {}
    static func arg(_ object: Any?) -> CVarArg { return (object as? NSObject) ?? ("(null)" as NSString) }
    static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }
    static func appending(_ path: String?, _ component: String) -> String? { return (path as NSString?)?.appendingPathComponent(component) }
    static func fileExists(_ path: String?) -> Bool { return path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static func set(_ object: AnyObject?, _ key: String) -> NSSet? { return object?.value(forKey: key) as? NSSet }
}

final class IncomingImportGate {
    struct Admission {}
    static let shared = IncomingImportGate()
    func admit(cancelling thread: Thread) -> Admission? { return Admission() }
    func leave(_ admission: Admission) {}
}

extension Thread {
    func enterOperation() {}
    func exitOperation() {}
    var status: String? { get { nil } set {} }
    var progress: CGFloat { get { 0 } set {} }
}

extension NSException {
    @discardableResult func printStackTrace() -> String { return "" }
}

extension Notification.Name {
    static let OsirixDatabaseObjectsMayBecomeUnavailable = Notification.Name("OsirixDatabaseObjectsMayBecomeUnavailable")
}

extension DicomImage {
    func completePath() -> String? { return nil }
    func inDatabaseFolder() -> NSNumber? { return nil }
    var series: DicomSeries? { return value(forKey: "series") as? DicomSeries }
}
extension DicomSeries {
    var study: DicomStudy? { return value(forKey: "study") as? DicomStudy }
    var name: String? { return value(forKey: "name") as? String }
    var id: NSNumber? { return value(forKey: "id") as? NSNumber }
    var numberOfImages: NSNumber? {
        get { return value(forKey: "numberOfImages") as? NSNumber }
        set { setValue(newValue, forKey: "numberOfImages") }
    }
    var thumbnail: Data? { get { return nil } set {} }
}
extension DicomStudy {
    func noFiles() -> NSNumber? { return rawNoFiles() }
    func numberOfImageSeries() -> UInt { return UInt(series?.count ?? 0) }
    func modalities() -> String? { return nil }
    var lockedStudy: NSNumber? { return nil }
    var modality: String? {
        get { return value(forKey: "modality") as? String }
        set { setValue(newValue, forKey: "modality") }
    }
    var numberOfImages: NSNumber? {
        get { return value(forKey: "numberOfImages") as? NSNumber }
        set { setValue(newValue, forKey: "numberOfImages") }
    }
}

enum ExcludedSeries {
    static func forget(study: String, database: String) {}
}

enum DatabaseStartupRepairs {
    static func recomputePatientUIDs(in context: NSManagedObjectContext!) { counters["uids", default: 0] += 1 }
}

let CurrentDatabaseVersion = "2.6"
private let PATIENTUIDVERSION = "2.0"

nonisolated(unsafe) var currentModel: NSManagedObjectModel! = nil
/// What the reader of the albums of a copy gives, as for a model it does not know when nil.
nonisolated(unsafe) var albumsInCopy: NSArray? = nil

func albumsFileEntries(ofIndexAtPath path: String, models: [NSManagedObjectModel]) -> NSArray? {
    return albumsInCopy
}

func fill(_ object: NSManagedObject, _ n: Int) {
    for (name, attribute) in object.entity.attributesByName where !attribute.isTransient {
        let value: Any?
        switch attribute.attributeType {
        case .stringAttributeType: value = "\(attribute.entity.name!).\(attribute.name).\(n)"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: value = NSNumber(value: n + 2)
        case .booleanAttributeType: value = NSNumber(value: n % 2 == 0)
        case .floatAttributeType, .doubleAttributeType: value = NSNumber(value: Double(n) + 0.5)
        case .dateAttributeType: value = Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(n))
        case .binaryDataAttributeType: value = Data([UInt8(n % 251), 1, 2, 3])
        default: value = nil
        }
        object.setValue(value, forKey: name)
    }
}

class DicomDatabase: N2ManagedDatabase {
    var importFilesFromIncomingDirLock: NSRecursiveLock? = nil
    /// What adds files directly waits here while the SQL file is replaced.
    let databaseWriterGate = DatabaseWriterGate()
    var defaultAlbumsCreated = false
    var restoredAlbums = "none"

    override var managedObjectModel: NSManagedObjectModel! { currentModel }
    /// Every store that opens comes through here. One that opens inside the main
    /// queue is one whose first failure would be an alert there.
    override func saveModel() -> Bool {
        if insideMainQueue() { alertOpened("a store") }
        return false
    }

    var baseDirPath: String! { return (sqlFilePath as NSString).deletingLastPathComponent }
    var dataBaseDirPath: String! { return baseDirPath }
    func dataDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("DATABASE.noindex") }
    func incomingDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("INCOMING.noindex") }
    func roisDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("ROIs") }
    func modelVersionFilePath() -> String! { return (baseDirPath as NSString).appendingPathComponent("DB_VERSION") }
    func loadingFilePath() -> String? { return nil }
    func rebuildAllowed() -> Bool { return true }
    func saveAlbums(toPath path: String!) {}
    func loadAlbums(fromPath path: String!) {
        restoredAlbums = (NSArray(contentsOfFile: path) as? [String] ?? ["unreadable"]).joined(separator: ",")
    }
    func addDefaultAlbums() { defaultAlbumsCreated = true }
    func checkForExistingReport(forStudy study: NSManagedObject!) {}
    func checkReportsConsistencyWithDICOMSR() {}
    func imageEntity() -> NSEntityDescription! { return currentModel.entitiesByName["Image"] }
    func seriesEntity() -> NSEntityDescription! { return currentModel.entitiesByName["Series"] }
    func studyEntity() -> NSEntityDescription! { return currentModel.entitiesByName["Study"] }

    /// As the scan does: every file goes to the data folder before it is indexed.
    func importAdmittedFilesFromIncomingDir(_ showGUI: NSNumber?, listenerCompressionSettings: Int32) -> Int {
        count("scans")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: incomingDirPath())) ?? []
        for name in names {
            try! FileManager.default.moveItem(atPath: (incomingDirPath() as NSString).appendingPathComponent(name), toPath: (dataDirPath() as NSString).appendingPathComponent(name))
        }
        return names.count
    }

    /// One study for each file.
    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {
        let context = managedObjectContext!
        for (n, _) in paths.enumerated() {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            fill(study, n)
            study.setValue("1.2.826.0.2.\(n)", forKey: "studyInstanceUID")
        }
        try! context.save()
        return []
    }

SLICES
}
"""

DRIVER = r"""
import ObjectiveC

let arguments = CommandLine.arguments
currentModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1]))!
let former = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[2]))!
let folder = arguments[3]
let fileManager = FileManager.default

/// A model the application does not know, as the index of a newer version is of.
let newer: NSManagedObjectModel = {
    let model = currentModel.copy() as! NSManagedObjectModel
    model.entitiesByName["Study"]!.properties.append(attribute("fromANewerVersion"))
    return model
}()

/// One Core Data cannot migrate from, which the opening treats as damaged.
let unmigratable: NSManagedObjectModel = {
    let model = currentModel.copy() as! NSManagedObjectModel
    model.entitiesByName["Study"]!.attributesByName["name"]!.attributeType = .binaryDataAttributeType
    return model
}()

/// The path of a move that fails, as a full or read-only volume makes it.
nonisolated(unsafe) var failingMove: String? = nil
extension FileManager {
    @objc func harnessMove(atPath source: String, toPath destination: String) throws {
        if let failingMove, (source as NSString).lastPathComponent == failingMove { throw CocoaError(.fileWriteNoPermission) }
        try harnessMove(atPath: source, toPath: destination)
    }
}
method_exchangeImplementations(class_getInstanceMethod(FileManager.self, #selector(FileManager.moveItem(atPath:toPath:)))!,
                               class_getInstanceMethod(FileManager.self, #selector(FileManager.harnessMove(atPath:toPath:)))!)

/// A value the copy of a study raises on, which the upgrade lists.
nonisolated(unsafe) var refusedValue: String? = nil
extension NSManagedObject {
    @objc func harnessSetValue(_ value: Any?, forKey key: String) {
        if let refusedValue, value as? String == refusedValue {
            NSException(name: .genericException, reason: "a value that cannot be copied", userInfo: nil).raise()
        }
        harnessSetValue(value, forKey: key)
    }
}
method_exchangeImplementations(class_getInstanceMethod(NSManagedObject.self, #selector(NSManagedObject.setValue(_:forKey:)))!,
                               class_getInstanceMethod(NSManagedObject.self, #selector(NSManagedObject.harnessSetValue(_:forKey:)))!)

func write(_ path: String, _ text: String) {
    try! fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: false, encoding: .utf8)
}

func listing(_ path: String) -> String {
    return ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted().joined(separator: ",")
}

func bytes(_ path: String) -> Data? { return fileManager.contents(atPath: path) }

/// An index of `model` with `studies` studies, and four image files beside it.
func makeBase(_ name: String, model: NSManagedObjectModel?, studies: Int = 3, file: String?, preference: String?) -> String {
    let base = (folder as NSString).appendingPathComponent(name)
    let data = (base as NSString).appendingPathComponent("DATABASE.noindex")
    for image in ["1000/A-1-1.dcm", "1000/A-1-2.dcm", "2000/B-1-1.dcm", "3000/C-1-1.dcm"] {
        write((data as NSString).appendingPathComponent(image), "synthetic")
    }
    try! fileManager.createDirectory(atPath: (base as NSString).appendingPathComponent("INCOMING.noindex"), withIntermediateDirectories: true)
    try! fileManager.createDirectory(atPath: (base as NSString).appendingPathComponent("ROIs"), withIntermediateDirectories: true)
    if let model {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: (base as NSString).appendingPathComponent("Database.sql")),
                                                        options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.performAndWait {
            for n in 0..<studies {
                let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
                fill(study, n)
                study.setValue("1.2.826.0.1.\(n)", forKey: "studyInstanceUID")
                study.setValue("P\(n)", forKey: "patientUID")
                study.setValue("only in the index \(n)", forKey: "comment")
            }
            try! context.save()
        }
        try! coordinator.remove(store)
    }
    if let file { write((base as NSString).appendingPathComponent("DB_VERSION"), file) }
    harnessDefaults.set(preference, forKey: "DATABASEVERSION")
    return base
}

func open(_ base: String) -> DicomDatabase? {
    counters = [:]
    alerts = []
    presented = []
    return DicomDatabase(path: (base as NSString).appendingPathComponent("Database.sql"))
}

func runLoopTurns() {
    for _ in 0..<5 { _ = CFRunLoopRunInMode(.defaultMode, 0.02, false) }
}

func forget() {
    counters = [:]
    alerts = []
    presented = []
}

/// `work` on a thread of its own, as the browser runs a rebuild, with the main run
/// loop turning. On the main thread the hops to it would run in place, and show
/// nothing of where an alert opens.
func onItsOwnThread(_ work: @escaping () -> Void) {
    let thread = Thread(block: work)
    thread.start()
    while !thread.isFinished { _ = CFRunLoopRunInMode(.defaultMode, 0.02, false) }
}

/// The opening of a source chosen in the browser, on a thread of its own.
func openOnItsOwnThread(_ base: String) -> DicomDatabase? {
    var database: DicomDatabase? = nil
    onItsOwnThread { database = open(base) }
    return database
}

/// A study received into INCOMING.
func receive(_ base: String) {
    write(((base as NSString).appendingPathComponent("INCOMING.noindex") as NSString).appendingPathComponent("received.dcm"), "synthetic")
}

/// A pass of the import, on a database of its own as the timer's is, and on the
/// database itself as a drop on the browser is.
func importPass(_ label: String, _ base: String, _ database: DicomDatabase?) {
    let worker = database?.privateQueueIndependentDatabase() as? DicomDatabase
    counters["scans"] = 0
    var imported = worker?.importFiles(fromIncomingDir: NSNumber(value: false), listenerCompressionSettings: 0) ?? -1
    imported += database?.importFiles(fromIncomingDir: NSNumber(value: false), listenerCompressionSettings: 0) ?? -1
    emit("\(label).scans", "\(counters["scans"] ?? 0)")
    emit("\(label).imported", "\(imported)")
    emit("\(label).incoming", listing((base as NSString).appendingPathComponent("INCOMING.noindex")))
    emit("\(label).in-data", fileManager.fileExists(atPath: ((base as NSString).appendingPathComponent("DATABASE.noindex") as NSString).appendingPathComponent("received.dcm")) ? "yes" : "no")
}

func report(_ label: String, _ base: String, _ database: DicomDatabase?) {
    runLoopTurns()
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    let folders = (try? fileManager.contentsOfDirectory(atPath: backups)) ?? []
    let index = (base as NSString).appendingPathComponent("Database.sql")
    emit("\(label).upgrades", "\(counters["upgrades"] ?? 0)")
    emit("\(label).rebuilds", "\(counters["rebuilds"] ?? 0)")
    emit("\(label).uids", "\(counters["uids"] ?? 0)")
    emit("\(label).alerts", alerts.joined(separator: ";"))
    emit("\(label).presented", presented.joined(separator: ";").replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: base, with: "<base>")
        .replacingOccurrences(of: folders.first ?? "<none>", with: "<uuid>"))
    emit("\(label).version", (try? String(contentsOfFile: (base as NSString).appendingPathComponent("DB_VERSION"), encoding: .utf8)) ?? "none")
    emit("\(label).preference", harnessDefaults.string(forKey: "DATABASEVERSION") ?? "none")
    emit("\(label).folders", "\(folders.count)")
    emit("\(label).recovery", folders.count == 1 ? listing((backups as NSString).appendingPathComponent(folders[0])) : "none")
    emit("\(label).base", listing(base))
    emit("\(label).stores", "\(database?.managedObjectContext?.persistentStoreCoordinator?.persistentStores.count ?? -1)")

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    guard (try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: index), options: options)) != nil else {
        emit("\(label).Study", "does not open")
        return
    }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        emit("\(label).Study", "\((try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Study"))) ?? -1)")
        let comments = ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? []).compactMap { $0.value(forKey: "comment") as? String }
        emit("\(label).kept", "\(comments.filter { $0.hasPrefix("only in the index") }.count)")
    }
}

// The real path of the defect: the preference and the file name a model that
// nothing here carries, as a downgrade leaves them.
do {
    let base = makeBase("unknown", model: newer, file: "9.9", preference: "9.9")
    let database = open(base)
    report("unknown", base, database)
}

// The file is gone, and only the preference is left to name the model.
do {
    let base = makeBase("preference", model: newer, file: nil, preference: "9.9")
    let database = open(base)
    report("preference", base, database)
}

// No index at all: there is nothing to upgrade, whatever they say.
do {
    let base = makeBase("no-index", model: nil, file: nil, preference: "9.9")
    let database = open(base)
    report("no-index", base, database)
}
do {
    let base = makeBase("no-index-file", model: nil, file: "9.9", preference: "9.9")
    let database = open(base)
    report("no-index-file", base, database)
}

// A model the application carries, and an upgrade that goes well.
do {
    let base = makeBase("former", model: former, file: "2.4", preference: "2.4")
    let database = open(base)
    report("former", base, database)
}

// An index of the current model is not touched, and one that will not open with
// the record saying it should still is set aside: that one is damaged.
do {
    let base = makeBase("current", model: currentModel, file: "2.6", preference: "2.6")
    let database = open(base)
    report("current", base, database)
}
do {
    let base = makeBase("damaged", model: unmigratable, file: "2.6", preference: "2.6")
    let database = open(base)
    report("damaged", base, database)
    emit("damaged.aside", listing(base).contains("Database.sql.unreadable-") ? "kept beside the new index" : "not set aside")
}

// An unknown model and a rebuild that stops: no recovery folder can be made. The
// index stays in its place and the record says what it is, however the
// database is saved; the next opening, with the cause gone, gets through.
do {
    let base = makeBase("stopped", model: newer, file: "9.9", preference: "9.9")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let before = bytes(index)
    var database = open(base)
    emit("stopped.index", bytes(index) == before ? "as it was" : "changed")
    report("stopped", base, database)

    var error: NSError? = nil
    emit("stopped.saved", database?.save(&error) == true ? "yes" : "no")
    emit("stopped.saved.error", error?.localizedDescription ?? "none")
    emit("stopped.saved.version", (try? String(contentsOfFile: (base as NSString).appendingPathComponent("DB_VERSION"), encoding: .utf8)) ?? "none")
    emit("stopped.saved.preference", harnessDefaults.string(forKey: "DATABASEVERSION") ?? "none")
    let context = database?.managedObjectContext
    database?.managedObjectContext = nil
    _ = database?.save(nil)
    database?.managedObjectContext = context
    emit("stopped.no-context.version", (try? String(contentsOfFile: (base as NSString).appendingPathComponent("DB_VERSION"), encoding: .utf8)) ?? "none")
    emit("stopped.no-context.preference", harnessDefaults.string(forKey: "DATABASEVERSION") ?? "none")

    // The same stop again, on another opening.
    database = open(base)
    emit("stopped-again.index", bytes(index) == before ? "as it was" : "changed")
    report("stopped-again", base, database)

    try! fileManager.removeItem(atPath: backups)
    database = open(base)
    report("retried", base, database)
}

// The same with the file gone, when only the preference says what the index is:
// neither the opening nor a rebuild from the menu that stops for the same cause
// takes the record for an index of the current model.
do {
    let base = makeBase("preference-stopped", model: newer, file: nil, preference: "9.9")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let before = bytes(index)
    var database = open(base)
    emit("preference-stopped.index", bytes(index) == before ? "as it was" : "changed")
    report("preference-stopped", base, database)
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: true) }
    emit("preference-port.index", bytes(index) == before ? "as it was" : "changed")
    report("preference-port", base, database)
    try! fileManager.removeItem(atPath: backups)
    database = open(base)
    report("preference-retried", base, database)
}

// The stop at the last moment: the copy is made and the index cannot be retired.
// Nothing is written before that, or the store would open and migrate the waiting
// index, and the next opening would run no upgrade.
do {
    let base = makeBase("retire-stopped", model: newer, file: "9.9", preference: "9.9")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let before = bytes(index)
    failingMove = "Database.sql"
    var database = open(base)
    failingMove = nil
    emit("retire-stopped.index", bytes(index) == before ? "as it was" : "changed")
    report("retire-stopped", base, database)
    database = open(base)
    report("retire-retried", base, database)
}

// A former model the application carries: the upgrade cannot put its index in
// place and the rebuild it starts stops, so the index waits, neither set aside
// nor migrated. The next opening upgrades it, and what only it held stays. What
// arrives in between stays in INCOMING, and is imported once the index is open.
do {
    let base = makeBase("former-stopped", model: former, file: "2.4", preference: "2.4")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let before = bytes(index)
    failingMove = "Database3.sql"
    var database = open(base)
    failingMove = nil
    emit("former-stopped.index", bytes(index) == before ? "as it was" : "changed")
    report("former-stopped", base, database)
    receive(base)
    importPass("former-stopped", base, database)

    try! fileManager.removeItem(atPath: backups)
    database = open(base)
    report("former-retried", base, database)
    importPass("former-retried", base, database)
}

// With the opening left without a store, the rebuild of the menu still works:
// nothing to save in the context, and the albums come from the copy.
do {
    let base = makeBase("from-the-menu", model: newer, file: "9.9", preference: "9.9")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let database = open(base)
    runLoopTurns()
    try! fileManager.removeItem(atPath: backups)
    counters = [:]
    alerts = []
    presented = []
    albumsInCopy = ["read from the copy"]
    database?.rebuild(true)
    albumsInCopy = nil
    report("from-the-menu", base, database)
    emit("from-the-menu.albums", "\(database?.restoredAlbums ?? "?") defaults=\(database?.defaultAlbumsCreated ?? false)")
}

// The same through the port, as the browser reaches it, on a database of its own
// and a thread of its own: a stop leaves the database as it is, and the new index
// reaches the one shown.
do {
    let base = makeBase("port", model: newer, file: "9.9", preference: "9.9")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let database = open(base)
    runLoopTurns()
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: true) }
    report("port-stopped", base, database)
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: false) }
    report("port-partial", base, database)
    try! fileManager.removeItem(atPath: backups)
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: true) }
    report("port", base, database)
    let context = database?.managedObjectContext
    var shown = -1
    context?.performAndWait { shown = (try? context?.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Study"))) ?? -1 }
    emit("port.shown", "\(shown)")
}

// The ordinary case, an index that is open. The rebuild, on a database of its own,
// puts a new file in the place of the one this database has open: what it shows
// afterwards, with the context the browser asks for, is read from the new file. A
// coordinator that outlived its file answers with rows of the former one.
do {
    let base = makeBase("port-open", model: currentModel, file: "2.6", preference: "2.6")
    let database = open(base)
    runLoopTurns()
    let context = database?.managedObjectContext
    var held: [NSManagedObject] = []
    context?.performAndWait {
        held = (try? context?.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? []
        for study in held { _ = study.value(forKey: "comment") }
    }
    let coordinator = context?.persistentStoreCoordinator
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: true) }
    report("port-open", base, database)
    database?.renewManagedObjectContext()
    let shown = database?.managedObjectContext
    emit("port-open.coordinator", shown?.persistentStoreCoordinator === coordinator ? "the former" : "a new one")
    var uids: [String] = []
    var comments = 0
    shown?.performAndWait {
        for study in (try? shown?.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? [] {
            uids.append(study.value(forKey: "studyInstanceUID") as? String ?? "none")
            if (study.value(forKey: "comment") as? String)?.hasPrefix("only in the index") == true { comments += 1 }
        }
    }
    emit("port-open.uids", uids.sorted().joined(separator: ","))
    emit("port-open.comments", "\(comments)")
}

// Asked on the main thread, nothing waits for the main run loop.
do {
    let base = makeBase("port-main", model: newer, file: "9.9", preference: "9.9")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    let database = open(base)
    runLoopTurns()
    try! fileManager.removeItem(atPath: backups)
    forget()
    database?.rebuilding.rebuildIndex(complete: true)
    report("port-main", base, database)
}

// An index closed for another reason, with the record saying it is current: the
// rebuild stops and replaces nothing, so nothing opens it a second time.
do {
    let base = makeBase("unreadable", model: currentModel, file: "2.6", preference: "2.6")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    chmod(index, 0o000)
    let database = open(base)
    runLoopTurns()
    forget()
    onItsOwnThread { database?.rebuilding.rebuildIndex(complete: true) }
    chmod(index, 0o644)
    report("unreadable", base, database)
}

// Rebuild SQL File on an index that waits, with what stopped the opening gone: the
// dump replaces the file and keeps the model, and the upgrade waits for an opening.
do {
    let base = makeBase("sql-closed", model: newer, file: "9.9", preference: "9.9")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    var database = open(base)
    runLoopTurns()
    try! fileManager.removeItem(atPath: backups)
    forget()
    onItsOwnThread { database?.rebuilding.rebuildSQLFile() }
    report("sql-closed", base, database)
    database = open(base)
    report("sql-retried", base, database)
}

/// As RemoteDicomDatabase, whose index is on its server: -rebuild: does nothing.
final class RemoteDouble: DicomDatabase {
    override func rebuildAllowed() -> Bool { return false }
    override func rebuild(_ complete: Bool) { count("rebuilds") }
}
do {
    let base = makeBase("remote", model: currentModel, file: nil, preference: "9.9")
    counters = [:]
    alerts = []
    presented = []
    let database = RemoteDouble(path: (base as NSString).appendingPathComponent("Database.sql"))
    report("remote", base, database)
}

// The alert of a model nobody knows, while the application launches: on the main
// thread, with the main run loop not turning. The answer reaches the upgrade, and
// the quit that came to nothing starts no rebuild.
do {
    let base = makeBase("quit-launch", model: newer, file: "9.9", preference: "9.9")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let before = bytes(index)
    answersQuit = true
    let database = open(base)
    answersQuit = false
    emit("quit-launch.index", bytes(index) == before ? "as it was" : "changed")
    report("quit-launch", base, database)
}

// The same in a source opened in the background: the alert and the quit reach the
// main thread from its run loop, and the thread that opens waits for the answer.
do {
    let base = makeBase("quit-source", model: newer, file: "9.9", preference: "9.9")
    let index = (base as NSString).appendingPathComponent("Database.sql")
    let before = bytes(index)
    answersQuit = true
    let database = openOnItsOwnThread(base)
    answersQuit = false
    emit("quit-source.index", bytes(index) == before ? "as it was" : "changed")
    report("quit-source", base, database)
}
do {
    let base = makeBase("source", model: newer, file: "9.9", preference: "9.9")
    let database = openOnItsOwnThread(base)
    report("source", base, database)
}

// The other two alerts of a source: an upgrade that stops, and one that lists a study.
do {
    let base = makeBase("source-stopped", model: former, file: "2.4", preference: "2.4")
    let backups = (base as NSString).appendingPathComponent("Index Backups")
    write(backups, "a file where the folder goes")
    failingMove = "Database3.sql"
    let database = openOnItsOwnThread(base)
    failingMove = nil
    report("source-stopped", base, database)
}
do {
    let base = makeBase("source-listed", model: former, file: "2.4", preference: "2.4")
    refusedValue = "1.2.826.0.1.1"
    let database = openOnItsOwnThread(base)
    refusedValue = nil
    report("source-listed", base, database)
}

emit("end", "reached")
"""


def run_driver(directory):
    work = directory / 'work'
    work.mkdir()
    sources = work / 'sources'
    sources.mkdir()
    (sources / 'doubles.swift').write_text(DOUBLES.replace('SLICES', database_slices()) + version_record())
    (sources / 'forwarders.swift').write_text('import CoreData\nimport Foundation\nimport IsiXContracts\n\n' + forwarders())
    (sources / 'upgrade.swift').write_text(read(UPGRADE))
    (sources / 'rebuild.swift').write_text(read(REBUILD))
    compiled = subprocess.run(['xcrun', 'momc', str(MODEL), str(work)], capture_output=True, text=True)
    momd = work / 'OsiriXDB_DataModel.momd'
    if compiled.returncode != 0 or not momd.exists():
        failures.append('the data model does not compile with momc:\n%s' % compiled.stderr[-1500:])
        return {}
    # Bundle.main of a tool is its folder: the former model is looked for there.
    former_model = former_models(directory / 'former-models') / FORMER_MODEL_NAME
    shutil.copy(former_model, work / FORMER_MODEL_NAME)
    swift = [str(sources / name) for name in ('doubles.swift', 'forwarders.swift', 'upgrade.swift', 'rebuild.swift')]
    swift += ['Horos/Sources/MainActorCallbacks.swift', 'Horos/Sources/DatabaseIndexBackup.swift', 'Horos/Sources/MissingFileReason.swift']
    binary, work, error = harness.build(DRIVER, swift_sources=swift, work=work, swift_flags=['-suppress-warnings'])
    if error:
        failures.append(error)
        return {}
    stores = directory / 'stores'
    stores.mkdir()
    try:
        status, results, _, stderr = harness.run(binary, [str(momd), str(former_model), str(stores)], timeout=240)
    except subprocess.TimeoutExpired:
        failures.append('the openings did not end')
        return {}
    if 'recursion' in results:
        failures.append('the opening and the rebuild called each other: %s without end' % results['recursion'])
    elif status != 0:
        failures.append('the driver failed (%d): %s' % (status, stderr[-1500:]))
    return results


STOPPED = 'Database reconstruction stopped before the index could be backed up: '
ALBUMS = 'The albums of the former database index could not be read, and the default albums were created again. The former index is kept in: <base>/Index Backups/<uuid>'
SQL_KEPT = 'The database index was rebuilt in its former model and stays closed. Its upgrade will be tried again the next time this database opens.'
WITHOUT_VERSION = 'DATABASE.noindex,Database.sql,INCOMING.noindex,Index Backups,ROIs'
WITH_VERSION = 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs'

with tempfile.TemporaryDirectory(prefix='horos-opening-upgrade-') as directory:
    results = run_driver(Path(directory))

if results and not any('called each other' in failure for failure in failures):
    expected = {
        # One upgrade, one rebuild, one recovery folder, one index, and the record
        # of the current model. The albums of a model nothing knows are lost, and
        # the person is told where the index is.
        'unknown.upgrades': '1', 'unknown.rebuilds': '1', 'unknown.folders': '1', 'unknown.Study': '4', 'unknown.kept': '0',
        'unknown.version': '2.6', 'unknown.preference': '2.6', 'unknown.stores': '1', 'unknown.alerts': 'IsiX DICOM Viewer Database',
        'unknown.recovery': 'DB_VERSION,Database.sql,RetiredDatabase.sql', 'unknown.presented': ALBUMS,
        'unknown.base': 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs',
        'preference.upgrades': '1', 'preference.rebuilds': '1', 'preference.folders': '1', 'preference.Study': '4',
        'preference.version': '2.6', 'preference.preference': '2.6', 'preference.stores': '1', 'preference.recovery': 'Database.sql,RetiredDatabase.sql',
        'preference.base': 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs',
        # The new index of the opening, which the first save records.
        'no-index.upgrades': '0', 'no-index.rebuilds': '0', 'no-index.folders': '0', 'no-index.stores': '1', 'no-index.Study': '0', 'no-index.alerts': '',
        'no-index-file.upgrades': '0', 'no-index-file.rebuilds': '0', 'no-index-file.folders': '0', 'no-index-file.stores': '1', 'no-index-file.Study': '0',
        'former.upgrades': '1', 'former.rebuilds': '0', 'former.uids': '1', 'former.Study': '3', 'former.kept': '3', 'former.version': '2.6', 'former.stores': '1', 'former.alerts': '',
        'former.folders': '0', 'former.base': 'DATABASE.noindex,DB_VERSION,Database-Old-PreviousVersion.sql,Database.sql,INCOMING.noindex,ROIs',
        'current.upgrades': '0', 'current.rebuilds': '0', 'current.Study': '3', 'current.kept': '3', 'current.stores': '1', 'current.alerts': '',
        'damaged.aside': 'kept beside the new index', 'damaged.upgrades': '0', 'damaged.stores': '1', 'damaged.Study': '0', 'damaged.alerts': 'driver.DicomDatabase Storage Error',
        # The stop: the index as it was, the record of its model, a store nobody
        # opened and two ways to say so. A save records nothing.
        'stopped.index': 'as it was', 'stopped.upgrades': '1', 'stopped.rebuilds': '1', 'stopped.folders': '0', 'stopped.stores': '0',
        'stopped.version': '9.9', 'stopped.preference': '9.9', 'stopped.alerts': 'IsiX DICOM Viewer Database;driver.DicomDatabase Storage Error',
        'stopped.base': 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs',
        'stopped.saved': 'no', 'stopped.saved.version': '9.9', 'stopped.saved.preference': '9.9',
        'stopped.no-context.version': '9.9', 'stopped.no-context.preference': '9.9',
        'preference-stopped.index': 'as it was', 'preference-stopped.upgrades': '1', 'preference-stopped.rebuilds': '1', 'preference-stopped.stores': '0',
        'preference-stopped.version': 'none', 'preference-stopped.preference': '9.9', 'preference-stopped.folders': '0', 'preference-stopped.base': WITHOUT_VERSION,
        'preference-stopped.alerts': 'IsiX DICOM Viewer Database;driver.DicomDatabase Storage Error',
        'preference-port.index': 'as it was', 'preference-port.upgrades': '0', 'preference-port.rebuilds': '1', 'preference-port.stores': '0',
        'preference-port.version': 'none', 'preference-port.preference': '9.9', 'preference-port.alerts': '', 'preference-port.folders': '0',
        'preference-retried.upgrades': '1', 'preference-retried.rebuilds': '1', 'preference-retried.folders': '1', 'preference-retried.Study': '4',
        'preference-retried.version': '2.6', 'preference-retried.preference': '2.6', 'preference-retried.stores': '1',
        # The copy exists, the index does not move: the same as a stop before it.
        'retire-stopped.index': 'as it was', 'retire-stopped.upgrades': '1', 'retire-stopped.rebuilds': '1', 'retire-stopped.stores': '0', 'retire-stopped.folders': '1',
        'retire-stopped.version': '9.9', 'retire-stopped.preference': '9.9', 'retire-stopped.base': WITH_VERSION,
        'retire-stopped.alerts': 'IsiX DICOM Viewer Database;driver.DicomDatabase Storage Error',
        'retire-retried.upgrades': '1', 'retire-retried.rebuilds': '1', 'retire-retried.folders': '2', 'retire-retried.Study': '4', 'retire-retried.version': '2.6', 'retire-retried.stores': '1',
        'stopped-again.index': 'as it was', 'stopped-again.upgrades': '1', 'stopped-again.rebuilds': '1', 'stopped-again.version': '9.9', 'stopped-again.stores': '0',
        'retried.upgrades': '1', 'retried.rebuilds': '1', 'retried.folders': '1', 'retried.Study': '4', 'retried.version': '2.6', 'retried.preference': '2.6', 'retried.stores': '1',
        'retried.recovery': 'DB_VERSION,Database.sql,RetiredDatabase.sql',
        'former-stopped.index': 'as it was', 'former-stopped.upgrades': '1', 'former-stopped.rebuilds': '1', 'former-stopped.stores': '0', 'former-stopped.version': '2.4',
        'former-stopped.preference': '2.4', 'former-stopped.alerts': 'Database Update;driver.DicomDatabase Storage Error', 'former-stopped.folders': '0',
        # What arrives while the index is closed waits, and goes in once it is open.
        'former-stopped.scans': '0', 'former-stopped.imported': '0', 'former-stopped.incoming': 'received.dcm', 'former-stopped.in-data': 'no',
        'former-retried.scans': '2', 'former-retried.imported': '1', 'former-retried.incoming': '', 'former-retried.in-data': 'yes',
        'former-retried.upgrades': '1', 'former-retried.rebuilds': '0', 'former-retried.uids': '1', 'former-retried.Study': '3', 'former-retried.kept': '3',
        'former-retried.version': '2.6', 'former-retried.stores': '1', 'former-retried.alerts': '', 'former-retried.folders': '0',
        'from-the-menu.upgrades': '0', 'from-the-menu.rebuilds': '1', 'from-the-menu.folders': '1', 'from-the-menu.Study': '4', 'from-the-menu.version': '2.6',
        'from-the-menu.stores': '1', 'from-the-menu.albums': 'read from the copy defaults=false', 'from-the-menu.presented': '',
        # No second opening after a rebuild that replaced nothing, and no alert of one.
        'port-stopped.upgrades': '0', 'port-stopped.rebuilds': '1', 'port-stopped.stores': '0', 'port-stopped.version': '9.9', 'port-stopped.alerts': '',
        'port-partial.upgrades': '0', 'port-partial.rebuilds': '1', 'port-partial.stores': '0', 'port-partial.version': '9.9', 'port-partial.alerts': '',
        'unreadable.upgrades': '0', 'unreadable.rebuilds': '1', 'unreadable.stores': '0', 'unreadable.alerts': '', 'unreadable.version': '2.6', 'unreadable.Study': '3',
        'port-open.rebuilds': '1', 'port-open.stores': '1', 'port-open.version': '2.6', 'port-open.alerts': '', 'port-open.presented': '',
        'port-open.coordinator': 'a new one', 'port-open.comments': '0',
        'port-open.uids': '1.2.826.0.2.0,1.2.826.0.2.1,1.2.826.0.2.2,1.2.826.0.2.3',
        'port-main.rebuilds': '1', 'port-main.stores': '1', 'port-main.version': '2.6', 'port-main.alerts': '',
        'port.rebuilds': '1', 'port.stores': '1', 'port.shown': '4', 'port.version': '2.6', 'port.folders': '1', 'port.alerts': '',
        # The dump keeps the model: no opening on its thread, and the next one upgrades.
        'sql-closed.upgrades': '0', 'sql-closed.rebuilds': '0', 'sql-closed.stores': '0', 'sql-closed.alerts': '', 'sql-closed.version': '9.9', 'sql-closed.preference': '9.9',
        'sql-closed.folders': '1', 'sql-closed.recovery': 'RetiredDatabase.sql', 'sql-closed.presented': SQL_KEPT,
        'sql-retried.upgrades': '1', 'sql-retried.rebuilds': '1', 'sql-retried.folders': '2', 'sql-retried.Study': '4', 'sql-retried.version': '2.6', 'sql-retried.stores': '1',
        # At launch, on the main thread, the alert and the quit in their place. The
        # index waits, as after any stop, and the opening says so there.
        'quit-launch.index': 'as it was', 'quit-launch.upgrades': '1', 'quit-launch.rebuilds': '0', 'quit-launch.folders': '0', 'quit-launch.stores': '0',
        'quit-launch.version': '9.9', 'quit-launch.preference': '9.9', 'quit-launch.presented': '',
        'quit-launch.alerts': 'IsiX DICOM Viewer Database;terminated;driver.DicomDatabase Storage Error',
        # A source: on the main thread too, in no block of the main queue.
        'quit-source.index': 'as it was', 'quit-source.upgrades': '1', 'quit-source.rebuilds': '0', 'quit-source.folders': '0', 'quit-source.stores': '0',
        'quit-source.version': '9.9', 'quit-source.preference': '9.9', 'quit-source.presented': '',
        'quit-source.alerts': 'IsiX DICOM Viewer Database;terminated',
        'source.upgrades': '1', 'source.rebuilds': '1', 'source.folders': '1', 'source.Study': '4', 'source.version': '2.6', 'source.stores': '1',
        'source.alerts': 'IsiX DICOM Viewer Database', 'source.presented': ALBUMS,
        'source-stopped.upgrades': '1', 'source-stopped.rebuilds': '1', 'source-stopped.stores': '0', 'source-stopped.version': '2.4', 'source-stopped.alerts': 'Database Update',
        'source-listed.upgrades': '1', 'source-listed.rebuilds': '0', 'source-listed.Study': '2', 'source-listed.version': '2.6', 'source-listed.stores': '1',
        'source-listed.alerts': 'Database Upgrade',
        # A database that rebuilds nothing has no later attempt to wait for.
        'remote.upgrades': '1', 'remote.rebuilds': '1', 'remote.version': '2.6', 'remote.Study': '3',
        'end': 'reached',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
    for key in ('stopped.presented', 'stopped-again.presented', 'former-stopped.presented', 'preference-stopped.presented', 'preference-port.presented',
                'port-stopped.presented', 'unreadable.presented'):
        if results.get(key, '').count(STOPPED) != 1 or not results[key].startswith(STOPPED):
            failures.append('%s: %r, expected what stopped it, once' % (key, results.get(key)))
    if 'Recovery files: <base>/Index Backups/' not in results.get('retire-stopped.presented', ''):
        failures.append('retire-stopped.presented: %r, expected where the copy is' % results.get('retire-stopped.presented'))
    if 'no persistent stores' not in results.get('stopped.saved.error', ''):
        failures.append('stopped.saved.error: %r, expected the reason the save failed' % results.get('stopped.saved.error'))
    if not results.get('port-partial.presented', '').startswith('Database maintenance stopped: '):
        failures.append('port-partial.presented: %r, expected what stopped it' % results.get('port-partial.presented'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a model nobody knows leaves one recovery folder, one index and the current version, with no recursion '
      'and a preference that cannot bring it back; a rebuild that stops leaves the index and its version as they were, '
      'set aside by nothing and recorded by no save, and the next opening tries again and gets through; in that session '
      'no rebuild opens the index a second time, no alert opens in the main queue or off the main thread, and what arrives stays in INCOMING; '
      'the three alerts of the upgrade open on the main thread at launch and from a source opened in the background, with their answer going back, '
      'and a quit that did not happen starts no rebuild')
