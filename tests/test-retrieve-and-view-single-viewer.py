#!/usr/bin/env python3
"""Retrieve & View of a series opens one viewer, whichever path sees it first.

Retrieve & View in the Query window opens the series' viewer from two places
in QueryController+Retrieve.swift: -view: starts a retry that looks for the
series every second (-checkAndView: after a delay), and, with progressive
viewing, each batch the database adds opens the pending item at once
(-observeDatabaseAddNotification: and -openPendingRetrieveAndViewItems...).
When a batch opened the viewer first, the retry still waiting looked again,
found the series and opened a second viewer: a DICOMweb series, imported as
soon as it arrives, always got two.

The methods of the Query window that make that flow are compiled from the
tree (and, when the history reaches it, from the revision before the
correction, which must show the double opening) with RetrieveViewing.swift as
it is, an in-memory Core Data index and stand-ins for the browser, the
database and the outline. Each case begins a Retrieve & View of a series and
lands its images at a given moment:

- before the first retry, then a second batch (as DICOMweb does);
- between two retries;
- found by a retry before any batch is announced (as C-GET and C-MOVE runs
  did);
- the first of these again without progressive viewing (only the retry).

Each must open exactly one viewer of its series.

Takes no argument; exits 2 when the toolchain cannot compile the probe.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import process_graph_stand_in  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RETRIEVE = 'Horos/Sources/QueryController+Retrieve.swift'
VIEWING = 'Horos/Sources/RetrieveViewing.swift'
# A line of the correction: a viewer that opened cancels the retries of its
# item. The correction wrote it with a delayed perform; the retries are named
# delayed calls of the window now, cancelled the same way.
MARKER = 'NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.checkAndView(_:)), object: item)'
CURRENT_MARKER = 'self.deferredCalls.cancel(Self.checkAndViewName(item))'


def member(source, signature):
    """A member from its attributes and signature to the brace that closes it."""
    at = source.index(signature)
    assert source.count(signature) == 1, signature
    start = source.rindex('\n', 0, at) + 1
    # Take the attribute lines above it (@objc, @IBAction) with it.
    while True:
        previous = source.rindex('\n', 0, start - 1) + 1
        if source[previous:start].strip().startswith('@'):
            start = previous
        else:
            break
    depth = 0
    for end in range(source.index('{', at), len(source)):
        depth += {'{': 1, '}': -1}.get(source[end], 0)
        if depth == 0:
            return source[start:end + 1]
    raise ValueError(signature)


SIGNATURES = (
    'public func retrieveAndView(_ sender: Any?) {',
    'public func view(_ sender: Any?) {',
    '    func checkAndView(_ item: Any?) {',
    'private func checkAndView(_ item: Any?, in context: NSManagedObjectContext,',
    'public func openPendingRetrieveAndViewItems(forStudyUIDs studyUIDs: [Any]!) {',
    'nonisolated func observeDatabaseAddNotification(_ notification: Notification) {',
    'private nonisolated static let pendingItems = PendingItems()',
    'private final class PendingItems: @unchecked Sendable {',
    'nonisolated static func progressiveRetrieveViewingEnabled() -> Bool {',
    'nonisolated static func viewingStudyUID(_ item: Any?) -> String {',
    'nonisolated static func viewingSeriesUID(_ item: Any?) -> String {',
    'public nonisolated func addPendingRetrieveAndViewItem(_ item: Any?) {',
    'public nonisolated func removePendingRetrieveAndViewItem(_ item: Any?) {',
    'public nonisolated func pendingRetrieveAndViewItems() -> [Any] {',
)


def controller(source):
    parts = []
    # The name of an item's retries, once they are named delayed calls.
    if 'static func checkAndViewName(' in source:
        parts.append(member(source, 'nonisolated static func checkAndViewName('))
    for signature in SIGNATURES:
        if signature.startswith('private nonisolated static let'):
            line_start = source.rindex('\n', 0, source.index(signature)) + 1
            parts.append(source[line_start:source.index('\n', line_start)])
        else:
            parts.append(member(source, signature))
    return '\n\n'.join(parts)


STANDINS = r'''
import AppKit
import CoreData
import IsiXPreferences

final class ViewerController: NSObject {}
final class DicomImage: NSManagedObject {}

class DCMTKQueryNode: NSObject {
    let ownUID: String
    let ownStudyUID: String
    init(uid: String, studyUID: String) { ownUID = uid; ownStudyUID = studyUID }
    @objc func uid() -> String? { ownUID }
    @objc func studyInstanceUID() -> String? { ownStudyUID }
}
final class DCMTKSeriesQueryNode: DCMTKQueryNode {}
final class DCMTKStudyQueryNode: DCMTKQueryNode {}

let OsirixAddToDBNotificationImagesArray = "OsirixAddToDBNotificationImagesArray"

enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}

func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext, _ block: () -> Void) {
    context.performAndWait(block)
}

struct DatabaseIngest {
    static let process = DatabaseIngest()
    func requestImport() {}
    func requestImport(of database: DicomDatabase?) {}
}

final class DicomDatabase: NSObject {
    nonisolated(unsafe) static var active: DicomDatabase?
    class func activeLocal() -> DicomDatabase? { active }
    let managedObjectContext: NSManagedObjectContext?
    let managedObjectModel: NSManagedObjectModel?
    init(context: NSManagedObjectContext) {
        managedObjectContext = context
        managedObjectModel = context.persistentStoreCoordinator?.managedObjectModel
    }
    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {}
}

final class BrowserController: NSObject {
    var database: DicomDatabase?
    var opened: [String] = []
    func childrenArray(_ item: Any!) -> [Any]! { [item as Any] }
    @discardableResult
    func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!,
                    keyImagesOnly keyImages: Bool) -> ViewerController! {
        for list in toOpenArray ?? [] {
            for series in (list as? [Any]) ?? [] {
                opened.append(((series as AnyObject).value(forKey: "seriesDICOMUID") as? String) ?? "?")
            }
        }
        return ViewerController()
    }
    func findAndSelectFile(_ path: String!, image curImage: DicomImage!, shouldExpand expand: Bool) -> Bool { true }
    func showEntireDatabase() {}
    func refreshStudyList(whileHidden: Bool) {}
    func databaseOpenStudy(_ item: NSManagedObject!) {}
}

final class AppControllerStandIn {
    func checkAllWindowsAreVisible(_ sender: Any?, makeKey: Bool) {}
}

// The class whose -tileWindows: the controller names by #selector.
final class AppController: NSObject {
    @objc(tileWindows:) func tileWindows(_ sender: Any!) {}
}

struct ProcessGraphStandIn {
    var currentBrowser: BrowserController?
    var appController: AppControllerStandIn? = AppControllerStandIn()
}

/// The window's preferences: nothing stored, read by text or through the catalog's keys.
final class PreferencesStandIn: PreferenceStore, @unchecked Sendable {
    func bool(forKey key: String) -> Bool { false }
    func object(forKey key: String) -> Any? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}

final class WindowStandIn { var isVisible = true }
final class PopupStandIn { var indexOfSelectedItem = 0 }

final class OutlineStandIn {
    var items: [Any] = []
    var selectedRowIndexes = IndexSet(integer: 0)
    var selectedRow: Int { selectedRowIndexes.first ?? -1 }
    func item(atRow row: Int) -> Any? { row >= 0 && row < items.count ? items[row] : nil }
}

/// The window's delayed calls, as DeferredCalls makes them: each named call
/// runs once from a timer of the run loop's default mode, unless its name is
/// cancelled first.
final class DeferredCalls {
    private var waiting: [String: [Timer]] = [:]
    func perform(_ name: String, after delay: TimeInterval, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            self?.waiting[name]?.removeAll { $0 === timer }
            body()
        }
        waiting[name, default: []].append(timer)
        RunLoop.main.add(timer, forMode: .default)
    }
    func cancel(_ name: String) { waiting.removeValue(forKey: name)?.forEach { $0.invalidate() } }
}

final class QueryController: NSObject {
    let deferredCalls = DeferredCalls()
    var processGraph = ProcessGraphStandIn()
    let preferences = PreferencesStandIn()
    let window: WindowStandIn? = WindowStandIn()
    let sendToPopup = PopupStandIn()
    let outlineView = OutlineStandIn()
    var checkAndViewTry: Int32 = 0

    static func describe(_ error: Error) -> String { "\(error)" }
    @objc func refresh(_ sender: Any?) {}

    /// The window's retrieve: it starts the transfer elsewhere and leaves the
    /// retry counter as the real one does before -view: sets it.
    func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool) {
        checkAndViewTry = -1
    }

CONTROLLER_MEMBERS
}
'''

DRIVER = r'''
import AppKit
import CoreData

func attribute(_ name: String) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = .stringAttributeType
    attribute.isOptional = true
    return attribute
}

let model = NSManagedObjectModel()
let image = NSEntityDescription(), series = NSEntityDescription(), study = NSEntityDescription()
image.name = "Image"; series.name = "Series"; study.name = "Study"
let images = NSRelationshipDescription(), seriesOfImage = NSRelationshipDescription()
images.name = "images"; images.destinationEntity = image; images.minCount = 0; images.maxCount = 0; images.deleteRule = .nullifyDeleteRule
seriesOfImage.name = "series"; seriesOfImage.destinationEntity = series; seriesOfImage.maxCount = 1; seriesOfImage.deleteRule = .nullifyDeleteRule
images.inverseRelationship = seriesOfImage; seriesOfImage.inverseRelationship = images
image.properties = [attribute("sopInstanceUID"), seriesOfImage]
series.properties = [attribute("seriesDICOMUID"), images]
study.properties = [attribute("studyInstanceUID")]
model.entities = [image, series, study]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
let database = DicomDatabase(context: context)
DicomDatabase.active = database

/// The images of `seriesUID` reach the index.
func land(_ seriesUID: String) {
    let row = NSManagedObject(entity: series, insertInto: context)
    row.setValue(seriesUID, forKey: "seriesDICOMUID")
    let instance = NSManagedObject(entity: image, insertInto: context)
    instance.setValue(seriesUID + ".1", forKey: "sopInstanceUID")
    instance.setValue(row, forKey: "series")
}

/// The database announces a batch of `studyUID`, as OsirixAddToDB does.
func announce(_ controller: QueryController, _ studyUID: String) {
    let batch: NSDictionary = ["series": ["study": ["studyInstanceUID": studyUID]]]
    controller.observeDatabaseAddNotification(Notification(name: Notification.Name("OsirixAddToDB"), object: nil,
                                                           userInfo: [OsirixAddToDBNotificationImagesArray: [batch]]))
}

struct Case {
    let name: String
    let events: [(TimeInterval, (QueryController, String, String) -> Void)]
}

let landAndAnnounce: (QueryController, String, String) -> Void = { controller, studyUID, seriesUID in
    land(seriesUID); announce(controller, studyUID)
}
let landOnly: (QueryController, String, String) -> Void = { _, _, seriesUID in land(seriesUID) }
let announceOnly: (QueryController, String, String) -> Void = { controller, studyUID, _ in announce(controller, studyUID) }

let progressive = UserDefaults.standard.bool(forKey: "HorosProgressiveRetrieveViewing")
let cases: [Case] = progressive ? [
    Case(name: "batch before the first retry", events: [(0.3, landAndAnnounce), (0.6, announceOnly)]),
    Case(name: "batch between two retries", events: [(1.4, landAndAnnounce)]),
    Case(name: "retry before any batch", events: [(0.5, landOnly), (1.5, announceOnly)]),
] : [
    Case(name: "batch before the first retry, not progressive", events: [(0.3, landAndAnnounce), (0.6, announceOnly)]),
]

var browsers: [(String, BrowserController, String)] = []
for (index, each) in cases.enumerated() {
    let studyUID = "1.2.826.0.1.\(index)", seriesUID = "1.2.826.0.1.\(index).1"
    let browser = BrowserController()
    browser.database = database
    let controller = QueryController()
    controller.processGraph.currentBrowser = browser
    controller.outlineView.items = [DCMTKSeriesQueryNode(uid: seriesUID, studyUID: studyUID)]
    browsers.append((each.name, browser, seriesUID))
    controller.retrieveAndView(nil)
    for (delay, event) in each.events {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { event(controller, studyUID, seriesUID) }
    }
    // Kept alive by the run loop's timers and the blocks above.
    objc_setAssociatedObject(browser, "controller", controller, .OBJC_ASSOCIATION_RETAIN)
}

// Long enough for every retry still scheduled after the last event.
RunLoop.main.run(until: Date().addingTimeInterval(4.5))
for (name, browser, seriesUID) in browsers {
    print("\(name): \(browser.opened.filter { $0 == seriesUID }.count) viewer(s)")
}
'''


def probe(label, retrieve_source, folder):
    source = STANDINS.replace('CONTROLLER_MEMBERS', controller(retrieve_source))
    work = folder / label
    work.mkdir()
    (work / 'Controller.swift').write_text(source)
    (work / 'main.swift').write_text(DRIVER)
    # The class methods read the launch's preferences from PreferencesSource, over a stand-in of the graph.
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(ROOT / VIEWING), str(work / 'Controller.swift'),
                            str(work / 'main.swift'), *process_graph_stand_in.swift_flags(work / 'graph'),
                            '-o', str(work / 'probe')], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr[-4000:]
    lines = []
    for progressive in ('YES', 'NO'):
        ran = subprocess.run([str(work / 'probe'), '-HorosProgressiveRetrieveViewing', progressive],
                             capture_output=True, text=True, timeout=60)
        if ran.returncode != 0:
            return None, (ran.stdout + ran.stderr)[-2000:]
        lines += ran.stdout.splitlines()
    return lines, None


current = (ROOT / RETRIEVE).read_text(encoding='utf-8')
if MARKER not in current and CURRENT_MARKER not in current:
    print('FAIL: -checkAndView: no longer cancels the retries of an item whose viewer opened')
    sys.exit(1)
# The retrieve thread starts only with the database the window's factory hands
# to the worker threads (performRetrieve returns at once without it). A
# property observer does not run in the class's own initializer, so the
# factory must hand it over itself.
factory = member((ROOT / 'Horos/Sources/QueryController.swift').read_text(encoding='utf-8'),
                 'public convenience init!(autoQuery autoQR: Bool) {')
if 'graphForWorkers.withLock { $0 = processGraph }' not in factory:
    print('FAIL: initAutoQuery: does not hand the process graph to the retrieve and query threads')
    sys.exit(1)
reference = history_reference.before_text_added(RETRIEVE, MARKER)

with tempfile.TemporaryDirectory(prefix='isix-retrieve-and-view-') as directory:
    folder = Path(directory)
    lines, error = probe('current', current, folder)
    if lines is None:
        if 'error:' not in (error or ''):
            print('skipped: the probe could not be built or run here:\n' + (error or ''))
            sys.exit(2)
        print('FAIL: the probe of this tree does not compile or run:\n' + error)
        sys.exit(1)
    previous = None
    if reference:
        previous, error = probe('previous', history_reference.show(reference, RETRIEVE).decode('utf-8'), folder)
        if previous is None:
            print('FAIL: the probe of %s does not compile or run:\n%s' % (reference[:10], error))
            sys.exit(1)

failures = [line for line in lines if not line.endswith(': 1 viewer(s)')]
for line in lines:
    print('  now:    ' + line)
if len(lines) != 4:
    failures.append('expected 4 cases, got %d' % len(lines))
if previous is not None:
    for line in previous:
        print('  before: ' + line)
    # The control: the revision before the correction opened two viewers when
    # a batch came first, and one when the retry did.
    expected = ['batch before the first retry: 2 viewer(s)', 'batch between two retries: 2 viewer(s)',
                'retry before any batch: 1 viewer(s)', 'batch before the first retry, not progressive: 1 viewer(s)']
    if previous != expected:
        failures.append('the revision before the correction (%s) did not show the double opening the cases model'
                        % reference[:10])
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: Retrieve & View opens one viewer of its series in every case'
      + (', where %s opened two when a batch came first' % reference[:10] if previous is not None else
         ' (the history does not reach the revision before the correction)'))
