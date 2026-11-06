#!/usr/bin/env python3
"""A deletion by hand stores the count of the studies that stay.

Deleting without asking (StudyDeletionJob.proceedDelete, which
-proceedDeleteObjects: sends) resets the count of what it touched, and ended on
`_ = study.noFiles`, which names the method and does not call it: the count stayed
0 until something asked for it, and the albums read it without asking.

The part of proceedDelete after the images are deleted, DicomStudy's noFiles and
series and DicomSeries' noFiles and horosImages are compiled from the sources, over a
real SQLite store, with stand-ins for what is around them. The count is taken after
the save, for until then each of those accessors walks all that was deleted, and in
a large deletion that took more than twice as long; so a study that went, which has
no context by then, must not be asked, and a deletion that could not be saved stores
nothing. The count is read from the file, on a new coordinator.

`<git revision>` as an optional argument reads the sources of that revision, the
negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
START = '            if let raised = HorosObjCException.caught({\n                // Remove series without images !'
# The end before the alert, which read the preference as UserDefaults before
# it read it through the job's preferences.
ENDS = ('\n        if !deletionSaved && !preferences[', '\n        if !deletionSaved && !UserDefaults')
JOB = 'Horos/Sources/StudyDeletionJob.swift'
FORMER = 'Horos/Sources/BrowserController+Deletion.swift'


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else None
    return (root / path).read_text(encoding='utf-8') if (root / path).exists() else None


def member(source, signature):
    """The declaration that starts with `signature`, up to its closing brace."""
    at = source.index(signature)
    depth, index = 0, source.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


# The deletion moved from the browser to StudyDeletionJob; an earlier revision has it in the browser.
deletion = read(JOB)
if deletion is None or START not in deletion:
    deletion = read(FORMER)
study = read('Horos/Sources/DicomStudy.swift')
series = read('Horos/Sources/DicomSeries.swift')
END = next((end for end in ENDS if deletion and end in deletion), None)
if deletion is None or START not in deletion or END is None:
    sys.exit('FAIL: the deletion in StudyDeletionJob.swift changed shape; this test is stale')
tail = deletion[deletion.index(START):deletion.index(END)]

HARNESS = r'''
import CoreData
import Foundation

func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) {
    if let context { context.performAndWait(block) } else { block() }
}
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: String) { print("exception:", e) }
enum DICOMSOPClass {
    static func isStructuredReport(_ uid: String?) -> Bool { uid == "SR" }
    static func isPresentationState(_ uid: String?) -> Bool { uid == "PR" }
    static func isSupportedPrivateClasses(_ uid: String?) -> Bool { uid == "PRIVATE" }
}
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

enum BrowserObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ e: NSException, stack: Bool, _ function: String) { print("exception:", e) }
}
enum ExcludedSeries { static func forget(study: String, database: String) {} }
func described(_ value: Any?) -> String { "\(value ?? "(null)")" }
func dicomStudyOnQueue<T>(_ context: NSManagedObjectContext?, _ body: () -> T) -> T {
    var result: T?
    N2ManagedObjectContextPerformAndWait(context) { result = body() }
    return result!
}
func dicomStudyTry(_ function: String, _ body: () -> Void) { body() }
func dicomStudyValue(_ object: Any?, _ key: String) -> Any? { (object as AnyObject?)?.value(forKey: key) }
func dicomSeriesTry(_ body: () -> Void) -> NSException? { body(); return nil }
func dicomSeriesIntValue(_ object: Any?) -> Int32 { (object as? NSNumber)?.int32Value ?? 0 }

@objc(DicomImage) final class DicomImage: NSManagedObject {
    @NSManaged var numberOfFrames: NSNumber?
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @NSManaged var numberOfImages: NSNumber!
    @NSManaged var thumbnail: Data!
    @NSManaged var seriesSOPClassUID: String?
    @NSManaged var name: String?
    var images: NSSet? { return horosImages() }
    //SERIES
}

@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @NSManaged var name: String?
    @NSManaged var numberOfImages: NSNumber!
    @NSManaged var modality: String?
    var patientUID: String? { nil }
    var patientID: String? { name }
    var studyInstanceUID: String? { name }
    @objc func modalities() -> String { "CT" }
    func imageSeries() -> NSArray? {
        NSArray(array: (series?.allObjects ?? []).filter { ($0 as? DicomSeries)?.seriesSOPClassUID != "SR" })
    }
    //STUDY
}

final class Database {
    var dataBaseDirPath: String? = nil
    var saves: (() throws -> Void)
    init(saves: @escaping () throws -> Void) { self.saves = saves }
    func save(_ failure: NSErrorPointer) -> Bool {
        do { try saves(); return true } catch { failure?.pointee = error as NSError; return false }
    }
}

final class Browser {
    // The tail reads the browser as the job does, and as the browser itself did.
    var browser: Browser { self }
    var comparativePatientUID: String? = nil
    var horos_previousItem: Any? = nil
    func finish(_ seriesSet: NSSet, _ studiesSet: NSSet, context: NSManagedObjectContext?, saves: @escaping () throws -> Void) {
        let database: Database? = Database(saves: saves)
        let objectsToDelete: [Any]? = []
        var refreshComparative = false
        var saveError: NSError?
        var deletionSaved = false
        N2ManagedObjectContextPerformAndWait(context) {
        //TAIL
        _ = refreshComparative
    }
}

func model() -> NSManagedObjectModel {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    func relationship(_ name: String, to destination: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
        let relationship = NSRelationshipDescription()
        relationship.name = name
        relationship.destinationEntity = destination
        relationship.minCount = 0
        relationship.maxCount = many ? 0 : 1
        relationship.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule
        return relationship
    }
    func entity(_ name: String, _ objectClass: String) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = objectClass
        return entity
    }
    let study = entity("Study", "DicomStudy"), series = entity("Series", "DicomSeries"), image = entity("Image", "DicomImage")
    let studySeries = relationship("series", to: series, many: true), seriesStudy = relationship("study", to: study, many: false)
    let seriesImages = relationship("images", to: image, many: true), imageSeries = relationship("series", to: series, many: false)
    studySeries.inverseRelationship = seriesStudy
    seriesStudy.inverseRelationship = studySeries
    seriesImages.inverseRelationship = imageSeries
    imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("name", .stringAttributeType), attribute("numberOfImages", .integer32AttributeType), attribute("modality", .stringAttributeType), studySeries]
    series.properties = [attribute("name", .stringAttributeType), attribute("numberOfImages", .integer32AttributeType), attribute("thumbnail", .binaryDataAttributeType),
                         attribute("seriesSOPClassUID", .stringAttributeType), seriesStudy, seriesImages]
    image.properties = [attribute("numberOfFrames", .integer32AttributeType), imageSeries]
    let model = NSManagedObjectModel()
    model.entities = [study, series, image]
    return model
}

func open(_ path: String, _ model: NSManagedObjectModel) -> NSManagedObjectContext {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: path), options: nil)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
}

let path = CommandLine.arguments[1]
let schema = model()
let context = open(path, schema)
context.performAndWait {
    func add(_ name: String, _ seriesOf: [(String, String?, Int, Int32)]) -> DicomStudy {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
        study.name = name
        for (seriesName, uid, count, frames) in seriesOf {
            let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as! DicomSeries
            series.name = seriesName
            series.seriesSOPClassUID = uid
            series.setValue(study, forKey: "study")
            for _ in 0..<count {
                let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
                image.numberOfFrames = NSNumber(value: frames)
                image.setValue(series, forKey: "series")
            }
            series.numberOfImages = NSNumber(value: frames > 1 ? 0 - Int32(count) : Int32(count))
        }
        study.numberOfImages = NSNumber(value: seriesOf.filter { $0.1 != "SR" }.reduce(Int32(0)) { $0 + Int32($1.2) })
        return study
    }
    // KEEP loses an image of K1 and all of K3; K2 is untouched, and the report in
    // KEEP-SR is not counted. FRAMES keeps one multi-frame image of two. WHOLE goes.
    // REFUSED is a deletion the store does not take: it stays as it was.
    let keep = add("KEEP", [("K1", "CT", 3, 1), ("K2", "CT", 2, 1), ("K3", "CT", 1, 1), ("KEEP-SR", "SR", 1, 1)])
    let frames = add("FRAMES", [("F1", "CT", 2, 5)])
    let whole = add("WHOLE", [("W1", "CT", 2, 1)])
    let refused = add("REFUSED", [("R1", "CT", 2, 1)])
    try! context.save()

    func series(_ study: DicomStudy, _ name: String) -> DicomSeries {
        return (study.value(forKey: "series") as! NSSet).allObjects.compactMap { $0 as? DicomSeries }.first { $0.name == name }!
    }
    func images(_ series: DicomSeries) -> [NSManagedObject] { return (series.value(forKey: "images") as! NSSet).allObjects as! [NSManagedObject] }
    let k1 = series(keep, "K1"), k3 = series(keep, "K3"), f1 = series(frames, "F1"), w1 = series(whole, "W1")
    for image in [images(k1).first!] + images(k3) + [images(f1).first!] + images(w1) { context.delete(image) }
    Browser().finish(NSSet(array: [k1, k3, f1, w1]), NSSet(array: [keep, frames, whole]), context: context) { try context.save() }
    print("left unsaved:", context.hasChanges)

    let r1 = series(refused, "R1")
    context.delete(images(r1).first!)
    Browser().finish(NSSet(array: [r1]), NSSet(array: [refused]), context: context) { throw NSError(domain: "store", code: 1) }
    print("left unsaved:", context.hasChanges)
}

// What the file holds, as the albums will read it.
let reading = open(path, schema)
reading.performAndWait {
    for row in try! reading.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study")) {
        print("study", row.value(forKey: "name") as! String, row.value(forKey: "numberOfImages") as? NSNumber ?? -1)
    }
    for row in try! reading.fetch(NSFetchRequest<NSManagedObject>(entityName: "Series")) {
        print("series", row.value(forKey: "name") as! String, row.value(forKey: "numberOfImages") as? NSNumber ?? -1)
    }
}
'''

source = HARNESS.replace('//SERIES', member(series, 'public func horosImages()') + '\n' + member(series, '@objc public func noFiles()')) \
                .replace('//STUDY', member(study, '@objc public dynamic var series: NSSet!') + '\n' + member(study, '@objc public dynamic func noFiles()')) \
                .replace('//TAIL', tail)

EXPECTED = {
    # K1 2 + K2 2; K3 went, and the report does not count.
    'study KEEP 4',
    # Multi-frame images are stored negative, and the albums read the absolute value.
    'study FRAMES -1',
    'series K1 2', 'series K2 2', 'series F1 -1',
    # Not saved: as it was, and the image is there.
    'study REFUSED 2', 'series R1 2',
}
with tempfile.TemporaryDirectory(prefix='horos-deletion-count-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(source, encoding='utf-8')
    # With the rules the deletion asks (StudyDeletion, ComparativeHistory), as the module has them.
    rules = root / 'Modules/IsiXDatabase/Sources/StudyListRowRules.swift'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(folder / 'main.swift'), str(rules), '-o', str(folder / 'test')],
                           capture_output=True, text=True, timeout=200)
    if built.returncode:
        sys.exit('FAIL: does not compile:\n' + built.stderr[-2500:])
    run = subprocess.run([str(folder / 'test'), str(folder / 'index.sql')], capture_output=True, text=True, timeout=30)
    if run.returncode:
        sys.exit('FAIL: the harness stopped: ' + (run.stderr or run.stdout)[-1500:])

found = set(run.stdout.splitlines())
failures = [f'not stored: {line}' for line in sorted(EXPECTED - found)]
failures += [f'still in the index: {line}' for line in sorted(found) if line.split()[1] in ('WHOLE', 'K3', 'W1')]
if 'left unsaved: true' in found:
    failures.append('the count was left in the context, not in the file')
if 'where study.managedObjectContext != nil' not in tail:
    failures.append('a study that went is still asked for its count')
if failures:
    print('FAIL:', *failures, sep='\n  ')
    print('found:', *sorted(found), sep='\n  ')
    sys.exit(1)
print('PASS: the deletion stores the count of the studies that stay, without what it deleted')
