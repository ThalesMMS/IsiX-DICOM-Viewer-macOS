#!/usr/bin/env python3
"""A key image marked on an image a shared database has just added reaches the server.

A RemoteDicomDatabase indexes in a local copy of the server's index, replaced at
each update. An image it adds is a record of that copy alone: marking it there
is gone at the next update, and `object(_:setValue:forKey:)`, which names an
object by its identifier in the index, would name with that record's identifier
no image of the server's, or another one the server numbered the same.

The real GeneratedSeriesImport.swift (the export's mark, `afterExportMarkThemAsKeyImages`),
the real key image capture of ViewerImageExporter.swift (its section, in a
double of the exporter) and the
real members of RemoteDicomDatabase.swift that mark and send are compiled here
against a double of the indexer, of the upload and of the server, whose index
and the client's copies share one store identifier, as a downloaded copy does.
It is checked, for both ways in, that:

- the image is marked in the copy at once, and no request names it before the
  server has it, so no other image of the server's is marked;
- an update whose index lacks the image (its upload has not arrived) sends
  nothing and keeps the mark waiting;
- the update whose index has it sends SETVA isKeyImage with the identifier the
  server knows, and marks the image in the new copy;
- a SETVA the server does not answer leaves the mark for the next update;
- what was sent is not sent again.

And that the capture of a viewer of the shared database, while the browser
shows another database, is written in the shared database's data folder and
indexed there, not in the folder of the database shown; and that a viewer whose
study has no database writes nothing. The real windows state SR of DicomStudy.swift
(writeWindowsStateAsDICOMSR, which saving the windows state as a DICOM SR reaches)
is compiled against a double of the SR: for a study of the shared database it is
written in the shared database's data folder and indexed there, nothing in the
local folder or index, with the browser on the local database or on the shared
one; a study without a database of its own takes the browser's; without any
database it fails as it did and writes nothing; an SR not written is not indexed.
The real annotations SR and report SR of DicomStudy.swift (archiveAnnotationsAsDICOMSR,
archiveReportAsDICOMSR, which a study's comments, status and report reach) and the
helpers they call are compiled against doubles of the SR, of the annotations' pruning
and of the report's indexing: for a study of the shared database each is written in
the shared database's data folder and indexed there - the annotations SR to replace
the earlier ones, the report SR as the report's copy, again over its earlier file -
nothing in the local folder or index and no scratch database, with the browser on
the local database or on the shared one; off the main thread the annotations SR is
indexed through a database of its own over the study's store; an annotations SR not
written is not indexed; without any database nothing is written and the report says
so. The real validated report's DICOM PDF of DicomStudy+Report.swift (archiveValidatedReportAsDICOMPDF,
which setting the status to validated reaches) is compiled against a double of the
conversion: for a study of the shared database it is written in the shared database's
data folder and indexed there, nothing in the local folder or index and no scratch
database, with the browser on the local database or on the shared one, and the report
closes once its PDF is in the study; off the main thread it is indexed through a database
of its own over the study's store; a conversion that fails or writes no file indexes
nothing, closes nothing and is said; without any database nothing is written and it is
said. The real BrowserKeyImages.remoteDatabase(of:) of ViewerController+KeyImages.swift
(which the key image check box, shortcut, all, none and the images with ROIs ask for each
file they mark), through the real RemoteDicomDatabase.database(of:), names, for an image
the server already has, the shared database of the image whichever database the browser shows - marking and unmarking it reach the server -
the main database for a context of an independent one, and none for an image of a local
database or an object of no database; and that the save those actions ask after marking
(BrowserKeyImages.saveDatabases(of:)) saves the shared database of the images, once, and not
the local one the browser shows, each of two databases once, and nothing for an object of no
database. And that -updateOnMainThread: hands the
new index to the marks before it tells the browser of it. No app, no network and no DICOM file are needed.
"""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


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


SUPPORT_H = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
extern NSString * const HorosObjCExceptionKey;
extern NSString * const DicomDatabaseImageEntityName;
@interface HorosObjCException : NSObject
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error NS_SWIFT_NAME(perform(_:));
@end
/// A managed database: its save, as the key images ask it, saves its context
/// and counts.
@interface N2ManagedDatabase : NSObject
@property (strong) NSManagedObjectContext *managedObjectContext;
@property (readonly) NSInteger saves;
/// As the Swift database declares it: an error out-parameter, not a throw.
- (BOOL)save:(NSError **)err NS_SWIFT_NOTHROW;
@end
/// The database as its header declares what these sources ask of it.
@interface DicomDatabase : N2ManagedDatabase
@property (strong) id mainDatabase;
@property (copy) NSString *dataFolder;
+ (DicomDatabase *)databaseForContext:(NSManagedObjectContext *)c;
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)ext;
- (BOOL)isMainDatabase;
- (id)objectWithID:(id)oid;
- (NSArray *)objectsWithIDs:(NSArray *)objectIDs;
/// One over the same store and folder, whose main database is this one.
- (id)privateQueueIndependentDatabase;
@end
/// The context of a database, which knows that database.
@interface N2ManagedObjectContext : NSManagedObjectContext
@property (weak) N2ManagedDatabase *database;
@end
'''

SUPPORT_M = r'''
#import "Support.h"
NSString * const HorosObjCExceptionKey = @"exception";
NSString * const DicomDatabaseImageEntityName = @"Image";
@implementation HorosObjCException
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try { block(); return YES; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain: @"double" code: 1 userInfo: @{HorosObjCExceptionKey: exception}];
        return NO;
    }
}
@end
@implementation N2ManagedDatabase {
    NSInteger _saves;
}
- (NSInteger)saves { return _saves; }
- (BOOL)save:(NSError **)err {
    _saves++;
    return [self.managedObjectContext save: err];
}
@end
/// The one main database of the double answers for every context.
static DicomDatabase *mainOne = nil;
@implementation DicomDatabase
- (instancetype)init { if ((self = [super init]) && !mainOne) mainOne = self; return self; }
+ (DicomDatabase *)databaseForContext:(NSManagedObjectContext *)c { return mainOne; }
- (BOOL)isMainDatabase { return self.mainDatabase == nil; }
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)ext {
    static long next = 0;
    next++;
    return [NSString stringWithFormat: @"%@/%ld.%@", self.dataFolder, next, ext];
}
- (id)objectWithID:(id)oid { return [self.managedObjectContext objectWithID: oid]; }
- (NSArray *)objectsWithIDs:(NSArray *)objectIDs {
    NSMutableArray *objects = [NSMutableArray array];
    for (id oid in objectIDs) [objects addObject: [self.managedObjectContext objectWithID: oid]];
    return objects;
}
- (id)privateQueueIndependentDatabase {
    DicomDatabase *independent = [[[self class] alloc] init];
    independent.managedObjectContext = self.managedObjectContext;
    independent.dataFolder = self.dataFolder;
    independent.mainDatabase = self;
    return independent;
}
@end
@implementation N2ManagedObjectContext
@end
'''

# What the real sources ask of the parts of the application not brought here.
STAGE = r'''
import AppKit
import CoreData
import Synchronization
import IsiXContracts
import IsiXPreferences

func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ body: () -> Void) {
    if let context { context.performAndWait(body) } else { body() }
}

/// The exceptions logged: where, and their reason.
enum Logged { nonisolated(unsafe) static var reasons: [String] = [] }
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ place: String) {
    Logged.reasons.append(place + ": " + (exception.reason ?? exception.name.rawValue))
}

extension HorosObjCException {
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool {
        do { try perform(body); return false } catch { return true }
    }

    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T {
        var result: T?
        var thrown: Error?
        do {
            try perform { do { result = try body() } catch { thrown = error } }
        } catch {
            throw failure(((error as NSError).userInfo[HorosObjCExceptionKey] as? NSException)
                          ?? NSException(name: .genericException, reason: nil, userInfo: nil))
        }
        if let thrown { throw thrown }
        return result!
    }
}

final class DicomImage: NSManagedObject {
    @NSManaged var compressedSopInstanceUID: Data!
    @NSManaged var frameID: NSNumber!
    @NSManaged var instanceNumber: NSNumber!
    @NSManaged var storedIsKeyImage: NSNumber?

    /// As in the application for a database that is not local: the stored value.
    @objc(setIsKeyImage:)
    func setIsKey(_ f: NSNumber!) { storedIsKeyImage = (f?.boolValue ?? false) ? f : nil }

    /// Every image is one of the study's.
    var series: DicomSeries? { DicomSeries(study: DicomStudy()) }
}

final class DicomSeries: NSObject {
    var name: String?
    var images: NSSet?
    var seriesDICOMUID: String?
    var id: NSNumber?
    var study: DicomStudy?
    override init() {}
    init(study: DicomStudy) { self.study = study }
}

final class DicomStudy: NSObject {
    var series: NSSet? = NSSet()
    var managedObjectContext: NSManagedObjectContext?
    var name: String! = "STUDY"
    var windowsState: Data! = Data("state".utf8)
    var hasDICOM: NSNumber? = NSNumber(value: true)
    /// What annotationsAsDictionary answers.
    var annotations: NSDictionary = [:]
    var reportURL: String!
    static let uid = "STUDY-UID"
    var studyInstanceUID: String! = DicomStudy.uid
    /// The study's report SR, once it has one.
    var reportSR: ReportSR?
    /// What the conversion of the validated report to a DICOM PDF does.
    enum Conversion { case writes, fails, writesNothing }
    var conversion = Conversion.writes
    nonisolated(unsafe) static var pdfsWritten: [String] = []
    /// The report as a DICOM PDF at `path`: a file there, an error, or nothing.
    func writeReportAsDicom(atPath path: String?) throws {
        switch conversion {
        case .fails: throw StudyDocumentError.named(NSExceptionName("Conversion"), "Pages could not export the report as PDF.")
        case .writesNothing: return
        case .writes:
            guard let path else { throw StudyDocumentError.named(NSExceptionName("Conversion"), "no path") }
            try Data("pdf".utf8).write(to: URL(fileURLWithPath: path))
            DicomStudy.pdfsWritten.append(path)
        }
    }
    static let avoidReentry = Atomic<Int>(0)
    static let avoidReentry2 = Atomic<Int>(0)
    func archivedSRReferenceImage() -> DicomImage! { nil }
    func annotationsSRImage() -> NSObject? { nil }
    func annotationsAsDictionary() -> NSDictionary! { annotations }
    func reportImage() -> ReportSR? { reportSR }
    func setPrimitiveValue(_ value: Any?, forKey key: String) {}
}

/// A report SR of the index, as the archive reads it.
final class ReportSR: NSObject {
    @objc let completePathResolved: String?
    @objc var completePath: String? { completePathResolved }
    init(_ path: String) { completePathResolved = path }
}

func dicomStudyArg(_ object: Any?) -> CVarArg {
    return (object as AnyObject?) as? NSObject ?? ("(null)" as NSString)
}

/// The SRs a study archives: records where each kind is written, writes nothing on disk.
final class SRAnnotation: NSObject {
    /// The windows state SRs.
    nonisolated(unsafe) static var written: [String] = []
    nonisolated(unsafe) static var annotationsWritten: [String] = []
    nonisolated(unsafe) static var reportsWritten: [String] = []
    var state: Data?
    var kind = "read"
    /// Annotations that ask for a failed write.
    var fails = false
    init!(windowsState dict: Data!, path: String!, for im: DicomImage!) { state = dict; kind = "windows state" }
    init!(dictionary dict: [AnyHashable: Any]!, path: String!, for im: DicomImage!) { kind = "annotations"; fails = dict?["fail"] != nil }
    init!(fileReport file: String!, path: String!, for im: DicomImage!, contentDate d: Date!) { kind = "report" }
    init!(urlReport s: String!, path: String!, for im: DicomImage!) { kind = "report" }
    /// An SR read back: never the one asked for, so each archive writes again.
    init!(contentsOfFile path: String!) {}
    func annotations() -> [AnyHashable: Any]! { nil }
    func reportURL() -> String! { nil }
    func dataEncapsulated() -> Data! { nil }
    func writeToFile(atPath path: String!) -> Bool {
        guard let path else { return false }
        switch kind {
        case "windows state":
            guard state != nil else { return false }
            SRAnnotation.written.append(path)
        case "annotations":
            guard !fails else { return false }
            SRAnnotation.annotationsWritten.append(path)
        case "report":
            SRAnnotation.reportsWritten.append(path)
        default:
            return false
        }
        return true
    }
}

enum StudyDocumentError: Error {
    case named(NSExceptionName, String)
    case raised(NSException)
    case failed(String)
    static func exception(of error: Error) -> NSException {
        switch error as? StudyDocumentError {
        case .named(let name, let reason)?: return NSException(name: name, reason: reason, userInfo: nil)
        case .failed(let reason)?: return NSException(name: .genericException, reason: reason, userInfo: nil)
        case .raised(let exception)?: return exception
        case nil: return NSException(name: .genericException, reason: "\(error)", userInfo: nil)
        }
    }
}

struct PreferencesSource {
    static let process = PreferencesSource()
    var preferences: Defaults { ProcessGraph.process.defaults }
    var processGraph: ProcessGraph { ProcessGraph.process }
}

/// The notifications the person was given: their title and description.
final class UserNotifications: @unchecked Sendable {
    var posted: [(title: String, description: String)] = []
    func post(title: String, description: String, name: String) { posted.append((title, description)) }
}

/// The reports closed in Pages once their PDF is in the study.
enum PagesPDFConversion {
    nonisolated(unsafe) static var closed: [String] = []
    static func closeValidatedReport(at path: String) { closed.append(path) }
}

extension FileManager {
    func tmpDirectoryPathInTmp() -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("report-" + UUID().uuidString)
        try? createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

enum ReportAttachment {
    static func isOnVolumeThatIsOut(_ path: String?, fileExists: (String) -> Bool) -> Bool { false }
}

/// The report SRs indexed as copies of their report.
enum ReportArchiveIndexing {
    nonisolated(unsafe) static var paths: [String] = []
    static func indexing(_ path: String?, _ body: () -> Void) {
        if let path { paths.append(path) }
        body()
    }
}

/// The annotations SRs indexed: where, in which database, on which thread.
enum AnnotationsSRPruning {
    nonisolated(unsafe) static var indexed: [(path: String, database: DicomDatabase, onMain: Bool)] = []
    static func index(_ path: String?, written: Bool, in database: DicomDatabase?) {
        guard let path, let database else { return }
        indexed.append((path, database, Thread.isMainThread))
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            _ = DatabaseIngest.process.index([path], preset: .generatedQuiet, in: database)
        }
    }
}

/// The database of a model object: its context's, the browser's without one.
struct BrowserDatabaseSource {
    static let process = BrowserDatabaseSource()
    func database(of object: DicomStudy?) -> DicomDatabase? {
        object?.managedObjectContext.flatMap { DicomDatabase(for: $0) } ?? ProcessGraph.process.browserDatabase
    }
}

final class AppController {
    private static let one = AppController()
    static func shared() -> AppController? { one }
    func playGrabSound() {}
}

enum ScreenCaptureSeriesName { static func current() -> String { "IsiX Screen Captures" } }

enum IsiXDCMTKTagEditor {
    static func replaceStringValues(_ values: [NSNumber: String], inFileAtPath path: String) throws {}
}

@MainActor
class ViewerController: NSObject {
    var study: DicomStudy?
    /// Where each capture was written.
    var written: [String?] = []
    func currentStudy() -> DicomStudy! { study }
}

final class BrowserController: NSObject {
    var database: DicomDatabase?
    func selectServer(_ objects: [Any]!) {}
    /// The report's archive: a copy of the file.
    class func encryptFileOrFolder(_ path: String!, inZIPFile zip: String!, password: String!, deleteSource: Bool, showGUI: Bool) {
        try? FileManager.default.copyItem(atPath: path, toPath: zip)
    }
}

final class Defaults: PreferenceStore, @unchecked Sendable {
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Bool }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}

final class ProcessGraph: @unchecked Sendable {
    static let process = ProcessGraph()
    let browser = BrowserController()
    let defaults = Defaults()
    let userNotifications = UserNotifications()
    @MainActor var currentBrowser: BrowserController? { browser }
    @MainActor var appController: AppController? { AppController.shared() }
    var browserDatabase: DicomDatabase? { browser.database }
    var preferences: Defaults { defaults }
    var databaseIngest: DatabaseIngest { DatabaseIngest.process }
}

/// The server: its index, in a store whose identifier the client's copies share.
enum Server {
    static let identifier = "SERVER-INDEX"
    nonisolated(unsafe) static var context: NSManagedObjectContext!
    /// The files whose upload left the client and has not arrived: their SOP instances.
    nonisolated(unsafe) static var uploading: [Data] = []
    /// The SETVA requests that reached the server: the object named, the value, the key.
    nonisolated(unsafe) static var setva: [(uri: String, value: String, key: String)] = []
    /// Whether each next request is answered; answered once this is empty.
    nonisolated(unsafe) static var outcomes: [Bool] = []

    static let model: NSManagedObjectModel = {
        let entity = NSEntityDescription()
        entity.name = "Image"
        entity.managedObjectClassName = NSStringFromClass(DicomImage.self)
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let description = NSAttributeDescription()
            description.name = name
            description.attributeType = type
            description.isOptional = true
            return description
        }
        entity.properties = [attribute("compressedSopInstanceUID", .binaryDataAttributeType), attribute("frameID", .integer32AttributeType),
                             attribute("instanceNumber", .integer32AttributeType), attribute("storedIsKeyImage", .booleanAttributeType)]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    static func newIndex() -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        store.identifier = identifier
        let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    @discardableResult
    static func insert(_ uid: String, in context: NSManagedObjectContext) -> DicomImage {
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
        image.compressedSopInstanceUID = Data(uid.utf8)
        image.frameID = 0
        try! context.save()
        return image
    }

    static func images(_ context: NSManagedObjectContext) -> [DicomImage] {
        let request = NSFetchRequest<DicomImage>(entityName: "Image")
        return try! context.fetch(request).sorted { $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString }
    }

    static func image(_ uid: String, _ context: NSManagedObjectContext) -> DicomImage? {
        images(context).first { $0.compressedSopInstanceUID == Data(uid.utf8) }
    }

    /// The uploads arrive: the server indexes them.
    static func receiveUploads() {
        for uid in uploading { insert(String(decoding: uid, as: UTF8.self), in: context) }
        uploading = []
    }

    /// A copy of the index, as an update downloads it.
    static func copy() -> NSManagedObjectContext {
        let copy = newIndex()
        for image in images(context) {
            let copied = insert(String(decoding: image.compressedSopInstanceUID, as: UTF8.self), in: copy)
            copied.storedIsKeyImage = image.storedIsKeyImage
            try! copy.save()
        }
        let same = images(copy).map { $0.objectID.uriRepresentation() } == images(context).map { $0.objectID.uriRepresentation() }
        if !same { print("FAIL: the double's copy does not number the images as the server"); exit(1) }
        return copy
    }

    /// What the server does with a request: SETVA as BonjourPublisher does, VERSI answers its date.
    static func answer(_ request: Data) -> NSData? {
        if !outcomes.isEmpty && !outcomes.removeFirst() { return nil }
        let command = String(decoding: request.prefix(5), as: UTF8.self)
        if command == "VERSI" {
            var date = UInt64(1).bigEndian
            return NSData(bytes: &date, length: 8)
        }
        guard command == "SETVA" else { return NSData() }
        var at = request.startIndex + 6
        func string() -> String {
            let length = Int(request[at]) << 24 | Int(request[at + 1]) << 16 | Int(request[at + 2]) << 8 | Int(request[at + 3])
            at += 4
            defer { at += length }
            return String(decoding: request[at..<(at + length - 1)], as: UTF8.self)
        }
        let (uri, value, key) = (string(), string(), string())
        setva.append((uri, value, key))
        if key == "isKeyImage", let url = URL(string: uri),
           let id = context.persistentStoreCoordinator!.managedObjectID(forURIRepresentation: url),
           let item = try? context.existingObject(with: id) as? DicomImage {
            item.storedIsKeyImage = (Int(value) ?? 0) != 0 ? NSNumber(value: true) : nil
            try! context.save()
        }
        return NSData(bytes: [UInt8](repeating: 0, count: 4), length: 4)
    }
}

/// The single entry: indexes each file as an image in the database's copy, and
/// the upload, which the override starts, leaves for the server.
struct DatabaseIngest {
    static let process = DatabaseIngest()
    /// The database it indexed in last.
    nonisolated(unsafe) static var last: DicomDatabase?
    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        DatabaseIngest.last = database
        var objectIDs: [Any] = []
        for case let path as String in paths ?? [] {
            let uid = "uid-" + (path as NSString).lastPathComponent
            objectIDs.append(Server.insert(uid, in: database.managedObjectContext).objectID)
            Server.uploading.append(Data(uid.utf8))
        }
        return objectIDs
    }
}

final class RemoteDicomDatabase: DicomDatabase {
    var _timestamp: TimeInterval = 0

@WAITING_PROPERTY@

    func synchronousRequest(_ request: NSData?, urgent now: Bool) -> NSData? {
        Server.answer((request ?? NSData()) as Data)
    }

    func sendRequest(_ request: NSData?, urgent: Bool) throws -> NSData? {
        Server.answer((request ?? NSData()) as Data)
    }

    /// An update: the downloaded index, handed to the marks as -updateOnMainThread: does.
    func update() {
        let context = Server.copy()
        (context as? N2ManagedObjectContext)?.database = self
        managedObjectContext = context
        markWaitingKeyImages(in: context)
    }

@REMOTE_MEMBERS@
}

@REMOTE_FUNCTIONS@
'''

DRIVER = r'''
import AppKit
import CoreData

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

@MainActor
func marked(_ uid: String, _ context: NSManagedObjectContext) -> Bool {
    Server.image(uid, context)?.storedIsKeyImage?.boolValue == true
}

@MainActor
func run() {
    Server.context = Server.newIndex()
    Server.insert("uid-before", in: Server.context)
    let database = RemoteDicomDatabase()
    database.dataFolder = "/remote/DATABASE.noindex"
    database.managedObjectContext = Server.copy()
    (database.managedObjectContext as? N2ManagedObjectContext)?.database = database
    ProcessGraph.process.browser.database = database
    ProcessGraph.process.defaults.values["afterExportMarkThemAsKeyImages"] = true

    // --- the export -------------------------------------------------------------------
    // Another client adds an image meanwhile: the server numbers it as the copy
    // numbers what this one adds.
    Server.insert("uid-other", in: Server.context)
    GeneratedSeriesImport.process.add(["/exports/export.dcm"])
    check(marked("uid-export.dcm", database.managedObjectContext), "the export's image is not marked in the copy")
    check(Server.image("uid-other", Server.context)?.objectID.uriRepresentation() == Server.image("uid-export.dcm", database.managedObjectContext)?.objectID.uriRepresentation(),
          "the double does not give the added image the identifier of the server's other image")
    check(Server.setva.isEmpty, "a mark was sent before the server had the image: \(Server.setva)")
    Server.receiveUploads()
    database.update()
    check(marked("uid-export.dcm", Server.context), "the export's mark did not reach the server: \(Server.setva)")
    check(!marked("uid-other", Server.context) && !marked("uid-before", Server.context), "another image of the server was marked")
    check(Server.setva.count == 1 && Server.setva[0].key == "isKeyImage" && Server.setva[0].value == "1",
          "the export's mark went as \(Server.setva)")
    check(marked("uid-export.dcm", database.managedObjectContext), "the new copy does not show the export's mark")
    database.update()
    check(Server.setva.count == 1, "the export's mark was sent again")

    // --- the key image capture --------------------------------------------------------------
    Server.setva = []
    let viewer = ViewerController()
    let study = DicomStudy()
    study.managedObjectContext = database.managedObjectContext
    viewer.study = study
    // The browser shows the local database: the capture of the shared study is
    // written in the shared database's folder, not in the one shown.
    let local = DicomDatabase()
    local.dataFolder = "/local/DATABASE.noindex"
    ProcessGraph.process.browser.database = local
    ViewerImageExporter(viewer: viewer).captureKeyImage()
    ProcessGraph.process.browser.database = database
    check(viewer.written.count == 1 && (viewer.written[0] ?? "").hasPrefix("/remote/DATABASE.noindex/"),
          "the capture was not written in the folder of its study's database: \(viewer.written)")
    let capture = "uid-" + ((viewer.written[0] ?? "") as NSString).lastPathComponent
    check(Server.image(capture, database.managedObjectContext) != nil, "the capture was not indexed in its study's database")
    check(marked(capture, database.managedObjectContext), "the capture is not marked in the copy")
    check(Server.setva.isEmpty, "the capture's mark was sent before the server had the image: \(Server.setva)")
    database.update()
    check(Server.setva.isEmpty, "an update without the capture sent a mark: \(Server.setva)")
    Server.receiveUploads()
    Server.outcomes = [false, false]
    database.update()
    check(!marked(capture, Server.context), "the double answered a request it was told to leave unanswered")
    database.update()
    check(marked(capture, Server.context), "the capture's mark did not reach the server after a failed attempt: \(Server.setva)")
    check(Server.setva.last?.key == "isKeyImage" && Server.setva.last?.value == "1", "the capture's mark went as \(Server.setva)")
    check(!marked("uid-other", Server.context) && !marked("uid-before", Server.context), "another image of the server was marked")
    let sent = Server.setva.count
    database.update()
    check(Server.setva.count == sent, "the capture's mark was sent again")

    // A viewer whose study has no database writes nothing.
    let orphan = ViewerController()
    orphan.study = DicomStudy()
    ViewerImageExporter(viewer: orphan).captureKeyImage()
    check(orphan.written.isEmpty, "a capture without a database was written: \(orphan.written)")

    // --- the windows state SR ---------------------------------------------------------------
    // The browser shows the local database, with an index of its own: the SR of
    // the shared study is written in the shared database's folder and indexed
    // there, nothing in the local folder or index.
    local.managedObjectContext = Server.newIndex()
    ProcessGraph.process.browser.database = local
    let remoteBefore = Server.images(database.managedObjectContext).count
    do { try study.writeWindowsStateAsDICOMSR() } catch { check(false, "the windows state SR of the shared study failed: \(error)") }
    check(SRAnnotation.written.count == 1 && SRAnnotation.written[0].hasPrefix("/remote/DATABASE.noindex/"),
          "the windows state SR was not written in the folder of its study's database: \(SRAnnotation.written)")
    check(Server.image("uid-" + (SRAnnotation.written[0] as NSString).lastPathComponent, database.managedObjectContext) != nil
          && Server.images(database.managedObjectContext).count == remoteBefore + 1,
          "the windows state SR was not indexed in its study's database")
    check(Server.images(local.managedObjectContext).isEmpty, "the windows state SR was indexed in the database the browser shows")
    // The browser shows the shared database: the same.
    ProcessGraph.process.browser.database = database
    do { try study.writeWindowsStateAsDICOMSR() } catch { check(false, "the windows state SR failed with the browser on the shared database: \(error)") }
    check(SRAnnotation.written.count == 2 && SRAnnotation.written[1].hasPrefix("/remote/DATABASE.noindex/")
          && Server.images(database.managedObjectContext).count == remoteBefore + 2,
          "with the browser on the shared database, the windows state SR went to \(SRAnnotation.written)")
    // A study of a local database the browser shows goes there, as it always did.
    let ownStudy = DicomStudy()
    ownStudy.managedObjectContext = nil
    ProcessGraph.process.browser.database = local
    do { try ownStudy.writeWindowsStateAsDICOMSR() } catch { check(false, "the windows state SR of a study without a context failed: \(error)") }
    check(SRAnnotation.written.count == 3 && SRAnnotation.written[2].hasPrefix("/local/DATABASE.noindex/")
          && Server.images(local.managedObjectContext).count == 1,
          "a study without a database of its own did not take the browser's: \(SRAnnotation.written)")
    // No database at all: the former exception, nothing written.
    ProcessGraph.process.browser.database = nil
    var refused = false
    do { try DicomStudy().writeWindowsStateAsDICOMSR() } catch StudyDocumentError.named(let name, _) { refused = name == .invalidArgumentException } catch {}
    check(refused && SRAnnotation.written.count == 3, "without a database the windows state SR did not fail as before or was written")
    // An SR that is not written is not indexed.
    ProcessGraph.process.browser.database = local
    let blank = DicomStudy()
    blank.windowsState = nil
    do { try blank.writeWindowsStateAsDICOMSR() } catch { check(false, "an unwritten SR threw: \(error)") }
    check(Server.images(local.managedObjectContext).count == 1, "an SR that was not written was indexed")

    // --- the annotations SR and the report SR -------------------------------------------------
    // The browser shows the local database: the SRs of the shared study are written in the
    // shared database's folder and indexed there, nothing in the local folder or index.
    ProcessGraph.process.defaults.values["archiveReportsAndAnnotationsAsDICOMSR"] = true
    ProcessGraph.process.browser.database = local
    let localImages = Server.images(local.managedObjectContext).count
    var remoteImages = Server.images(database.managedObjectContext).count
    study.annotations = ["comment": "first"]
    study.archiveAnnotationsAsDICOMSR()
    remoteImages += 1
    check(SRAnnotation.annotationsWritten.count == 1 && SRAnnotation.annotationsWritten[0].hasPrefix("/remote/DATABASE.noindex/"),
          "the annotations SR was not written in the folder of its study's database: \(SRAnnotation.annotationsWritten)")
    check(AnnotationsSRPruning.indexed.count == 1 && AnnotationsSRPruning.indexed[0].database === database
          && AnnotationsSRPruning.indexed[0].path == SRAnnotation.annotationsWritten[0],
          "the annotations SR was not indexed, replacing the earlier ones, in its study's database: \(AnnotationsSRPruning.indexed)")
    check(Server.images(database.managedObjectContext).count == remoteImages && Server.images(local.managedObjectContext).count == localImages,
          "the annotations SR was not indexed in the shared database alone")

    let reportFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("report-\(UUID().uuidString).txt")
    try! Data("report".utf8).write(to: URL(fileURLWithPath: reportFile))
    defer { try? FileManager.default.removeItem(atPath: reportFile) }
    study.reportURL = reportFile
    study.archiveReportAsDICOMSR()
    remoteImages += 1
    check(SRAnnotation.reportsWritten.count == 1 && SRAnnotation.reportsWritten[0].hasPrefix("/remote/DATABASE.noindex/"),
          "the report SR was not written in the folder of its study's database: \(SRAnnotation.reportsWritten) \(Logged.reasons)")
    check(ReportArchiveIndexing.paths == SRAnnotation.reportsWritten, "the report SR was not indexed as the report's copy: \(ReportArchiveIndexing.paths)")
    check(Server.images(database.managedObjectContext).count == remoteImages && Server.images(local.managedObjectContext).count == localImages,
          "the report SR was not indexed in the shared database alone")
    // The study's report SR is written again over its file.
    study.reportSR = ReportSR(SRAnnotation.reportsWritten[0])
    study.archiveReportAsDICOMSR()
    remoteImages += 1
    check(SRAnnotation.reportsWritten.count == 2 && SRAnnotation.reportsWritten[1] == SRAnnotation.reportsWritten[0],
          "the report SR was not written over the study's earlier one: \(SRAnnotation.reportsWritten)")

    // The browser shows the shared database: the same.
    ProcessGraph.process.browser.database = database
    study.annotations = ["comment": "second"]
    study.archiveAnnotationsAsDICOMSR()
    remoteImages += 1
    check(SRAnnotation.annotationsWritten.count == 2 && SRAnnotation.annotationsWritten[1].hasPrefix("/remote/DATABASE.noindex/")
          && AnnotationsSRPruning.indexed.count == 2 && AnnotationsSRPruning.indexed[1].database === database
          && Server.images(database.managedObjectContext).count == remoteImages,
          "with the browser on the shared database, the annotations SR went to \(SRAnnotation.annotationsWritten)")

    // Off the main thread, as an import that puts the study in an album: indexed through
    // a database of its own over the study's store, never through the study's context.
    ProcessGraph.process.browser.database = local
    study.annotations = ["comment": "third"]
    final class Done: @unchecked Sendable { var done = false }
    let finished = Done()
    Thread { study.archiveAnnotationsAsDICOMSR(); finished.done = true }.start()
    let deadline = Date().addingTimeInterval(20)
    while !finished.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    remoteImages += 1
    check(finished.done, "the annotations SR off the main thread did not end")
    let offMain = AnnotationsSRPruning.indexed.last
    check(AnnotationsSRPruning.indexed.count == 3 && offMain?.onMain == false && offMain?.database !== database
          && (offMain?.database.mainDatabase as AnyObject?) === database && offMain?.path.hasPrefix("/remote/DATABASE.noindex/") == true,
          "off the main thread the annotations SR was not indexed through a database of the study's own store: \(String(describing: offMain))")
    check(Server.images(database.managedObjectContext).count == remoteImages && Server.images(local.managedObjectContext).count == localImages,
          "off the main thread the annotations SR was not indexed in the shared database alone")

    // An annotations SR that is not written is not indexed.
    study.annotations = ["fail": true]
    study.archiveAnnotationsAsDICOMSR()
    check(AnnotationsSRPruning.indexed.count == 3 && Server.images(database.managedObjectContext).count == remoteImages,
          "an annotations SR that was not written was indexed")

    // Without any database nothing is written, and the report says it was not archived.
    ProcessGraph.process.browser.database = nil
    let homeless = DicomStudy()
    homeless.annotations = ["comment": "nowhere"]
    homeless.archiveAnnotationsAsDICOMSR()
    homeless.reportURL = reportFile
    Logged.reasons = []
    homeless.archiveReportAsDICOMSR()
    check(SRAnnotation.annotationsWritten.count == 3 && SRAnnotation.reportsWritten.count == 2,
          "a study without a database wrote an SR: \(SRAnnotation.annotationsWritten) \(SRAnnotation.reportsWritten)")
    check(Logged.reasons.contains { $0.contains("archiveReportAsDICOMSR") && $0.contains("Could not write the DICOM report archive") },
          "the report of a study without a database was not said to be unarchived: \(Logged.reasons)")

    // --- the validated report's DICOM PDF -------------------------------------------------------
    // Folders on disk: the PDF is indexed once the conversion's file is there.
    let folders = (NSTemporaryDirectory() as NSString).appendingPathComponent("pdf-\(UUID().uuidString)")
    let remoteFolder = folders + "/remote", localFolder = folders + "/local"
    for folder in [remoteFolder, localFolder] { try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: folders) }
    let (remoteData, localData) = (database.dataFolder, local.dataFolder)
    database.dataFolder = remoteFolder
    local.dataFolder = localFolder
    func onDisk(_ folder: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] }
    ProcessGraph.process.defaults.values["closePagesReportWhenValidated"] = true
    // The browser shows the local database: the PDF of the shared study is written in the shared database's
    // folder and indexed there, nothing in the local folder or index, and the report closes once it is in the study.
    ProcessGraph.process.browser.database = local
    remoteImages = Server.images(database.managedObjectContext).count
    let localPDFImages = Server.images(local.managedObjectContext).count
    study.reportURL = reportFile
    study.archiveValidatedReportAsDICOMPDF()
    check(DicomStudy.pdfsWritten.count == 1 && DicomStudy.pdfsWritten[0].hasPrefix(remoteFolder + "/") && onDisk(localFolder).isEmpty,
          "the validated report's PDF was not written in the folder of its study's database: \(DicomStudy.pdfsWritten) \(Logged.reasons)")
    check(DatabaseIngest.last === database && Server.images(database.managedObjectContext).count == remoteImages + 1
          && Server.images(local.managedObjectContext).count == localPDFImages,
          "the validated report's PDF was not indexed in its study's database alone")
    check(PagesPDFConversion.closed == [reportFile], "the report was not closed once its PDF was in the study: \(PagesPDFConversion.closed)")
    // The browser shows the shared database: the same.
    ProcessGraph.process.browser.database = database
    study.archiveValidatedReportAsDICOMPDF()
    check(DicomStudy.pdfsWritten.count == 2 && DicomStudy.pdfsWritten[1].hasPrefix(remoteFolder + "/")
          && Server.images(database.managedObjectContext).count == remoteImages + 2 && PagesPDFConversion.closed.count == 2,
          "with the browser on the shared database, the validated report's PDF went to \(DicomStudy.pdfsWritten)")
    // Off the main thread, as a status an import sets: indexed through a database of its own over the study's store.
    ProcessGraph.process.browser.database = local
    let pdfFinished = Done()
    Thread { study.archiveValidatedReportAsDICOMPDF(); pdfFinished.done = true }.start()
    let pdfDeadline = Date().addingTimeInterval(20)
    while !pdfFinished.done && Date() < pdfDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(pdfFinished.done && DicomStudy.pdfsWritten.count == 3 && DatabaseIngest.last !== database && (DatabaseIngest.last?.mainDatabase as AnyObject?) === database
          && Server.images(database.managedObjectContext).count == remoteImages + 3,
          "off the main thread the validated report's PDF was not indexed through a database of the study's own store")
    // A conversion that fails, or that writes no file, indexes nothing and leaves the report open; it is said.
    Logged.reasons = []
    study.conversion = .fails
    study.archiveValidatedReportAsDICOMPDF()
    study.conversion = .writesNothing
    study.archiveValidatedReportAsDICOMPDF()
    study.conversion = .writes
    check(DicomStudy.pdfsWritten.count == 3 && Server.images(database.managedObjectContext).count == remoteImages + 3
          && PagesPDFConversion.closed.count == 3 && onDisk(remoteFolder).count == 3,
          "a validated report whose conversion failed or wrote nothing was indexed or closed")
    check(Logged.reasons.count == 2 && Logged.reasons[0].contains("setStateText") && Logged.reasons[0].contains("Pages could not export")
          && Logged.reasons[1].contains("The DICOM PDF could not be written"),
          "a failed conversion of the validated report was not said: \(Logged.reasons)")
    // Without any database nothing is written, and it is said.
    ProcessGraph.process.browser.database = nil
    let homelessPDF = DicomStudy()
    homelessPDF.reportURL = reportFile
    homelessPDF.archiveValidatedReportAsDICOMPDF()
    check(DicomStudy.pdfsWritten.count == 3 && Logged.reasons.count == 3 && Logged.reasons[2].contains("The DICOM PDF could not be written"),
          "a validated report without a database was written or not said: \(DicomStudy.pdfsWritten) \(Logged.reasons)")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(ProcessGraph.process.userNotifications.posted.count == 3 && ProcessGraph.process.userNotifications.posted.allSatisfy { $0.title == "Report Error" },
          "the person was not told of each validated report left without its PDF: \(ProcessGraph.process.userNotifications.posted)")
    database.dataFolder = remoteData
    local.dataFolder = localData

    // --- the key image of an image the server has, marked in a viewer ---------------------------
    // The browser shows the local database and a viewer an image of the shared one that the server already
    // has: marking it and unmarking it reach the server, under the identifier the server knows.
    ProcessGraph.process.browser.database = local
    database.update()
    Server.setva = []
    let keyImages = KeyImageDatabase()
    let existing = Server.image("uid-before", database.managedObjectContext)
    check(existing != nil && keyImages.remoteDatabase(of: existing) === database, "an image of the shared database does not name it")
    keyImages.remoteDatabase(of: existing)?.object(existing, setValue: NSNumber(value: true), forKey: "isKeyImage")
    check(marked("uid-before", Server.context), "marking an image the server has did not reach the server: \(Server.setva)")
    keyImages.remoteDatabase(of: existing)?.object(existing, setValue: NSNumber(value: false), forKey: "isKeyImage")
    check(!marked("uid-before", Server.context) && Server.setva.map(\.value) == ["1", "0"] && Server.setva.allSatisfy { $0.key == "isKeyImage" },
          "unmarking an image the server has did not reach the server: \(Server.setva)")
    check(!marked("uid-other", Server.context), "another image of the server was marked")
    // A context of an independent database of the shared one: its main database sends.
    let independent = database.privateQueueIndependentDatabase() as! RemoteDicomDatabase
    let independentContext = Server.newIndex() as! N2ManagedObjectContext
    independentContext.database = independent
    check(keyImages.remoteDatabase(of: Server.insert("uid-independent", in: independentContext)) === database,
          "an image of an independent database of the shared one does not name the main database")
    // An image of a local database, while the browser shows the shared one, and an object without a database: no request.
    ProcessGraph.process.browser.database = database
    (local.managedObjectContext as! N2ManagedObjectContext).database = local
    check(keyImages.remoteDatabase(of: Server.insert("uid-local", in: local.managedObjectContext)) == nil
          && keyImages.remoteDatabase(of: nil) == nil, "an image of a local database, or of none, names a shared database")

    // --- the save after a change of mark ---------------------------------------------------------
    // The browser shows the local database and a viewer images of the shared one: the marks are saved in the
    // shared database's context, once for its two images, and the local database is not saved.
    ProcessGraph.process.browser.database = local
    let second = Server.insert("uid-second", in: database.managedObjectContext)
    let (sharedSaves, localSaves) = (database.saves, local.saves)
    for image in [existing!, second] { image.setValue(NSNumber(value: true), forKey: "isKeyImage") }
    check(database.managedObjectContext.hasChanges, "marking an image of the shared database changed nothing in its context")
    keyImages.saveDatabases(of: [existing!, second])
    check(!database.managedObjectContext.hasChanges && database.saves == sharedSaves + 1 && local.saves == localSaves,
          "the marks of a shared study's images were not saved once in its own database while the browser shows another: "
          + "shared \(database.saves - sharedSaves), local \(local.saves - localSaves)")
    // Images of two databases: each database saved once, in its own context.
    let localImage = Server.insert("uid-local-marked", in: local.managedObjectContext)
    for image in [existing!, localImage] { image.setValue(NSNumber(value: false), forKey: "isKeyImage") }
    keyImages.saveDatabases(of: [existing!, localImage, second, localImage])
    check(!database.managedObjectContext.hasChanges && !local.managedObjectContext.hasChanges
          && database.saves == sharedSaves + 2 && local.saves == localSaves + 1,
          "images of two databases were not saved once in each: shared \(database.saves - sharedSaves), local \(local.saves - localSaves)")
    // An object of no database, or none at all: nothing is saved.
    let homelessContext = Server.newIndex()
    keyImages.saveDatabases(of: [Server.insert("uid-homeless", in: homelessContext)])
    keyImages.saveDatabases(of: [])
    check(database.saves == sharedSaves + 2 && local.saves == localSaves + 1, "a file of no database saved a database")
    print("ok")
}

MainActor.assumeIsolated { run() }
'''


def main():
    remote = (root / 'Horos/Sources/RemoteDicomDatabase.swift').read_text(encoding='utf-8')
    generated = (root / 'Horos/Sources/GeneratedSeriesImport.swift').read_text(encoding='utf-8')
    exporter = (root / 'Horos/Sources/ViewerImageExporter.swift').read_text(encoding='utf-8')
    section = exporter[exporter.index('    // MARK: - The key image capture'):exporter.index('    // MARK: - The report')]
    if 'captureKeyImage()' not in (root / 'Horos/Sources/ViewerController+KeyImageCapture.swift').read_text(encoding='utf-8'):
        print('FAIL: -captureAndSetKeyImage: does not reach the capture')
        return 1
    capture = ('import Foundation\n\n@MainActor final class ViewerImageExporter {\n'
               '    let viewer: ViewerController\n    let processGraph = ProcessGraph.process\n'
               '    init(viewer: ViewerController) { self.viewer = viewer }\n'
               '    /// The DICOM file of the image shown, at `destination`.\n'
               '    func writeDICOM(format: Int32, name: String?, allViewers: Bool, to destination: String? = nil) -> [AnyHashable: Any] {\n'
               '        viewer.written.append(destination)\n'
               '        return destination.map { ["file": $0] } ?? [:]\n    }\n}\n\nextension ViewerImageExporter {\n'
               + section + '}\n')
    study = (root / 'Horos/Sources/DicomStudy.swift').read_text(encoding='utf-8')
    windows_state = 'import Foundation\n\nextension DicomStudy {\n' + member(study, '@nonobjc func writeWindowsStateAsDICOMSR()') + '\n}\n'
    # The annotations SR and the report SR, with the helpers of the file they call.
    archives = [member(study, signature).replace('@objc public dynamic func', 'func') for signature in (
        '@objc public dynamic func archiveAnnotationsAsDICOMSR()', '@objc public dynamic func archiveReportAsDICOMSR()')]
    helpers = [member(study, 'func dicomStudyGeneratedFilesDatabase(')] + [member(study, f'fileprivate func {name}') for name in (
        'dicomStudyAddGeneratedFiles(', 'dicomStudyOnQueue<', 'dicomStudyEqual(', 'dicomStudyHasPrefix(', 'dicomStudyFileExists(',
        'dicomStudyRemoveItem(', 'dicomStudyValue(', 'dicomStudyDataEqual(')]
    study_archives = ('import CoreData\nimport Synchronization\nimport IsiXContracts\nimport IsiXPreferences\n\n' + '\n\n'.join(helpers)
                      + '\n\nextension DicomStudy {\n' + '\n\n'.join(archives) + '\n}\n')
    # The validated report's DICOM PDF, with the helper of its file that indexes it.
    report = (root / 'Horos/Sources/DicomStudy+Report.swift').read_text(encoding='utf-8')
    validated_pdf = ('import CoreData\nimport IsiXContracts\nimport IsiXPreferences\n\n' + member(report, 'private func addValidatedReport(')
                     + '\n\nextension DicomStudy {\n' + member(report, 'func archiveValidatedReportAsDICOMPDF()') + '\n}\n')
    if 'try study.writeWindowsStateAsDICOMSR()' not in (root / 'Horos/Sources/ViewerWorkspaceArchiver.swift').read_text(encoding='utf-8'):
        print('FAIL: saving the windows state as a DICOM SR does not reach DicomStudy.writeWindowsStateAsDICOMSR')
        return 1
    state_text = indicator.swift_code(member(study, '@objc public dynamic var stateText: NSNumber!'))
    if state_text.count('self.archiveValidatedReportAsDICOMPDF()') != 1:
        print('FAIL: validating the report does not reach DicomStudy.archiveValidatedReportAsDICOMPDF')
        return 1

    # The key images of the 2D viewer tell the shared database of each file they mark, whichever the browser shows.
    keys = (root / 'Horos/Sources/ViewerController+KeyImages.swift').read_text(encoding='utf-8')
    key_database = ('import CoreData\n\nstruct KeyImageDatabase {\n'
                    + member(keys, 'func remoteDatabase(of file: NSManagedObject?) -> RemoteDicomDatabase? {') + '\n\n'
                    + member(keys, 'func saveDatabases(of files: [NSManagedObject]) {') + '\n}\n')
    for action, saved in (('func checkBoxChanged(', 'browser.saveDatabases(of: file.map { [$0] } ?? [])'),
                          ('func markImagesWithROIs(', 'browser.saveDatabases(of: files)'),
                          ('func markEveryImage(', 'browser.saveDatabases(of: files)')):
        body = indicator.swift_code(member(keys, action))
        if 'browser.remoteDatabase(of: file)?.object(file, setValue:' not in body or 'browser.remoteDatabase?' in body:
            print(f'FAIL: {action[5:-1]} of the key images does not tell the shared database of the file it marks')
            return 1
        if body.count(saved) != 1 or 'saveDatabase()' in body:
            print(f'FAIL: {action[5:-1]} of the key images does not save the databases of the files it marks')
            return 1

    # -updateOnMainThread: hands the new index to the marks before the browser hears of it.
    update = indicator.swift_code(member(remote, '@objc(updateOnMainThread:)'))
    installed = update.find('self.managedObjectContext = context')
    marks = update.find('self.markWaitingKeyImages(in: context)')
    told = update.find('NotificationCenter.default.post(')
    if not (0 <= installed < marks < told):
        print('FAIL: -updateOnMainThread: does not mark the waiting key images in the new index before it tells the browser')
        return 1

    remote_members = [member(remote, signature) for signature in (
        'static func database(of object: NSManagedObject?)',
        '@objc(object:setValue:forKey:)',
        'private func setRemoteValue(',
        '@objc(markAddedImagesAsKeyImages:)',
        'private func markWaitingKeyImages(',
        '@objc func fetchDatabaseTimestamp()',
        'private func requestDatabaseTimestamp()',
        'private func requestInteger<',
        '@objc(_data:appendInt:)',
        '@objc(_data:appendStringUTF8:)')]
    remote_members = [m.replace('private func markWaitingKeyImages(', 'func markWaitingKeyImages(') for m in remote_members]
    remote_functions = [member(remote, signature) for signature in (
        'private enum SharedDatabaseClientFailure',
        'private func raisingForObjectiveC<',
        'private struct RemoteDicomDatabaseWaitingKeyImage')]
    waiting = [line for line in remote.splitlines() if line.strip().startswith('private var _waitingKeyImages')]
    if len(waiting) != 1:
        print('FAIL: the main database keeps no _waitingKeyImages')
        return 1

    with tempfile.TemporaryDirectory(prefix='horos-remote-key-') as directory:
        work = Path(directory)
        (work / 'Support.h').write_text(SUPPORT_H)
        (work / 'Support.m').write_text(SUPPORT_M)
        (work / 'stage.swift').write_text(STAGE.replace('@WAITING_PROPERTY@', waiting[0])
                                          .replace('@REMOTE_MEMBERS@', '\n\n'.join(remote_members))
                                          .replace('@REMOTE_FUNCTIONS@', '\n\n'.join(remote_functions)))
        (work / 'generated.swift').write_text(generated)
        (work / 'capture.swift').write_text(capture)
        (work / 'windows-state.swift').write_text(windows_state)
        (work / 'study-archives.swift').write_text(study_archives)
        (work / 'key-database.swift').write_text(key_database)
        (work / 'validated-pdf.swift').write_text(validated_pdf)
        (work / 'main.swift').write_text(DRIVER)
        subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(work), str(work / 'Support.m'), '-o', str(work / 'Support.o')],
                       check=True, timeout=120)
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                '-import-objc-header', str(work / 'Support.h'),
                                *isix_modules.module_flags('IsiXContracts', work / 'internal'),
                                *isix_modules.module_flags('IsiXPreferences', work / 'internal'),
                                *isix_modules.module_flags('IsiXDatabase', work / 'internal'),
                                *(str(work / name) for name in ('stage.swift', 'generated.swift', 'capture.swift', 'windows-state.swift',
                                                                'study-archives.swift', 'key-database.swift', 'validated-pdf.swift',
                                                                'main.swift')),
                                *isix_modules.log_text_sources(), str(work / 'Support.o'), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print('FAIL: the sources do not compile with their doubles\n' + built.stderr[-3000:])
            return 1
        run = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
        if run.returncode or run.stdout.strip() != 'ok':
            print('FAIL:', (run.stdout + run.stderr).strip()[-1500:])
            return 1
    print('remote database: the key image of an export and of a capture is marked in the copy at once, reaches the server '
          'with the identifier the server knows once an update brings the image, waits through an update without it and '
          'an unanswered request, marks no other image and is not sent twice; the capture and the windows state, '
          "annotations and report SRs and the validated report's PDF of a shared study go to the shared database's folder "
          'and index, not to those of the database the browser shows nor to a scratch database; a key image marked or '
          'unmarked in a viewer of a shared study reaches the server whichever database the browser shows, and is saved '
          'once in the database of each file marked, not in the one the browser shows')
    return 0


if __name__ == '__main__':
    sys.exit(main())
