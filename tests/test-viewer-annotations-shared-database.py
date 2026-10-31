#!/usr/bin/env python3
"""A viewer's comment and status of a shared study reach its server, whichever database the browser shows.

A viewer of a study of a shared database stays open beside a browser that shows
a local database. The comments sheet (series or study comment), the status
pop-up and the contextual comment menu write the series and the study of the
image shown, and the server is told the value with SETVA
(`object(_:setValue:forKey:)` of the shared database), naming the image and the
key path from it. They used to tell the database the browser shows, and only
when it was a shared one: with the browser on a local database, the server's
rows kept the former comment and status, which the next update of the index
then brought back to the viewer.

The real StudyAnnotationEditor.swift, the real comment action of
ViewerContextualMenuBuilder.swift (`contextualMenuEvent(_:in:)`) and, once it
exists, the real RemoteDicomDatabase.database(of:) of RemoteDicomDatabase.swift
are compiled against doubles of the viewer, the browser, the databases and their
contexts. It is checked that, with the browser on the local database and on the
shared one, each of the four writes sends one SETVA to the shared database of
the image, with the key path and the value written locally; that an image of an
independent database of the shared one is told through the main database; and
that an image of a local database, or of no database, sends nothing, even while
the browser shows the shared database. It is also checked that the key images
ask the same RemoteDicomDatabase.database(of:). No app, no network and no DICOM
file are needed.
"""
from pathlib import Path
import importlib.util
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


# What the real sources ask of the parts of the application not brought here.
DOUBLES = r'''
import AppKit
import CoreData

/// A database: its context, and the main database of an independent one.
class DicomDatabase {
    var managedObjectContext: NSManagedObjectContext?
    var mainDatabase: Any?
    func isMainDatabase() -> Bool { mainDatabase == nil }
}

/// What the servers were told: database, image, key path, value.
nonisolated(unsafe) var told: [String] = []

final class RemoteDicomDatabase: DicomDatabase {
    let name: String
    init(_ name: String) { self.name = name }
    func object(_ object: NSManagedObject?, setValue value: Any?, forKey key: String?) {
        told.append("\(name) \((object as? DicomImage)?.name ?? "nil") \(key ?? "nil") = \(value.map { "\($0)" } ?? "nil")")
    }
}

/// The context of a database, which knows that database.
final class N2ManagedObjectContext: NSManagedObjectContext {
    weak var database: DicomDatabase?
}

@objc(DicomImage)
final class DicomImage: NSManagedObject {
    var name = ""
    var series: DicomSeries?
}

final class DicomSeries {
    var comment: String?
    var study: DicomStudy?
}

final class DicomStudy {
    var comment: String?
    var stateText: NSNumber?
}

final class DCMView {
    var curImage = 0
}

extension NSWindow {
    func orderOutAndEndSheet(returnCode: NSApplication.ModalResponse) {}
}

final class BrowserController {
    var database: DicomDatabase?
    var isCurrentDatabaseBonjour: Bool { database is RemoteDicomDatabase }
    var databaseOutline: NSOutlineView?
    func showDatabase(_ sender: Any?) {}
    func querySelectedStudy(_ sender: Any?) {}
}

final class ProcessGraph {
    var currentBrowser: BrowserController?
}

@MainActor final class ViewerSessionGraph {
    let processGraph: ProcessGraph
    init(_ processGraph: ProcessGraph) { self.processGraph = processGraph }
}

@MainActor final class ViewerController {
    var sessionGraph: ViewerSessionGraph!
    var files: NSMutableArray = []
    var window: NSWindow?
    var horos_curMovieIndex: Int16 = 0
    var horos_imageView: DCMView? = DCMView()
    var horos_CommentsWindow: NSWindow?
    var horos_CommentsEditField: NSTextField? = NSTextField(string: "")
    var horos_CommentsField: NSButton? = NSButton(title: "", target: nil, action: nil)
    var horos_StatusPopup: NSPopUpButton?
    var horos_statusValueToApply: Int32 = -1
    func horos_fileList(at index: Int) -> NSMutableArray? { files }
    func buildMatrixPreview(_ update: Bool) {}
    func horosLoadViewerPanels() {}
}

/// [sender title] as the comment action reads it.
enum ViewerSender {
    static func string(_ sender: Any?, _ key: String) -> String? { (sender as? NSMenuItem)?.title }
}

/// IsiXImaging's composition of a comment: the menus' titles, then the item's.
enum ViewerContextualMenus {
    static func composedTitle(itemTitle: String, enclosingMenuTitles: [String]) -> String {
        (enclosingMenuTitles.reversed() + [itemTitle]).joined(separator: ": ")
    }
}
'''

DRIVER = r'''
import AppKit
import CoreData

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

let model: NSManagedObjectModel = {
    let entity = NSEntityDescription()
    entity.name = "Image"
    entity.managedObjectClassName = NSStringFromClass(DicomImage.self)
    let model = NSManagedObjectModel()
    model.entities = [entity]
    return model
}()

/// A database with a context of its own over a store of the model.
func database<D: DicomDatabase>(_ made: D) -> D {
    let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    context.database = made
    made.managedObjectContext = context
    return made
}

/// An image of `context` (none: of no database), with its series and study.
func image(_ name: String, _ context: NSManagedObjectContext?) -> DicomImage {
    let image = context.map { DicomImage(entity: model.entities[0], insertInto: $0) }
        ?? DicomImage(entity: model.entities[0], insertInto: nil)
    image.name = name
    image.series = DicomSeries()
    image.series?.study = DicomStudy()
    return image
}

@MainActor
func run() {
    let shared = database(RemoteDicomDatabase("shared"))
    let local = database(DicomDatabase())
    let graph = ProcessGraph()
    graph.currentBrowser = BrowserController()
    let viewer = ViewerController()
    viewer.sessionGraph = ViewerSessionGraph(graph)
    let menu = ViewerContextualMenuBuilder(viewer.sessionGraph)

    /// The four writes of the viewer on `file`, and what the servers were told.
    func writes(_ file: DicomImage, _ tag: String) -> [String] {
        told = []
        viewer.files = [file]
        viewer.horos_CommentsEditField?.stringValue = "series " + tag
        viewer.endSetComments(tag: 1)
        check(file.series?.comment == "series " + tag, "the comments sheet did not write the series comment")
        viewer.horos_CommentsEditField?.stringValue = "study " + tag
        viewer.endSetComments(tag: 2)
        check(file.series?.study?.comment == "study " + tag, "the comments sheet did not write the study comment")
        viewer.horos_statusValueToApply = 2
        viewer.studyAnnotations.applyStatus()
        check(file.series?.study?.stateText == 2, "the status pop-up did not write the study's status")
        let root = NSMenu(title: "Root"), lung = NSMenu(title: "Lung")
        let item = lung.addItem(withTitle: "Nodule " + tag, action: nil, keyEquivalent: "")
        root.addItem(withTitle: "Lung", action: nil, keyEquivalent: "").submenu = lung
        withExtendedLifetime(root) { menu.contextualMenuEvent(item, in: viewer) }
        check(file.series?.comment == "Lung: Nodule " + tag, "the comment menu did not write its composed title: \(file.series?.comment ?? "nil")")
        return told
    }

    func expected(_ name: String, _ tag: String) -> [String] {
        ["shared \(name) series.comment = series \(tag)", "shared \(name) series.study.comment = study \(tag)",
         "shared \(name) series.study.stateText = 2", "shared \(name) series.comment = Lung: Nodule \(tag)"]
    }

    // The browser shows the local database, a viewer an image of the shared one: the server is told each write.
    graph.currentBrowser?.database = local
    let remote = image("remote", shared.managedObjectContext)
    let sent = writes(remote, "a")
    check(sent == expected("remote", "a"), "browser on the local database: the server was not told the viewer's writes: \(sent)")

    // The browser shows the shared database: the same.
    graph.currentBrowser?.database = shared
    let sentShown = writes(remote, "b")
    check(sentShown == expected("remote", "b"), "browser on the shared database: the server was not told the viewer's writes: \(sentShown)")

    // An image of an independent database of the shared one: its main database tells the server.
    let independent = database(RemoteDicomDatabase("independent"))
    independent.mainDatabase = shared
    let sentIndependent = writes(image("independent", independent.managedObjectContext), "c")
    check(sentIndependent == expected("independent", "c"), "an image of an independent database was not told through the main database: \(sentIndependent)")

    // An image of a local database, and one of no database, while the browser shows the shared one: no request.
    let sentLocal = writes(image("local", local.managedObjectContext), "d")
    check(sentLocal.isEmpty, "an image of a local database was sent to a server: \(sentLocal)")
    let sentNone = writes(image("none", nil), "e")
    check(sentNone.isEmpty, "an image of no database was sent to a server: \(sentNone)")
    print("ok")
}

MainActor.assumeIsolated { run() }
'''


def main():
    editor = (SOURCES / 'StudyAnnotationEditor.swift').read_text(encoding='utf-8')
    menus = (SOURCES / 'ViewerContextualMenuBuilder.swift').read_text(encoding='utf-8')
    remote = (SOURCES / 'RemoteDicomDatabase.swift').read_text(encoding='utf-8')
    keys = (SOURCES / 'ViewerController+KeyImages.swift').read_text(encoding='utf-8')
    façade = (SOURCES / 'ViewerController+CommentsStatus.swift').read_text(encoding='utf-8')
    failures = []

    if 'studyAnnotations.endComments(tag: ViewerSender.tag(sender))' not in indicator.swift_code(member(façade, 'func endSetComments(')) \
            or 'studyAnnotations.applyStatus()' not in indicator.swift_code(member(façade, 'func applyStatusValue()')):
        failures.append("the viewer's -endSetComments: and -applyStatusValue no longer reach StudyAnnotationEditor")
    # The key images ask the same question of the same place.
    row = 'static func database(of object: NSManagedObject?)'
    if row in remote:
        asked = indicator.swift_code(member(keys, 'func remoteDatabase(of file: NSManagedObject?) -> RemoteDicomDatabase? {'))
        if 'RemoteDicomDatabase.database(of: file)' not in asked:
            failures.append('the key images do not ask RemoteDicomDatabase.database(of:) for the shared database of a file')
    if shutil.which('xcrun') is None:
        for failure in failures:
            print('FAIL:', failure)
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return 1 if failures else SKIPPED
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1

    action = member(menus, 'func contextualMenuEvent(_ sender: Any?, in viewer: ViewerController) {')
    builder = ('import AppKit\n\n@MainActor struct ViewerContextualMenuBuilder {\n    private let graph: ViewerSessionGraph\n'
               '    init(_ graph: ViewerSessionGraph) { self.graph = graph }\n\n    ' + action + '\n}\n'
               '\nextension ViewerController {\n    func endSetComments(tag: Int) { studyAnnotations.endComments(tag: tag) }\n}\n')
    # The base has no RemoteDicomDatabase.database(of:): its routes compile without it.
    shared = ('import CoreData\n\nextension RemoteDicomDatabase {\n    ' + member(remote, row) + '\n}\n') if row in remote else ''

    with tempfile.TemporaryDirectory(prefix='horos-annotations-shared-') as directory:
        work = Path(directory)
        files = {'doubles.swift': DOUBLES, 'editor.swift': editor, 'menu.swift': builder, 'shared.swift': shared, 'main.swift': DRIVER}
        for name, text in files.items():
            (work / name).write_text(text, encoding='utf-8')
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *(str(work / name) for name in files), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print('FAIL: the sources do not compile with their doubles\n' + built.stderr[-3000:])
            return 1
        run = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
        if run.returncode or run.stdout.strip() != 'ok':
            print('FAIL:', (run.stdout + run.stderr).strip()[-1500:])
            return 1
    print("viewer annotations: the comments sheet's series and study comments, the status pop-up and the contextual "
          "comment menu tell the server of the shared database the image is a row of, with the browser on the local "
          'database or on the shared one, through the main database for an independent one, and nothing for an image '
          'of a local database or of none; the key images ask the same RemoteDicomDatabase.database(of:)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
