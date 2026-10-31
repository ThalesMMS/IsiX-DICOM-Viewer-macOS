#!/usr/bin/env python3
"""Rows dropped on a viewer and files edited from a viewer's image go to their own database.

A viewer of a study of a shared database (another computer's) stays open
beside a browser that shows a local database, and a viewer of a local study
beside a browser that shows a shared one.

- A drop of database rows on a viewer (a series dragged from the series list of
  a viewer, or from the browser) looked every row up in the database the
  browser shows. A series of the shared study's list, beside a browser on a
  local database, was found nowhere: the drop raised and the series did not
  open, and the reverse too. The rows are now read in the open database whose
  store holds them (viewerDraggedRow).
- The metadata window indexed the files it had edited in the browser's
  database: the edited files of a shared study went into the local database and
  never reached their server, and those of a local study were sent to the
  server of the shared database the browser showed, while the local index kept
  the values before the edit. When an edit moved the images to another series
  or study, their former rows were deleted through the browser, which deletes
  in the database it shows only. An edit at the patient level took the
  patient's studies from the browser's database, so files of another database
  were edited. The files are now indexed in the database of the rows edited,
  the former rows removed there, and the patient's studies read in the image's
  database.

Compiled with doubles of the databases (Core Data in memory, the URI of a row
resolved as N2ManagedDatabase -objectWithID: resolves it): the real
viewerDraggedRow(named:shown:open:) finds the row of either database with the
browser on either, and nothing for a database that is not open; the real
XMLController.database(ofEdited:image:source:) answers the rows' main
database; the real XMLController.removeReplacedRows(_:from:browser:) removes
the rows in their own database, with the viewers of their series closed and the
series and studies left empty, and lets the browser delete when it shows that
database. The wiring of performDragOperation: and updateDB:objects: is checked
in their sources. No app, no network and no DICOM file are needed.
"""
from pathlib import Path
import importlib.util
import re
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

DRAG = 'ViewerController+DragAndDrop.swift'
XML = 'XMLController.swift'
EDITED = 'XMLController+EditedFiles.swift'


def read(name):
    path = SOURCES / name
    return path.read_text(encoding='utf-8', errors='replace') if path.exists() else ''


def member(source, signature):
    """A declaration of Swift, from `signature` through its closing brace; None when absent."""
    if signature not in source:
        return None
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


def with_attributes(source, signature):
    """`member`, with the attribute lines just above the declaration (@MainActor)."""
    body = member(source, signature)
    if body is None:
        return None
    before = source[:source.index(signature)].rstrip(' ')
    lines = before.split('\n')
    attributes = []
    while len(lines) > 1 and lines[-2].strip().startswith('@'):
        attributes.insert(0, lines[-2].strip())
        lines.pop(-2)
    return '\n'.join(attributes + [body])


def source_failures():
    failures = []
    drag = member(read(DRAG), '    @objc(performDragOperation:)')
    if drag is None:
        return ['performDragOperation: is missing from ' + DRAG]
    rows = drag[drag.index('databaseObjectXIDsPasteboardTypes()'):]
    rows = indicator.swift_code(rows[:rows.index('} else {')])
    if 'viewerDraggedRow(named:' not in rows:
        failures.append("the rows dropped on a viewer are looked up in the browser's database only, not in the database holding them")
    if re.search(r'browserDatabase\s*\n?\s*.*\n?.*\.object\(withID:', rows) or 'database?.object(withID:' in rows:
        failures.append("the rows dropped on a viewer are still asked of the browser's database")

    update = member(read(XML), '    func updateDB(_ files: NSArray?, objects: NSArray?) -> NSArray? {')
    if update is None:
        failures.append('updateDB:objects: is missing from ' + XML)
    else:
        code = indicator.swift_code(update)
        if 'browserDatabase' in code or 'XMLController.database(ofEdited:' not in code or 'in: $0)' not in code:
            failures.append("updateDB:objects: indexes the edited files in the browser's database, not in the database of the rows edited")
        if 'proceedDelete' in code or 'removeReplacedRows(' not in code:
            failures.append("the rows an edit replaced are deleted through the browser, which deletes in the database it shows only")
    patient = member(read(XML), '    func arrayOfFiles() -> NSArray? {')
    if patient is not None:
        code = indicator.swift_code(patient[patient.index('case 3:'):])
        if 'browser?.database' in code or '_imObj?.managedObjectContext' not in code:
            failures.append("an edit at the patient level takes the patient's studies from the browser's database")
    return failures


DOUBLES = r'''
import AppKit
import CoreData

/// What happened: deletions by the browser, viewers closed, placeholders forgotten.
nonisolated(unsafe) var told: [String] = []

class DicomDatabase: NSObject {
    let name: String
    var managedObjectContext: NSManagedObjectContext!
    var mainDatabase: Any?
    var dataBaseDirPath: String? { "/db/" + name }
    required init(_ name: String) { self.name = name }
    func isMainDatabase() -> Bool { mainDatabase == nil }
    /// As N2ManagedDatabase -objectWithID: finds a row: an ID, or a URI of it, through the store coordinator.
    func object(withID oid: Any!) -> Any! {
        var objectID = oid as? NSManagedObjectID
        if let string = oid as? String {
            objectID = URL(string: string).flatMap { managedObjectContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: $0) }
        }
        guard let objectID else { return nil }
        return try? managedObjectContext.existingObject(with: objectID)
    }
    func save(_ error: NSErrorPointer) -> Bool {
        do { try managedObjectContext.save(); return true } catch { return false }
    }
    nonisolated(unsafe) static var open: [DicomDatabase] = []
    class func allDatabases() -> [Any]! { open }
}

final class RemoteDicomDatabase: DicomDatabase {}

final class N2ManagedObjectContext: NSManagedObjectContext {
    weak var database: DicomDatabase?
}

extension NSManagedObject {
    class func uid(forXid xid: String!) -> String! { "x-coredata://" + xid }
    func xid() -> String { String(objectID.uriRepresentation().absoluteString.dropFirst("x-coredata://".count)) }
}

@objc(DicomImage)
final class DicomImage: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var series: DicomSeries!
}

@objc(DicomSeries)
final class DicomSeries: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var images: Set<AnyHashable>!
    @NSManaged var study: DicomStudy!
    @NSManaged var numberOfImages: NSNumber!
    @NSManaged var thumbnail: Data!
}

@objc(DicomStudy)
final class DicomStudy: NSManagedObject {
    @NSManaged var studyInstanceUID: String!
    @NSManaged var series: NSSet!
    @NSManaged var numberOfImages: NSNumber!
    @NSManaged var modality: String!
    func imageSeries() -> NSArray! { NSArray(array: (series?.allObjects as? [DicomSeries] ?? []).filter { !$0.isDeleted }) }
    func modalities() -> String! { "CT" }
}

struct BrowserDatabaseSource {
    var browserDatabase: DicomDatabase?
}

final class BrowserController {
    var database: DicomDatabase?
    init(_ database: DicomDatabase?) { self.database = database }
    func proceedDelete(_ rows: [Any]!) {
        told.append("browser deletes " + (rows ?? []).compactMap { ($0 as? DicomImage)?.name }.joined(separator: ","))
    }
}

final class HarnessWindow {
    let name: String
    init(_ name: String) { self.name = name }
    func close() { told.append("closed " + name) }
}

final class ViewerController {
    let shown: DicomImage
    var window: HarnessWindow?
    init(_ shown: DicomImage) { self.shown = shown; window = HarnessWindow("viewer of " + shown.series.name) }
    func fileList() -> NSMutableArray! { NSMutableArray(array: [shown]) }
    nonisolated(unsafe) static var displayed: [ViewerController] = []
    class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray(array: displayed) }
}

enum ExcludedSeries {
    static func forget(study: String, database: String) { told.append("forget \(study) in \(database)") }
}

final class XMLController {}
'''

DRIVER = r'''
import AppKit
import CoreData

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

let model: NSManagedObjectModel = {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    func relation(_ name: String, _ many: Bool) -> NSRelationshipDescription {
        let relation = NSRelationshipDescription()
        relation.name = name
        relation.minCount = 0
        relation.maxCount = many ? 0 : 1
        relation.deleteRule = .nullifyDeleteRule
        relation.isOptional = true
        return relation
    }
    let image = NSEntityDescription(), series = NSEntityDescription(), study = NSEntityDescription()
    image.name = "Image"; image.managedObjectClassName = NSStringFromClass(DicomImage.self)
    series.name = "Series"; series.managedObjectClassName = NSStringFromClass(DicomSeries.self)
    study.name = "Study"; study.managedObjectClassName = NSStringFromClass(DicomStudy.self)
    let imageSeries = relation("series", false), seriesImages = relation("images", true)
    let seriesStudy = relation("study", false), studySeries = relation("series", true)
    imageSeries.destinationEntity = series; seriesImages.destinationEntity = image
    seriesStudy.destinationEntity = study; studySeries.destinationEntity = series
    imageSeries.inverseRelationship = seriesImages; seriesImages.inverseRelationship = imageSeries
    seriesStudy.inverseRelationship = studySeries; studySeries.inverseRelationship = seriesStudy
    image.properties = [attribute("name", .stringAttributeType), imageSeries]
    series.properties = [attribute("name", .stringAttributeType), attribute("numberOfImages", .integer32AttributeType),
                         attribute("thumbnail", .binaryDataAttributeType), seriesImages, seriesStudy]
    study.properties = [attribute("studyInstanceUID", .stringAttributeType), attribute("numberOfImages", .integer32AttributeType),
                        attribute("modality", .stringAttributeType), studySeries]
    let model = NSManagedObjectModel()
    model.entities = [image, series, study]
    return model
}()

/// A database with a main-queue context over a store of its own; open unless told otherwise.
func database<D: DicomDatabase>(_ made: D, open: Bool = true) -> D {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    _ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.database = made
    made.managedObjectContext = context
    if open { DicomDatabase.open.append(made) }
    return made
}

/// A study of `database` with series of `images` images each, saved; its series.
func study(_ uid: String, in database: DicomDatabase, series names: [String: Int]) -> [String: DicomSeries] {
    let context = database.managedObjectContext!
    let study = DicomStudy(entity: model.entities[2], insertInto: context)
    study.studyInstanceUID = uid
    var made: [String: DicomSeries] = [:]
    for (name, count) in names.sorted(by: { $0.key < $1.key }) {
        let series = DicomSeries(entity: model.entities[1], insertInto: context)
        series.name = name
        series.study = study
        for index in 0..<count {
            let image = DicomImage(entity: model.entities[0], insertInto: context)
            image.name = "\(name)-\(index)"
            image.series = series
        }
        made[name] = series
    }
    try! context.save()
    return made
}

func images(of series: DicomSeries) -> [DicomImage] {
    (series.images as? Set<DicomImage> ?? []).sorted { $0.name < $1.name }
}

@MainActor
func run() {
    let local = database(DicomDatabase("local"))
    let shared = database(RemoteDicomDatabase("shared"))
    let closed = database(DicomDatabase("closed"), open: false)
    let mine = study("1.1", in: local, series: ["L1": 1, "L2": 2])
    let theirs = study("2.1", in: shared, series: ["S1": 1, "S2": 2])
    let gone = study("3.1", in: closed, series: ["C1": 1])

    // A drop of database rows: found in their own database, the browser on either.
    for shown in [local, shared, nil] as [DicomDatabase?] {
        let on = "browser on \(shown?.name ?? "no") database"
        for series in [mine["L2"]!, theirs["S2"]!] {
            let found = viewerDraggedRow(named: series.xid(), shown: shown, open: DicomDatabase.allDatabases())
            check((found as? DicomSeries) === series, "\(on): the dropped series \(series.name) is not found in its own database: \(String(describing: found))")
        }
        let image = images(of: theirs["S2"]!)[1]
        check((viewerDraggedRow(named: image.xid(), shown: shown, open: DicomDatabase.allDatabases()) as? DicomImage) === image,
              "\(on): a dropped image of the shared database is not found")
        check(viewerDraggedRow(named: gone["C1"]!.xid(), shown: shown, open: DicomDatabase.allDatabases()) == nil,
              "\(on): a row of a database no longer open is found")
    }
    check(viewerDraggedRow(named: "not-a-store/Series/p1", shown: local, open: DicomDatabase.allDatabases()) == nil, "an identifier of no store is found")

    // The database the edited files are indexed in: the rows' own one, the browser's for none.
    for browser in [local, shared] {
        let source = BrowserDatabaseSource(browserDatabase: browser)
        let on = "browser on the \(browser.name) database"
        check(XMLController.database(ofEdited: images(of: theirs["S2"]!), image: nil, source: source) === shared,
              "\(on): the files edited from a shared image are not indexed in the shared database")
        check(XMLController.database(ofEdited: nil, image: images(of: mine["L1"]!)[0], source: source) === local,
              "\(on): the files edited from a local image (no rows given) are not indexed in the local database")
        check(XMLController.database(ofEdited: [images(of: mine["L2"]!)[0]], image: images(of: theirs["S1"]!)[0], source: source) === local,
              "\(on): the database of the edited rows does not come before that of the image shown")
        check(XMLController.database(ofEdited: nil, image: nil, source: source) === browser, "\(on): without a row, the browser's database is not used")
    }
    // A row of an independent database of the shared one: its main database.
    let independent = RemoteDicomDatabase("shared independent")
    let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = shared.managedObjectContext.persistentStoreCoordinator
    context.database = independent
    independent.managedObjectContext = context
    independent.mainDatabase = shared
    let row = try! context.existingObject(with: images(of: theirs["S1"]!)[0].objectID) as! DicomImage
    check(XMLController.database(ofEdited: [row], image: nil, source: BrowserDatabaseSource(browserDatabase: local)) === shared,
          "a row of an independent database is not indexed through its main database")

    // The rows an edit replaced, the browser on the local database: the shared study's go in the shared database.
    ViewerController.displayed = [ViewerController(images(of: theirs["S2"]!)[0]), ViewerController(images(of: mine["L2"]!)[0])]
    told = []
    let replaced = images(of: theirs["S2"]!) + images(of: theirs["S1"]!)
    XMLController.removeReplacedRows(replaced, from: shared, browser: BrowserController(local))
    let left = shared.managedObjectContext.registeredObjects.filter { !$0.isDeleted }
    check(told == ["closed viewer of S2", "forget 2.1 in /db/shared"], "the rows of a shared study, browser local: \(told)")
    check(left.isEmpty && (try! shared.managedObjectContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "Image"))) == 0,
          "the shared study's replaced rows, series and study are not removed from the shared database: \(left.count) left")
    check((try! local.managedObjectContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "Image"))) == 3,
          "rows of the local database were touched")

    // Part of a local series, the browser on the shared database: the series keeps its other image and is recounted.
    told = []
    let part = [images(of: mine["L2"]!)[0]]
    XMLController.removeReplacedRows(part, from: local, browser: BrowserController(shared))
    check(told == ["closed viewer of L2"], "the rows of a local study, browser shared: \(told)")
    check(images(of: mine["L2"]!).map(\.name) == ["L2-1"] && mine["L2"]!.numberOfImages == 0 && !mine["L2"]!.isDeleted
          && mine["L2"]!.study.managedObjectContext != nil,
          "the series left with images is not kept and recounted in the local database")
    check(!local.managedObjectContext.hasChanges, "the local database was not saved")

    // The browser shows the database of the rows: its own deletion, as before.
    told = []
    XMLController.removeReplacedRows(images(of: mine["L1"]!), from: local, browser: BrowserController(local))
    check(told == ["browser deletes L1-0"], "the browser does not delete the rows of the database it shows: \(told)")
    check(images(of: mine["L1"]!).count == 1, "the rows were removed besides the browser's deletion")
    print("ok")
}

MainActor.assumeIsolated { run() }
'''


def main():
    failures = source_failures()
    drag = read(DRAG)
    edited = read(EDITED)
    pieces = {
        'viewerDraggedRow': member(drag, 'func viewerDraggedRow(named xid: String'),
        'database(ofEdited:)': member(edited, '    static func database(ofEdited rows: [Any]?'),
        'removeReplacedRows': with_attributes(edited, '    static func removeReplacedRows('),
    }
    for name, body in pieces.items():
        if body is None:
            failures.append('%s is missing: the rows of a viewer are looked up, indexed or removed in the browser\'s database' % name)
    deletion = member((ROOT / 'Modules/IsiXDatabase/Sources/StudyListRowRules.swift').read_text(encoding='utf-8'), 'public enum StudyDeletion {')
    source = member(read('BrowserDatabaseSource.swift'), '    func database(of object: NSManagedObject?) -> DicomDatabase? {')
    if deletion is None or source is None:
        failures.append('StudyDeletion or BrowserDatabaseSource.database(of:) is missing')
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return SKIPPED

    code = ('import AppKit\nimport CoreData\n\n' + pieces['viewerDraggedRow'] + '\n\n' + deletion + '\n\n'
            'extension BrowserDatabaseSource {\n' + source + '\n}\n\n'
            'extension XMLController {\n' + pieces['database(ofEdited:)'] + '\n\n' + pieces['removeReplacedRows'] + '\n}\n')
    with tempfile.TemporaryDirectory(prefix='horos-viewer-rows-own-database-') as directory:
        work = Path(directory)
        files = {'doubles.swift': DOUBLES, 'pieces.swift': code, 'main.swift': DRIVER}
        for name, text in files.items():
            (work / name).write_text(text, encoding='utf-8')
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *(str(work / name) for name in files), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the sources do not compile with their doubles\n' + built.stderr[-3000:])
        else:
            ran = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
            if ran.returncode or ran.stdout.strip() != 'ok':
                failures.append((ran.stdout + ran.stderr).strip()[-1500:].removeprefix('FAIL: '))
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print("rows of a viewer's database: a drop finds them in the open database holding them with the browser on either "
          "database; the files edited from a viewer's image are indexed in the rows' own database, the rows an edit replaced "
          "removed there (by the browser when it shows it), and the patient's studies of a patient-level edit read in the "
          "image's database")
    return 0


if __name__ == '__main__':
    sys.exit(main())
