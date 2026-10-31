#!/usr/bin/env python3
"""The process graph is made once, hands out today's singletons, states its
isolation, and the types that receive it get it from one composition point.

Horos/Sources/ProcessGraph.swift is compiled as it is, with doubles of the
three singleton classes it reads (the browser and the application controller,
main-actor objects whose accessors answer from any thread, and the default
database), and driven:
- once: `ProcessGraph.process` is the same object on the main thread and on
  sixteen threads that reach it at the same time;
- live: the browser, its database, the application controller, the
  shared-database publisher it keeps and the default database are read when
  asked, never kept from the first read, so a type that receives the graph sees
  what the global access it replaces would return at that moment; the
  preferences are UserDefaults.standard;
- the send queue (IsiXDICOMNetwork's DICOMSendQueue): one, made with the
  graph and the same from any thread, with nothing pending at first;
- the routing queue (IsiXDICOMNetwork's RoutingQueue): one, made with the
  graph and the same from any thread, with nothing queued at first;
- the reslices of the 2D viewers (IsiXImaging's SeriesResliceWorker): one,
  made with the graph and the same from any thread;
- the PACS On-Demand searches (IsiXDatabase's PACSOnDemandSearch): one, made
  with the graph over the standard preferences and the same from any thread,
  with no distant studies for the list at first;
- the scheduler of the incoming files (IsiXDatabase's IngestScheduler): one,
  made with the graph and the same from any thread, and the single entry over
  it, DatabaseIngest, which receives the graph;
- the readers of a local database: one for the default database, one for the
  active local database and one for the browser's, each asking its database
  at every read; no other file makes one;
- the browser's delete queue: a file queued through the graph from any
  thread goes to the browser's queue, nothing before the browser exists;
- isolation: the default database, the publisher, the preferences and the
  browser's network-log switch and database are read from any thread; reading
  the browser or the application controller outside the main actor does not
  compile, and nothing but `process` makes a graph.

And over the sources, "one way": the types that receive the graph get it from
their composition point, the factory that makes them, which is the only kind
of place that reads `ProcessGraph.process`:
- a nib-loaded window controller, through its `processGraph` property, set
  right after the factory makes it;
- a type made in code, through its initializer.
A new reader of `ProcessGraph.process` fails here until it is listed with the
type it makes; a type below a composition point uses the graph it was given.
Comments and strings do not count, as for tools/swift-idiom-indicator.py.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402  - the send queue the graph holds is IsiXDICOMNetwork's

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
GRAPH = root / 'Horos/Sources/ProcessGraph.swift'
failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

# --- one way: who reads the process graph, and how each type receives it ---------
# The composition points: each file that reads ProcessGraph.process, and how the
# type it makes receives the graph. A property is set on the line right after
# the line that makes the controller; an initializer receives it as an argument.
COMPOSITION = {
    'Horos/Sources/BonjourBrowser.swift':
        ('init', 'self.init(browserController: bC, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/BonjourPublisher.swift':
        ('init', 'self.init(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/CustomIntervalPanel.swift':
        ('property', 'let panel = CustomIntervalPanel(windowNibName: "CustomIntervalPanel")',
         'panel.processGraph = ProcessGraph.process'),
    'Horos/Sources/DatabaseIngest.swift':
        ('init', 'static let process = ProcessGraph.process.databaseIngest', None),
    'Horos/Sources/GeneratedSeriesImport.swift':
        ('init', 'static let process = GeneratedSeriesImport(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DatabaseRouting.swift':
        ('init', 'static let process = DatabaseRouting(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DatabaseCleanupService.swift':
        ('init', 'self.init(database: database, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DatabaseModelUpgrade.swift':
        ('init', 'self.init(database: database, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DatabaseRebuildService.swift':
        ('init', 'self.init(database: database, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DatabaseStartupRepairs.swift':
        ('init', 'self.init(database: database, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DicomFile+ImportSettings.swift':
        ('init', 'static let process = ImportSettingsSource(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/ReceivingIndicator.swift':
        ('init', 'self.init(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/UpdateCheckScheduler.swift':
        ('init', 'self.init(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/PreferenceChangeResponder.swift':
        ('init', 'self.init(listener: listener, windowArranger: windowArranger, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/DICOMNodeService.swift':
        ('init', 'static let store = DICOMNodeStore(preferences: NodePreferences(processGraph: ProcessGraph.process))', None),
    'Horos/Sources/ICloudDriveDetector.swift':
        ('property', 'detector.browserController = browserController',
         'detector.processGraph = ProcessGraph.process'),
    'Horos/Sources/NavigatorWindowController.swift':
        ('property', 'self.init(windowNibName: "Navigator")',
         'processGraph = ProcessGraph.process'),
    'Horos/Sources/SCPDatabaseSession.swift':
        ('init', 'self.init(callingAETitle: callingAETitle, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/QueryController.swift':
        ('property', 'self.init(windowNibName: "Query")',
         'processGraph = ProcessGraph.process'),
    'Horos/Sources/PreferencesSource.swift':
        ('init', 'static let process = PreferencesSource(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/BrowserDatabaseSource.swift':
        ('init', 'static let process = BrowserDatabaseSource(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/PreferencesWindowController.swift':
        ('property', 'let created = PreferencesWindowController()',
         'created.processGraph = ProcessGraph.process'),
    'Horos/Sources/DicomFileIndexer.swift':
        ('init', 'DicomFileIndexer(database: database, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/ImportFeedback.swift':
        ('init', 'ImportFeedback(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/LogManager.swift':
        ('init', 'private static let currentLogManagerInstance = LogManager(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/StudyNoteEditor.swift':
        ('init', 'showEditor(for: study, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/SendController.swift':
        ('init', 'self.init(files: files, processGraph: ProcessGraph.process)', None),
    'Horos/Sources/ViewerController.swift':
        ('init', 'self.init(windowNibName: "Viewer", processGraph: ProcessGraph.process)', None),
    'Horos/Sources/WADODownload.swift':
        ('init', 'self.init(processGraph: ProcessGraph.process)', None),
    'Horos/Sources/XMLController.swift':
        ('property', 'self.init(windowNibName: "XMLViewer")',
         'processGraph = ProcessGraph.process'),
    'Horos/Sources/XMLRPCInterface.swift':
        ('init', 'self.init(processGraph: ProcessGraph.process)', None),
}
READ = re.compile(r'\bProcessGraph\s*\.\s*process\b|\bprocessGraph\s*:\s*\.process\b')
SCOPES = ('Horos/', 'Preference Panes/', 'Modules/', 'Nitrogen/')
listed = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '--', *SCOPES],
                        capture_output=True, text=True)
if listed.returncode != 0:
    print(f'skipped: {root} is not a git checkout', file=sys.stderr)
    sys.exit(SKIPPED)
readers = set()
for path in listed.stdout.splitlines():
    if not path.endswith('.swift') or not (root / path).is_file():
        continue
    code = indicator.swift_code((root / path).read_text(encoding='utf-8', errors='replace'))
    if READ.search(code):
        readers.add(path)
for path in sorted(readers - set(COMPOSITION)):
    fail(f'{path} reads ProcessGraph.process: receive the graph from whoever makes the type, '
         'or list the new composition point here with the type it makes')
for path in sorted(set(COMPOSITION) - readers):
    fail(f'{path} no longer reads ProcessGraph.process: remove it from the composition points')
for path, (kind, made, handed) in sorted(COMPOSITION.items()):
    if not (root / path).is_file():
        continue
    lines = [line.strip() for line in (root / path).read_text(encoding='utf-8').splitlines()]
    if made not in lines:
        fail(f'{Path(path).name}: the composition point no longer makes the type with {made!r}')
        continue
    after = lines[lines.index(made) + 1]
    if kind == 'property' and after != handed:
        fail(f'{Path(path).name}: the graph is not set right after the controller is made ({handed!r})')
    text = indicator.swift_code((root / path).read_text(encoding='utf-8'))
    if kind == 'property' and not re.search(r'\bvar processGraph: ProcessGraph!', text):
        fail(f'{Path(path).name}: the controller has no processGraph property')
    if kind == 'init' and not re.search(r'\binit\([^)]*\bprocessGraph: ProcessGraph\)', text):
        fail(f'{Path(path).name}: the initializer does not receive the graph')
    # The class methods that run before any instance exists may still read
    # the preferences; the browser and the application controller come from the graph.
    for pattern in ('current_browser', 'app_controller_shared'):
        uses = [number for number, line in enumerate(text.splitlines(), 1)
                if indicator.AXIS_B_SWIFT[pattern].search(line)]
        if uses:
            fail(f'{Path(path).name}: reaches the singleton again ({pattern}, line {uses[0]})')

graph = indicator.swift_code(GRAPH.read_text(encoding='utf-8'))
for needle, what in ((r'\bnonisolated\s+final\s+class\s+ProcessGraph\s*:\s*Sendable\b', 'a nonisolated, Sendable class'),
                     (r'\bstatic\s+let\s+process\s*=\s*ProcessGraph\(\)', 'made once, by the static `process`'),
                     (r'\bprivate\s+init\(\)', 'a private initializer'),
                     (r'@MainActor\s+var\s+currentBrowser\b', 'the browser on the main actor'),
                     (r'@MainActor\s+var\s+appController\b', 'the application controller on the main actor'),
                     (r'@MainActor\s+var\s+browserWindow\b', "the database window's graph on the main actor"),
                     (r'@MainActor\s+var\s+windowArranger\b', "the arrangement of the viewers' windows on the main actor"),
                     (r'@MainActor\s+var\s+applicationMenus\b', "the application's menus on the main actor")):
    if not re.search(needle, graph):
        fail(f'ProcessGraph.swift: the graph is no longer {what}')

# The readers of a local database are made by the graph, each over its database.
MAKES_READER = re.compile(r'(?<!extension )(?<!class )(?<!-> )(?<!: )\bLocalDatabaseStudyReader\s*(?:\{|\(|\.init\b)')
for path in sorted(readers | {p for p in listed.stdout.splitlines() if p.endswith('.swift')}):
    if not (root / path).is_file() or path == 'Horos/Sources/ProcessGraph.swift':
        continue
    if MAKES_READER.search(indicator.swift_code((root / path).read_text(encoding='utf-8', errors='replace'))):
        fail(f'{path} makes a LocalDatabaseStudyReader: ask the process graph for one')
if len(MAKES_READER.findall(graph)) != 3:
    fail('ProcessGraph.swift no longer makes the three readers of a local database')

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(1 if failures else SKIPPED)

# --- the graph, compiled as it is ------------------------------------------------
DOUBLES = r'''
import AppKit
import IsiXDatabase
import IsiXPreferences

// The PACS On-Demand nodes over QueryController, with the preferences it reads.
struct QueryControllerDistantStudies: DistantStudyQuerying {
    let preferences: any PreferenceStore
    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] { [] }
    func patientStudies(of patient: String, activity: String) async -> [DistantStudySummary] { [] }
}

// The browser: a main-actor window controller whose accessor answers from any
// thread, as BrowserController.currentBrowser() does.
@MainActor final class BrowserController: NSObject {
    nonisolated(unsafe) static var current: BrowserController?
    nonisolated static func currentBrowser() -> BrowserController! { current }
    // The network-log switch, which the browser keeps for any thread.
    nonisolated(unsafe) var logs = false
    nonisolated func isNetworkLogsActive() -> Bool { logs }
    // The database it shows, which it keeps for any thread.
    nonisolated(unsafe) var database: DicomDatabase!
    // The delete queue, which any thread adds to.
    nonisolated(unsafe) var queued: [String] = []
    nonisolated let queuing = NSLock()
    nonisolated func addFile(toDeleteQueue file: String!) { queuing.lock(); queued.append(file); queuing.unlock() }
}

// The application controller: main actor, with an accessor for any thread,
// and the publisher it keeps, which it answers from any thread.
@MainActor final class AppController: NSObject {
    nonisolated(unsafe) static var instance: AppController?
    nonisolated static func shared() -> AppController! { instance }
    nonisolated(unsafe) var publisher: BonjourPublisher?
    nonisolated var bonjourPublisher: BonjourPublisher! { publisher }
    // The graph of the database window it makes from its nib, and the Recent Studies outlet.
    var browserWindow: BrowserWindowGraph?
    var recentStudiesMenu: NSMenu!
    // The Dock's receiving indicator, which any thread reaches through the graph.
    nonisolated let receivingIndicator = ReceivingIndicator()
    final class ReceivingIndicator: Sendable { nonisolated func showReceiving(_ receiving: Bool) {} }
}

@MainActor final class ViewerController: NSObject {
    static func areLoadingViewers() -> Bool { false }
}

// The graph of the database window: main actor, made by the application controller.
@MainActor final class BrowserWindowGraph {
    let browser: BrowserController
    init(browser: BrowserController) { self.browser = browser }
}

// The DICOM listeners: main actor, made by the graph from any thread with the
// graph; their state answers from any thread.
@MainActor final class DICOMListenerController {
    nonisolated let processGraph: ProcessGraph
    nonisolated init(processGraph: ProcessGraph) { self.processGraph = processGraph }
    nonisolated(unsafe) var inactive = false
    nonisolated var isSessionInactive: Bool { inactive }
    nonisolated var isListening: Bool { false }
}

// The notifications: main actor, made with the graph from any thread.
@MainActor final class UserNotificationDelivery {
    nonisolated init() {}
}

// The arrangement of the viewers' windows: main actor, made by the graph with the graph.
@MainActor final class ViewerWindowArranger: NSObject {
    let processGraph: ProcessGraph
    nonisolated init(processGraph: ProcessGraph) { self.processGraph = processGraph }
}

// The application's menus: main actor, made by the graph on the main actor.
@MainActor final class ApplicationMenus: NSObject {
    let recentStudiesMenu: @MainActor () -> NSMenu?
    let processGraph: ProcessGraph
    init(recentStudiesMenu: @escaping @MainActor () -> NSMenu?, processGraph: ProcessGraph) {
        self.recentStudiesMenu = recentStudiesMenu
        self.processGraph = processGraph
    }
}

// The register of the viewers, which the graph makes once and any thread reads.
nonisolated final class ViewerRegistry: Sendable {
    init() {}
}

// The presets menus of the viewers' popups: main actor, made with the graph from any thread.
@MainActor final class PresetMenuCache {
    nonisolated init() {}
}

// The colour table the viewers applied last: main actor, made with the graph from any thread.
@MainActor final class ColourTableCache {
    nonisolated init() {}
}

// The synchronization the viewers share: main actor, made with the graph from any thread.
@MainActor final class ViewerSyncState {
    nonisolated init() {}
}

@MainActor final class BonjourPublisher: NSObject {}

// The single entry of what comes in; the graph hands itself to it.
struct DatabaseIngest {
    let processGraph: ProcessGraph
    init(processGraph: ProcessGraph) { self.processGraph = processGraph }
}

// The default database, made on first use from any thread; counts its reads.
// The active local database, which a retrieve fills.
final class DicomDatabase: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var instance: DicomDatabase?
    nonisolated(unsafe) static var active: DicomDatabase?
    nonisolated(unsafe) static var reads = 0
    static func `default`() -> DicomDatabase! {
        reads += 1
        return instance
    }
    static func activeLocal() -> DicomDatabase! { active }
}

// The ROI archives of a viewer's images, made for each load and save over the
// graph's single entry, on the main actor.
final class DicomImage: NSObject {}
@MainActor final class ViewerROIArchiveStore {
    let images: [DicomImage]
    let database: DicomDatabase
    let ingest: DatabaseIngest
    init(images: [DicomImage], database: DicomDatabase, ingest: DatabaseIngest) {
        self.images = images
        self.database = database
        self.ingest = ingest
    }
}

// The reader of a local database, which asks its database at each read.
final class LocalDatabaseStudyReader: @unchecked Sendable {
    let database: @Sendable () -> DicomDatabase?
    init(database: @escaping @Sendable () -> DicomDatabase?) { self.database = database }
}
'''

DRIVER = r'''
import AppKit

func expect(_ condition: Bool, _ what: String) {
    if !condition {
        print("FAIL: \(what)")
        exit(1)
    }
}

// once, on the main thread
let graph = ProcessGraph.process
expect(graph === ProcessGraph.process, "the process graph is made again")

// once, from sixteen threads at the same time; the any-thread members from there
let lock = NSLock()
nonisolated(unsafe) var seen = Set<ObjectIdentifier>()
nonisolated(unsafe) var preferencesSeen = Set<ObjectIdentifier>()
DispatchQueue.concurrentPerform(iterations: 16) { _ in
    let graph = ProcessGraph.process
    _ = graph.defaultDatabase
    _ = graph.networkLogsActive
    let preferences = graph.preferences
    lock.lock()
    seen.insert(ObjectIdentifier(graph))
    preferencesSeen.insert(ObjectIdentifier(preferences))
    lock.unlock()
}
expect(seen == [ObjectIdentifier(graph)], "threads got \(seen.count) graphs, or not the main thread's")
expect(preferencesSeen == [ObjectIdentifier(UserDefaults.standard)], "the preferences are not UserDefaults.standard")
expect(graph.preferences === UserDefaults.standard, "the preferences are not UserDefaults.standard")

// live: read when asked, never kept from a first read
expect(graph.currentBrowser == nil, "a browser before there is one")
let first = BrowserController(), second = BrowserController()
BrowserController.current = first
expect(graph.currentBrowser === first, "the browser is not the current one")
BrowserController.current = second
expect(graph.currentBrowser === second, "the browser was kept from an earlier read")

// the browser's network-log switch, from any thread, read when asked
BrowserController.current = nil
expect(!graph.networkLogsActive, "network logs on before there is a browser")
BrowserController.current = second
second.logs = true
nonisolated(unsafe) var logsSeen = Set<Bool>()
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    let active = ProcessGraph.process.networkLogsActive
    lock.lock(); logsSeen.insert(active); lock.unlock()
}
expect(logsSeen == [true], "the network-log switch is not the browser's from other threads")
second.logs = false
expect(!graph.networkLogsActive, "the network-log switch was kept from an earlier read")

// the browser's database, from any thread, read when asked
BrowserController.current = nil
expect(graph.browserDatabase == nil, "a browser database before there is a browser")
BrowserController.current = second
let shown = DicomDatabase()
second.database = shown
nonisolated(unsafe) var databasesSeen = Set<ObjectIdentifier>()
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    let database = ProcessGraph.process.browserDatabase
    lock.lock(); if let database { databasesSeen.insert(ObjectIdentifier(database)) }; lock.unlock()
}
expect(databasesSeen == [ObjectIdentifier(shown)], "the browser database is not the browser's from other threads")
second.database = nil
expect(graph.browserDatabase == nil, "the browser database was kept from an earlier read")

// the browser's delete queue, from any thread; nothing before the browser exists
BrowserController.current = nil
graph.queueForDeletion("/before")
BrowserController.current = second
DispatchQueue.concurrentPerform(iterations: 8) { index in
    ProcessGraph.process.queueForDeletion("/file\(index)")
}
graph.queueForDeletion(nil)
expect(Set(second.queued) == Set((0..<8).map { "/file\($0)" }), "the delete queue is not the browser's from other threads: \(second.queued)")

expect(graph.appController == nil, "an application controller before there is one")
let app = AppController()
AppController.instance = app
expect(graph.appController === app, "the application controller is not the shared one")

// the publisher, from any thread, read when asked
expect(graph.bonjourPublisher == nil, "a publisher before the application controller made one")
expect(graph.isSessionInactive == false, "an inactive session before the application controller exists")
let publisher = BonjourPublisher()
app.publisher = publisher
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.bonjourPublisher === publisher, "the publisher is not the application controller's")
}

// the graph of the database window: the application controller's, read when asked
expect(graph.browserWindow == nil, "a database window graph before the application controller made one")
let window = BrowserWindowGraph(browser: second)
app.browserWindow = window
expect(graph.browserWindow === window, "the database window graph is not the application controller's")

// the DICOM listeners: made once, with the graph, the same from any thread;
// the session's state is theirs, from any thread
nonisolated(unsafe) var listenersSeen = Set<ObjectIdentifier>()
DispatchQueue.concurrentPerform(iterations: 16) { _ in
    let listener = ProcessGraph.process.dicomListener
    lock.lock(); listenersSeen.insert(ObjectIdentifier(listener)); lock.unlock()
}
expect(listenersSeen.count == 1, "threads made \(listenersSeen.count) listener controllers")
let listener = graph.dicomListener
expect(listenersSeen == [ObjectIdentifier(listener)] && listener.processGraph === graph,
       "the listener controller is made again, or with another graph")
listener.inactive = true
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.isSessionInactive, "the session's state is not the listener controller's")
}
listener.inactive = false
expect(!graph.isSessionInactive, "the session's state was kept from an earlier read")

// the notifications: one, made with the graph, the same from any thread
let notifications = graph.userNotifications
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.userNotifications === notifications, "the notifications are not the graph's own")
}

// the arrangement of the viewers' windows and the application's menus: made
// once, with the graph, on the main actor; Recent Studies read when needed
let arranger = graph.windowArranger
expect(arranger === graph.windowArranger && arranger.processGraph === graph,
       "the arrangement of the viewers' windows is made again, or with another graph")
let menus = graph.applicationMenus
expect(menus === graph.applicationMenus && menus.processGraph === graph, "the menus are made again, or with another graph")
expect(menus.recentStudiesMenu() == nil, "a Recent Studies menu before the nib set it")
let recentStudiesMenu = NSMenu()
app.recentStudiesMenu = recentStudiesMenu
expect(menus.recentStudiesMenu() === recentStudiesMenu, "the Recent Studies menu is not the application controller's outlet")

// the send queue: made once, with the graph, the same from any thread
let queue = graph.dicomSendQueue
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.dicomSendQueue === queue, "the send queue is not the graph's own")
}
expect(queue.pendingSends == 0, "a send pending before any was queued")

// the register of the viewers: made once, with the graph, the same from any thread
let viewerRegistry = graph.viewerRegistry
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.viewerRegistry === viewerRegistry, "the register of the viewers is not the graph's own")
}

// the presets menus of the viewers: made once, with the graph, the same from any thread
let presetMenuCache = graph.presetMenuCache
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.presetMenuCache === presetMenuCache, "the presets menus are not the graph's own")
}

// the colour table the viewers applied last: made once, with the graph, the same from any thread
let colourTableCache = graph.colourTableCache
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.colourTableCache === colourTableCache, "the colour table cache is not the graph's own")
}

// the synchronization the viewers share: made once, with the graph, the same from any thread
let viewerSync = graph.viewerSync
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.viewerSync === viewerSync, "the viewers' synchronization is not the graph's own")
}

// the reslices of the viewers (IsiXImaging's SeriesResliceWorker): made once, with the graph, the same from any thread
let seriesResliceWorker = graph.seriesResliceWorker
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.seriesResliceWorker === seriesResliceWorker, "the reslice worker is not the graph's own")
}

// the routing queue: made once, with the graph, the same from any thread
// the PACS On-Demand searches: made once, with the graph, the same from any thread
let pacsOnDemand = graph.pacsOnDemand
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.pacsOnDemand === pacsOnDemand, "the PACS On-Demand searches are not the graph's own")
}
expect(pacsOnDemand.nodes.preferences as? UserDefaults === UserDefaults.standard, "the PACS On-Demand nodes do not read the standard preferences")
expect(pacsOnDemand.listStudies.studies == nil, "distant studies for the list before any search")

let routing = graph.routingQueue
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.routingQueue === routing, "the routing queue is not the graph's own")
}
let routingChecked = DispatchSemaphore(value: 0)
Task.detached {
    let queued = await routing.queued
    expect(queued.isEmpty, "files queued for routing before any rule chose them")
    routingChecked.signal()
}
routingChecked.wait()

// the scheduler of the incoming files: made once, with the graph, the same from
// any thread; the single entry over it receives the graph
let scheduler = graph.ingestScheduler
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.ingestScheduler === scheduler, "the scheduler is not the graph's own")
    expect(ProcessGraph.process.databaseIngest.processGraph === ProcessGraph.process, "the single entry has another graph")
}
expect(!scheduler.isPassRunning("no database"), "a pass running before any was asked for")

let readsBefore = DicomDatabase.reads
expect(graph.defaultDatabase == nil, "a default database while the first-use choice is pending")
let database = DicomDatabase()
DicomDatabase.instance = database
expect(graph.defaultDatabase === database, "the default database was kept from an earlier read")
expect(DicomDatabase.reads == readsBefore + 2, "the default database is not read when asked")

// the readers of a local database: each reads its own database, asked at each read
let defaultReader = graph.localStudyReader(reading: .defaultDatabase)
let activeReader = graph.localStudyReader(reading: .activeLocal)
let browserReader = graph.localStudyReader(reading: .browser)
let active = DicomDatabase(), shownByBrowser = DicomDatabase()
DicomDatabase.active = active
second.database = shownByBrowser
expect(defaultReader.database() === database, "the reader of the default database reads another one")
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    expect(ProcessGraph.process.activeLocalDatabase === active, "the active local database is not read when asked")
}
expect(activeReader.database() === active, "the reader of the active local database reads another one")
expect(browserReader.database() === shownByBrowser, "the reader of the browser's database reads another one")
let replacement = DicomDatabase()
DicomDatabase.active = replacement
second.database = nil
expect(activeReader.database() === replacement, "the reader of the active local database kept an earlier one")
expect(browserReader.database() == nil, "the reader of the browser's database kept an earlier one")

// the ROI archives of a viewer's images: a store over them and their database
// for each load and save, which indexes through the graph's single entry
MainActor.assumeIsolated {
    let image = DicomImage()
    let first = graph.roiArchives(of: [image], in: database), again = graph.roiArchives(of: [image], in: database)
    expect(first !== again, "the ROI archives of a load are kept for the next one")
    expect(first.images == [image] && first.database === database, "the ROI archives are not those of the images asked for")
    expect(first.ingest.processGraph === ProcessGraph.process, "the ROI archives index through another graph")
}
print("PASS: one graph for the process and its threads; browser, its network-log switch and database, application controller, publisher, database window graph, default and active local database read when asked; the preferences are UserDefaults.standard; one send queue, one routing queue, one scheduler of the incoming files, one listener controller and one set of notifications from any thread; one window arrangement and one set of menus on the main actor; each reader of a local database reads its own database when asked; a store of the ROI archives for each load and save")
'''

# Each must not compile: (name, source, a fragment of the expected error).
REFUSED = [
    ('the browser outside the main actor',
     'nonisolated func probe() -> BrowserController? { ProcessGraph.process.currentBrowser }\n',
     'main actor'),
    ('the application controller outside the main actor',
     'nonisolated func probe() -> AppController? { ProcessGraph.process.appController }\n',
     'main actor'),
    ('the arrangement of the viewers\' windows outside the main actor',
     'nonisolated func probe() -> ViewerWindowArranger { ProcessGraph.process.windowArranger }\n',
     'main actor'),
    ('the menus outside the main actor',
     'nonisolated func probe() -> ApplicationMenus { ProcessGraph.process.applicationMenus }\n',
     'main actor'),
    ('the database window\'s graph outside the main actor',
     'nonisolated func probe() -> BrowserWindowGraph? { ProcessGraph.process.browserWindow }\n',
     'main actor'),
    ('a second graph',
     'func probe() -> ProcessGraph { ProcessGraph() }\n',
     'private'),
]

with tempfile.TemporaryDirectory(prefix='horos-process-graph-') as directory:
    folder = Path(directory)
    (folder / 'doubles.swift').write_text(DOUBLES)
    (folder / 'main.swift').write_text(DRIVER)
    flags = ['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(folder / 'modules'),
             *isix_modules.module_flags('IsiXDICOMNetwork', folder / 'internal'),
             *isix_modules.module_flags('IsiXDatabase', folder / 'internal'),
             *isix_modules.module_flags('IsiXImaging', folder / 'internal')]
    built = subprocess.run([*flags, str(GRAPH), str(folder / 'doubles.swift'), str(folder / 'main.swift'),
                            '-o', str(folder / 'graph')], capture_output=True, text=True)
    if built.returncode != 0:
        fail('ProcessGraph.swift does not compile with the doubles:\n' + built.stderr[-2500:])
    else:
        warnings = [line for line in built.stderr.splitlines() if 'ProcessGraph.swift' in line and 'warning:' in line]
        if warnings:
            fail('ProcessGraph.swift compiles with warnings:\n' + '\n'.join(warnings))
        try:
            ran = subprocess.run([str(folder / 'graph')], capture_output=True, text=True, timeout=60)
            print(ran.stdout.strip())
            if ran.returncode != 0:
                fail('the graph does not behave as the singletons it hands out:\n' + (ran.stdout + ran.stderr)[-1500:])
        except subprocess.TimeoutExpired:
            fail('the graph driver did not finish in 60 seconds')
    for name, source, expected in REFUSED:
        probe = folder / 'probe.swift'
        probe.write_text(source)
        checked = subprocess.run([*flags, '-typecheck', str(GRAPH), str(folder / 'doubles.swift'), str(probe)],
                                 capture_output=True, text=True)
        if checked.returncode == 0:
            fail(f'the compiler accepts {name}')
        elif expected not in checked.stderr:
            fail(f'{name} is refused for another reason:\n' + checked.stderr[-1500:])

if failures:
    sys.exit(1)
print(f'PASS: {len(COMPOSITION)} composition points read ProcessGraph.process and hand the graph to the type they make, '
      'and no other file reads it; the browser and the application controller only on the main actor, '
      'and no graph but `process`')
