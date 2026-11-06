#!/usr/bin/env python3
"""A DCMPix reads and writes its image's row in the database the row is of.

A viewer of a study of a shared database (another computer's, over Bonjour)
stays open beside a browser that shows a local database, and a viewer of a
local study beside a browser that shows a shared one. The row of a DCMPix's
image is then not in the database the browser shows. Its image, series and
study (imageObj, seriesObj, studyObj: the ROI export, the plugins' image
attributes, the stored window level and zoom, the workspace state), the size
written back to the row (storeSize:inDatabaseForImageID:), and the ROIs made
from an RT structure set (refused for a shared database, the images it refers
to looked up in the database) used to ask the browser's database, which has
neither the row nor its series.

Compiled with doubles of the databases over real Core Data stores in memory
and of DCMPix, the real members of DCMPix+Database.swift and the entry points
of DCMPix+RTStruct.swift are driven with the browser on either database:
- imageObj, seriesObj and studyObj answer the row of the image's own database,
  its series and its study, in that database's context;
- the size is written in the image's own store, on a private-queue context of
  its database, and the browser's store is not touched;
- the RT structure set of a local image is converted in the local database,
  that of a shared image refused, and a DCMPix without a row follows the
  browser's database, as before.
No app, no network and no DICOM file are needed.
"""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
SKIPPED = 2
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8', errors='replace')


def member(source, signature):
    """A declaration of Swift, from `signature` through its closing brace."""
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


DOUBLES = r'''
import AppKit
import CoreData

/// What the databases were asked: database, request.
nonisolated(unsafe) var told: [String] = []

@objc(DicomDatabase)
class DicomDatabase: NSObject {
    let name: String
    var managedObjectContext: NSManagedObjectContext!
    var mainDatabase: DicomDatabase?
    required init(_ name: String) { self.name = name }
    var mainName: String { mainDatabase?.name ?? name }
    func isMainDatabase() -> Bool { mainDatabase == nil }
    func isLocal() -> Bool { true }
    /// As N2ManagedDatabase: on the context's queue, nil for a row of another store.
    func object(withID oid: Any!) -> Any! {
        var found: Any?
        guard let objectID = oid as? NSManagedObjectID else { return nil }
        managedObjectContext.performAndWait { found = try? managedObjectContext.existingObject(with: objectID) }
        return found
    }
    func performBlockAndWait(_ block: () -> Void) { managedObjectContext.performAndWait(block) }
    func save() -> Bool {
        told.append("\(mainName) save on \(managedObjectContext.concurrencyType == .privateQueueConcurrencyType ? "a private queue" : "the main queue")")
        return (try? managedObjectContext.save()) != nil
    }
    /// A database over a private-queue context of this one's store.
    func privateQueueIndependentDatabase() -> Any! {
        let independent = type(of: self).init(name + " independent")
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = managedObjectContext.persistentStoreCoordinator
        independent.managedObjectContext = context
        independent.mainDatabase = self
        return independent
    }
    nonisolated(unsafe) static var open: [DicomDatabase] = []
    class func allDatabases() -> [Any]! { open }
}

final class RemoteDicomDatabase: DicomDatabase {
    override func isLocal() -> Bool { false }
}

@objc(DicomImage)
final class DicomImage: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var width: NSNumber?
    @NSManaged var series: DicomSeries?
}

@objc(DicomSeries)
final class DicomSeries: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var study: DicomStudy?
}

@objc(DicomStudy)
final class DicomStudy: NSManagedObject {
    @NSManaged var name: String
}

/// The database the browser shows.
nonisolated(unsafe) var shown: DicomDatabase?

struct BrowserDatabaseSource {
    static let process = BrowserDatabaseSource()
    var browserDatabase: DicomDatabase? { shown }
}

final class DCMObject: NSObject {}

final class DCMPix: NSObject {
    var horos_imageObjectID: NSManagedObjectID!
}

/// The conversion, which DCMPix+RTStruct.swift runs inside the database it is given.
nonisolated(unsafe) var converted = DispatchSemaphore(value: 0)
extension DCMPix {
    @objc(createROIsFromRTSTRUCT:inDatabase:)
    func createROIs(fromRTSTRUCT dict: NSDictionary!, in database: DicomDatabase!) {
        told.append("convert in \(database.mainName) on \(database.managedObjectContext.concurrencyType == .privateQueueConcurrencyType ? "a private queue" : "the main queue")")
        converted.signal()
    }
}

extension Thread {
    var supportsCancel: Bool { get { false } set {} }
    var status: String? { get { nil } set {} }
}

final class ThreadsManager {
    static func `default`() -> ThreadsManager { ThreadsManager() }
    func addThreadAndStart(_ thread: Thread) { thread.start() }
}

enum HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
}
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: String) {}
'''

DRIVER = r'''
import AppKit
import CoreData

nonisolated(unsafe) var failures: [String] = []
func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

let model: NSManagedObjectModel = {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    func entity(_ name: String, _ type: AnyClass, _ properties: [NSPropertyDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        entity.properties = properties
        return entity
    }
    let image = entity("Image", DicomImage.self, [attribute("name", .stringAttributeType), attribute("width", .integer32AttributeType)])
    let series = entity("Series", DicomSeries.self, [attribute("name", .stringAttributeType)])
    let study = entity("Study", DicomStudy.self, [attribute("name", .stringAttributeType)])
    func relation(_ name: String, _ from: NSEntityDescription, _ to: NSEntityDescription) {
        let relation = NSRelationshipDescription()
        relation.name = name
        relation.destinationEntity = to
        relation.maxCount = 1
        relation.isOptional = true
        relation.deleteRule = .nullifyDeleteRule
        from.properties.append(relation)
    }
    relation("series", image, series)
    relation("study", series, study)
    let model = NSManagedObjectModel()
    model.entities = [image, series, study]
    return model
}()

/// A database with a main-queue context over a store of its own, open.
func database<D: DicomDatabase>(_ made: D) -> D {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    _ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    made.managedObjectContext = context
    DicomDatabase.open.append(made)
    return made
}

/// A saved image of `database`, in a series of a study of its own.
func image(_ name: String, of database: DicomDatabase) -> DicomImage {
    let context = database.managedObjectContext!
    let study = DicomStudy(entity: model.entitiesByName["Study"]!, insertInto: context)
    study.name = "study of \(name)"
    let series = DicomSeries(entity: model.entitiesByName["Series"]!, insertInto: context)
    series.name = "series of \(name)"
    series.study = study
    let image = DicomImage(entity: model.entitiesByName["Image"]!, insertInto: context)
    image.name = name
    image.width = 64
    image.series = series
    try! context.save()
    return image
}

/// The width the store of `database` holds for `image`, read by a context of its own.
func storedWidth(_ image: DicomImage, in database: DicomDatabase) -> Int? {
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = database.managedObjectContext.persistentStoreCoordinator
    var width: Int?
    context.performAndWait { width = (try? context.existingObject(with: image.objectID) as? DicomImage)?.width?.intValue }
    return width
}

func pix(of image: DicomImage?) -> DCMPix {
    let pix = DCMPix()
    pix.horos_imageObjectID = image?.objectID
    return pix
}

/// What the RT structure set conversion of `pix` did: converted where, or nothing (refused).
func structureSet(of pix: DCMPix) -> [String] {
    told = []
    converted = DispatchSemaphore(value: 0)
    pix.createROIs(fromRTSTRUCT: DCMObject())
    _ = converted.wait(timeout: .now() + 2)
    return told
}

@MainActor
func run() {
    let shared = database(RemoteDicomDatabase("shared"))
    let local = database(DicomDatabase("local"))
    let remote = image("remote", of: shared)
    let mine = image("mine", of: local)

    for browser in [local, shared] {
        shown = browser
        let on = "browser on the \(browser.name) database"
        for (row, owner) in [(remote, shared), (mine, local)] {
            let of = "\(on), an image of the \(owner.name) database"
            let image = pix(of: row).imageObj()
            check(image?.name == row.name && image?.managedObjectContext === owner.managedObjectContext,
                  "\(of): imageObj is not the row of the image's own database: \(image?.name ?? "nil")")
            check(pix(of: row).seriesObj()?.name == "series of \(row.name)", "\(of): seriesObj is not the image's series")
            check(pix(of: row).studyObj()?.name == "study of \(row.name)", "\(of): studyObj is not the image's study")

            told = []
            let width = 100 + (owner === shared ? 1 : 2) + (browser === shared ? 10 : 20)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) let id = row.objectID
            Thread { DCMPix.storeSize(["width": NSNumber(value: width)], inDatabaseForImageID: id); done.signal() }.start()
            done.wait()
            let other = owner === shared ? local : shared
            check(storedWidth(row, in: owner) == width && told == ["\(owner.name) save on a private queue"],
                  "\(of): the size is not written to the image's own row on a private queue: \(storedWidth(row, in: owner).map(String.init) ?? "nil") \(told)")
            check(!told.contains { $0.hasPrefix(other.name) }, "\(of): the size is written in the \(other.name) database")
        }

        check(structureSet(of: pix(of: mine)) == ["convert in local on a private queue"],
              "\(on): the RT structure set of a local image is not converted in its database: \(told)")
        check(structureSet(of: pix(of: remote)).isEmpty, "\(on): the RT structure set of a shared image is not refused: \(told)")
        let rowless = structureSet(of: pix(of: nil))
        check(browser === local ? rowless == ["convert in local on a private queue"] : rowless.isEmpty,
              "\(on): the RT structure set of a DCMPix without a row does not follow the browser's database: \(rowless)")
        check(pix(of: nil).imageObj() == nil, "\(on): a DCMPix without a row answers an image")
    }
    print(failures.isEmpty ? "ok" : failures.map { "FAIL: " + $0 }.joined(separator: "\n"))
}

MainActor.assumeIsolated { run() }
'''


def main():
    pix = read('DCMPix+Database.swift')
    rt = read('DCMPix+RTStruct.swift')
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return SKIPPED
    pieces = 'import AppKit\nimport CoreData\n\n' + member(pix, 'extension DCMPix {') + '\n\n'
    pieces += 'extension DCMPix {\n    ' + member(pix, '@objc(storeSize:inDatabaseForImageID:)') + '\n}\n\n'
    pieces += 'extension DCMPix {\n    ' + member(rt, '@objc(createROIsFromRTSTRUCT:)') + '\n\n    ' \
        + member(rt, '@objc(createROIsFromRTSTRUCTThread:)') + '\n}\n\n'
    # What the members ask of the database of the row (absent before they did).
    if 'final func databaseOfImage()' in pix:
        pieces += 'extension DCMPix {\n    ' + member(pix, 'final func databaseOfImage()') + '\n}\n\n'
    for signature in ('func databaseOfRow(', 'private func openDatabase(holding', 'func privateQueueDatabase('):
        if signature in pix:
            pieces += member(pix, signature) + '\n\n'

    failures = []
    with tempfile.TemporaryDirectory(prefix='horos-dcmpix-own-rows-') as directory:
        work = Path(directory)
        files = {'doubles.swift': DOUBLES, 'pieces.swift': pieces, 'main.swift': DRIVER}
        for name, text in files.items():
            (work / name).write_text(text, encoding='utf-8')
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *(str(work / name) for name in files), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the sources do not compile with their doubles\n' + built.stderr[-3000:])
        else:
            ran = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=120)
            if ran.returncode or ran.stdout.strip() != 'ok':
                failures.append((ran.stdout + ran.stderr).strip()[-3000:].removeprefix('FAIL: '))
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print("a DCMPix of a shared or a local image, with the browser on either database: imageObj, seriesObj and "
          "studyObj answer the rows of the image's own database, the size is written to the image's own row on a "
          'private queue, the RT structure set of a local image is converted in its database and that of a shared '
          "one refused; a DCMPix without a row follows the browser's database")
    return 0


if __name__ == '__main__':
    sys.exit(main())
