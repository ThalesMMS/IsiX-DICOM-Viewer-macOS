#!/usr/bin/env python3
"""What is added to a shared database reaches the server.

A RemoteDicomDatabase indexes in a local copy of the server's index, replaced at
each update, so a file that is not sent is gone at the next one and was never
anyone else's. The real -addFilesAtPaths: chain of DicomFileIndexer.swift
(the variants down to the indexer's call, with the read of a batch's headers
side by side, ParsedDICOMFiles, as DicomFile+DICOMReading.swift writes it) and
the real members of RemoteDicomDatabase.swift (the override, the background
sender, the upload and the incoming folder's pass) are compiled here against a
double of the indexer on a Core Data store in memory and a double of the
connection, and it is checked that:

- -addFiles of a generated object sends SENDG, with the file's bytes, from the
  temporary folder, and the image takes the name the server answered;
- -addFiles of anything else sends SENDD, and `importedFiles` reaches the indexer;
- the variants of -addFilesDescribed with fewer arguments send once, not twice;
- an addition that asks for no array sends all the same and answers none;
- an independent database, which has no address, sends through the main one;
- the frames of a multi-frame object send their one file once;
- the plain DICOM files of one addition, whose headers are read side by side,
  each come to their read with their own header, in order, and are sent once;
- a new index between the addition and the sending does not lose the file;
- an addition that added nothing sends nothing;
- a remote database asks for a pass when its incoming folder holds something, an
  independent one too, and its update timer looks; not when it is empty;
- an upload that fails keeps its files where they are, tells the person once,
  and the next update sends them again, as SENDG or SENDD as they were added;
  of an upload of several requests, only what the server did not answer, and
  a failure again tells nobody a second time;
- the index an update replaced stays while a context of an upload or a pass
  still uses its coordinator, which saves in it, and goes at a later update
  once nothing does.

No app, no network and no DICOM file are needed.
"""
import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402  - the indexer reads the preferences through IsiXPreferences

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
extern NSString * const HorosObjCExceptionKey;
/// The exceptions the double caught: what Core Data raised included.
extern NSInteger HorosCaughtExceptions;
@interface HorosObjCException : NSObject
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error NS_SWIFT_NAME(perform(_:));
@end
'''

SUPPORT_M = r'''
#import "Support.h"
NSString * const HorosObjCExceptionKey = @"exception";
NSInteger HorosCaughtExceptions = 0;
@implementation HorosObjCException
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try { block(); return YES; }
    @catch (NSException *exception) {
        @synchronized ([HorosObjCException class]) { HorosCaughtExceptions += 1; }
        if (error) *error = [NSError errorWithDomain: @"double" code: 1 userInfo: @{HorosObjCExceptionKey: exception}];
        return NO;
    }
}
@end
'''

# What the real members ask of the parts of the application not brought here.
STAGE = r'''
import CoreData
import Foundation
import IsiXPreferences
import Synchronization

/// The double of the alert: it counts what would have been shown, from the
/// main run loop, which the double of that does not run.
func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
    RemoteDicomDatabase.sentLock.lock()
    Stage.warnings += 1
    RemoteDicomDatabase.sentLock.unlock()
}

@MainActor
enum HorosAlertPanel {
    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { 1 }
}

extension Thread {
    @objc var status: String? { get { nil } set {} }
    @objc var progress: CGFloat { get { 0 } set {} }
    @objc func enterOperation() {}
    @objc func exitOperation() {}
    @objc func enterOperationIgnoringLowerLevels() {}
}

final class ThreadsManager {
    private static let shared = ThreadsManager()
    class func `default`() -> ThreadsManager { shared }
    func addThreadAndStart(_ thread: Thread) {}
}

extension NSArray {
    func splitArrayIntoChunks(ofMinSize minSize: UInt, maxChunks: UInt) -> NSArray {
        [NSValue(range: NSRange(location: 0, length: count))]
    }
}

func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ body: () -> Void) {
    if let context { context.performAndWait(body) } else { body() }
}

func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ place: String) {}


// The guards Swift puts where Objective-C had @try or @synchronized, around
// code that can raise an NSException (Core Data, KVC, DCMTK adapters, plugins,
// Foundation): Swift cannot catch one, and an exception crossing Swift frames
// would end the process. Every guard names HorosObjCException, so each one
// is counted where it stands.
extension HorosObjCException {

    /// The NSException that a failed perform(_:) carries in its error.
    static func exception(in error: Error) -> NSException? {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }

    /// Runs `body` as an @try block and answers the NSException it raised, or nil.
    @inline(__always)
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? {
        do {
            try perform(body)
            return nil
        } catch {
            return exception(in: error)
        }
    }

    /// Runs `body` as an @try block whose @catch calls `handler` with the
    /// NSException it raised.
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) {
        if let raised = caught(body) {
            handler(raised)
        }
    }

    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool {
        guard let raised = caught(body) else { return false }
        _N2LogExceptionImpl(raised, stack, function)
        return true
    }



    /// `@synchronized (object) { … }`: the same recursive lock on the same
    /// object, nothing locked when it is nil. An exception raised inside is
    /// caught, the lock is left, and the exception is raised again for the
    /// caller, as @synchronized does.
    @inline(__always)
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
        guard let object else { return body() }
        objc_sync_enter(object)
        var result: T?
        let raised = caught { result = body() }
        objc_sync_exit(object)
        if let raised { raised.raise() }
        return result!
    }

    /// Runs `body`, whose NSException goes on to the caller: it is caught where
    /// it was raised and raised again here, so that it does not unwind the Swift
    /// frames of `body`.
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T {
        var result: T?
        if let raised = caught({ result = body() }) {
            raised.raise()
        }
        return result!
    }

    /// Runs `body`, which may throw or raise: its error is thrown on, and an
    /// NSException it raised is thrown as `failure(exception)`.
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T {
        var result: T?
        var thrown: Error?
        do {
            try perform {
                do { result = try body() } catch { thrown = error }
            }
        } catch {
            throw failure(exception(in: error)
                          ?? NSException(name: .genericException, reason: (error as NSError).localizedDescription, userInfo: nil))
        }
        if let thrown { throw thrown }
        return result!
    }
}


enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? {
        do { try HorosObjCException.perform(body) } catch { return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException }
        return nil
    }
    static func log(_ exception: NSException, stack: Bool, _ place: String) {}
    static func localizedFileCount(_ count: Int) -> String { "\(count)" }
}

final class ImportRefusals {
    var count = 0
    var summary = ""
    init(considered: Int) {}
}

enum ActivityProgressCount { static func set(done: Int, total: Int, on thread: Thread) {} }
enum ImportShortfall { static func progressDone(index: Int, total: Int) -> Int { index } }

/// The double of the read of one file's header, which is what the read of a
/// batch's headers side by side makes of each plain DICOM file.
final class DicomFile {
    let path: String?
    init!(_ f: String!, dicomOnly DICOMOnly: Bool) { path = f }
    class func nSreplaceBadCharacter(_ name: String) -> String! { name.replacingOccurrences(of: "/", with: "_") }
}

/// No plugin reads a format of its own here.
enum PluginManager {
    static func fileFormatPlugins() -> NSMutableDictionary! { nil }
}

@PARSED_FILES@

final class DicomImage: NSManagedObject {
    @NSManaged var path: String?
    @NSManaged var inDatabaseFolder: NSNumber?
    @NSManaged var sopInstanceUID: String?
    @NSManaged var instanceNumber: NSNumber?
    @NSManaged var numberOfFrames: NSNumber?
    /// A path the image already answered, as the application's cache keeps it.
    var remembered: String?

    override func value(forUndefinedKey key: String) -> Any? {
        switch key {
        case "extension": return "dcm"
        case "series": return ["study": ["patientUID": "PATIENT"]]
        default: return nil
        }
    }

    /// As in the application: the folder of the database first, then the cache.
    func completePath() -> String! {
        if let remembered { return remembered }
        guard let path, inDatabaseFolder?.boolValue == true else { return self.path }
        let stored = path.hasPrefix("/") ? path : (Stage.dataDirectory as NSString).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: stored) ? stored : Stage.cachedPath(self)
    }
}

enum Stage {
    nonisolated(unsafe) static var dataDirectory = ""
    nonisolated(unsafe) static var cachedPath: (DicomImage) -> String? = { _ in nil }
    /// What the double of the indexer was told, one line per call.
    nonisolated(unsafe) static var indexed: [(generated: Bool, imported: Bool, returnArray: Bool)] = []
    /// The files that came to their read with a header already read, and the
    /// file that header was read from.
    nonisolated(unsafe) static var headers: [(path: String, header: String?)] = []
    /// The alerts that would have been shown.
    nonisolated(unsafe) static var warnings = 0

    static func coordinator() -> NSPersistentStoreCoordinator {
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
        entity.properties = [attribute("path", .stringAttributeType), attribute("inDatabaseFolder", .booleanAttributeType),
                             attribute("sopInstanceUID", .stringAttributeType), attribute("instanceNumber", .integer32AttributeType),
                             attribute("numberOfFrames", .integer32AttributeType)]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        return coordinator
    }
}

class DicomDatabase: NSObject {
    var managedObjectContext: NSManagedObjectContext!
    var main: DicomDatabase?
    let folder: String

    init(folder: String, main: DicomDatabase? = nil) {
        self.folder = folder
        self.main = main
        super.init()
        if main == nil {
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = Stage.coordinator()
            managedObjectContext = context
        } else {
            managedObjectContext = main!.privateQueueIndependentContext()
        }
    }

    var mainDatabase: Any! { main }
    var name: String! { "shared database" }
    func isMainDatabase() -> Bool { main == nil }
    func privateQueueIndependentContext() -> NSManagedObjectContext! {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = (main ?? self).managedObjectContext.persistentStoreCoordinator
        return context
    }
    func dataDirPath() -> String! { folder + "/DATABASE.noindex" }
    func reportsDirPath() -> String! { folder + "/REPORTS" }
    func errorsDirPath() -> String! { folder + "/NOT READABLE" }
    func tempDirPath() -> String! { folder + "/TEMP.noindex" }
    func incomingDirPath() -> String! { folder + "/INCOMING.noindex" }
    func hasFilesToImport() -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: incomingDirPath())) ?? []).isEmpty
    }
    func objects(withIDs objectIDs: [Any]!) -> [Any]! {
        var images: [Any] = []
        managedObjectContext.performAndWait {
            images = (objectIDs ?? []).compactMap { $0 as? NSManagedObjectID }.map { managedObjectContext.object(with: $0) }
        }
        return images
    }
    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {}
    func setLastImportRefusalSummary(_ summary: String?) {}
    func addImportRefusalSummary(_ summary: String) {}
    func checkForCorrectContextThreadIfDeclared() {}
    func checkForCorrectContextThread() {}

    /// The read of one file: the double of what it finds in a real one, whether
    /// or not its header came already read.
    func readFile(_ path: String?, parsed: DicomFile?, dicomOnly: Bool, dataDirPath: String?, errorsDirPath: String?, deleteFileListener: Bool,
                  refusals: ImportRefusals, into dicomFilesArray: NSMutableArray) {
        guard let path else { return }
        if let parsed { Stage.headers.append((path, parsed.path)) }
        dicomFilesArray.add(["filePath": path, "frames": (path as NSString).lastPathComponent.hasPrefix("frames") ? 3 : 1] as NSDictionary)
    }

@IMPORT_MEMBERS@

    /// The indexer of the real database: the images of each file, one per frame, saved as it saves them.
    func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {
        Stage.indexed.append((generatedByOsiriX, importedFiles, returnArray))
        var objectIDs: [Any] = []
        managedObjectContext.performAndWait {
            var made: [DicomImage] = []
            for case let file as NSDictionary in dicomFilesArray ?? [] {
                let path = file["filePath"] as! String
                let inFolder = path.hasPrefix(dataDirPath())
                let uid = UUID().uuidString
                let frames = file["frames"] as! Int
                for frame in 0..<frames {
                    let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: managedObjectContext) as! DicomImage
                    image.path = inFolder ? (path as NSString).lastPathComponent : path
                    image.inDatabaseFolder = NSNumber(value: inFolder)
                    image.sopInstanceUID = uid
                    image.instanceNumber = NSNumber(value: frame + 1)
                    image.numberOfFrames = NSNumber(value: frames)
                    if (path as NSString).lastPathComponent.hasPrefix("frames-kept") { image.remembered = path }
                    made.append(image)
                }
            }
            try! managedObjectContext.save()
            objectIDs = made.map(\.objectID)
        }
        return returnArray ? objectIDs : nil
    }
}

/// What the real database's forwarders give the indexer.
final class ProcessGraph {
    static let process = ProcessGraph()
}

/// The indexer as a type of its own: its read of the files, pasted, over the
/// double of the read of one file.
struct DicomFileIndexer {
    let database: DicomDatabase
    let preferences = UserDefaults.standard
    init(database: DicomDatabase, processGraph: ProcessGraph) { self.database = database }
    func readFile(_ path: String?, parsed: DicomFile?, dicomOnly: Bool, dataDirPath: String?, errorsDirPath: String?, deleteFileListener: Bool,
                  refusals: ImportRefusals, into dicomFilesArray: NSMutableArray) {
        database.readFile(path, parsed: parsed, dicomOnly: dicomOnly, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath,
                          deleteFileListener: deleteFileListener, refusals: refusals, into: dicomFilesArray)
    }

@INDEXER_MEMBERS@
}

/// `schedulePass(over:)`, which is what the real override asks of the single entry.
struct DatabaseIngest {
    static let process = DatabaseIngest()
    nonisolated(unsafe) static var passes: [DicomDatabase] = []
    func schedulePass(over database: DicomDatabase) { Self.passes.append(database) }
}

class RemoteDicomDatabase: DicomDatabase {
    var address: String?
    /// What reached the connection: the address, the command, the files in it.
    struct Sent { let address: String?; let command: String; let files: [Data] }
    nonisolated(unsafe) static var sent: [Sent] = []
    nonisolated(unsafe) static var sentLock = NSLock()
    nonisolated(unsafe) static var nextPathNumber: UInt32 = 7000
    /// The requests that reached the double, answered or not.
    nonisolated(unsafe) static var attempts = 0
    /// Whether each next request is answered: false is a failure, which the
    /// real connection logs and answers nil. Answered once this is empty.
    nonisolated(unsafe) static var outcomes: [Bool] = []

@WAITING_PROPERTY@
@REPLACED_PROPERTY@

    func initiateUpdate() -> Thread? { nil }

    /// The double of the connection: reads the request as the server does, and
    /// answers the name of each file.
    func sendRequest(_ request: NSData?, urgent: Bool) throws -> NSData? {
        synchronousRequest(request, urgent: urgent)
    }

    func synchronousRequest(_ request: NSData?, urgent now: Bool) -> NSData? {
        Self.sentLock.lock()
        Self.attempts += 1
        let answered = Self.outcomes.isEmpty ? true : Self.outcomes.removeFirst()
        Self.sentLock.unlock()
        if !answered { return nil }
        let data = (request ?? NSData()) as Data
        func integer(_ at: Int) -> Int {
            Int(data[data.startIndex + at]) << 24 | Int(data[data.startIndex + at + 1]) << 16 |
                Int(data[data.startIndex + at + 2]) << 8 | Int(data[data.startIndex + at + 3])
        }
        let count = integer(6)
        var at = 10
        var files: [Data] = []
        for _ in 0..<count {
            let length = integer(at)
            at += 4
            files.append(data[(data.startIndex + at)..<(data.startIndex + at + length)])
            at += length
        }
        let command = String(decoding: data.prefix(5), as: UTF8.self)
        Self.sentLock.lock()
        Self.sent.append(Sent(address: address, command: command, files: files))
        let answer = NSMutableData()
        RemoteDicomDatabase._data(answer, appendInt: UInt32(count))
        for _ in 0..<count {
            RemoteDicomDatabase._data(answer, appendInt: Self.nextPathNumber)
            Self.nextPathNumber += 1
        }
        Self.sentLock.unlock()
        return answer
    }

    /// An update: the index is another store, as in -updateOnMainThread:.
    func replaceIndex() {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = Stage.coordinator()
        managedObjectContext = context
    }

@REMOTE_MEMBERS@
}

@REMOTE_FUNCTIONS@
'''

DRIVER = r'''
import CoreData
import Foundation

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

let work = CommandLine.arguments[1]
let files = FileManager.default

func sentNow() -> [RemoteDicomDatabase.Sent] {
    RemoteDicomDatabase.sentLock.lock()
    defer { RemoteDicomDatabase.sentLock.unlock() }
    return RemoteDicomDatabase.sent
}

/// The sender runs on a thread of its own: what it sent, after it had the time to
/// send `count` requests and, when that is what is expected, nothing more.
func waitForSends(_ count: Int) -> [RemoteDicomDatabase.Sent] {
    let deadline = Date().addingTimeInterval(10)
    while sentNow().count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    Thread.sleep(forTimeInterval: 0.1)
    return sentNow()
}

func reset() {
    RemoteDicomDatabase.sentLock.lock()
    RemoteDicomDatabase.sent = []
    RemoteDicomDatabase.attempts = 0
    RemoteDicomDatabase.outcomes = []
    Stage.warnings = 0
    RemoteDicomDatabase.sentLock.unlock()
    Stage.indexed = []
    Stage.headers = []
    DatabaseIngest.passes = []
}

func counted() -> (attempts: Int, warnings: Int) {
    RemoteDicomDatabase.sentLock.lock()
    defer { RemoteDicomDatabase.sentLock.unlock() }
    return (RemoteDicomDatabase.attempts, Stage.warnings)
}

/// The sender after it made `attempts` requests and had the time to note what
/// they did not send.
func waitForAttempts(_ attempts: Int) {
    let deadline = Date().addingTimeInterval(10)
    while counted().attempts < attempts && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    Thread.sleep(forTimeInterval: 0.2)
}

var databases = 0
func newDatabase() -> RemoteDicomDatabase {
    databases += 1
    let database = RemoteDicomDatabase(folder: work + "/db\(databases)")
    database.address = "server"
    for folder in [database.dataDirPath()!, database.tempDirPath()!, database.incomingDirPath()!] {
        try! files.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    Stage.dataDirectory = database.dataDirPath()
    Stage.cachedPath = { database.localPath(for: $0) }
    return database
}

func write(_ name: String, in folder: String) -> String {
    let path = folder + "/" + name
    try! Data(name.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

func add(_ database: DicomDatabase, _ paths: [String], generated: Bool = false, imported: Bool = false, returnArray: Bool = true) -> [Any]? {
    var added: [Any]?
    database.managedObjectContext.performAndWait {
        added = database.addFiles(atPaths: paths, postNotifications: true, dicomOnly: true, rereadExistingItems: true,
                                  generatedByOsiriX: generated, importedFiles: imported, returnArray: returnArray)
    }
    return added
}

// --- a generated object, written in the database's folder ---------------------
let one = newDatabase()
let capture = write("100.dcm", in: one.dataDirPath())
let ids = add(one, [capture], generated: true)
var sent = waitForSends(1)
check(sent.count == 1, "the generated file reached no send: \(sent.count)")
check(sent[0].command == "SENDG" && sent[0].address == "server", "a generated file went as \(sent[0].command) to \(sent[0].address ?? "nobody")")
check(sent[0].files == [Data("100.dcm".utf8)], "the request does not hold the file")
check(ids?.count == 1, "the addition lost its answer")
check(!files.fileExists(atPath: capture), "the file stayed in the database folder of a remote database")
var cached: String?
var named: String?
let answered = one.objects(withIDs: ids)!.first as! DicomImage
for _ in 0..<500 {
    one.managedObjectContext.performAndWait {
        one.managedObjectContext.refreshAllObjects()
        named = answered.path
    }
    if named == "7000.dcm" { break }
    Thread.sleep(forTimeInterval: 0.01)
}
one.managedObjectContext.performAndWait { cached = one.localPath(for: answered) }
check(cached != nil && files.fileExists(atPath: cached!), "the file is not in the cache of the remote database")
check(named == "7000.dcm", "the image did not take the name the server answered: \(named ?? "nil")")

// --- anything else ------------------------------------------------------------------
reset()
let elsewhere = write("dropped.dcm", in: work)
_ = add(one, [elsewhere], imported: true)
sent = waitForSends(1)
check(sent.count == 1 && sent[0].command == "SENDD", "a file that was not generated went as \(sent.first?.command ?? "nothing")")
check(Stage.indexed.count == 1 && Stage.indexed[0].imported && !Stage.indexed[0].generated, "the indexer was not told what was asked: \(Stage.indexed)")
check(files.fileExists(atPath: elsewhere), "a file outside the database folder was taken from where it was")

// --- the variants with fewer arguments send once --------------------------------------
reset()
let other = write("other.dcm", in: work)
one.managedObjectContext.performAndWait {
    _ = one.addFilesDescribed(inDictionaries: [["filePath": other, "frames": 1] as NSDictionary], postNotifications: true, rereadExistingItems: true,
                              generatedByOsiriX: true, returnArray: true)
}
sent = waitForSends(1)
check(sent.count == 1 && Stage.indexed.count == 1, "the variant of five arguments sent \(sent.count) times and indexed \(Stage.indexed.count)")
reset()
one.managedObjectContext.performAndWait {
    _ = one.addFilesDescribed(inDictionaries: [["filePath": other, "frames": 1] as NSDictionary], postNotifications: true, rereadExistingItems: true,
                              generatedByOsiriX: false)
}
sent = waitForSends(1)
check(sent.count == 1 && Stage.indexed.count == 1, "the variant of four arguments sent \(sent.count) times and indexed \(Stage.indexed.count)")

// --- no array asked for ---------------------------------------------------------------
reset()
let quiet = add(one, [other], returnArray: false)
sent = waitForSends(1)
check(sent.count == 1, "an addition that asked for no array sent nothing")
check(Stage.indexed.first?.returnArray == true, "the override does not ask for what it needs to send")
check(quiet == nil, "an addition that asked for no array got one")
reset()
var direct: [Any]? = []
one.managedObjectContext.performAndWait {
    direct = one.addFilesDescribed(inDictionaries: [["filePath": other, "frames": 1] as NSDictionary], postNotifications: true, rereadExistingItems: true,
                                   generatedByOsiriX: false, importedFiles: false, returnArray: false)
}
check(direct == nil && waitForSends(1).count == 1, "the indexer asked directly for no array got one, or sent nothing")

// --- an independent database has no address --------------------------------------------
reset()
let worker = RemoteDicomDatabase(folder: one.folder, main: one)
check(worker.address == nil, "the double of an independent database has an address")
let imported = write("101.dcm", in: one.dataDirPath())
_ = add(worker, [imported])
sent = waitForSends(1)
check(sent.count == 1 && sent[0].address == "server", "an independent database sent to \(sent.first?.address ?? "nobody")")

// --- one file, many frames ----------------------------------------------------------
reset()
let frames = write("frames.dcm", in: work)
_ = add(one, [frames], generated: true)
sent = waitForSends(1)
check(sent.count == 1 && sent[0].files.count == 1, "a file of three frames went \(sent.first?.files.count ?? 0) times")
reset()
let framesInFolder = write("frames-in.dcm", in: one.dataDirPath())
let framesIDs = add(one, [framesInFolder], generated: true)
sent = waitForSends(1)
check(sent.count == 1 && sent[0].files == [Data("frames-in.dcm".utf8)],
      "a file of three frames in the database folder went as \(sent.first?.files.map(\.count) ?? []) of \(sent.count) requests")
var framesCached: String?
one.managedObjectContext.performAndWait { framesCached = one.localPath(for: one.objects(withIDs: framesIDs)!.first as? DicomImage) }
check(framesCached != nil && files.fileExists(atPath: framesCached!), "the next frame removed the file the first moved to the cache")
reset()
let framesKept = write("frames-kept.dcm", in: one.dataDirPath())
let keptIDs = add(one, [framesKept], generated: true)
sent = waitForSends(1)
check(sent.count == 1 && sent[0].files == [Data("frames-kept.dcm".utf8)],
      "frames that remember the path before the move went as \(sent.first?.files.map(\.count) ?? []) of \(sent.count) requests")
var keptCached: String?
one.managedObjectContext.performAndWait { keptCached = one.localPath(for: one.objects(withIDs: keptIDs)!.first as? DicomImage) }
check(keptCached != nil && files.fileExists(atPath: keptCached!), "a frame that remembered the path before the move removed the file the first moved")

// --- plain DICOM files, whose headers are read side by side ---------------------------
reset()
let plain = (1...5).map { number -> String in
    let path = work + "/plain-\(number).dcm"
    try! (Data(count: 128) + Data("DICM plain-\(number)".utf8)).write(to: URL(fileURLWithPath: path))
    return path
}
_ = add(one, plain)
sent = waitForSends(1)
check(Stage.headers.map(\.path) == plain && Stage.headers.allSatisfy { $0.header == $0.path },
      "the files of a batch did not each come with their own header, in order: \(Stage.headers.map { ($0.header ?? "none") as NSString }.map(\.lastPathComponent))")
check(sent.count == 1 && Set(sent[0].files) == Set(plain.map { try! Data(contentsOf: URL(fileURLWithPath: $0)) }) && sent[0].files.count == plain.count,
      "the files of a batch whose headers were read side by side went as \(sent.map { $0.files.map(\.count) })")

// --- a new index meanwhile -----------------------------------------------------------
reset()
let second = newDatabase()
let late = write("late.dcm", in: work)
var lateIDs: [Any]?
second.managedObjectContext.performAndWait {
    lateIDs = second.addFilesDescribed(inDictionaries: [] as [Any], postNotifications: true, rereadExistingItems: true, generatedByOsiriX: false, importedFiles: false, returnArray: true)
}
check(lateIDs?.isEmpty == true && waitForSends(0).isEmpty, "an addition of nothing sent something")
let stale = second.managedObjectContext.persistentStoreCoordinator!
let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = stale
var staleID: NSManagedObjectID!
context.performAndWait {
    let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
    try! context.save()
    staleID = image.objectID
}
second.replaceIndex()
let caughtBefore = HorosCaughtExceptions
RemoteDicomDatabase._uploadFilesAtPathsGeneratedByOsiriX(NSArray(objects: [late] as NSArray, [staleID!] as NSArray, NSNumber(value: false), second))
check(sentNow().count == 1, "a new index lost the file")
check(HorosCaughtExceptions == caughtBefore, "the images of the replaced index were looked up in the new one, and Core Data raised")

// --- the incoming folder -----------------------------------------------------------------
reset()
let third = newDatabase()
third.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
third._updateTimerCallback()
check(DatabaseIngest.passes.isEmpty, "an empty folder asked for a pass")
_ = write("url-1.zip", in: third.incomingDirPath())
third.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
check(DatabaseIngest.passes.count == 1 && DatabaseIngest.passes[0] === third, "what waits in the folder asked for no pass")
RemoteDicomDatabase(folder: third.folder, main: third).initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
check(DatabaseIngest.passes.count == 2, "an independent database asked for no pass")
third._updateTimerCallback()
check(DatabaseIngest.passes.count == 3, "the update timer does not look at the folder")

// --- an upload that fails, and the next update ------------------------------------------
reset()
let fourth = newDatabase()
RemoteDicomDatabase.outcomes = [false]
let refusedIDs = add(fourth, [write("200.dcm", in: fourth.dataDirPath())], generated: true)
waitForAttempts(1)
check(sentNow().isEmpty && counted().warnings == 1, "a failed upload sent \(sentNow().count) and told the person \(counted().warnings) times")
var waiting: String?
fourth.managedObjectContext.performAndWait { waiting = fourth.localPath(for: fourth.objects(withIDs: refusedIDs)!.first as? DicomImage) }
check(waiting != nil && files.fileExists(atPath: waiting!), "the file of a failed upload is not where the next attempt looks")
fourth._updateTimerCallback()
sent = waitForSends(1)
check(sent.count == 1 && sent[0].command == "SENDG" && sent[0].files == [Data("200.dcm".utf8)],
      "the next update sent \(sent.map(\.command)) with \(sent.first?.files.count ?? 0) files")
fourth._updateTimerCallback()
Thread.sleep(forTimeInterval: 0.3)
check(sentNow().count == 1 && counted().warnings == 1, "what arrived was sent again, or the person was told again")

// --- several requests: only what the server did not answer, and one alert --------------
reset()
let big = work + "/big.dcm"
try! Data(count: 33 * 1024 * 1024).write(to: URL(fileURLWithPath: big))
let small = write("small.dcm", in: work)
RemoteDicomDatabase.outcomes = [true, false]
_ = add(fourth, [big, small])
check(Stage.headers.isEmpty, "files that are not plainly DICOM came to their read with a header")
waitForAttempts(2)
sent = sentNow()
check(sent.count == 1 && sent[0].files.count == 1 && sent[0].files[0].count == 33 * 1024 * 1024,
      "the first request of the upload did not arrive alone: \(sent.map { $0.files.map(\.count) })")
check(counted().warnings == 1, "the failure of the second request told the person \(counted().warnings) times")
RemoteDicomDatabase.sentLock.lock()
RemoteDicomDatabase.outcomes = [false]
RemoteDicomDatabase.sentLock.unlock()
fourth._updateTimerCallback()
waitForAttempts(3)
check(sentNow().count == 1 && counted().warnings == 1, "a second failure in a row told the person again, or sent something")
fourth._updateTimerCallback()
sent = waitForSends(2)
check(sent.count == 2 && sent[1].command == "SENDD" && sent[1].files == [Data("small.dcm".utf8)],
      "the next update did not send only what had not arrived: \(sent.dropFirst().map { "\($0.command) \($0.files.map(\.count))" })")
fourth._updateTimerCallback()
Thread.sleep(forTimeInterval: 0.3)
check(sentNow().count == 2, "what arrived was sent again")

// --- the index an update replaced, and the contexts that still use it -------------------
let fifth = newDatabase()
let replaced = URL(fileURLWithPath: work + "/file-replaced")
var writer: NSManagedObjectContext? = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
autoreleasepool {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Stage.coordinator().managedObjectModel)
    try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: replaced, options: nil)
    let previous = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    previous.persistentStoreCoordinator = coordinator
    writer!.persistentStoreCoordinator = coordinator
    fifth.retireIndex(of: previous)
}
autoreleasepool { fifth.retireIndex(of: nil) }
check(files.fileExists(atPath: replaced.path), "an index a context still uses was removed at the next update")
var savedInReplaced = false
autoreleasepool {
    writer!.performAndWait {
        _ = NSEntityDescription.insertNewObject(forEntityName: "Image", into: writer!)
        savedInReplaced = (try? writer!.save()) != nil
    }
}
check(savedInReplaced, "a context could not save in the index an update replaced")
autoreleasepool { writer = nil }
var retired = false
for _ in 0..<200 where !retired {
    autoreleasepool { fifth.retireIndex(of: nil) }
    retired = !files.fileExists(atPath: replaced.path)
    if !retired { Thread.sleep(forTimeInterval: 0.01) }
}
check(retired, "the index an update replaced stayed once nothing used it")
print("ok")
'''


def main():
    remote = (root / 'Horos/Sources/RemoteDicomDatabase.swift').read_text(encoding='utf-8')
    importer = (root / 'Horos/Sources/DicomFileIndexer.swift').read_text(encoding='utf-8')
    reading = (root / 'Horos/Sources/DicomFile+DICOMReading.swift').read_text(encoding='utf-8')

    overrides = indicator.swift_code(remote).count('override func addFilesDescribed(')
    if overrides != 1:
        print('FAIL: %d overrides of addFilesDescribed: the shorter variants come to the one that takes importedFiles, and a second one sends twice' % overrides)
        return 1

    # The indexer's read of the files is a member of DicomFileIndexer; the
    # selectors of the database forward to it. It reads the headers of a batch
    # through ParsedDICOMFiles, compiled as written over the doubles of the
    # read of one header and of the plugins' formats.
    parsed_files = member(reading, 'struct ParsedDICOMFiles {')
    indexer_members = [member(importer, 'func addFiles(atPaths paths: NSArray?, postNotifications: Bool, dicomOnly: Bool, '
                                        'rereadExistingItems: Bool, generatedByOsiriX: Bool,\n'),
                       member(importer, 'static func process(_ database: DicomDatabase) -> DicomFileIndexer {')]
    import_members = [member(importer, signature) for signature in (
        'func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {',
        'func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool) -> [Any]! {',
        'func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {')]
    remote_members = [member(remote, signature) for signature in (
        '@objc(localPathForImage:)',
        'public override func addFilesDescribed(',
        '@objc(_uploadFilesAtPathsGeneratedByOsiriX:)',
        '@objc(uploadFilesAtPaths:imageObjects:generatedByOsiriX:)',
        'private func uploadFiles(atPaths paths: [Any]?, imageObjects images: [Any]?, generatedByOsiriX: Bool, arrived: inout Int) throws {',
        'private func send(',
        'private func recordUpload(',
        'private func sendWhatWaits(',
        'private func retireIndex(',
        '@objc(_data:appendInt:)',
        '@objc(_data:appendStringUTF8:)',
        '@objc(data:readInteger:)',
        '@objc func _updateTimerCallback() {',
        'public override func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {',
        'private func requestPassForFilesThatWait() {')]
    remote_functions = [member(remote, signature) for signature in (
        'private enum SharedDatabaseClientFailure',
        'private func raisingForObjectiveC<',
        'private func remoteDicomDatabaseAdd(',
        'private final class RemoteDicomDatabaseWaitingUploads',
        'private struct RemoteDicomDatabaseReplacedIndex')]
    waiting_property = re.search(r'^[ \t]*private let waitingUploads = .*$', remote, re.M)
    if not waiting_property:
        print('FAIL: the main database keeps no waitingUploads')
        return 1
    replaced_property = re.search(r'^[ \t]*private var _replacedIndexes: .*$', remote, re.M)
    if not replaced_property:
        print('FAIL: the main database keeps no _replacedIndexes')
        return 1
    # The driver calls the retirement itself, as -updateOnMainThread: does.
    remote_members = [m.replace('private func retireIndex(', 'func retireIndex(') for m in remote_members]

    with tempfile.TemporaryDirectory(prefix='horos-remote-add-') as directory:
        work = Path(directory)
        (work / 'Support.h').write_text(SUPPORT_H)
        (work / 'Support.m').write_text(SUPPORT_M)
        (work / 'stage.swift').write_text(STAGE.replace('@IMPORT_MEMBERS@', '\n\n'.join(import_members))
                                          .replace('@PARSED_FILES@', parsed_files)
                                          .replace('@INDEXER_MEMBERS@', '\n\n'.join(indexer_members))
                                          .replace('@REMOTE_MEMBERS@', '\n\n'.join(remote_members))
                                          .replace('@WAITING_PROPERTY@', waiting_property.group(0))
                                          .replace('@REPLACED_PROPERTY@', replaced_property.group(0))
                                          .replace('@REMOTE_FUNCTIONS@', '\n\n'.join(remote_functions)))
        (work / 'main.swift').write_text(DRIVER)
        subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(work), str(work / 'Support.m'), '-o', str(work / 'Support.o')],
                       check=True, timeout=120)
        subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-import-objc-header', str(work / 'Support.h'),
                        *isix_modules.module_flags('IsiXPreferences', work / 'internal'),
                        str(work / 'stage.swift'), *isix_modules.log_text_sources(), str(work / 'main.swift'),
                        str(work / 'Support.o'), '-o', str(work / 'check')],
                       check=True, timeout=200)
        data = work / 'data'
        data.mkdir()
        run = subprocess.run([str(work / 'check'), str(data)], capture_output=True, text=True, timeout=60)
        if run.returncode or run.stdout.strip() != 'ok':
            print('FAIL:', (run.stdout + run.stderr).strip()[-1500:])
            return 1
    print('remote database: addFiles reaches the upload once, as SENDG or SENDD, through the main database, one file per '
          'multi-frame object, also across a new index; what waits in the incoming folder asks for a pass; a failed upload '
          'waits for the next update, tells the person once and is not sent twice; a replaced index stays while in use')
    return 0


if __name__ == '__main__':
    sys.exit(main())
