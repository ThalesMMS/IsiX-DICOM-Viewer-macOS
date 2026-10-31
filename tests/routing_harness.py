"""Compile the autorouting of the app, as it is or as an earlier revision had
it, over doubles that record what it queues and sends, for the routing tests.

The doubles are the same whatever the revision:
- a Core Data model in memory with the attributes the routing reads (Study,
  Series and Image as DicomStudy, DicomSeries and DicomImage, answering by key
  as Core Data does and by property as Swift reads them), saved, so that the
  images have the permanent IDs an import gives them;
- DicomDatabase, over that model: one local main database, its own
  private-queue database, the smart-album predicate (the filter text itself);
- DCMTKStoreSCU, which records every association it is asked for and never
  opens one, failing for a file whose name says "fail";
- the C-FIND of a destination (QueryController.queryStudyInstanceUID), which
  answers the image counts a case sets and records what it was asked;
- the thread manager, the preferences of the registration domain only (no
  persistent domain is written), and what the process graph reads.

The revision before the routing moved to IsiXDICOMNetwork applied the rules in
DicomDatabase+Routing.swift with RoutingSchedule, RoutingDestination and
PreviousRoutingStudies of the app; this tree applies them through
DatabaseRouting and the module's RoutingSelection and RoutingQueue, built with
`-D ROUTING_ACTOR`.

Each record is one line of text:
  queue <rule> -> <server> retry <n> | <files>       what is queued
  store <calling> -> <called>@<host>:<port> syntax <n> compression <f> | <files> | <TLS view>
  cfind <Study Instance UID> @ <AE title>             a C-FIND of a destination
The files of a line are sorted: the order of the files within a batch is not
compared, the batches and their order are.
"""
from pathlib import Path
import subprocess

import isix_modules
import send_controller_harness

ROOT = Path(__file__).resolve().parents[1]

DOUBLES = r'''
import AppKit
import CoreData
#if ROUTING_ACTOR
import IsiXDICOMNetwork
import IsiXDatabase
import IsiXPreferences
#endif

nonisolated(unsafe) var recorded: [String] = []
let recordLock = NSLock()

func record(_ line: String) {
    recordLock.lock(); recorded.append(line); recordLock.unlock()
}

// MARK: The model

@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @NSManaged var patientID: String!
    @NSManaged var patientUID: String!
    @NSManaged var name: String!
    @NSManaged var studyName: String!
    @NSManaged var studyInstanceUID: String!
    @NSManaged var date: Date!
    @NSManaged var modality: String!
    @NSManaged var fileCount: NSNumber!
    @NSManaged var series: NSSet!
    @objc func noFiles() -> NSNumber! { fileCount }
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @NSManaged var study: DicomStudy!
    @NSManaged var images: Set<AnyHashable>!
}

@objc(DicomImage) final class DicomImage: NSManagedObject {
    @NSManaged var pathString: String!
    @NSManaged var storage: NSNumber!
    @NSManaged var importedFile: NSNumber!
    @NSManaged var series: DicomSeries!
    @objc func completePath() -> String! { pathString }
    @objc func isImageStorage() -> NSNumber! { storage }
}

func makeModel() -> NSManagedObjectModel {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    let study = NSEntityDescription(), series = NSEntityDescription(), image = NSEntityDescription()
    study.name = "Study"; study.managedObjectClassName = "DicomStudy"
    series.name = "Series"; series.managedObjectClassName = "DicomSeries"
    image.name = "Image"; image.managedObjectClassName = "DicomImage"
    let studySeries = NSRelationshipDescription(), seriesStudy = NSRelationshipDescription()
    studySeries.name = "series"; studySeries.destinationEntity = series; studySeries.minCount = 0; studySeries.maxCount = 0
    studySeries.deleteRule = .cascadeDeleteRule
    seriesStudy.name = "study"; seriesStudy.destinationEntity = study; seriesStudy.maxCount = 1
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    let seriesImages = NSRelationshipDescription(), imageSeries = NSRelationshipDescription()
    seriesImages.name = "images"; seriesImages.destinationEntity = image; seriesImages.minCount = 0; seriesImages.maxCount = 0
    seriesImages.deleteRule = .cascadeDeleteRule
    imageSeries.name = "series"; imageSeries.destinationEntity = series; imageSeries.maxCount = 1
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("patientID", .stringAttributeType), attribute("patientUID", .stringAttributeType),
                        attribute("name", .stringAttributeType), attribute("studyName", .stringAttributeType),
                        attribute("studyInstanceUID", .stringAttributeType), attribute("date", .dateAttributeType),
                        attribute("modality", .stringAttributeType), attribute("fileCount", .integer32AttributeType),
                        studySeries]
    series.properties = [seriesStudy, seriesImages]
    image.properties = [attribute("pathString", .stringAttributeType), attribute("storage", .booleanAttributeType),
                        attribute("importedFile", .booleanAttributeType), attribute("generatedByOsiriX", .booleanAttributeType),
                        imageSeries]
    let model = NSManagedObjectModel()
    model.entities = [study, series, image]
    return model
}

// MARK: The database

public class DicomDatabase: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var shared: DicomDatabase!
    let context: NSManagedObjectContext
    let folder: String
    // What the former routing kept in the database.
    var routingSendQueues: NSMutableArray?
    var routingLock: NSRecursiveLock?

    init(folder: String) {
        self.folder = folder
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: makeModel())
        _ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        super.init()
    }

    var dataBaseDirPath: String! { folder }
    var baseDirPath: String! { folder }
    var mainDatabase: Any? { nil }
    var managedObjectContext: NSManagedObjectContext! { context }
    func isMainDatabase() -> Bool { true }
    func isLocal() -> Bool { true }
    class func allDatabases() -> [Any]! { shared.map { [$0] } ?? [] }
    class func activeLocal() -> DicomDatabase! { shared }
    class func `default`() -> DicomDatabase! { shared }
    func privateQueueIndependentDatabase() -> Any! { self }
    func performBlockAndWait(_ block: () -> Void) { context.performAndWait(block) }
    func studyEntity() -> NSEntityDescription! { context.persistentStoreCoordinator!.managedObjectModel.entitiesByName["Study"] }

    func objects(withIDs objectIDs: [Any]!) -> [Any]! {
        var found: [Any] = []
        context.performAndWait {
            for identifier in objectIDs ?? [] {
                var objectID = identifier as? NSManagedObjectID
                if let text = identifier as? String, let url = URL(string: text) {
                    objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
                }
                if let objectID, let object = try? context.existingObject(with: objectID) {
                    found.append(object)
                }
            }
        }
        return found
    }

    func objects(forEntity e: Any!, predicate p: NSPredicate!) -> [Any]! {
        var found: [Any] = []
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
            request.predicate = p
            found = (try? context.fetch(request)) ?? []
        }
        return found
    }

    /// The filter as a predicate, as DicomDatabase makes one: everything for no filter.
    class func predicate(forSmartAlbumFilter string: String!) -> NSPredicate! {
        if ((string as NSString?)?.length ?? 0) == 0 { return NSPredicate(value: true) }
        return NSPredicate(format: string)
    }
}

// MARK: What the routing calls

func _N2LogExceptionImpl(_ exception: NSException?, _ stack: Bool, _ function: UnsafePointer<CChar>?) {
    NSLog("logged exception: %@", exception?.reason ?? "")
}

func DicomDatabaseLogError(_ function: String, _ file: String, _ line: Int32, _ message: String) {
    NSLog("%@", message)
}

extension UserDefaults {
    class func defaultAETitle() -> String { "HARNESS" }
}

final class ThreadsManager: NSObject, @unchecked Sendable {
    static let shared = ThreadsManager()
    class func `default`() -> ThreadsManager! { shared }
    func addThreadAndStart(_ thread: Thread!) {
        if !thread.isExecuting && !thread.isFinished { thread.start() }
    }
}

nonisolated(unsafe) private var statusKey = 0, cancelKey = 0, progressKey = 0
extension Thread {
    @objc var status: String? {
        get { objc_getAssociatedObject(self, &statusKey) as? String }
        set { objc_setAssociatedObject(self, &statusKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }
    @objc var supportsCancel: Bool {
        get { (objc_getAssociatedObject(self, &cancelKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &cancelKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN) }
    }
    @objc var progress: CGFloat {
        get { (objc_getAssociatedObject(self, &progressKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
        set { objc_setAssociatedObject(self, &progressKey, NSNumber(value: Double(newValue)), .OBJC_ASSOCIATION_RETAIN) }
    }
    func enterOperation(withRange start: CGFloat, _ length: CGFloat) {}
    func exitOperation() {}
}

struct StoreSendFailure: Error {
    let name: String
    let reason: String
}

final class DCMTKStoreSCU: NSObject {
    let files: [String]
    let line: String

    init(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, filesToSend: [Any]?,
         transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        files = (filesToSend ?? []).compactMap { $0 as? String }
        func text(_ key: String) -> String {
            guard let value = extraParameters?[key] else { return "-" }
            return (value as? NSNumber)?.stringValue ?? "\(value)"
        }
        let tls = "tls \(text("TLSEnabled")) \(text("TLSAuthenticated"))"
        line = "store \(callingAET ?? "(null)") -> \(calledAET ?? "(null)")@\(hostname ?? "(null)"):\(port) syntax \(transferSyntax) "
            + "compression \(compression) | \(files.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ",")) | \(tls)"
        super.init()
    }

    private func perform() -> StoreSendFailure? {
        record(line)
        return files.contains { ($0 as NSString).lastPathComponent.contains("fail") }
            ? StoreSendFailure(name: "DICOM Network Failure (STORE-SCU)", reason: "files not sent") : nil
    }

    func run(_ operation: Operation!) {
        if let failure = perform() {
            NSException(name: NSExceptionName(failure.name), reason: failure.reason, userInfo: nil).raise()
        }
    }

    func sendReportingFailure(_ operation: Operation? = nil) -> StoreSendFailure? {
        perform()
    }
}

/// The node a C-FIND answers with.
final class DCMTKQueryNode: NSObject {
    let count: NSNumber?
    init(_ count: NSNumber?) { self.count = count }
    @objc func numberImages() -> NSNumber! { count }
}

/// The image counts each destination answers for a study, by Study Instance UID.
nonisolated(unsafe) var remoteCounts: [String: [Int]] = [:]

final class QueryController: NSObject {
    class func queryStudyInstanceUID(_ an: String!, server aServer: [AnyHashable: Any]!, showErrors: Bool) -> [Any]! {
        record("cfind \(an ?? "") @ \(aServer?["AETitle"] as? String ?? "")")
        return (remoteCounts[an ?? ""] ?? []).map { DCMTKQueryNode(NSNumber(value: $0)) }
    }
}

#if ROUTING_ACTOR

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
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }

    static func log(_ exception: NSException, stack: Bool, _ function: String) {
        NSLog("logged exception: %@", exception.reason ?? "")
    }
}

struct HarnessNodePreferences: DICOMNodePreferences {
    func object(forKey key: String) -> Any? { UserDefaults.standard.object(forKey: key) }
    func bool(forKey key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    func string(forKey key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    func set(_ value: Any?, forKey key: String) {}
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}

enum DICOMNodeService {
    static let store = DICOMNodeStore(preferences: HarnessNodePreferences())
}

// The singletons the process graph reads; the routing never reaches them.
@MainActor final class BrowserController: NSObject {
    nonisolated static func currentBrowser() -> BrowserController! { nil }
    nonisolated func isNetworkLogsActive() -> Bool { false }
    nonisolated var database: DicomDatabase! { nil }
    nonisolated func addFile(toDeleteQueue file: String!) {}
}

@MainActor final class AppController: NSObject {
    nonisolated static func shared() -> AppController! { nil }
    nonisolated var bonjourPublisher: BonjourPublisher! { nil }
    var browserWindow: BrowserWindowGraph? { nil }
    var recentStudiesMenu: NSMenu! { nil }
    // The Dock's receiving indicator, which any thread reaches through the graph.
    nonisolated let receivingIndicator = ReceivingIndicator()
    final class ReceivingIndicator: Sendable { nonisolated func showReceiving(_ receiving: Bool) {} }
}

@MainActor final class BonjourPublisher: NSObject {}

// The members the process graph makes for the application; never reached here.
@MainActor final class BrowserWindowGraph {}
@MainActor final class DICOMListenerController {
    nonisolated init(processGraph: ProcessGraph) {}
    nonisolated var isSessionInactive: Bool { false }
}
@MainActor final class UserNotificationDelivery { nonisolated init() {} }
@MainActor final class ViewerWindowArranger { nonisolated init(processGraph: ProcessGraph) {} }
@MainActor final class ApplicationMenus {
    init(recentStudiesMenu: @escaping @MainActor () -> NSMenu?, processGraph: ProcessGraph) {}
}

@MainActor final class ViewerController: NSObject {
    static func areLoadingViewers() -> Bool { false }
}
// The register of the viewers, a member of the process graph.
nonisolated final class ViewerRegistry: Sendable {}
// The presets menus and the last colour table of the viewers, members of the process graph.
@MainActor final class PresetMenuCache { nonisolated init() {} }
@MainActor final class ColourTableCache { nonisolated init() {} }
@MainActor final class ViewerSyncState { nonisolated init() {} }
// The ROI archives of a viewer's images, which the process graph makes for the viewers.
@MainActor final class ViewerROIArchiveStore {
    init(images: [DicomImage], database: DicomDatabase, ingest: DatabaseIngest) {}
}

struct DatabaseIngest { init(processGraph: ProcessGraph) {} }

// The PACS On-Demand nodes over QueryController, a member of the process graph that routing never asks.
struct QueryControllerDistantStudies: DistantStudyQuerying {
    let preferences: any PreferenceStore
    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] { [] }
    func patientStudies(of patient: String, activity: String) async -> [DistantStudySummary] { [] }
}

// The reader of a local database the graph hands out, which routing never asks for.
final class LocalDatabaseStudyReader: @unchecked Sendable {
    init(database: @escaping @Sendable () -> DicomDatabase?) {}
}
#endif
'''


# The model, the cases and the records, the same for every revision.
DRIVER_PRELUDE = r'''
import AppKit
import CoreData
#if ROUTING_ACTOR
import IsiXDICOMNetwork
#endif

let folder = CommandLine.arguments[2]
let database = DicomDatabase(folder: folder)
DicomDatabase.shared = database
let context = database.context

/// A study with its images; a path that says "missing" has no file.
@discardableResult
func study(_ patientID: String?, _ uid: String, _ modality: String, _ name: String, days: Double,
           files: [(String, image: Bool, generated: Bool, imported: Bool)], patientUID: String? = nil,
           fileCount: Int = -1) -> [DicomImage] {
    var images: [DicomImage] = []
    context.performAndWait {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
        study.patientID = patientID
        study.patientUID = patientUID ?? patientID
        study.name = "Name " + (patientID ?? "none")
        study.studyName = name
        study.studyInstanceUID = uid
        study.modality = modality
        study.date = Date(timeIntervalSinceReferenceDate: 800_000_000 - days * 86_400)
        study.fileCount = NSNumber(value: fileCount < 0 ? files.count : fileCount)
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as! DicomSeries
        series.study = study
        for (name, isImage, generated, imported) in files {
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
            let path = folder + "/" + name + ".dcm"
            image.pathString = path
            image.storage = NSNumber(value: isImage)
            image.importedFile = NSNumber(value: imported)
            image.setValue(NSNumber(value: generated), forKey: "generatedByOsiriX")
            image.series = series
            if !name.contains("missing") {
                FileManager.default.createFile(atPath: path, contents: Data())
            }
            images.append(image)
        }
        try! context.save()
    }
    return images
}

func plain(_ names: String...) -> [(String, image: Bool, generated: Bool, imported: Bool)] {
    names.map { ($0, image: true, generated: false, imported: false) }
}

func node(_ name: String, _ aet: String, _ port: Any, _ extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["Description": name, "AETitle": aet, "Address": "127.0.0.1", "Port": port]
    for (key, value) in extra { entry[key] = value }
    return entry
}

let servers: [[String: Any]] = [
    node("PACS", "PACS", "11112", ["Activated": true, "TransferSyntax": 0]),
    node("ARCHIVE", "ARCH", 104, ["Activated": true, "TransferSyntax": 5]),
    node("TWIN", "TWIN1", "201", ["Activated": true]),
    node("TWIN", "TWIN2", "202", ["Activated": true]),
    node("OFF", "OFF", "301", ["Activated": false]),
    node("NOKEY", "NOKEY", "401"),
    node("SECURE", "SECURE", 4242, ["Activated": "1", "TransferSyntax": "13", "TLSEnabled": true, "TLSAuthenticated": "YES"]),
]

func names(_ rules: [[String: Any]]) -> [Any] { rules }

func lines() -> [String] {
    recordLock.lock(); defer { recordLock.unlock() }
    return recorded
}

func spin(_ seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
    }
}

/// Applies rules as the import or the database window does, on the database's queue.
func apply(_ rules: [[String: Any]]?, _ images: [DicomImage]) {
    context.performAndWait {
#if ROUTING_ACTOR
        database.applyRoutingRules(rules, toImages: images)
#else
        database.applyRoutingRules(rules.map { $0 as NSArray }, toImages: images as NSArray)
#endif
    }
}

func queueForRule(_ images: [DicomImage], _ rule: [String: Any]) {
    context.performAndWait {
#if ROUTING_ACTOR
        database.addImages(images, toSendQueueForRoutingRule: rule)
#else
        database.addImages(images as NSArray, toSendQueueForRoutingRule: rule as NSDictionary)
#endif
    }
}

/// What is queued, one line per list.
func recordQueue() {
    spin(0.3)
#if ROUTING_ACTOR
    let queue = ProcessGraph.process.routingQueue
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var orders: [RoutingOrder] = []
    Task.detached { orders = await queue.queued; done.signal() }
    done.wait()
    for order in orders {
        // The images still in the database, as the former queue, which kept
        // their IDs, read them back.
        let there = Set((database.objects(withIDs: order.files.map(\.id)) ?? []).compactMap { ($0 as? DicomImage)?.completePath() })
        let paths = order.files.compactMap(\.path).filter(there.contains).map { ($0 as NSString).lastPathComponent }.sorted()
        record("queue \(order.rule?.name ?? "(null)") -> \(order.destinationName ?? "(null)") retry \(order.failureRetry) | \(paths.joined(separator: ","))")
    }
#else
    var lines: [String] = []
    context.performAndWait {
        for case let order as NSDictionary in database.routingSendQueues ?? [] {
            let objects = database.objects(withIDs: order["objectIDs"] as? [Any]) ?? []
            let paths = objects.compactMap { ($0 as? DicomImage)?.completePath() }.map { ($0 as NSString).lastPathComponent }.sorted()
            let rule = (order["routingRule"] as? NSDictionary)?["name"] as? String ?? "(null)"
            // -intValue, as the queue read it: a number, or the text the pane wrote.
            let retry = (order["failureRetry"] as? NSNumber)?.int32Value ?? (order["failureRetry"] as? NSString)?.intValue ?? 0
            lines.append("queue \(rule) -> \(order["server"] as? String ?? "(null)") retry \(retry) | \(paths.joined(separator: ","))")
        }
    }
    lines.forEach(record)
#endif
}

/// Sends what is queued, and waits for it.
func drain() {
#if ROUTING_ACTOR
    let queue = ProcessGraph.process.routingQueue
    let delivery = DatabaseRoutingDelivery(processGraph: ProcessGraph.process)
    let done = DispatchSemaphore(value: 0)
    Task.detached { await queue.drain(through: delivery); done.signal() }
    while done.wait(timeout: .now() + 0.02) == .timedOut {
        autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }
#else
    database.performBlockAndWait { database.routing() }
#endif
    spin(0.2)
}

func deleteImage(_ image: DicomImage) {
    context.performAndWait {
        context.delete(image)
        try! context.save()
    }
}
'''

DRIVER_END = r'''
print("finished")
for line in lines() {
    print(line)
}
'''


def build(folder, sources, driver, name, routing_actor):
    """The executable of `driver` over `sources` (path -> text); raises CalledProcessError."""
    folder = Path(folder)
    work = folder / name
    work.mkdir(parents=True, exist_ok=True)
    paths = []
    for file_name, text in sources.items():
        (work / file_name).write_text(text)
        paths.append(work / file_name)
    (work / 'Doubles.swift').write_text(DOUBLES)
    (work / 'main.swift').write_text(driver)
    (work / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n')
    paths += [work / 'main.swift', work / 'Doubles.swift', ROOT / 'Horos/Sources/MainActorCallbacks.swift']
    flags = []
    if routing_actor:
        activity = (ROOT / 'Horos/Sources/ActivityThread.swift').read_text(encoding='utf-8')
        (work / 'ActivityThread.swift').write_text(send_controller_harness.activity_thread_source(activity))
        paths += [work / 'ActivityThread.swift', ROOT / 'Horos/Sources/ProcessGraph.swift']
        # The graph also makes the scheduler of the incoming files and the conversion queue.
        modules = folder / 'modules'
        flags = ['-D', 'ROUTING_ACTOR', *isix_modules.module_flags('IsiXDICOMNetwork', modules),
                 *isix_modules.module_flags('IsiXDatabase', modules),
                 *isix_modules.module_flags('IsiXImaging', modules)]  # the graph's reslice worker
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(ROOT / 'Horos/Sources'),
                    str(ROOT / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
                   check=True, capture_output=True)
    executable = work / name
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-swift-version', '5', '-suppress-warnings', *flags,
                    '-import-objc-header', str(work / 'bridging.h'), '-I', str(ROOT / 'Horos/Sources'),
                    *map(str, paths), str(work / 'exception.o'), '-o', str(executable)],
                   check=True, capture_output=True)
    return executable


def run(executable, case, folder, timeout=90):
    try:
        return subprocess.run([str(executable), case, str(folder)], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        out = expired.stdout.decode(errors='replace') if isinstance(expired.stdout, bytes) else (expired.stdout or '')
        return subprocess.CompletedProcess(expired.cmd, -1, out, '')
