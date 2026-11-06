"""Compile SendController.swift, as it is or as an earlier revision had it,
over doubles that record what each send would do, for the send tests.

The doubles are the same whatever the revision: the images (DicomImage,
DicomSeries, DicomStudy, answering by key as Core Data does and by property as
Swift reads them), DCMTKStoreSCU, which records every association it is asked
for and never opens one, the STOW-RS send of a DICOMweb node, the direct
transfer of a Horos peer, the thread manager of the Activity window and the
alerts. The revision before the send queue ran each association in an
operation of its own (`-run:` raising when files were not sent); this tree
runs it on an activity thread (`sendReportingFailure()`): the double answers
both, and records the same line either way.

Each record is one line of text, so that two revisions are compared by their
sorted lines:
  store  <thread> | <calling> -> <called>@<host>:<port> syntax <n> compression <f> | <files> | <TLS view>
  stow   <thread> | <node> <patient> | <files>
  direct <host>:<port> token <token> | <files>
  alert  <title> | <message>
"""
from pathlib import Path
import re
import subprocess

import isix_modules

ROOT = Path(__file__).resolve().parents[1]

DOUBLES = r'''
import AppKit
import IsiXDICOMNetwork

/// What the doubles saw, across threads.
nonisolated(unsafe) var recorded: [String] = []
nonisolated(unsafe) var running = 0
nonisolated(unsafe) var mostRunning = 0
nonisolated(unsafe) var storeDelay: TimeInterval = 0
/// A part whose first file is this one waits until its thread is cancelled.
nonisolated(unsafe) var waitForCancel: String?
/// The direct transfer answers this.
nonisolated(unsafe) var directSends = true
let recordLock = NSLock()

func record(_ line: String) {
    recordLock.lock(); recorded.append(line); recordLock.unlock()
}

// The images, by key and by property.
@objc(DicomStudy) final class DicomStudy: NSObject {
    @objc dynamic var patientUID: String!
    @objc dynamic var name: String!
    init(_ uid: String?, _ name: String?) { patientUID = uid; self.name = name }
}

@objc(DicomSeries) final class DicomSeries: NSObject {
    @objc dynamic var study: DicomStudy!
    @objc dynamic var name: String!
    @objc dynamic var id: NSNumber!
    init(_ study: DicomStudy, _ name: String?, _ id: NSNumber?) { self.study = study; self.name = name; self.id = id }
}

@objc(DicomImage) final class DicomImage: NSObject {
    @objc dynamic var series: DicomSeries!
    let path: String?
    @objc dynamic var isKeyImage = false
    @objc dynamic var modality = "CT"
    init(_ series: DicomSeries, _ path: String?) { self.series = series; self.path = path }
    @objc func completePath() -> String! { path }
    @objc func completePathResolved() -> String! { path }
}

final class HorosAlertPanel: NSObject {
    static func run(title: String?, message: String?, defaultButton: String?, alternateButton: String?, otherButton: String?) {
        record("alert  \(title ?? "") | \(message ?? "")")
    }
    static func runCritical(title: String?, message: String?, defaultButton: String?, alternateButton: String?, otherButton: String?) {
        record("alert  \(title ?? "") | \(message ?? "")")
    }
}

extension UserDefaults {
    class func defaultAETitle() -> String { return "HARNESS" }
}

// NSUserDefaultsController+N2.
extension NSUserDefaultsController {
    func addObserver(_ observer: NSObject, forValuesKey key: String, options: NSKeyValueObservingOptions, context: UnsafeMutableRawPointer?) {
        addObserver(observer, forKeyPath: "values." + key, options: options, context: context)
    }
    func removeObserver(_ observer: NSObject, forValuesKey key: String) {
        removeObserver(observer, forKeyPath: "values." + key)
    }
}

// No DIMSE node in the preferences: the sends name their node.
struct NodePreferences: DICOMNodePreferences {
    func object(forKey key: String) -> Any? { nil }
    func bool(forKey key: String) -> Bool { false }
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}

final class DICOMNodeService: NSObject {
    static let store = DICOMNodeStore(preferences: NodePreferences())
    static func dicomNodes(sendOnly: Bool, queryRetrieveOnly: Bool) -> [DICOMNode] { return [] }
}

// DICOMwebIntegration.swift: a node is DICOMweb when its dictionary names one.
final class DICOMwebSources: NSObject {
    static func sendDestinations() -> [[String: Any]] { return [] }
    static func isDICOMwebServer(_ server: [AnyHashable: Any]?) -> Bool { return server?["DICOMwebNode"] != nil }
    static func storeURL(forServer server: [AnyHashable: Any]?) -> String { return "" }
}

final class DICOMwebSendActivity: NSObject {
    static func send(files: [String], patientName: String?, to server: [AnyHashable: Any]?, thread: Thread) {
        let listed = thread === Thread.current && thread.supportsCancel
        record("stow   \(listed ? "activity" : "not listed") | \(server?["DICOMwebNode"] as? String ?? "") \(patientName ?? "(null)") | \(files.joined(separator: ","))")
    }
}

enum SendWhatFilter {
    static func resolvedIndex(_ requested: Int, hasKeyImages: Bool, hasSecondaryCaptures: Bool) -> Int { return 0 }
}

struct TransferSyntaxCodes { var rawValue: UInt32 }
let SendExplicitLittleEndian = TransferSyntaxCodes(rawValue: 0)

/// Lists the threads it starts, as the Activity window does, for a driver to
/// cancel them as its Cancel button does.
final class ThreadsManager: NSObject {
    static let shared = ThreadsManager()
    nonisolated(unsafe) static var listed: [Thread] = []
    class func `default`() -> ThreadsManager! { return shared }
    func addThreadAndStart(_ thread: Thread!) {
        recordLock.lock(); ThreadsManager.listed.append(thread); recordLock.unlock()
        thread.start()
    }
    static func cancelAll() {
        recordLock.lock(); let threads = listed; recordLock.unlock()
        threads.forEach { $0.cancel() }
    }
}

// NSThread+N2: progress, status and supportsCancel, by associated objects.
nonisolated(unsafe) private var progressKey = 0, statusKey = 0, cancelKey = 0
extension Thread {
    @objc var progress: CGFloat {
        get { return (objc_getAssociatedObject(self, &progressKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
        set { objc_setAssociatedObject(self, &progressKey, NSNumber(value: Double(newValue)), .OBJC_ASSOCIATION_RETAIN) }
    }
    @objc var status: String? {
        get { return objc_getAssociatedObject(self, &statusKey) as? String }
        set { objc_setAssociatedObject(self, &statusKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }
    @objc var supportsCancel: Bool {
        get { return (objc_getAssociatedObject(self, &cancelKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &cancelKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN) }
    }
}

// HorosDirectTransfer.swift: a peer that advertises the transfer and gave its
// token is sent to directly; the double sends when `directSends`.
final class DirectTransferPolicy: NSObject {
    static let routeDirect = "direct"
    static func route(server: [String: Any], destinationChosen: Bool, authorized: Bool) -> String {
        return destinationChosen && authorized && server["HorosDirectTransferVersion"] != nil ? "direct" : "dimse"
    }
}

final class DirectTransferService: NSObject, @unchecked Sendable {
    static let shared = DirectTransferService()
    func send(files: [String], toHost host: String, port: Int, token: String, activityThread: Thread?) -> Bool {
        record("direct \(host):\(port) token \(token) | \(files.joined(separator: ","))")
        return directSends
    }
}

/// What the sources read of the send's failure: a category of a closed set,
/// what the user is shown and what the log writes.
struct StoreSendFailure: Error {
    enum Category: String {
        case store = "DICOM Network Failure (STORE-SCU)"
    }
    let category: Category
    let reason: String
    var logReason: String { reason }
}

final class DCMTKStoreSCU: NSObject {
    let files: [String]
    let line: String

    init(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, filesToSend: [Any]?,
          transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        files = (filesToSend ?? []).compactMap { $0 as? String }
        // What the association reads of the extra parameters: the TLS settings.
        let tls = TLSNodeSettings(extraParameters: extraParameters)
        let view = "tls \(tls.enabled) \(tls.authenticated) \(tls.storedCertificateVerification) \(tls.cipherSuites) \(tls.dhParameterFile ?? "-")"
        let thread = OperationQueue.current?.name ?? Thread.current.name ?? "?"
        line = "store  \(thread) | \(callingAET ?? "(null)") -> \(calledAET ?? "(null)")@\(hostname ?? "(null)"):\(port) syntax \(transferSyntax) compression \(compression) | \(files.joined(separator: ",")) | \(view)"
        super.init()
    }

    /// Runs the send: records it, counts the sends at once, waits when asked;
    /// a file named "fail" is not sent.
    /// Stopped as DCMTKStoreSCU is: by its operation, or else by its thread.
    private func perform(_ operation: Operation?) -> StoreSendFailure? {
        record(line)
        recordLock.lock()
        running += 1
        mostRunning = max(mostRunning, running)
        let delay = storeDelay
        let waits = waitForCancel != nil && files.first == waitForCancel
        recordLock.unlock()
        Thread.sleep(forTimeInterval: delay)
        let cancelled = { operation?.isCancelled ?? Thread.current.isCancelled }
        let deadline = Date(timeIntervalSinceNow: 10)
        while waits && !cancelled() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        recordLock.lock(); running -= 1; recordLock.unlock()
        if waits { return StoreSendFailure(category: .store, reason: "Aborted") }
        return files.contains { $0.contains("fail") } ? StoreSendFailure(category: .store, reason: "1 file not sent") : nil
    }

    func run(_ operation: Operation!) {
        if let failure = perform(operation) {
            NSException(name: NSExceptionName(failure.category.rawValue), reason: failure.reason, userInfo: nil).raise()
        }
    }

    func sendReportingFailure(_ operation: Operation? = nil) -> StoreSendFailure? {
        return perform(operation)
    }
}

// The singletons the process graph reads; the sends never reach them.
@MainActor final class BrowserController: NSObject {
    nonisolated static func currentBrowser() -> BrowserController! { nil }
    nonisolated func isNetworkLogsActive() -> Bool { false }
    nonisolated var database: DicomDatabase! { nil }
    nonisolated func addFile(toDeleteQueue file: String!) {}
}

@MainActor final class AppController: NSObject {
    nonisolated static func shared() -> AppController! { nil }
    nonisolated var bonjourPublisher: BonjourPublisher! { nil }
    nonisolated var isSessionInactive: Bool { false }
    // The Dock's receiving indicator, which any thread reaches through the graph.
    nonisolated let receivingIndicator = ReceivingIndicator()
    final class ReceivingIndicator: Sendable { nonisolated func showReceiving(_ receiving: Bool) {} }
}

@MainActor final class BonjourPublisher: NSObject {}

@MainActor final class ViewerController: NSObject {
    static func areLoadingViewers() -> Bool { false }
}
// The register of the viewers, a member of the process graph.
nonisolated final class ViewerRegistry: Sendable {}
// The presets menus and the last colour table of the viewers, members of the process graph.
@MainActor final class PresetMenuCache { nonisolated init() {} }
@MainActor final class ColourTableCache { nonisolated init() {} }
@MainActor final class ViewerSyncState { nonisolated init() {} }

final class DicomDatabase: NSObject, @unchecked Sendable {
    static func `default`() -> DicomDatabase! { nil }
}
'''


def activity_thread_source(text):
    """ActivityThread as Horos/Sources declares it, cut out of the file it is in."""
    start = text.index('enum ActivityThread {')
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                break
        index += 1
    return 'import Foundation\n' + text[start:index + 1] + '\n'


def is_queue_revision(source):
    """Whether a SendController.swift queues its sends (this tree's design)."""
    return 'dicomSendQueue' in source


# What the graph hands out beside the send: the single entry of what comes in and the reader of a local
# database, which a send never reaches.
GRAPH_MEMBERS = '''import AppKit
import IsiXDatabase
import IsiXPreferences

// The graph of the database window and the Recent Studies outlet the graph reads.
extension AppController {
    var browserWindow: BrowserWindowGraph? { nil }
    var recentStudiesMenu: NSMenu! { nil }
}

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

struct DatabaseIngest { init(processGraph: ProcessGraph) {} }
// The ROI archives of a viewer's images, which the process graph makes for the viewers.
@MainActor final class ViewerROIArchiveStore {
    init(images: [DicomImage], database: DicomDatabase, ingest: DatabaseIngest) {}
}

// The PACS On-Demand nodes over QueryController, a member of the process graph that a send never asks.
struct QueryControllerDistantStudies: DistantStudyQuerying {
    let preferences: any PreferenceStore
    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] { [] }
    func patientStudies(of patient: String, activity: String) async -> [DistantStudySummary] { [] }
}

final class LocalDatabaseStudyReader: @unchecked Sendable {
    init(database: @escaping @Sendable () -> DicomDatabase?) {}
}

extension DicomDatabase {
    static func activeLocal() -> DicomDatabase? { nil }
}
'''


def build(folder, send_source, driver, name, sanitize=False, activity_text=None):
    """The executable of `driver` over `send_source`; raises CalledProcessError."""
    folder = Path(folder)
    work = folder / name
    work.mkdir(parents=True, exist_ok=True)
    queue = is_queue_revision(send_source)
    (work / 'SendController.swift').write_text(send_source)
    (work / 'Doubles.swift').write_text(DOUBLES)
    (work / 'main.swift').write_text(driver)
    (work / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n')
    sources = [work / 'main.swift', work / 'SendController.swift', work / 'Doubles.swift',
               ROOT / 'Horos/Sources/MainActorCallbacks.swift', ROOT / 'Nitrogen/Sources/NSWindow+N2.swift',
               ROOT / 'Horos/Sources/MutableArrayCategory.swift']
    if queue:
        activity = activity_text if activity_text is not None else \
            (ROOT / 'Horos/Sources/ActivityThread.swift').read_text(encoding='utf-8')
        (work / 'ActivityThread.swift').write_text(activity_thread_source(activity))
        sources += [work / 'ActivityThread.swift', ROOT / 'Horos/Sources/ActivitySendTransport.swift',
                    ROOT / 'Horos/Sources/DICOMSendSelection+DicomImage.swift', ROOT / 'Horos/Sources/ProcessGraph.swift',
                    # Where the class methods read the preferences without an instance.
                    ROOT / 'Horos/Sources/PreferencesSource.swift']
        (work / 'DatabaseIngest.swift').write_text(GRAPH_MEMBERS)
        sources.append(work / 'DatabaseIngest.swift')
    extra = ['-sanitize=thread', '-g'] if sanitize else []
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', *(['-fsanitize=thread'] if sanitize else []),
                    '-I', str(ROOT / 'Horos/Sources'),
                    str(ROOT / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
                   check=True, capture_output=True)
    # The queue is the module's: instrumented with the rest under ThreadSanitizer.
    modules = isix_modules.module_flags('IsiXDICOMNetwork', folder / ('modules-tsan' if sanitize else 'modules'),
                                        ['-sanitize=thread', '-g'] if sanitize else ())
    modules += isix_modules.module_flags('IsiXDatabase', folder / ('modules-tsan' if sanitize else 'modules'),
                                         ['-sanitize=thread', '-g'] if sanitize else ())
    # The graph also keeps the reslice worker, which is IsiXImaging's.
    modules += isix_modules.module_flags('IsiXImaging', folder / ('modules-tsan' if sanitize else 'modules'),
                                         ['-sanitize=thread', '-g'] if sanitize else ())
    executable = work / name
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-swift-version', '5', *extra, *modules,
                    *(['-D', 'SEND_QUEUE'] if queue else []),
                    '-import-objc-header', str(work / 'bridging.h'), '-I', str(ROOT / 'Horos/Sources'),
                    # LogText: what the Send sheet tells the log of an error.
                    *map(str, sources), *isix_modules.log_text_sources(), str(work / 'exception.o'), '-o', str(executable)],
                   check=True, capture_output=True)
    return executable


# The images and the sends of the drivers, the same for every revision.
DRIVER_PRELUDE = r'''
import AppKit

func images(_ study: DicomStudy, _ seriesName: String?, _ seriesID: NSNumber?, _ paths: [String?]) -> [DicomImage] {
    let series = DicomSeries(study, seriesName, seriesID)
    return paths.map { DicomImage(series, $0) }
}

/// What -sendFiles:toNode: does, without writing sendROIs and syntaxListOffis
/// to the user defaults: the preferences are the registration domain's.
func send(_ objects: [DicomImage], to node: NSDictionary?) {
    let controller = SendController(files: objects)
    _ = Unmanaged.passRetained(controller) // released when the send is done with it
#if SEND_QUEUE
    controller.sendToNode(node as? [AnyHashable: Any], objects: objects)
#else
    controller.sendToNode(node, objects: objects)
#endif
}

/// Spins the main run loop until no controller and no send is left.
func finished(within seconds: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        if SendController.sendControllerObjects() == 0 {
            // The alerts the sends queued for the main thread.
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
            return true
        }
    }
    return false
}

func lines() -> [String] {
    recordLock.lock(); defer { recordLock.unlock() }
    return recorded
}
'''


def run(executable, *arguments, timeout=60):
    try:
        return subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        out = expired.stdout.decode(errors='replace') if isinstance(expired.stdout, bytes) else (expired.stdout or '')
        return subprocess.CompletedProcess(expired.cmd, -1, out, '')


def strip_comments(text):
    return re.sub(r'//[^\n]*', '', text)
