#!/usr/bin/env python3
"""A shared database's server keeps one annotations SR per study, whoever wrote it.

A client writes a study's annotations SR when the study's comments, status or
key images change, and sends it to the server (SENDG) whichever database its
browser shows. It removes the earlier SRs only from its own copy of the index,
which the next update replaces, and the protocol has no request that removes an
image: the server is the one that has to. When the client also tells the server
the change (SETVA), the server writes an SR of its own; the two arrive in either
order.

The real AnnotationsSRPruning.swift and the real SEND of the server
(O2DatabaseConnection in BonjourPublisher.swift) are compiled here against a
Core Data store of studies, series and images, a double of the indexer and the
real IsiXDatabase (AnnotationsSRSuccession, DatabaseWriterGate) and
IsiXDICOMNetwork (the upload's reply). It is checked that:

- each annotations SR a client sends replaces the study's earlier ones;
- an SR the server writes itself replaces the ones clients sent, and one a
  client sends after it, older, goes in its place, so the study keeps the SR it
  reads back, the most recent one;
- an upload's images of other series and the other SRs (ROI) stay, as do the
  other studies' SRs;
- what a client received elsewhere and forwards (SENDD) is filed as it came.

No app, no network and no DICOM file are needed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]

STAGE = r'''
import CoreData
import Foundation
import IsiXContracts
import IsiXDatabase
import IsiXDICOMNetwork

@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @NSManaged var studyInstanceUID: String?
    @NSManaged var series: NSSet?
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @NSManaged var id: NSNumber?
    @NSManaged var name: String?
    @NSManaged var seriesSOPClassUID: String?
    @NSManaged var images: NSSet?
    @NSManaged var study: DicomStudy?
}

@objc(DicomImage) final class DicomImage: NSManagedObject {
    @NSManaged var pathString: String?
    @NSManaged var date: Date?
    @NSManaged var pathNumber: NSNumber?
    @NSManaged var series: DicomSeries?
    func completePath() -> String? { pathString }
}

func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let a = NSAttributeDescription()
    a.name = name
    a.attributeType = type
    a.isOptional = true
    return a
}

func relate(_ from: NSEntityDescription, _ name: String, _ to: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
    let r = NSRelationshipDescription()
    r.name = name
    r.destinationEntity = to
    r.minCount = 0
    r.maxCount = many ? 0 : 1
    r.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule
    r.isOptional = true
    from.properties.append(r)
    return r
}

func makeModel() -> NSManagedObjectModel {
    let study = NSEntityDescription(), series = NSEntityDescription(), image = NSEntityDescription()
    study.name = "Study"; study.managedObjectClassName = "DicomStudy"
    series.name = "Series"; series.managedObjectClassName = "DicomSeries"
    image.name = "Image"; image.managedObjectClassName = "DicomImage"
    study.properties = [attribute("studyInstanceUID", .stringAttributeType)]
    series.properties = [attribute("id", .integer32AttributeType), attribute("name", .stringAttributeType),
                         attribute("seriesSOPClassUID", .stringAttributeType)]
    image.properties = [attribute("pathString", .stringAttributeType), attribute("date", .dateAttributeType),
                        attribute("pathNumber", .integer64AttributeType)]
    let studySeries = relate(study, "series", series, many: true), seriesStudy = relate(series, "study", study, many: false)
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    let seriesImages = relate(series, "images", image, many: true), imageSeries = relate(image, "series", series, many: false)
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    let model = NSManagedObjectModel()
    model.entities = [study, series, image]
    return model
}

/// The database of the server: a private-queue context over the one store, and
/// the databases of its own that work over that store, which the driver drains.
final class DicomDatabase: NSObject {
    nonisolated(unsafe) static var workers: [DicomDatabase] = []
    let managedObjectContext: NSManagedObjectContext!
    let databaseWriterGate: DatabaseWriterGate

    init(coordinator: NSPersistentStoreCoordinator, gate: DatabaseWriterGate) {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        managedObjectContext = context
        databaseWriterGate = gate
    }

    func privateQueueIndependentDatabase() -> Any! {
        let database = DicomDatabase(coordinator: managedObjectContext.persistentStoreCoordinator!, gate: databaseWriterGate)
        DicomDatabase.workers.append(database)
        return database
    }

    func objects(withIDs ids: [Any]?) -> [Any]! {
        var found: [Any] = []
        managedObjectContext.performAndWait {
            for case let id as NSManagedObjectID in ids ?? [] {
                if let object = try? managedObjectContext.existingObject(with: id) { found.append(object) }
            }
        }
        return found
    }
}

func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) {
    if let context { context.performAndWait(block) } else { block() }
}

enum HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}

enum DicomDatabaseObjC {
    static func log(_ exception: NSException, stack: Bool, _ where: String) {}
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum DICOMSOPClass {
    static func isStructuredReport(_ uid: String?) -> Bool { uid?.hasPrefix("1.2.840.10008.5.1.4.1.1.88.") ?? false }
}

/// The indexer: each file is a line "study|series id|series name|SOP class|seconds", filed in its study and
/// series as the real indexer files an image, numbered by its file's name.
final class DatabaseIngest {
    static let process = DatabaseIngest()
    nonisolated(unsafe) var presets: [String] = []

    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        presets.append(preset.name)
        var added: [NSManagedObject] = []
        let context = database.managedObjectContext!
        context.performAndWait {
            for case let path as String in paths ?? [] {
                let fields = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "|")
                guard fields.count == 5 else { continue }
                let studies = (try? context.fetch(NSFetchRequest<DicomStudy>(entityName: "Study"))) ?? []
                let study = studies.first { $0.studyInstanceUID == fields[0] } ?? {
                    let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
                    s.studyInstanceUID = fields[0]
                    return s
                }()
                let id = NSNumber(value: Int32(fields[1])!)
                let series = (study.series as? Set<DicomSeries>)?.first { $0.id == id && $0.name == fields[2] } ?? {
                    let s = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as! DicomSeries
                    s.id = id; s.name = fields[2]; s.seriesSOPClassUID = fields[3]; s.study = study
                    return s
                }()
                let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
                image.pathString = path
                image.date = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(fields[4])!)
                image.pathNumber = NSNumber(value: Int64(((path as NSString).lastPathComponent as NSString).deletingPathExtension)!)
                image.series = series
                added.append(image)
            }
            try! context.save()
        }
        return added.map(\.objectID)
    }
}

private enum O2Interrupt: Error {
    case invalidRequest(String)
    case exception(NSException)
}

@objc private protocol O2SharedDatabaseImage {
    var pathNumber: NSNumber? { get }
}

/// One request of a client, as the server runs it: the files of the upload saved, then SEND.
final class O2DatabaseConnection {
    private let database: DicomDatabase
    private let _savedFiles: [String]
    private(set) var written: [Data] = []

    init(database: DicomDatabase, savedFiles: [String]) {
        self.database = database
        self._savedFiles = savedFiles
    }

    private func _requestIndexDatabase() throws -> DicomDatabase { database }
    private func writeData(_ data: Data?) { if let data { written.append(data) } }

    func upload(generatedByViewer: Bool) throws { try SEND(generatedByViewer: generatedByViewer) }

@SEND@
}
'''

DRIVER = r'''
import CoreData
import Foundation
import IsiXDatabase

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }

let coordinator = NSPersistentStoreCoordinator(managedObjectModel: makeModel())
try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
let server = DicomDatabase(coordinator: coordinator, gate: DatabaseWriterGate())
let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("sdb-annotations-\(UUID().uuidString)")
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: folder) }

var fileNumber = 0
/// A file of the server's data folder, as the upload saves one.
func file(_ study: String, _ seriesID: Int, _ name: String, _ sop: String, seconds: Int) -> String {
    fileNumber += 1
    let path = (folder as NSString).appendingPathComponent("\(fileNumber).dcm")
    try! "\(study)|\(seriesID)|\(name)|\(sop)|\(seconds)".write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
let srClass = "1.2.840.10008.5.1.4.1.1.88.33", ctClass = "1.2.840.10008.5.1.4.1.1.2"
func annotationsSR(_ study: String = "1.2.3", seconds: Int) -> String { file(study, 5004, "OsiriX Annotations SR", srClass, seconds: seconds) }

/// Every pruning queued so far has run.
func drain() {
    var drained = 0
    while drained < DicomDatabase.workers.count {
        DicomDatabase.workers[drained].managedObjectContext.performAndWait {}
        drained += 1
    }
}

/// The paths of a study's images in `seriesID`, sorted.
func paths(_ study: String = "1.2.3", series seriesID: Int) -> [String] {
    drain()
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    var found: [String] = []
    context.performAndWait {
        let request = NSFetchRequest<DicomImage>(entityName: "Image")
        request.predicate = NSPredicate(format: "series.id == %d AND series.study.studyInstanceUID == %@", seriesID, study)
        found = ((try? context.fetch(request)) ?? []).compactMap(\.pathString).sorted()
    }
    return found
}

func send(_ files: [String], generated: Bool = true) {
    let connection = O2DatabaseConnection(database: server, savedFiles: files)
    do { try connection.upload(generatedByViewer: generated) } catch { failures.append("SEND failed: \(error)") }
    check(connection.written.count == 1, "SEND did not answer once: \(connection.written.count)")
}

// The study on the server: one image series.
_ = DatabaseIngest.process.index((0..<3).map { _ in file("1.2.3", 1, "SER1", ctClass, seconds: 0) }, preset: .listener, in: server)
// Another study with an annotations SR of its own, which nothing here replaces.
let otherStudySR = annotationsSR("9.9.9", seconds: 50)
send([otherStudySR])

// A client's SRs, each after the other: the study keeps the last one.
let first = annotationsSR(seconds: 100)
send([first])
check(paths(series: 5004) == [first], "the first SR a client sent is not the study's one: \(paths(series: 5004))")
let second = annotationsSR(seconds: 200)
send([second])
check(paths(series: 5004) == [second], "a client's second SR did not replace the first one: \(paths(series: 5004))")
let third = annotationsSR(seconds: 210)
send([third])
check(paths(series: 5004) == [third], "a client's third SR did not replace the second one: \(paths(series: 5004))")

// The server writes its own, later (the client told it the change): it replaces the client's.
let own = annotationsSR(seconds: 300)
AnnotationsSRPruning.index(own, written: true, in: server)
check(paths(series: 5004) == [own], "the server's own SR did not replace the client's: \(paths(series: 5004))")

// The client's SR of that change, written before the server's but arriving after it: it goes.
let late = annotationsSR(seconds: 250)
send([late])
check(paths(series: 5004) == [own], "a client's SR older than the server's stayed beside it: \(paths(series: 5004))")

// An upload of a viewer's images with an SR: the images and a ROI SR stay, the SR replaces.
let image = file("1.2.3", 2, "SER2", ctClass, seconds: 400)
let roi = file("1.2.3", 5002, "OsiriX ROI SR", srClass, seconds: 400)
let withImages = annotationsSR(seconds: 400)
send([image, roi, withImages])
check(paths(series: 5004) == [withImages], "the SR of a mixed upload did not replace the earlier one: \(paths(series: 5004))")
check(paths(series: 2) == [image] && paths(series: 5002) == [roi] && paths(series: 1).count == 3,
      "an upload's other images went: \(paths(series: 2)) \(paths(series: 5002)) \(paths(series: 1))")
// Images of other series alone remove nothing.
let alone = file("1.2.3", 2, "SER2", ctClass, seconds: 900)
send([alone])
check(paths(series: 5004) == [withImages] && paths(series: 2) == [image, alone].sorted(),
      "an upload without SR changed the study's SRs: \(paths(series: 5004)) \(paths(series: 2))")

// What a client received elsewhere and forwards is filed as it came.
let forwarded = annotationsSR(seconds: 500)
send([forwarded], generated: false)
check(paths(series: 5004) == [withImages, forwarded].sorted(), "a forwarded SR replaced the study's: \(paths(series: 5004))")

check(paths("9.9.9", series: 5004) == [otherStudySR], "another study's SR went: \(paths("9.9.9", series: 5004))")
check(DatabaseIngest.process.presets.contains("sharedDatabaseGenerated") && DatabaseIngest.process.presets.contains("sharedDatabaseReceived"),
      "the uploads were not indexed with their presets: \(DatabaseIngest.process.presets)")

print(failures.isEmpty ? "ok" : failures.joined(separator: "\n"))
'''


def method(source, signature):
    """The text of the method that starts with `signature`, to its closing brace."""
    start = source.find(signature)
    if start < 0:
        return None
    depth = 0
    for index in range(source.index('{', start), len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[source.rfind('\n', 0, start) + 1:index + 1]
    return None


def main():
    publisher = (root / 'Horos/Sources/BonjourPublisher.swift').read_text(encoding='utf-8')
    send = method(publisher, 'private func SEND(generatedByViewer: Bool) throws {')
    if send is None:
        print('FAIL: BonjourPublisher.swift has no SEND(generatedByViewer:)')
        return 1
    pruning = (root / 'Horos/Sources/AnnotationsSRPruning.swift').read_text(encoding='utf-8')
    if 'import IsiXDICOMFile\n' not in pruning:
        print('FAIL: AnnotationsSRPruning.swift no longer imports IsiXDICOMFile, which the double replaces')
        return 1
    pruning = pruning.replace('import IsiXDICOMFile\n', '')

    with tempfile.TemporaryDirectory(prefix='horos-sdb-annotations-') as directory:
        work = Path(directory)
        (work / 'stage.swift').write_text(STAGE.replace('@SEND@', send))
        (work / 'pruning.swift').write_text(pruning)
        (work / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *isix_modules.module_flags('IsiXContracts', work / 'internal'),
                                *isix_modules.module_flags('IsiXPreferences', work / 'internal'),
                                *isix_modules.module_flags('IsiXDatabase', work / 'internal'),
                                *isix_modules.module_flags('IsiXDICOMNetwork', work / 'internal'),
                                *(str(work / name) for name in ('stage.swift', 'pruning.swift', 'main.swift')),
                                '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=600)
        if built.returncode:
            print('FAIL: the sources do not compile with their doubles\n' + built.stderr[-3000:])
            return 1
        run = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
        if run.returncode or run.stdout.strip() != 'ok':
            print('FAIL:', (run.stdout + run.stderr).strip()[-2000:])
            return 1
    print("shared database: each annotations SR a client sends replaces the study's earlier ones on the server, the "
          "server's own replaces the clients' and a client's older one arriving after it goes, so the study keeps the SR "
          "it reads back; an upload's other images, ROI SRs, other studies' SRs and forwarded files stay")
    return 0


if __name__ == '__main__':
    sys.exit(main())
