#!/usr/bin/env python3
"""A viewer's report actions act on the viewer's study, in that study's own database.

The Delete Report and Report items of a 2D viewer, and its templates pop-up,
used to send the browser's -deleteReport: and -generateReport:, which act on the
study selected in the browser and decide between a local and a shared database
by the database the browser shows. With another study selected, the viewer
deleted or opened that study's report; with the viewer on a study of a shared
database beside a browser on a local database, the server was not told of a
deleted report, the local copy of an existing report was not refreshed from its
SR and a new report went into the local database's reports folder.

The real report actions of StudyReports.swift, the viewer's actions of
ViewerImageExporter.swift, the browser's actions of
BrowserController+ReportImport.swift and RemoteDicomDatabase.database(of:) are
compiled against doubles of the databases, their contexts, the studies, the
alerts and the report generator. With TextEdit reports (no Word, no Pages and no
document opened: the workspace is a double), it is checked that:

* a viewer of a local study, with another study selected in the browser,
  deletes and creates its own study's report, in its database's reports folder,
  and leaves the selected study's report alone;
* a viewer of a study of a shared database, beside a browser on a local
  database, tells the shared database the report it deleted, refreshes an
  existing report from its SR through the shared database before opening it,
  and creates a new one in the shared database's TEMP.noindex folder; a study
  of an independent database of the shared one goes through the main database;
* the browser's own actions keep acting on the selected study, in the database
  the browser shows, local or shared.

No app, no network and no DICOM file are needed.

    python3 tests/test-viewer-report-own-study.py [<git revision>]
"""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import objc_exception_guards  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SKIPPED = 2
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', sys.argv[1] + ':' + path]).decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


def member(source, signature):
    """A declaration of Swift, from the line of `signature` through its closing brace."""
    at = source.rindex('\n', 0, source.index(signature)) + 1
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index] + '\n'


def members(source, signatures):
    """The members of `signatures` that `source` has; a revision may lack some."""
    return ''.join(member(source, signature) for signature in signatures if signature in source)


# What the real sources ask of the parts of the application not brought here.
DOUBLES = r'''
import AppKit
import CoreData

/// What happened, in order: deletions told to servers, refreshes, reports made and opened.
nonisolated(unsafe) var events: [String] = []

class DicomDatabase: NSObject {
    let name: String
    let folder: String
    var managedObjectContext: NSManagedObjectContext?
    var mainDatabase: Any?
    init(_ name: String, _ folder: String) { self.name = name; self.folder = folder }
    func isMainDatabase() -> Bool { mainDatabase == nil }
    func isLocal() -> Bool { true }
    var baseDirPath: String? { folder }
    func reportsDirPath() -> String? { (folder as NSString).appendingPathComponent("REPORTS") }

    /// The report the SR holds, extracted to a file of its own.
    static func extractReportSR(_ source: String?, contentDate: Date?) -> String? {
        guard let source else { return nil }
        let extracted = source + ".extracted"
        try? FileManager.default.removeItem(atPath: extracted)
        try? FileManager.default.copyItem(atPath: source, toPath: extracted)
        return extracted
    }
}

final class RemoteDicomDatabase: DicomDatabase {
    override func isLocal() -> Bool { false }
    func object(_ object: NSManagedObject?, setValue value: Any?, forKey key: String?) {
        events.append("\(name) told \((object as? DicomStudy)?.name ?? "nil") \(key ?? "nil") = \(value.map { "\($0)" } ?? "nil")")
    }
    func refreshCacheData(for image: DicomImage) -> String? {
        events.append("\(name) refreshed \(image.path)")
        return image.path
    }
}

/// The context of a database, which knows that database.
final class N2ManagedObjectContext: NSManagedObjectContext {
    weak var database: DicomDatabase?
}

final class DicomImage: NSObject {
    let path: String
    init(_ path: String) { self.path = path }
    var date: Date? { nil }
    func inDatabaseFolder() -> NSNumber? { true }
    func completePathResolved() -> String? { path }
}

@objc(DicomStudy)
final class DicomStudy: NSManagedObject {
    var name: String?
    var reportURL: String?
    var sr: DicomImage?
    func reportImage() -> DicomImage? { sr }
}

final class DicomSeries: NSObject {
    var study: DicomStudy?
}

enum HorosAlertPanel {
    static let defaultResponse = 1
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        events.append("alert: " + message)
        return defaultResponse
    }
    static func runInformational(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        defaultResponse
    }
    @discardableResult
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        run(title: title, message: message, defaultButton: defaultButton, alternateButton: alternateButton, otherButton: otherButton)
    }
}

func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ function: String) {}
func HorosReplaceReportFile(_ source: String?, _ destination: String?, _ error: inout NSError?) -> Bool {
    guard let source, let destination else { return false }
    try? FileManager.default.removeItem(atPath: destination)
    return (try? FileManager.default.copyItem(atPath: source, toPath: destination)) != nil
}
func HorosCleanReportExtractionParent(_ path: String?) {}

enum PluginManager {
    static func startProtectForCrash(withFilter filter: AnyObject?) {}
    static func endProtectForCrash() {}
}

enum ReportTemplateMenu {
    static func templateName(for sender: Any?) -> String? { nil }
}

enum WordReportAutomation {
    static func requestConsent(_ completion: @escaping (Error?) -> Void) { completion(nil) }
}

/// The report generator: a TextEdit report in the destination folder.
final class Reports: NSObject {
    func setTemplateName(_ name: String?) {}
    @discardableResult
    func createNewReport(_ study: DicomStudy?, destination: String, type: Int32) -> Bool {
        guard let study else { return false }
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let file = (destination as NSString).appendingPathComponent((study.name ?? "nil") + ".rtf")
        FileManager.default.createFile(atPath: file, contents: Data("{\\rtf1 new}".utf8))
        study.reportURL = file
        events.append("created \(study.name ?? "nil") in \(destination)")
        return true
    }
}

/// The workspace: what would open, without opening it.
enum Workspace {
    static func open(_ url: URL) -> Bool {
        events.append("opened " + url.lastPathComponent)
        return true
    }
    /// An existing report, which the real one opens in Pages when it is a
    /// Pages document and as the user opens it otherwise.
    static func openReport(atPath path: String) -> Bool { open(URL(fileURLWithPath: path)) }
    static func urlForApplication(withBundleIdentifier identifier: String) -> URL? { nil }
}

extension Notification.Name {
    static let OsirixReportModeChanged = Notification.Name("OsirixReportModeChanged")
    static let OsirixDeletedReport = Notification.Name("OsirixDeletedReport")
}

final class Outline {
    func reloadData() {}
}

@MainActor final class OpenReports {
    var watched: [String] = []
    func watch(_ study: DicomStudy) { watched.append(study.name ?? "nil") }
    func forget(_ study: DicomStudy) { watched.removeAll { $0 == study.name } }
}

@MainActor final class BrowserController: NSObject {
    var database: DicomDatabase?
    var selected: AnyObject?
    var horos_databaseOutline: Outline? = Outline()
    var horos_reportTemplatesListPopUpButton: NSPopUpButton?
    lazy var reports = StudyReports(browser: self)
}

extension BrowserController {
@@BROWSER@@
}

@MainActor final class ProcessGraph {
    var currentBrowser: BrowserController?
}

@MainActor final class ViewerController {
    var study: DicomStudy?
    func currentStudy() -> DicomStudy! { study }
}

@MainActor final class ViewerImageExporter {
    let viewer: ViewerController
    let processGraph: ProcessGraph
    init(viewer: ViewerController, processGraph: ProcessGraph) { self.viewer = viewer; self.processGraph = processGraph }
    static func refreshReportToolbarIcon(of viewer: ViewerController) {}
@@VIEWER@@
}

extension RemoteDicomDatabase {
@@SHARED@@
}

@@FILESCOPE@@

@MainActor final class StudyReports {
    unowned let browser: BrowserController
    let openReports = OpenReports()
    init(browser: BrowserController) { self.browser = browser }
    var reportsMode: Int { 1 }
    var selectedReportPlugin: Bundle? { nil }
    static func filter(of plugin: Bundle) -> AnyObject? { nil }
    var firstSelectedItem: AnyObject? { browser.selected }
    func updateToolbarIconSoon() {}
    func updateToolbarIcon() {}
@@REPORTS@@
}
'''

DRIVER = r'''
import AppKit
import CoreData

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

let root = CommandLine.arguments[1]
let model: NSManagedObjectModel = {
    let entity = NSEntityDescription()
    entity.name = "Study"
    entity.managedObjectClassName = NSStringFromClass(DicomStudy.self)
    let model = NSManagedObjectModel()
    model.entities = [entity]
    return model
}()

/// A database, with a context of its own over a store of the model.
func database<D: DicomDatabase>(_ made: D) -> D {
    let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    context.database = made
    made.managedObjectContext = context
    try? FileManager.default.createDirectory(atPath: made.reportsDirPath()!, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: made.folder + "/TEMP.noindex", withIntermediateDirectories: true)
    return made
}

/// A study of `database`, with a report in `folder` (and its SR) when `folder` is given.
func study(_ name: String, of database: DicomDatabase, reportIn folder: String? = nil) -> DicomStudy {
    let study = DicomStudy(entity: model.entities[0], insertInto: database.managedObjectContext)
    study.name = name
    if let folder {
        let file = (folder as NSString).appendingPathComponent(name + ".rtf")
        FileManager.default.createFile(atPath: file, contents: Data("{\\rtf1 old}".utf8))
        study.reportURL = file
        let sr = (database.folder as NSString).appendingPathComponent(name + "-sr.rtf")
        FileManager.default.createFile(atPath: sr, contents: Data("{\\rtf1 from the SR}".utf8))
        study.sr = DicomImage(sr)
    }
    return study
}

func exists(_ path: String?) -> Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
func contents(_ path: String?) -> String { path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "" }

@MainActor
func run() {
    let local = database(DicomDatabase("local", root + "/local"))
    let shared = database(RemoteDicomDatabase("shared", root + "/shared"))
    let graph = ProcessGraph()
    let browser = BrowserController()
    graph.currentBrowser = browser
    let viewer = ViewerController()
    let exporter = ViewerImageExporter(viewer: viewer, processGraph: graph)

    // A viewer of a local study while the browser selects another study of the same database.
    browser.database = local
    let a = study("A", of: local, reportIn: local.reportsDirPath())
    let b = study("B", of: local, reportIn: local.reportsDirPath())
    let fileA = a.reportURL, fileB = b.reportURL
    browser.selected = b
    viewer.study = a
    events = []
    exporter.deleteReport(nil)
    check(a.reportURL == nil && !exists(fileA), "the viewer did not delete its own study's report")
    check(b.reportURL == fileB && exists(fileB), "the viewer deleted the report of the study the browser selects")
    exporter.generateReport(nil)
    check(events == ["created A in \(local.reportsDirPath()!)/"],
          "the viewer did not create its own study's report in its database's reports folder: \(events)")
    check(b.reportURL == fileB, "the viewer touched the selected study's report")

    // A viewer of a study of a shared database beside a browser on the local database.
    let r = study("R", of: shared, reportIn: shared.folder + "/TEMP.noindex")
    let fileR = r.reportURL
    viewer.study = r
    events = []
    exporter.generateReport(nil)
    check(events == ["shared refreshed \(r.sr!.path)", "opened R.rtf"],
          "the viewer's shared report was not refreshed from its SR through the shared database, then opened: \(events)")
    check(contents(fileR).contains("from the SR"), "the local copy of the shared report was not replaced by the SR's")
    check(browser.reports.openReports.watched.contains("R"), "the shared report opened is not watched")
    events = []
    exporter.deleteReport(nil)
    check(events == ["shared told R reportURL = nil"], "the shared database was not told the report the viewer deleted: \(events)")
    check(r.reportURL == nil && !exists(fileR), "the viewer did not delete its shared study's report")
    check(b.reportURL == fileB && exists(fileB), "the viewer of a shared study deleted the selected local study's report")
    events = []
    exporter.generateReport(nil)
    check(events == ["created R in \(shared.folder)/TEMP.noindex/"],
          "the viewer's new shared report was not made in the shared database's TEMP.noindex folder: \(events)")

    // A study of an independent database of the shared one: through the main database.
    let independent = database(RemoteDicomDatabase("independent", root + "/independent"))
    independent.mainDatabase = shared
    let i = study("I", of: independent, reportIn: shared.folder + "/TEMP.noindex")
    viewer.study = i
    events = []
    exporter.deleteReport(nil)
    check(events == ["shared told I reportURL = nil"], "a study of an independent database was not told through the main database: \(events)")

    // The browser's own actions: the selected study, in the database the browser shows.
    events = []
    browser.deleteReport(nil)
    check(b.reportURL == nil && !exists(fileB), "the browser did not delete its selected study's report")
    browser.generateReport(nil)
    check(events == ["created B in \(local.reportsDirPath()!)/"], "the browser did not create its selected study's report: \(events)")
    browser.database = shared
    let s = study("S", of: shared)
    browser.selected = s
    events = []
    browser.generateReport(nil)
    check(events == ["created S in \(shared.folder)/TEMP.noindex/"], "the browser on the shared database did not create in TEMP.noindex: \(events)")
    events = []
    browser.deleteReport(nil)
    check(events == ["shared told S reportURL = nil"], "the browser on the shared database did not tell it the deleted report: \(events)")
    print("ok")
}

MainActor.assumeIsolated { run() }
'''


def main():
    reports = read('Horos/Sources/StudyReports.swift')
    exporter = read('Horos/Sources/ViewerImageExporter.swift')
    browser = read('Horos/Sources/BrowserController+ReportImport.swift')
    remote = read('Horos/Sources/RemoteDicomDatabase.swift')

    taken = members(reports, [
        'private static func study(of item: Any?)', 'private func reportError(', 'private func reportDatabase(of study:',
        'func deleteSelectedReport()', 'func deleteReport(of study:', 'func generateReport(sender: Any?)',
        'func generateReport(of study:', 'private func reportModeChanged()', 'private func openOrCreateReport(',
        'private func refreshSharedReport(', 'private func createWordReport(',
    ])
    # The double of the workspace stands for NSWorkspace.shared: nothing opens.
    taken = taken.replace('NSWorkspace.shared.', 'Workspace.')
    filescope = members(reports, ['private func objcSendBool(', 'private func objcClassOf('])
    viewer = members(exporter, ['func deleteReport(_ sender: Any?)', 'func generateReport(_ sender: Any?)'])
    forwards = members(browser, ['func deleteReport(_ sender: Any!)', 'func generateReport(_ sender: Any!)'])
    shared = members(remote, ['static func database(of object: NSManagedObject?)'])
    if not viewer or not forwards:
        print('FAIL: the report actions of the viewer or of the browser are missing')
        return 1
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return SKIPPED

    doubles = (DOUBLES.replace('@@BROWSER@@', forwards).replace('@@VIEWER@@', viewer).replace('@@SHARED@@', shared)
               .replace('@@FILESCOPE@@', filescope).replace('@@REPORTS@@', taken))
    with tempfile.TemporaryDirectory(prefix='horos-viewer-report-') as directory:
        work = Path(directory)
        files = {'guards.swift': 'import Foundation\n' + objc_exception_guards.STAND_IN, 'doubles.swift': doubles, 'main.swift': DRIVER}
        for name, text in files.items():
            (work / name).write_text(text, encoding='utf-8')
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *(str(work / name) for name in files), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print('FAIL: the report actions do not compile with their doubles\n' + built.stderr[-3000:])
            return 1
        data = work / 'data'
        data.mkdir()
        run = subprocess.run([str(work / 'check'), str(data)], capture_output=True, text=True, timeout=60)
        if run.returncode or run.stdout.strip() != 'ok':
            print((run.stdout + run.stderr).strip()[-1500:] or f'FAIL: exit {run.returncode}')
            return 1
    print("viewer reports: a viewer deletes, opens and creates its own study's report, whichever study the browser "
          "selects, in the study's own database (the shared one told of a deletion and refreshing an existing report, "
          "through the main database for an independent one; a new one in its TEMP.noindex), and the browser's own "
          'actions keep acting on the selected study in the database it shows')
    return 0


if __name__ == '__main__':
    sys.exit(main())
