#!/usr/bin/env python3
"""A viewer's images are read from their own database, whichever database the browser shows.

A viewer of a study of a shared database (another computer's, over Bonjour)
stays open beside a browser that shows a local database, and a viewer of a
local study beside a browser that shows a shared one. A DCMPix made for an
image is told whether its file is a shared database's (isBonjour): then it
fetches the file into the cache when it loads, else it reads the path it was
given. The series menu's and the series list's thumbnails, the movie export of
images (the burner's, a plugin's), the loading of a series into a viewer and
the sub-series sheet used to say so from the database the browser shows, and
the file the DCMPix fetched was asked of that database too. With the browser on
a local database the files of a shared study were never fetched, and with the
browser on a shared database a local image's file was asked of its server.
The series menu and the list looked for the patient's studies in the database
the browser shows, which has neither the viewer's study nor its patient's; the
window's file and the XML-RPC path of the front image were asked of the browser.

Compiled with doubles of the databases, their contexts and stores (Core Data in
memory) and of DCMPix: the real thumbnail of the series menu
(SeriesMenuPresenter.thumbnail(of:...)) tells the DCMPix of an image of the
shared database that its file is a shared one, and not that of a local image,
with the browser on either; the real file of a shared image
(DCMPix.localFileOfSharedImage(), on the main thread and on another one) and of
a row (DatabaseImageFiles.localFile(ofRow:)) are fetched from the database the image
is a row of, through the main database for an independent one, and a local
image's file is its path, the shared database never asked. The other paths are
checked in their sources: every DCMPix they make for an image takes isBonjour
from the image's own database, and the patient's studies come from the
database of the viewer's study. No app, no network and no DICOM file are needed.
"""
from pathlib import Path
import importlib.util
import re
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


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8', errors='replace')


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


def bonjour_arguments(code):
    """The isBonjour: argument of each DCMPix made in `code` (comments and strings removed)."""
    found = []
    for match in re.finditer(r'\bDCMPix\(path:', code):
        depth, index = 0, match.start() + len('DCMPix')
        while True:
            depth += {'(': 1, ')': -1}.get(code[index], 0)
            index += 1
            if depth == 0:
                break
        call = code[match.start():index]
        argument = re.search(r'isBonjour:\s*(.*?),\s*imageObj:', call, re.S)
        found.append(' '.join(argument.group(1).split()) if argument else None)
    return found


def own_database(argument, code):
    """Whether an isBonjour: argument says it from the image's own database."""
    if argument is None:
        return False
    if 'RemoteDicomDatabase.database(of:' in argument:
        return True
    name = re.fullmatch(r'(\w+)(\(.*\))?', argument)
    if not name:
        return False
    # A local value or helper of the same file, defined from the image's own database.
    for definition in re.finditer(r'\b(?:let|var|func)\s+%s\b[^\n]*' % re.escape(name.group(1)), code):
        line = definition.group(0)
        if 'RemoteDicomDatabase.database(of:' in line:
            return True
        helper = re.search(r'=\s*(\w+)\(', line)
        if helper and helper.group(1) != name.group(1) and own_database(helper.group(1) + '()', code):
            return True
    return False


def source_failures():
    failures = []
    # Every DCMPix a path of a viewer, a study or a series makes for an image.
    paths = {
        'ViewerController+SeriesPopup.swift': None,
        'SelectionMovieExport.swift': 'func exportSeries(of images: [DicomImage]',
        'ViewerSeriesLoader.swift': None,
        'ViewerOpener.swift': 'func chooseSubSeries(',
    }
    for name, signature in paths.items():
        source = read(name)
        code = indicator.swift_code(member(source, signature) if signature else source)
        whole = indicator.swift_code(source)
        arguments = bonjour_arguments(code)
        if not arguments:
            failures.append('%s: no DCMPix found where one is made for an image' % name)
        for argument in arguments:
            if not own_database(argument, whole):
                failures.append('%s: a DCMPix is told isBonjour from the browser, not from the image\'s database: %s' % (name, argument))
        for asked in ('isCurrentDatabaseBonjour', 'browser.isRemote', 'getLocalDCMPath'):
            if asked in code:
                failures.append('%s still asks the browser %s for an image of the viewer' % (name, asked))

    loading = indicator.swift_code(member(read('DCMPix+Loading.swift'), 'final func loadIfNeeded()'))
    if 'localFileOfSharedImage()' not in loading:
        failures.append("a DCMPix of a shared image does not fetch its file from the image's own database (localFileOfSharedImage)")
    for name in ('DCMPix+CAPI.m', 'DCMPix+CAPI.h', 'DCMPix+Loading.swift'):
        if 'HorosDCMPixLocalPathForBonjourImage' in read(name):
            failures.append('%s: the file of a shared image is still asked of the database the browser shows' % name)

    popup = read('ViewerController+SeriesPopup.swift')
    build = indicator.swift_code(member(popup, '    func build() {'))
    if 'database(of: study)' not in build or 'browser.database' in build:
        failures.append("the series menu looks for the patient's studies in the browser's database, not the viewer study's")
    cells = indicator.swift_code(member(read('SeriesListPresenter.swift'), 'private func fillCells('))
    if 'seriesMenuPresenter.database(of: study)' not in cells or re.search(r'let db = browser\.database', cells):
        failures.append("the series list looks for the patient's studies in the browser's database, not the viewer study's")
    studies = indicator.swift_code(member(popup, 'func patientStudies(of study: DicomStudy'))
    if 'browser.database === db' not in studies:
        failures.append("the browser's history of another database's patient is listed for the viewer's study")
    for signature in ('func updateRepresentedFileName()', 'func showMetaData()'):
        if 'DatabaseImageFiles.localFile(ofRow:' not in indicator.swift_code(member(popup, signature)):
            failures.append("the viewer's window file is asked of the browser (%s)" % signature)
    front = indicator.swift_code(member(read('XMLRPCInterface+Windows.swift'), 'public func pathToFrontDCM('))
    if 'DatabaseImageFiles.localFile(ofRow:' not in front or 'getLocalDCMPath' in front:
        failures.append('the XML-RPC path of the front image is asked of the browser')
    return failures


DOUBLES = r'''
import AppKit
import CoreData

/// What the databases were asked: database, request, image.
nonisolated(unsafe) var told: [String] = []
/// The DCMPix made: image, isBonjour.
nonisolated(unsafe) var made: [String] = []

class DicomDatabase: NSObject {
    let name: String
    var managedObjectContext: NSManagedObjectContext!
    var mainDatabase: Any?
    required init(_ name: String) { self.name = name }
    func isMainDatabase() -> Bool { mainDatabase == nil }
    func isLocal() -> Bool { true }
    func object(withID oid: Any!) -> Any! {
        try? managedObjectContext.existingObject(with: oid as! NSManagedObjectID)
    }
    func performBlockAndWait(_ block: () -> Void) { managedObjectContext.performAndWait(block) }
    /// A database over a private-queue context of this one's store.
    func privateQueueIndependentDatabase() -> Any! {
        let independent = type(of: self).init(name + " independent")
        let context = N2ManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = managedObjectContext.persistentStoreCoordinator
        context.database = independent
        independent.managedObjectContext = context
        independent.mainDatabase = self
        return independent
    }
    nonisolated(unsafe) static var open: [DicomDatabase] = []
    class func allDatabases() -> [Any]! { open }
}

final class RemoteDicomDatabase: DicomDatabase {
    override func isLocal() -> Bool { false }
    func cacheData(for image: DicomImage?, maxFiles: Int) -> String? {
        told.append("\(name) cacheData \(image?.name ?? "nil") \(maxFiles)")
        return image.map { "/cache/\(name)/\($0.name)" }
    }
}

final class N2ManagedObjectContext: NSManagedObjectContext {
    weak var database: DicomDatabase?
}

@objc(DicomImage)
final class DicomImage: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var path: String?
    @objc var series: AnyObject? { nil }
    @objc func completePath() -> String! { path }
}

@objc(DicomSeries)
final class DicomSeries: NSManagedObject {
    @NSManaged var thumbnail: Data?
}

/// The database the browser shows.
nonisolated(unsafe) var shown: DicomDatabase?

struct BrowserDatabaseSource {
    static let process = BrowserDatabaseSource()
    var browserDatabase: DicomDatabase? { shown }
}

final class DCMPix: NSObject {
    var horos_imageObjectID: NSManagedObjectID!
    var notAbleToLoadImage = false
    init?(path: String?, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>?, _ f: Int, _ ss: Int, isBonjour: Bool,
          imageObj: NSManagedObject?) {
        made.append("\((imageObj as? DicomImage)?.name ?? "nil") isBonjour \(isBonjour)")
        horos_imageObjectID = imageObj?.objectID
    }
    override init() {}
    func checkLoad() {}
    func generateThumbnailImage(withWW ww: Float, wl: Float) -> NSImage? { NSImage(size: NSSize(width: 4, height: 4)) }
}

enum HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
}
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: String) {}
enum ViewerSender {
    static func intValue(_ value: Any?) -> Int32 { (value as? NSNumber)?.int32Value ?? 0 }
}
enum DatabasePreferences { static let storeThumbnailsInDB = "storeThumbnailsInDB" }
struct Preferences { subscript(_ key: String) -> Bool { false } }
final class BrowserController {
    static func produceJPEGThumbnail(_ image: NSImage) -> Data? { nil }
}

/// The browser as the series menu asks it: the database it shows.
final class HarnessBrowser {
    var database: DicomDatabase? { shown }
    var isRemote: Bool { !(shown?.isLocal() ?? false) }
}
'''

DRIVER = r'''
import AppKit
import CoreData

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

let model: NSManagedObjectModel = {
    func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    let image = NSEntityDescription()
    image.name = "Image"
    image.managedObjectClassName = NSStringFromClass(DicomImage.self)
    image.properties = [attribute("name", .stringAttributeType), attribute("path", .stringAttributeType)]
    let series = NSEntityDescription()
    series.name = "Series"
    series.managedObjectClassName = NSStringFromClass(DicomSeries.self)
    series.properties = [attribute("thumbnail", .binaryDataAttributeType)]
    let model = NSManagedObjectModel()
    model.entities = [image, series]
    return model
}()

/// A database with a main-queue context over a store of its own, open.
func database<D: DicomDatabase>(_ made: D) -> D {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    _ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.database = made
    made.managedObjectContext = context
    DicomDatabase.open.append(made)
    return made
}

/// A saved image of `database`, its file in the database's folder.
func image(_ name: String, of database: DicomDatabase) -> DicomImage {
    let image = DicomImage(entity: model.entities[0], insertInto: database.managedObjectContext)
    image.name = name
    image.path = "/data/\(database.name)/\(name)"
    try! database.managedObjectContext.save()
    return image
}

/// The file of a DCMPix of `image`, read on the main thread or on another one.
func sharedFile(_ image: DicomImage, onMainThread: Bool) -> String? {
    let pix = DCMPix()
    pix.horos_imageObjectID = image.objectID
    if onMainThread { return pix.localFileOfSharedImage() }
    nonisolated(unsafe) var answer: String?
    let done = DispatchSemaphore(value: 0)
    Thread { answer = pix.localFileOfSharedImage(); done.signal() }.start()
    done.wait()
    return answer
}

@MainActor
func run() {
    let shared = database(RemoteDicomDatabase("shared"))
    let local = database(DicomDatabase("local"))
    let remote = image("remote", of: shared)
    let mine = image("mine", of: local)
    let presenter = SeriesMenuPresenter(browser: HarnessBrowser())

    /// What the series menu's thumbnail of `file` told its DCMPix.
    func thumbnail(of file: DicomImage) -> [String] {
        made = []
        let series = DicomSeries(entity: model.entities[1], insertInto: nil)
        _ = presenter.thumbnail(of: series, images: [file], index: 0, function: "check")
        return made
    }

    for browser in [local, shared] {
        shown = browser
        let on = "browser on the \(browser.name) database"
        check(thumbnail(of: remote) == ["remote isBonjour true"], "\(on): the series menu's thumbnail of a shared image is read as a local file: \(made)")
        check(thumbnail(of: mine) == ["mine isBonjour false"], "\(on): the series menu's thumbnail of a local image is fetched from a server: \(made)")

        for main in [true, false] {
            let thread = main ? "main thread" : "another thread"
            told = []
            let file = sharedFile(remote, onMainThread: main)
            check(file == "/cache/shared/remote" && told == ["shared cacheData remote 0"],
                  "\(on), \(thread): the file of a shared image is not fetched from its database: \(file ?? "nil") \(told)")
        }

        told = []
        check(DatabaseImageFiles.localFile(ofRow: remote) == "/cache/shared/remote" && told == ["shared cacheData remote 0"],
              "\(on): the file of a row of the shared database is not its copy in the cache: \(told)")
        told = []
        check(DatabaseImageFiles.localFile(ofRow: mine) == "/data/local/mine" && told.isEmpty,
              "\(on): the file of a local row is asked of a server: \(told)")
    }

    // A local image whose DCMPix says isBonjour (a plugin's), the browser on the shared database: its own path, no server.
    shown = shared
    told = []
    let file = sharedFile(mine, onMainThread: true)
    check(file == "/data/local/mine" && told.isEmpty, "a local image's file is asked of the shared database the browser shows: \(file ?? "nil") \(told)")

    // A row of an independent database of the shared one: its main database fetches the file.
    let independent = shared.privateQueueIndependentDatabase() as! RemoteDicomDatabase
    var row: DicomImage?
    independent.performBlockAndWait { row = independent.object(withID: remote.objectID) as? DicomImage }
    told = []
    independent.performBlockAndWait { _ = DatabaseImageFiles.localFile(ofRow: row) }
    check(told == ["shared cacheData remote 0"], "a row of an independent database is not fetched through the main database: \(told)")
    print("ok")
}

MainActor.assumeIsolated { run() }
'''


def main():
    failures = source_failures()
    popup = read('ViewerController+SeriesPopup.swift')
    pix = read('DCMPix+Database.swift')
    bonjour = read('BrowserController+Bonjour.swift')
    remote = read('RemoteDicomDatabase.swift')
    resolver = 'final func localFileOfSharedImage()'
    if resolver not in pix or 'func localFile(ofRow image: NSManagedObject?)' not in bonjour:
        failures.append("the file of a viewer's image cannot be asked of its own database (DCMPix.localFileOfSharedImage, "
                        'DatabaseImageFiles.localFile(ofRow:))')
    if shutil.which('xcrun') is None:
        for failure in failures:
            print('FAIL:', failure)
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        return 1 if failures else SKIPPED

    thumbnail = member(popup, 'func thumbnail(of curSeries: DicomSeries')
    presenter = ('import AppKit\nimport CoreData\n\n@MainActor final class SeriesMenuPresenter {\n    let browser: HarnessBrowser\n'
                 '    let preferences = Preferences()\n    init(browser: HarnessBrowser) { self.browser = browser }\n\n    '
                 + thumbnail + '\n}\n')
    row = 'static func database(of object: NSManagedObject?)'
    pieces = 'import CoreData\n\n'
    if row in remote:
        pieces += 'extension RemoteDicomDatabase {\n    ' + member(remote, row) + '\n}\n'
    else:
        failures.append('RemoteDicomDatabase.database(of:) is missing')
    driver = DRIVER
    if resolver in pix and 'func localFile(ofRow image: NSManagedObject?)' in bonjour:
        pieces += ('\nextension DCMPix {\n    ' + member(pix, resolver) + '\n}\n\n' + member(pix, 'func databaseOfRow(')
                   + '\n\n' + member(pix, 'private func openDatabase(holding') + '\n\n' + member(pix, 'func privateQueueDatabase(')
                   + '\n\n' + member(bonjour, 'enum DatabaseImageFiles {') + '\n')
    else:
        # The base: only the series menu's thumbnail is run.
        driver = re.sub(r'\n/// The file of a DCMPix of `image`.*?\n}\n', '\n', DRIVER, flags=re.S)
        driver = re.sub(r'\n        for main in \[true, false\] \{.*?\n    print\("ok"\)', '\n    }\n    print("ok")', driver, flags=re.S)

    with tempfile.TemporaryDirectory(prefix='horos-viewer-shared-files-') as directory:
        work = Path(directory)
        files = {'doubles.swift': DOUBLES, 'presenter.swift': presenter, 'pieces.swift': pieces, 'main.swift': driver}
        for name, text in files.items():
            (work / name).write_text(text, encoding='utf-8')
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                                *(str(work / name) for name in files), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the sources do not compile with their doubles\n' + built.stderr[-3000:])
        else:
            ran = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
            if ran.returncode or ran.stdout.strip() != 'ok':
                failures.append((ran.stdout + ran.stderr).strip()[-1500:].removeprefix('FAIL: '))
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print("viewer images of a shared or a local database: the series menu's thumbnails, the movie export, the series "
          "loading and the sub-series sheet tell DCMPix isBonjour from the image's own database, with the browser on "
          'either; the file of a shared image is fetched from the database it is a row of, on the main thread and on '
          "another one, through the main database for an independent one, and a local image's file is its path; the "
          "series menu and the list look for the patient's studies in the viewer study's database; the window's file "
          'and the XML-RPC path ask the image\'s own database')
    return 0


if __name__ == '__main__':
    sys.exit(main())
