#!/usr/bin/env python3
"""Upgrading an index of an older model closes what it opened and survives a study without a name.

-upgradeSqlFileFromModelVersion: (DatabaseModelUpgrade) copies Database.sql,
opened with the former model, into Database3.sql, opened with the current one,
and then renames Database.sql to Database-Old-PreviousVersion.sql and
Database3.sql to Database.sql.

1. The models, coordinators and contexts it created were never released (the
   Objective-C declared them twice, and released the outer, nil, ones), so both
   stores stayed open while their files were renamed: the index the database
   then opened as Database.sql was still held by a coordinator of the upgrade,
   and what Core Data kept in Database3.sql's write-ahead log was left behind
   under the old name. The stores are now closed before the rename, and again
   after the upgrade whether or not it finished, before a rebuild moves the
   index.
2. A study that could not be copied was listed by its name, and one without a
   name made -addObject: raise nil inside the handler: the whole upgrade
   stopped and the index was rebuilt from the files. It is now listed under a
   name that is never nil.

The helpers run compiled from the source with xcrun swiftc, against a real
SQLite store; where the upgrade calls them is read from the source. `<git
revision>` as an optional argument reads the sources of that revision, the
negative control.

3. The upgrade itself, with its database a stand-in, compiled from the checkout
   and from the revision before it became a type of its own, runs over the same
   real stores of the former model 2.4 the application carries: every attribute of
   every study, series, image and album comes out with the same value, with more
   than a hundred studies, and the same alerts and rebuilds when the index is
   damaged or its model unknown.
4. The attributes of each former model are measured against the current model:
   every one that left it or changed type has to be one the rules or the setters
   of the image account for, and the list is the one below.
5. Real stores of the former models the application carries, 1.1 to 2.3, written
   with those models, come out with their studies, saved layouts that can be read,
   protection, frames, key images and what the setters of the image keep, where
   the revision before the type loses them. Only the stores of 2.4 stay compared
   with that revision: the former ones differ from it on purpose. They, and a
   store of 2.4, are compared with what was written in them instead, attribute by
   attribute and object by object, through the table of what becomes of each
   attribute that changed. The Dicom* classes are stand-ins, with the behaviour
   that matters here read from DicomStudy, DicomSeries and DicomImage: an unknown
   key is swallowed, and the image has the setters of the attributes that left
   the model.
6. A series or an image whose copy raised stayed in the index as a row of nothing,
   a series because it is inserted before it is linked to its study, and only the
   log said so. It now goes, its study stays, and the alert names the study, in a
   sentence that does not say it left. A study copied twice, because its batch did
   not save, is counted once, and one that left is not named as having stayed.
7. The activity history was not copied, in any model. It is now, in batches, with
   every attribute of every entry. Copied from the revision before the type, the
   same stores keep the orphans and lose the history.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from isix_modules import former_models, module_flags, revision_before  # noqa: E402

revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SKIPPED = 2
SOURCE = 'Horos/Sources/DatabaseModelUpgrade.swift'
# Where the upgrade was until it became a type of its own.
FORMER_SOURCE = 'Horos/Sources/DicomDatabase+Other.swift'
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'
# The folder the build unpacks this into does not come with a clone.
# Compiled with the application, unlike those of the archive.
FORMER_MODEL_SOURCE = root / 'Horos/Models/OsiriXDB_Previous_DataModel2.5.xcdatamodel'
IMAGE_SOURCE = root / 'Horos/Sources/DicomImage.swift'


def read():
    if revision:
        for path in (SOURCE, FORMER_SOURCE):
            shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
            if shown.returncode == 0:
                return shown.stdout.decode('utf-8')
        raise SystemExit('FAIL: %s has neither %s nor %s' % (revision, SOURCE, FORMER_SOURCE))
    return (root / SOURCE).read_text()


def private_function(text, name):
    match = re.search(r'^private func %s\(.*?^}\n' % re.escape(name), text, re.S | re.M)
    return match.group(0) if match else None


text = read()
start = text.find('func run(fromModelVersion')
if start >= 0:
    upgrade = text[start:]
else:
    start = text.find('@objc(upgradeSqlFileFromModelVersion:)')
    end = text.find('@objc(', start + 1)
    upgrade = text[start:end] if start >= 0 and end > start else ''
if not upgrade:
    failures.append('-upgradeSqlFileFromModelVersion: is not in %s' % SOURCE)

# --- 1. what the upgrade opens is closed before the files move ----------------
close = private_function(text, 'closeUpgradeStores')
if 'passRetained' in upgrade or re.search(r'\bleak\(', upgrade):
    failures.append('the upgrade still keeps its models, coordinators and contexts alive for good')
if close is None:
    failures.append('there is nothing that closes the stores the upgrade opened')
if upgrade:
    rename = upgrade.find('moveUpgradedIndex(')
    before = upgrade.rfind('closeUpgradeStores(', 0, rename)
    if rename < 0:
        failures.append('the upgrade no longer renames the index; this test needs a new look')
    elif before < 0 or upgrade.find('try? newContext.save()', before) >= 0:
        failures.append('Database.sql and Database3.sql are renamed while their stores are still open')
    handler = upgrade.find('if let e = exception')
    after = upgrade.rfind('closeUpgradeStores(', 0, handler)
    attempt_end = upgrade.rfind('\n        }\n', 0, handler)
    if handler < 0 or after < 0 or after < attempt_end:
        failures.append('when the upgrade stops, its stores stay open while the index is rebuilt')
    for owned in ('openedContexts = [oldContext, newContext]',
                  'openedCoordinators = [oldPersistentStoreCoordinator, newPersistentStoreCoordinator]'):
        if owned not in upgrade:
            failures.append('the cleanup does not hold what the upgrade opened: %s' % owned)
    options = re.search(r'"Database3\.sql"\)!\), options: (.*)\)\n', upgrade)
    new_store_options = options.group(1) if options else 'nil'

# --- 2. a study without a name ------------------------------------------------
name = private_function(text, 'upgradeProblemName')
if re.search(r'add\(studyName, to: upgradeProblems\)', upgrade):
    failures.append('a study without a name still adds nil to the upgrade problems, which raises')
if name is None or 'upgradeProblems.add(upgradeProblemName(studyName))' not in upgrade:
    failures.append('a study that could not be copied is not listed under a name that is never nil')

DOUBLES = '''
import CoreData
import Foundation

// The guards of HorosObjCException+Guards.swift, running each body.
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) { body() }
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? { body(); return nil }
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T { body() }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool, _ function: String) { print("logged\\t\\(exception)") }
    static func logError(_ message: String?, _ function: String) { print("logged\\t\\(message ?? "")") }
}

// Nitrogen's: the block on the context's queue; directly without a queue.
func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) {
    guard let context, context.concurrencyType != .confinementConcurrencyType else { block(); return }
    context.performAndWait(block)
}
'''

DRIVER = '''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

emit("name.nil", upgradeProblemName(nil))
emit("name.empty", upgradeProblemName(""))
emit("name.named", upgradeProblemName("DOE^JANE"))

let study = NSEntityDescription()
study.name = "Study"
let attribute = NSAttributeDescription()
attribute.name = "name"
attribute.attributeType = .stringAttributeType
attribute.isOptional = true
study.properties = [attribute]
let model = NSManagedObjectModel()
model.entities = [study]

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let database3 = folder.appendingPathComponent("Database3.sql")
let database = folder.appendingPathComponent("Database.sql")

let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
let context = NSManagedObjectContext()
context.persistentStoreCoordinator = coordinator
context.undoManager = nil
try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: database3, options: NEW_STORE_OPTIONS)
for n in 0..<250 {
    NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("study \\(n)", forKey: "name")
}
try! context.save()

closeUpgradeStores([context], [coordinator])
emit("stores.left", "\\(coordinator.persistentStores.count)")
emit("context.objects", "\\(context.registeredObjects.count)")
closeUpgradeStores([context], [coordinator]) // after the upgrade, again
emit("stores.again", "\\(coordinator.persistentStores.count)")

// The rename of the upgrade: only Database3.sql moves.
try! FileManager.default.moveItem(at: database3, to: database)

let reopened = NSPersistentStoreCoordinator(managedObjectModel: model)
try! reopened.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: database,
                                 options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
let check = NSManagedObjectContext()
check.persistentStoreCoordinator = reopened
let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
emit("renamed.studies", "\\((try? check.count(for: request)) ?? -1)")
'''

results = {}
if close is not None and name is not None and upgrade:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-stores-') as directory:
        directory = Path(directory)
        (directory / 'doubles.swift').write_text(DOUBLES)
        # File-private in the app; the driver is another file.
        helpers = (close + '\n' + name).replace('private func ', 'func ')
        (directory / 'helpers.swift').write_text('import CoreData\nimport Foundation\n\n' + helpers)
        (directory / 'main.swift').write_text(DRIVER.replace('NEW_STORE_OPTIONS', new_store_options))
        binary = directory / 'upgrade-stores'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'doubles.swift'), str(directory / 'helpers.swift'),
                                str(directory / 'main.swift')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the upgrade helpers do not compile:\n%s' % built.stderr[-1500:])
        else:
            store = directory / 'store'
            store.mkdir()
            run = subprocess.run([str(binary), str(store)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value
            if results.get('logged') is not None:
                failures.append('closing the stores logged a failure: %s' % results['logged'])

if results:
    for key in ('name.nil', 'name.empty'):
        if not results.get(key):
            failures.append('%s: a study without a name is listed as %r' % (key, results.get(key)))
    expected = {'name.named': 'DOE^JANE', 'stores.left': '0', 'context.objects': '0',
                'stores.again': '0', 'renamed.studies': '250'}
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

# --- 3. the upgrade itself, the same as before it became a type -----------------
TRY_HEADER = """#import <Foundation/Foundation.h>
NSException * _Nullable HarnessAttempt(void (NS_NOESCAPE ^ _Nonnull body)(void));
"""
TRY_SOURCE = """#import "try.h"
NSException *HarnessAttempt(void (NS_NOESCAPE ^body)(void)) {
    @try { body(); } @catch (NSException *exception) { return exception; }
    return nil;
}
"""

UPGRADE_DOUBLES = """
import AppKit
import CoreData

nonisolated(unsafe) var alerts: [String] = []
nonisolated(unsafe) var alertMessages: [String] = []
/// The values the copy raises on, as a setter that cannot take them.
nonisolated(unsafe) var refusedValues: Set<String> = []
/// The names of the studies that do not validate.
nonisolated(unsafe) var invalidStudies: Set<String> = []

func refuse(_ value: Any?) {
    if let value = value as? String, refusedValues.contains(value) {
        NSException(name: .genericException, reason: "a value that cannot be copied", userInfo: nil).raise()
    }
}

// The guards of HorosObjCException+Guards.swift, catching through HarnessAttempt.
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { HarnessAttempt(body) }
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) { body() }
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? { body(); return nil }
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T { body() }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { HarnessAttempt(body) }
    static func log(_ exception: NSException, stack: Bool, _ function: String) {}
    static func logError(_ message: String?, _ function: String) {}
    static func arg(_ object: Any?) -> CVarArg { return (object as? NSObject) ?? ("(null)" as NSString) }
    static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }
    static func appending(_ path: String?, _ component: String) -> String? { return (path as NSString?)?.appendingPathComponent(component) }
    static func fileExists(_ path: String?) -> Bool { return path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static func set(_ object: AnyObject?, _ key: String) -> NSSet? { return object?.value(forKey: key) as? NSSet }
}

// Nitrogen's: an exception raised on the queue goes on outside it.
func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) {
    guard let context else { block(); return }
    var raised: NSException? = nil
    context.performAndWait { raised = HarnessAttempt(block) }
    raised?.raise()
}

enum HorosAlertPanel {
    static let defaultResponse = 1
    static let alternateResponse = 0
    static let otherResponse = -1
    @discardableResult
    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(title ?? "")
        alertMessages.append(message)
        return defaultResponse
    }
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

// An unknown key is swallowed, as DicomStudy, DicomSeries and DicomImage do.
@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
    override func validateForInsert() throws {
        try super.validateForInsert()
        if let name = primitiveValue(forKey: "name") as? String, invalidStudies.contains(name) {
            throw NSError(domain: "harness", code: 1, userInfo: [NSLocalizedDescriptionKey: "does not validate"])
        }
    }
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
    override func setValue(_ value: Any?, forKey key: String) {
        refuse(value)
        super.setValue(value, forKey: key)
    }
}

// The setters by which DicomImage keeps what left the model, without the
// defaults they leave out or the compression of the identifier.
@objc(DicomImage) final class DicomImage: NSManagedObject {
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
    override func setValue(_ value: Any?, forKey key: String) {
        refuse(value)
        super.setValue(value, forKey: key)
    }
    private func keep(_ value: Any?, _ key: String) {
        willChangeValue(forKey: key)
        setPrimitiveValue(value, forKey: key)
        didChangeValue(forKey: key)
    }
    @objc(setPath:) func setPath(_ path: String?) {
        let relative = path.flatMap { $0.hasPrefix("/") || !$0.hasSuffix(".dcm") ? nil : $0 }
        keep(relative.map { NSNumber(value: ($0 as NSString).intValue) }, "pathNumber")
        keep(relative == nil ? path : nil, "pathString")
    }
    @objc(setSopInstanceUID:) func setSopInstanceUID(_ uid: String?) { keep(uid.map { Data($0.utf8) }, "compressedSopInstanceUID") }
    @objc(setHeight:) func setHeight(_ value: NSNumber?) { keep(value, "storedHeight") }
    @objc(setWidth:) func setWidth(_ value: NSNumber?) { keep(value, "storedWidth") }
    @objc(setNumberOfFrames:) func setNumberOfFrames(_ value: NSNumber?) { keep(value, "storedNumberOfFrames") }
    @objc(setNumberOfSeries:) func setNumberOfSeries(_ value: NSNumber?) { keep(value, "storedNumberOfSeries") }
    @objc(setInDatabaseFolder:) func setInDatabaseFolder(_ value: NSNumber?) { keep(value, "storedInDatabaseFolder") }
    @objc(setExtension:) func setExtension(_ value: String?) { keep(value, "storedExtension") }
    @objc(setFileType:) func setFileType(_ value: String?) { keep(value, "storedFileType") }
    @objc(setModality:) func setModality(_ value: String?) { keep(value, "storedModality") }
}

let CurrentDatabaseVersion = "2.6"

final class ProcessGraph {
    static let process = ProcessGraph()
    var preferences: UserDefaults { .standard }
}

final class DicomDatabase: NSObject {
    var baseDirPath: String!
    var sqlFilePath: String!
    var managedObjectModel: NSManagedObjectModel!
    var rebuilds = 0
    init(base: String, model: NSManagedObjectModel) {
        baseDirPath = base
        sqlFilePath = (base as NSString).appendingPathComponent("Database.sql")
        managedObjectModel = model
    }
    func loadingFilePath() -> String? { return nil }
    func modelVersionFilePath() -> String! { return (baseDirPath as NSString).appendingPathComponent("DB_VERSION") }
    func rebuildAllowed() -> Bool { return true }
    func rebuild(_ complete: Bool) { rebuilds += complete ? 1 : 100 }
}
"""

UPGRADE_DRIVER = r"""
import AppKit
import CoreData

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let arguments = CommandLine.arguments
let current = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1]))!
let former = writingModel(arguments[2])
let folder = arguments[3]

/// A former model to write a store with: plain objects, so that the attributes
/// reach the store and not the setters of the classes of today, whose names they
/// share. The upgrade loads the model again for itself.
func writingModel(_ path: String) -> NSManagedObjectModel {
    let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path))!
    for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
    return model
}

func value(_ attribute: NSAttributeDescription, _ n: Int) -> Any? {
    switch attribute.attributeType {
    case .stringAttributeType: return "\(attribute.entity.name!).\(attribute.name).\(n)"
    case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: return NSNumber(value: n + 2)
    case .booleanAttributeType: return NSNumber(value: n % 2 == 0)
    case .floatAttributeType, .doubleAttributeType: return NSNumber(value: Double(n) + 0.5)
    case .dateAttributeType: return Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(n))
    case .binaryDataAttributeType: return Data([UInt8(n % 251), 1, 2, 3])
    default: return nil
    }
}
func fill(_ object: NSManagedObject, _ n: Int) {
    for (name, attribute) in object.entity.attributesByName where !attribute.isTransient {
        object.setValue(value(attribute, n), forKey: name)
    }
}

func base(_ name: String) -> String {
    let path = (folder as NSString).appendingPathComponent(name)
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// A value as the comparison reads it: bytes and dates by what they hold.
func printed(_ value: Any) -> String {
    switch value {
    case let data as Data: return "data:" + data.map { String(format: "%02x", $0) }.joined()
    case let date as Date: return "date:\(date.timeIntervalSinceReferenceDate)"
    case let number as NSNumber: return number.stringValue
    default: return "\(value)"
    }
}

/// Every attribute with a value of every object of a store, as JSON, by the place
/// of the object: the study by its identifier, its series by theirs, an image by
/// its number in the series, an album by its name and its studies. What is not in
/// its place, or not in the store, shows as an object the other side does not have.
/// The entries of the activity history, which are in no other place, are read by
/// logEntries(of:).
func values(of context: NSManagedObjectContext) -> String {
    var all: [String: [String: String]] = [:]
    func record(_ object: NSManagedObject, _ place: String) {
        var attributes: [String: String] = [:]
        for (name, attribute) in object.entity.attributesByName where !attribute.isTransient {
            if let value = object.primitiveValue(forKey: name) { attributes[name] = printed(value) }
        }
        all["\(object.entity.name!)|\(place)"] = attributes
    }
    func related(_ object: NSManagedObject, _ key: String) -> [NSManagedObject] {
        return (object.value(forKey: key) as! NSSet).allObjects as! [NSManagedObject]
    }
    for study in (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? [] {
        let uid = "\(study.primitiveValue(forKey: "studyInstanceUID") ?? "?")"
        record(study, uid)
        for series in related(study, "series") {
            let place = "\(uid)/\(series.primitiveValue(forKey: "seriesInstanceUID") ?? "?")"
            record(series, place)
            for image in related(series, "images") {
                record(image, "\(place)/\(image.primitiveValue(forKey: "instanceNumber") ?? "?")")
            }
        }
    }
    for album in (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Album"))) ?? [] {
        let studies = related(album, "studies").map { "\($0.primitiveValue(forKey: "studyInstanceUID") ?? "?")" }.sorted()
        record(album, "\(album.primitiveValue(forKey: "name") ?? "?")|\(studies.joined(separator: ","))")
    }
    return String(decoding: try! JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]), as: UTF8.self)
}

/// The entries of the activity history of a store, each with all its attributes,
/// so that two stores compare whatever their order.
func logEntries(of context: NSManagedObjectContext) -> [String] {
    return ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "LogEntry"))) ?? []).map { entry in
        entry.entity.attributesByName.keys.sorted().map { "\($0)=\(entry.primitiveValue(forKey: $0).map(printed) ?? "nil")" }.joined(separator: ",")
    }.sorted()
}

/// An index of the former model with `studies` studies of two series of three
/// images, and albums that overlap, two of them of the same name, and `logEntries`
/// entries of activity. With a `label`, what was written goes out under it.
func formerIndex(_ path: String, studies count: Int, label: String? = nil, logEntries entries: Int = 0) {
    let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database.sql"))
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: former)
    let store = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                    options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        var studies: [NSManagedObject] = []
        for n in 0..<count {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            fill(study, n)
            study.setValue("1.2.826.0.1.\(n)", forKey: "studyInstanceUID")
            study.setValue("P\(n % 7)", forKey: "patientUID")
            for s in 0..<2 {
                let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
                fill(series, 10 * n + s)
                series.setValue(study, forKey: "study")
                for i in 0..<3 {
                    let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
                    fill(image, 100 * n + 10 * s + i)
                    image.setValue(series, forKey: "series")
                }
            }
            studies.append(study)
        }
        for (name, members) in [("Teaching", studies.prefix(5)), ("Same", studies.prefix(2)), ("Same", studies.suffix(3)), ("Empty", [])] as [(String, ArraySlice<NSManagedObject>)] {
            let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
            album.setValue(name, forKey: "name")
            album.setValue(false, forKey: "smartAlbum")
            album.mutableSetValue(forKey: "studies").addObjects(from: Array(members))
        }
        for n in 0..<entries {
            fill(NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: context), n)
        }
        try! context.save()
        if let label { emit("\(label).written", values(of: context)) }
    }
    try! coordinator.remove(store)
}

func studyUID(_ n: Int) -> String { return "1.2.826.0.1.\(n)" }

/// What the index of a former model held for a study as text: the property list
/// of a saved layout, as XML or in the old text form, or nothing.
func layoutText(_ n: Int) -> String? {
    switch n {
    case 0:
        let viewers: [[String: Any]] = [["studyInstanceUID": studyUID(n), "seriesInstanceUID": "1.2.3", "rows": 2, "columns": 1]]
        return String(decoding: try! PropertyListSerialization.data(fromPropertyList: viewers, format: .xml, options: 0), as: UTF8.self)
    case 1:
        return "({studyInstanceUID = \"\(studyUID(n))\"; seriesInstanceUID = \"1.2.3\"; rows = 2; columns = 1;})"
    default:
        return nil
    }
}

/// An index written with the former model `version`, as that version left it:
/// three studies of two series of three images, in two albums, with every
/// attribute that left the model or changed since. Protected are the first study,
/// which has a layout too, and the last, which has none.
func formerModelIndex(_ path: String, version: String) {
    let model = writingModel((Bundle.main.resourcePath! as NSString).appendingPathComponent("OsiriXDB_Previous_DataModel\(version).mom"))
    let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database.sql"))
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                    options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator

    /// Sets the attributes this model has.
    func set(_ object: NSManagedObject, _ values: [String: Any?]) {
        for (name, value) in values where object.entity.attributesByName[name] != nil {
            object.setValue(value, forKey: name)
        }
    }

    context.performAndWait {
        var studies: [NSManagedObject] = []
        for n in 0..<3 {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            fill(study, n)
            set(study, ["studyInstanceUID": studyUID(n), "patientUID": "P\(n)", "windowsState": layoutText(n), "locked": [true, false, true][n]])
            for s in 0..<2 {
                let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
                fill(series, 10 * n + s)
                series.setValue(study, forKey: "study")
                for i in 0..<3 {
                    let serial = 100 * n + 10 * s + i
                    let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
                    fill(image, serial)
                    set(image, ["frameNo": i, "instanceNumber": i + 1, "isKeyImage": [true, false, nil][i], "mountedVolume": true,
                                "path": "\(serial).dcm", "sopInstanceUID": "1.2.3.\(serial)", "height": 256, "width": 128, "numberOfFrames": 3,
                                "numberOfSeries": 4, "inDatabaseFolder": false, "extension": "dicom", "fileType": "FILE", "modality": "MR"])
                    image.setValue(series, forKey: "series")
                }
            }
            studies.append(study)
        }
        for (name, members) in [("Teaching", studies.prefix(2)), ("Empty", [])] as [(String, ArraySlice<NSManagedObject>)] {
            let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
            set(album, ["name": name, "smartAlbum": false])
            album.mutableSetValue(forKey: "studies").addObjects(from: Array(members))
        }
        for n in 0..<3 {
            fill(NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: context), n)
        }
        try! context.save()
        emit("former.\(version).written", values(of: context))
        emit("former.\(version).entries", logEntries(of: context).joined(separator: ";"))
    }
    try! coordinator.remove(store)
}

func files(_ path: String) -> String {
    return (try! FileManager.default.contentsOfDirectory(atPath: path)).sorted().joined(separator: ",")
}

/// What the database opens afterwards, whatever the upgrade left there.
func report(_ label: String, _ path: String) {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    guard let _ = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                      at: URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database.sql")), options: options) else {
        emit("\(label).index", "does not open with the current model")
        return
    }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        for entity in ["Study", "Series", "Image", "Album"] {
            emit("\(label).\(entity)", "\((try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))) ?? -1)")
        }
        let studies = (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? []
        let lines = studies.map { study -> String in
            let series = ((study.value(forKey: "series") as! NSSet).allObjects as! [NSManagedObject])
            let images = series.map { ($0.value(forKey: "images") as! NSSet).count }.sorted()
            let albums = ((study.value(forKey: "albums") as! NSSet).allObjects as! [NSManagedObject]).map { $0.value(forKey: "name") as! String }.sorted()
            return "\(study.value(forKey: "studyInstanceUID") ?? "?") \(study.value(forKey: "comment") ?? "") \(images) \(albums)"
        }.sorted()
        emit("\(label).studies", lines.joined(separator: ";"))
        emit("\(label).values", values(of: context))
    }
}

/// What the upgrade of an index of a former model has to keep, as the readers
/// of the application read it.
func reportFormer(_ label: String, _ path: String) {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    guard let _ = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                      at: URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database.sql")), options: options) else { return }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        let byUID = NSFetchRequest<NSManagedObject>(entityName: "Study")
        byUID.sortDescriptors = [NSSortDescriptor(key: "studyInstanceUID", ascending: true)]
        let studies = (try? context.fetch(byUID)) ?? []
        // As the opening of a study reads the layout: data of a property list.
        emit("\(label).layouts", studies.map { study -> String in
            guard let state = study.value(forKey: "windowsState") else { return "none" }
            guard let data = state as? Data, let viewers = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? NSArray,
                  let viewer = viewers.firstObject as? NSDictionary else { return "unreadable" }
            return "\(viewer["studyInstanceUID"] ?? "?") \(viewer["rows"] ?? "?")"
        }.joined(separator: ";"))
        emit("\(label).locked", studies.map { "\($0.value(forKey: "lockedStudy") ?? "nil")" }.joined(separator: ";"))

        let images = (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Image"))) ?? []
        for key in ["frameID", "instanceNumber", "storedIsKeyImage", "storedMountedVolume", "storedHeight", "storedWidth", "storedNumberOfFrames",
                    "storedNumberOfSeries", "storedInDatabaseFolder", "storedExtension", "storedFileType", "storedModality"] {
            emit("\(label).\(key)", Set(images.map { "\($0.primitiveValue(forKey: key) ?? "nil")" }).sorted().joined(separator: ","))
        }
        for key in ["pathNumber", "pathString", "compressedSopInstanceUID"] {
            emit("\(label).\(key)", "\(Set(images.compactMap { $0.primitiveValue(forKey: key) as? NSObject }).count)")
        }
        emit("\(label).upgraded.entries", logEntries(of: context).joined(separator: ";"))
    }
}

/// What is in the index without being in its place: a series with no study, an
/// image with no series. And the alert, on one line.
func reportLosses(_ label: String, _ path: String) {
    emit("\(label).said", alertMessages.joined(separator: " // ").replacingOccurrences(of: "\r", with: "|"))
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    guard let _ = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                      at: URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database.sql")), options: options) else { return }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        func withoutParent(_ entity: String, _ parent: String) -> Int {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            request.predicate = NSPredicate(format: "%K == nil", parent)
            return (try? context.count(for: request)) ?? -1
        }
        emit("\(label).orphan.series", "\(withoutParent("Series", "study"))")
        emit("\(label).orphan.images", "\(withoutParent("Image", "series"))")
        emit("\(label).entries", "\(logEntries(of: context).count)")
    }
}

/// The entries of the former index the upgrade left beside the new one.
func entriesOfFormerIndex(_ path: String) -> [String] {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: former)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    guard let _ = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                      at: URL(fileURLWithPath: (path as NSString).appendingPathComponent("Database-Old-PreviousVersion.sql")), options: options) else { return [] }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    var entries: [String] = []
    context.performAndWait { entries = logEntries(of: context) }
    return entries
}

func upgrade(_ label: String, _ path: String, version: String) {
    alerts = []
    alertMessages = []
    let database = DicomDatabase(base: path, model: current)
    emit("\(label).result", "\(database.upgradeSqlFile(fromModelVersion: version))")
    emit("\(label).rebuilds", "\(database.rebuilds)")
    emit("\(label).alerts", alerts.joined(separator: ";"))
    emit("\(label).files", files(path))
    report(label, path)
}

// More than a hundred studies, with what an upgrade that stopped left beside them.
let good = base("good")
formerIndex(good, studies: 230, label: "good")
try! Data("x".utf8).write(to: URL(fileURLWithPath: (good as NSString).appendingPathComponent("Database3.sql-wal")))
upgrade("good", good, version: "2.4")

let empty = base("empty")
formerIndex(empty, studies: 0)
upgrade("empty", empty, version: "2.4")

let hundred = base("hundred")
formerIndex(hundred, studies: 100)
upgrade("hundred", hundred, version: "2.4")

// An index that cannot be read stays as it is, and the rebuild takes over.
let damaged = base("damaged")
try! Data("not an index".utf8).write(to: URL(fileURLWithPath: (damaged as NSString).appendingPathComponent("Database.sql")))
upgrade("damaged", damaged, version: "2.4")

// The model of the index is not among those the application carries.
let unknown = base("unknown")
formerIndex(unknown, studies: 3)
upgrade("unknown", unknown, version: "9.9")

// A series of the second study and an image of the third do not copy. The fifth
// study loses a series too, and then does not validate: its batch is saved again
// study by study, the second and the third are copied twice, and it leaves whole.
let losses = base("losses")
formerIndex(losses, studies: 6)
refusedValues = ["Series.name.10", "Image.storedModality.212", "Series.name.40"]
invalidStudies = ["Study.name.4"]
upgrade("losses.partial", losses, version: "2.4")
refusedValues = []
invalidStudies = []
reportLosses("losses.partial", losses)

// The same, with nothing that makes a study leave: only the sentence of what stayed.
let kept = base("losses-kept")
formerIndex(kept, studies: 3)
refusedValues = ["Image.storedModality.212"]
upgrade("losses.kept", kept, version: "2.4")
refusedValues = []
reportLosses("losses.kept", kept)

// The history of a busy server: more entries than one batch, and more than the
// studies, each with every attribute it had.
let history = base("losses-history")
formerIndex(history, studies: 2, logEntries: 1203)
upgrade("losses.history", history, version: "2.4")
reportLosses("losses.history", history)
do {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
    let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true]
    _ = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                            at: URL(fileURLWithPath: (history as NSString).appendingPathComponent("Database.sql")), options: options)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    var entries: [String] = []
    context.performAndWait { entries = logEntries(of: context) }
    emit("losses.history.same", entries == entriesOfFormerIndex(history) ? "yes" : "no")
}

// Each model the application upgrades from, with what changed since.
for version in ["1.1", "1.5", "2.0", "2.1", "2.2", "2.3"] {
    let path = base("former-\(version)")
    formerModelIndex(path, version: version)
    upgrade("former.\(version)", path, version: version)
    reportFormer("former.\(version)", path)
}
"""

MEASURE_DRIVER = r"""
import CoreData
import IsiXDatabase

let arguments = CommandLine.arguments
let current = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1]))!

// One line for each attribute of a former model that the current one does not
// have as it is, saying what becomes of it.
for path in arguments.dropFirst(2) {
    let former = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path))!
    let version = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "OsiriXDB_Previous_DataModel", with: "")
    print("model\t\(version)")
    for entity in ["Study", "Series", "Image", "Album", "LogEntry"] {
        let leftOut = entity == "Series" ? ModelUpgradeRules.seriesKeysLeftOut : entity == "Image" ? ModelUpgradeRules.imageKeysLeftOut : []
        let now = current.entitiesByName[entity]!.attributesByName
        for (name, attribute) in former.entitiesByName[entity]!.attributesByName where !attribute.isTransient {
            let key = ModelUpgradeRules.currentKey(name, ofEntity: entity)
            if ModelUpgradeRules.isRetired(name, ofEntity: entity) {
                print("\(version)\t\(entity).\(name)\tretired")
            } else if let target = now[key] {
                if target.attributeType != attribute.attributeType {
                    print("\(version)\t\(entity).\(name)\tretyped")
                } else if key != name {
                    print("\(version)\t\(entity).\(name)\trenamed")
                }
            } else {
                print("\(version)\t\(entity).\(name)\t\(leftOut.contains(name) ? "left out" : "no attribute")")
            }
        }
    }
}
"""

# What left the model and has no rule: DicomImage has a setter for each of these,
# which key-value coding reaches, and keeps the value where the model has it.
IMAGE_SETTERS = {
    'path': r'@objc\(setPath:\)', 'sopInstanceUID': r'@objc\(setSopInstanceUID:\)', 'height': r'@objc\(setHeight:\)',
    'width': r'@objc\(setWidth:\)', 'numberOfSeries': r'@objc\(setNumberOfSeries:\)', 'inDatabaseFolder': r'@objc\(setInDatabaseFolder:\)',
    'extension': r'@objc\(setExtension:\)', 'fileType': r'@objc\(setFileType:\)',
    'numberOfFrames': r'@objc public dynamic var numberOfFrames\b', 'modality': r'@objc public dynamic var modality\b',
}
UP_TO_2_1 = {
    'Study.dicomTime': 'retired', 'Study.type': 'retired', 'Series.dicomTime': 'retired', 'Series.type': 'retired',
    'Image.dicomTime': 'retired', 'Image.type': 'retired', 'Image.name': 'retired', 'Image.iPod': 'retired',
    'Image.isKeyImage': 'renamed', 'Image.mountedVolume': 'renamed',
    # A DICOM IS value fits the 32 bits it now has: the copy keeps it, and the
    # stores below confirm it.
    'Image.instanceNumber': 'retyped',
    **{'Image.%s' % name: 'no attribute' for name in IMAGE_SETTERS},
}
WITH_FRAME_NUMBERS = {**UP_TO_2_1, 'Image.frameNo': 'renamed'}
WITH_TEXT_LAYOUTS = {'Study.locked': 'renamed', 'Study.windowsState': 'retyped'}
# What the current model does not have as it is, by former model, as measured.
MEASURED = {
    '1.1': UP_TO_2_1, '1.5': UP_TO_2_1, '2.0': WITH_FRAME_NUMBERS, '2.1': WITH_FRAME_NUMBERS,
    '2.2': {**WITH_TEXT_LAYOUTS, 'Image.wl': 'left out', 'Image.ww': 'left out'}, '2.3': WITH_TEXT_LAYOUTS, '2.4': {}, '2.5': {},
}

# The display state, which the upgrade does not copy.
LEFT_OUT = {'xOffset', 'yOffset', 'scale', 'rotationAngle', 'displayStyle', 'windowLevel', 'windowWidth', 'yFlipped', 'xFlipped', 'wl', 'ww'}
# What was written under a name and is read under another, with its value as the
# upgrade leaves it, or None for none. The image attributes that left the model go
# through the setters, here those of the stand-in.
UTF8_DATA = lambda value: 'data:' + value.encode('utf-8').hex()
CHANGED = {
    'Study.locked': ('lockedStudy', str),
    'Study.windowsState': ('windowsState', lambda value: value if value.startswith('data:') else UTF8_DATA(value)),
    'Image.frameNo': ('frameID', str),
    'Image.isKeyImage': ('storedIsKeyImage', lambda value: value if value == '1' else None),
    'Image.mountedVolume': ('storedMountedVolume', str),
    'Image.path': ('pathNumber', lambda value: value.split('.')[0]), 'Image.sopInstanceUID': ('compressedSopInstanceUID', UTF8_DATA),
    'Image.height': ('storedHeight', str), 'Image.width': ('storedWidth', str), 'Image.numberOfFrames': ('storedNumberOfFrames', str),
    'Image.numberOfSeries': ('storedNumberOfSeries', str), 'Image.inDatabaseFolder': ('storedInDatabaseFolder', str),
    'Image.extension': ('storedExtension', str), 'Image.fileType': ('storedFileType', str), 'Image.modality': ('storedModality', str),
}
RETIRED = {'Study.dicomTime', 'Study.type', 'Series.dicomTime', 'Series.type', 'Image.dicomTime', 'Image.type', 'Image.name', 'Image.iPod'}


def after_the_upgrade(written):
    """What the objects of `written` hold in the current model, as {place: {attribute: value}}."""
    wanted = {}
    for place, attributes in written.items():
        entity = place.split('|')[0]
        wanted[place] = {}
        for name, value in attributes.items():
            attribute = '%s.%s' % (entity, name)
            if attribute in RETIRED:
                continue
            if entity in ('Series', 'Image') and name in LEFT_OUT:
                wanted[place][name] = None
                continue
            key, upgraded = CHANGED.get(attribute, (name, str))
            if upgraded(value) is not None:
                wanted[place][key] = upgraded(value)
    return wanted


def compare_values(what, found, wanted, only_wanted=False):
    """One failure for each attribute that differs, whatever the number of its objects."""
    different = {}
    for place in sorted(set(found) | set(wanted)):
        entity = place.split('|')[0]
        if place not in found or place not in wanted:
            different.setdefault('%s, the object' % entity, []).append((place, place in found, place in wanted))
            continue
        for name in sorted(wanted[place] if only_wanted else set(found[place]) | set(wanted[place])):
            if found[place].get(name) != wanted[place].get(name):
                different.setdefault('%s.%s' % (entity, name), []).append((place, found[place].get(name), wanted[place].get(name)))
    for attribute, places in sorted(different.items()):
        failures.append('%s, %s, in %d objects, the first %r' % (what, attribute, len(places), places[0]))
    return not different


def upgrade_sources(source, label):
    """The upgrade of `source`, wherever it is, as a Swift file, and whether it is the type."""
    if 'struct DatabaseModelUpgrade {' in source:
        body = source[source.index('/// `[NSEntityDescription entityForName:name'):]
        return ('import AppKit\nimport CoreData\nimport IsiXDatabase\nimport IsiXPreferences\n\n' + body + """
extension DicomDatabase {
    func upgradeSqlFile(fromModelVersion version: String!) -> Bool {
        return DatabaseModelUpgrade(database: self, processGraph: ProcessGraph()).run(fromModelVersion: version)
    }
}
""")
    helpers = source[source.index('/// The attributes that the former upgrade copied'):source.index('public extension DicomDatabase {')]
    method = source[source.index('    @objc(upgradeSqlFileFromModelVersion:)'):source.index('    // The database preferences run this over every database')]
    method = method.replace('@objc(upgradeSqlFileFromModelVersion:)\n    dynamic func', 'func')
    return 'import AppKit\nimport CoreData\n\n' + helpers + '\nextension DicomDatabase {\n' + method + '\n}\n'


def run_upgrade(source, label, directory, momd, models):
    """What the upgrade of `source` leaves in new stores, as {key: value}."""
    folder = directory / label
    folder.mkdir()
    (folder / 'doubles.swift').write_text(UPGRADE_DOUBLES)
    (folder / 'upgrade.swift').write_text(upgrade_sources(source, label))
    (folder / 'main.swift').write_text(UPGRADE_DRIVER)
    (folder / 'try.h').write_text(TRY_HEADER)
    (folder / 'try.m').write_text(TRY_SOURCE)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-o', str(folder / 'try.o'), str(folder / 'try.m')], check=True, capture_output=True)
    # Bundle.main of a tool is its folder: the former model is looked for there.
    binary = folder / 'upgrade'
    for model in models.glob('*.mom'):
        (folder / model.name).write_bytes(model.read_bytes())
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary), '-import-objc-header', str(folder / 'try.h'),
                            *module_flags('IsiXDatabase', directory / 'modules'),
                            str(folder / 'doubles.swift'), str(folder / 'upgrade.swift'), str(folder / 'main.swift'), str(folder / 'try.o'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the upgrade of %s does not compile:\n%s' % (label, built.stderr[-2500:]))
        return {}
    stores = folder / 'stores'
    stores.mkdir()
    run = subprocess.run([str(binary), str(momd), str(models / 'OsiriXDB_Previous_DataModel2.4.mom'), str(stores)], capture_output=True, text=True, cwd=folder, timeout=180)
    if run.returncode != 0:
        failures.append('the upgrade of %s failed: %s' % (label, (run.stderr or run.stdout)[-1500:]))
    return dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)


def measure_models(directory, momd, models):
    """What the current model does not have as it is, as {version: {attribute: kind}}."""
    compiled = subprocess.run(['xcrun', 'momc', str(FORMER_MODEL_SOURCE), str(directory)], capture_output=True, text=True)
    if compiled.returncode != 0:
        failures.append('model 2.5 does not compile with momc:\n%s' % compiled.stderr[-1500:])
        return {}
    source = directory / 'measure.swift'
    source.write_text(MEASURE_DRIVER)
    binary = directory / 'measure'
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary),
                            *module_flags('IsiXDatabase', directory / 'modules'), str(source)], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the measure of the models does not compile:\n%s' % built.stderr[-2500:])
        return {}
    paths = [str(momd)] + sorted(map(str, models.glob('*.mom'))) + [str(directory / (FORMER_MODEL_SOURCE.stem + '.mom'))]
    run = subprocess.run([str(binary), *paths], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        failures.append('the measure of the models failed: %s' % run.stderr[-1500:])
    measured = {}
    for line in run.stdout.splitlines():
        fields = line.split('\t')
        if fields[0] == 'model':
            measured[fields[1]] = {}
        else:
            measured[fields[0]][fields[1]] = fields[2]
    return measured


if not revision:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-equivalence-') as directory:
        directory = Path(directory)
        compiled = subprocess.run(['xcrun', 'momc', str(MODEL), str(directory)], capture_output=True, text=True)
        momd = directory / 'OsiriXDB_DataModel.momd'
        if compiled.returncode != 0 or not momd.exists():
            failures.append('the data model does not compile with momc:\n%s' % compiled.stderr[-1500:])
        else:
            before_the_type = revision_before(root, SOURCE)
            shown = subprocess.run(['git', '-C', str(root), 'show', f'{before_the_type}:{FORMER_SOURCE}'], capture_output=True) if before_the_type else None
            models = former_models(directory / 'former-models')
            now = run_upgrade(text, 'now', directory, momd, models)
            compared = shown is not None and shown.returncode == 0
            if compared:
                then = run_upgrade(shown.stdout.decode('utf-8'), 'before', directory, momd, models)
                # The stores of 2.4: the former ones differ on purpose, and are
                # what that revision loses.
                # What 'losses.' measures is what that revision got wrong.
                for key in sorted(key for key in set(now) | set(then) if not key.startswith(('former.', 'losses.')) and not key.endswith('.written')):
                    if key.endswith('.values'):
                        compare_values('the upgrade changed, %s' % key, json.loads(now.get(key, '{}')), json.loads(then.get(key, '{}')))
                    elif now.get(key) != then.get(key):
                        failures.append('the upgrade changed, %s: %r, was %r' % (key, (now.get(key) or '')[:300], (then.get(key) or '')[:300]))
                lost = {'former.2.3.Study': '1', 'former.2.3.alerts': 'Database Upgrade', 'former.2.3.locked': 'nil',
                        'former.2.1.frameID': 'nil', 'former.2.1.storedIsKeyImage': 'nil', 'former.2.1.storedMountedVolume': 'nil',
                        'losses.history.entries': '0', 'losses.kept.said': '', 'losses.kept.orphan.images': '1'}
                for key, want in lost.items():
                    if then.get(key) != want:
                        failures.append('negative control: the revision before the type no longer loses %s: %r, expected %r' % (key, then.get(key), want))

            measured = measure_models(directory, momd, models)
            if measured != MEASURED:
                for version in sorted(set(measured) | set(MEASURED)):
                    if measured.get(version) != MEASURED.get(version):
                        failures.append('model %s differs from the list of what the upgrade accounts for: measured %r, listed %r'
                                        % (version, measured.get(version), MEASURED.get(version)))
            image_source = IMAGE_SOURCE.read_text()
            for name, setter in IMAGE_SETTERS.items():
                if not re.search(setter, image_source):
                    failures.append('DicomImage no longer has the setter that keeps %s of a former model' % name)

            for version in ('1.1', '1.5', '2.0', '2.1', '2.2', '2.3'):
                label = 'former.%s.' % version
                former = {'result': 'true', 'rebuilds': '0', 'alerts': '', 'files': 'Database-Old-PreviousVersion.sql,Database.sql',
                          'Study': '3', 'Series': '6', 'Image': '18', 'Album': '2'}
                if version in ('2.2', '2.3'):
                    former.update({'layouts': '1.2.826.0.1.0 2;1.2.826.0.1.1 2;none', 'locked': '1;0;1'})
                else:
                    former.update({'layouts': 'none;none;none', 'locked': 'nil;nil;nil', 'instanceNumber': '1,2,3', 'storedIsKeyImage': '1,nil',
                                   'storedMountedVolume': '1', 'storedHeight': '256', 'storedWidth': '128', 'storedNumberOfFrames': '3',
                                   'storedNumberOfSeries': '4', 'storedInDatabaseFolder': '0', 'storedExtension': 'dicom', 'storedFileType': 'FILE',
                                   'storedModality': 'MR', 'pathNumber': '18', 'pathString': '0', 'compressedSopInstanceUID': '18',
                                   'frameID': '0,1,2' if version in ('2.0', '2.1') else 'nil'})
                for key, want in former.items():
                    if now.get(label + key) != want:
                        failures.append('%s%s: %r, expected %r' % (label, key, now.get(label + key), want))
                if 'Teaching' not in now.get(label + 'studies', ''):
                    failures.append('the upgrade of model %s lost the albums of its studies' % version)
                if not now.get(label + 'entries') or now.get(label + 'entries') != now.get(label + 'upgraded.entries'):
                    failures.append('the upgrade of model %s did not keep the activity history: %r, wrote %r'
                                    % (version, (now.get(label + 'upgraded.entries') or '')[:200], (now.get(label + 'entries') or '')[:200]))
            # What each store of a former model was written with, and one of 2.4: the
            # attributes that came from it, with the display state left without a
            # value, and not those the current model added.
            for label in ['good'] + ['former.%s' % version for version in ('1.1', '1.5', '2.0', '2.1', '2.2', '2.3')]:
                compare_values('the upgrade of %s' % label, json.loads(now.get(label + '.values', '{}')),
                               after_the_upgrade(json.loads(now.get(label + '.written', '{}'))), only_wanted=True)

            expected = {
                'good.result': 'true', 'good.rebuilds': '0', 'good.alerts': '',
                'good.files': 'Database-Old-PreviousVersion.sql,Database.sql',
                'good.Study': '230', 'good.Series': '460', 'good.Image': '1380', 'good.Album': '4',
                'hundred.Study': '100', 'hundred.Series': '200', 'hundred.Image': '600',
                'empty.result': 'true', 'empty.Study': '0', 'empty.Album': '4',
                'damaged.result': 'false', 'damaged.rebuilds': '1', 'damaged.alerts': 'Database Update', 'damaged.files': 'Database.sql',
                'unknown.result': 'false', 'unknown.rebuilds': '1', 'unknown.alerts': 'IsiX DICOM Viewer Database', 'unknown.files': 'Database.sql',
                # Five studies stay and one leaves, with no row of nothing and each named once.
                'losses.partial.result': 'true', 'losses.partial.rebuilds': '0', 'losses.partial.alerts': 'Database Upgrade',
                'losses.partial.Study': '5', 'losses.partial.Series': '9', 'losses.partial.Image': '26',
                'losses.partial.orphan.series': '0', 'losses.partial.orphan.images': '0',
                'losses.partial.said': 'The upgrade encountered 1 errors. These corrupted studies have been removed: Study.name.4'
                                       '||The upgrade could not copy some series or images. These studies stay in the database without them, and their files were not removed: '
                                       'Study.name.1 (1 series, 0 images), Study.name.2 (0 series, 1 images)',
                'losses.kept.result': 'true', 'losses.kept.alerts': 'Database Upgrade', 'losses.kept.Study': '3', 'losses.kept.Series': '6', 'losses.kept.Image': '17',
                'losses.kept.orphan.series': '0', 'losses.kept.orphan.images': '0',
                'losses.kept.said': 'The upgrade could not copy some series or images. These studies stay in the database without them, and their files were not removed: '
                                    'Study.name.2 (0 series, 1 images)',
                'losses.history.result': 'true', 'losses.history.alerts': '', 'losses.history.entries': '1203', 'losses.history.same': 'yes',
            }
            for key, want in expected.items():
                if now.get(key) != want:
                    failures.append('%s: %r, expected %r' % (key, now.get(key), want))
            if '[3, 3]' not in now.get('good.studies', ''):
                failures.append('the upgraded studies lost their series or images: %r' % now.get('good.studies', '')[:200])
            if 'Same' not in now.get('good.studies', '') or 'Teaching' not in now.get('good.studies', ''):
                failures.append('the upgraded studies lost their albums')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
if not revision and not compared:
    print('skipped: git does not have the revision before %s, so the upgrade was not compared with it' % SOURCE, file=sys.stderr)
    sys.exit(SKIPPED)
print('ok: the upgrade closes both stores before renaming their files and after it stops, '
      'lists a study without a name without raising, and, compiled from the checkout and from '
      'the revision before the type, leaves every attribute of every study, series, image and album, and the same alerts and files, on real stores of model 2.4; '
      'every attribute that changed since a former model is accounted for, and real stores of 1.1 to 2.3 and 2.4 hold what was written in them, '
      'with what that revision loses; a series or an image that does not copy leaves no row behind and is named in the alert with its study, which stayed, '
      'and the activity history reaches the new index')
