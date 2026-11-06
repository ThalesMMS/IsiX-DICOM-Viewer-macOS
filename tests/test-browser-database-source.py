#!/usr/bin/env python3
"""The model objects, the reports and the plugin adapters read the browser's
database from one registered source, and the children of a row are a type of
their own.

BrowserDatabaseSource (Horos/Sources/BrowserDatabaseSource.swift) is the
registered source of the objects the process graph does not reach. It is
compiled as it is, with doubles of the process graph and of the databases over
real Core Data stores in memory, and driven:
- the browser's database and the active local database are the graph's, read
  when asked, from any thread;
- the database of an object: for a row of the browser's database, the
  browser's database itself (its main context) or one of the same folder and
  store (a context of its own on that store), so both answer the same; for a
  row of another database, that database, which is the one that counts; the
  browser's for an object without a context;
- whether an object is a row of the browser's database: the same store, as
  the identity of the two coordinators always said (two nils included).

Over the sources, case by case:
- the ten files read neither `BrowserController.currentBrowser()` nor
  `DicomDatabase.default()` / `activeLocal()`; each place that read them reads
  what the table CASES says: the browser's database, the active local database,
  the store comparison, the browser on the main actor or the delete queue
  through the graph, or the object's own database;
- the places that now read the object's own database are SWAPS, each with the
  reason both answer the same while the object is a row the browser shows;
- the source is the composition point tests/test-process-graph.py lists.

DatabaseItemChildren (Horos/Sources/DatabaseItemChildren.swift), what
`childrenArray:onlyImages:` did inside BrowserController, is compiled with
doubles of the model (Core Data objects, so a deleted one is deleted) next to
the browser's code of the revision before it moved, and both answer the same
for a series, a study (its image series, and every series with the documents
last), a distant row, a deleted row, an image, another object and nil. The
browser's two selectors are one-line façades over it, and the reports read the
paths of the first series through it, without `perform(#selector(...))`.
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
import history_reference  # noqa: E402

SKIPPED = 2
ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
SOURCE = SOURCES / 'BrowserDatabaseSource.swift'
CHILDREN = SOURCES / 'DatabaseItemChildren.swift'
SELECTION = 'Horos/Sources/BrowserController+SelectionFiles.swift'
OLD_MARK = 'sortedArray = object.value(forKey: "imageSeries") as? [Any]'
failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

SOURCE_READ = 'BrowserDatabaseSource.process'
BROWSER_DATABASE = 'BrowserDatabaseSource.process.browserDatabase'
ACTIVE = 'BrowserDatabaseSource.process.activeLocalDatabase'
STORE = 'BrowserDatabaseSource.process.isInBrowserDatabase(self)'
OBJECT = 'BrowserDatabaseSource.process.database(of: self)'
BROWSER = 'BrowserDatabaseSource.process.processGraph.currentBrowser'
LOGS = 'BrowserDatabaseSource.process.processGraph.networkLogsActive'
DELETION = 'BrowserDatabaseSource.process.processGraph.queueForDeletion('

# Each file, and how many lines read each thing from the source. The lines
# that read the source and are not in the table fail, as do those missing.
CASES = {
    'DicomStudy.swift': {
        OBJECT: 5,            # SWAPS below
    },
    'DicomStudy+Report.swift': {
        OBJECT: 1,            # SWAPS below
    },
    'Reports.swift': {
        BROWSER_DATABASE: 6,  # the RTF, Word, OpenDocument and Pages templates of the database the browser shows
    },
    'IsiXDatabaseAdapter.swift': {
        ACTIVE: 1,            # the database a plugin reads and changes
        BROWSER: 4,           # the selection, the viewer of a series, the albums after a change (two)
    },
    'DicomImage.swift': {
        DELETION: 2,          # the image's file and its Analyze .img, after the save that deletes the row
    },
    'DCMPix+Database.swift': {
        BROWSER_DATABASE: 1,  # the database of an image's row when no open database holds it, or of no row: the
                              # row, the size written back, the shared file fetched and the RT STRUCT ROIs ask it
    },
    'DCMPix+RTStruct.swift': {
                              # refused for a shared database and the images it refers to looked up: the image's
                              # own database (DCMPix+Database.swift), not the browser's
    },
    'RemoteDicomDatabase.swift': {
        BROWSER: 2,           # the password sheet; the context about to change
    },
    'PluginManager.swift': {
        BROWSER: 1,           # the database window: target of database plugins, holder of the plugin manager
    },
    'IsiXPluginHost.swift': {
        BROWSER: 1,           # the parent window of a plugin without a viewer
    },
    'DCMTKStoreSCU.swift': {
        LOGS: 1,              # the network log of a send
        ACTIVE: 1,            # the temporary folder of the converted copies
    },
}

# The places that read the object's own database where they read the browser's,
# and why both answer the same while the study is a row the browser shows.
SWAPS = {
    ('DicomStudy.swift', 'reportURL', 'get'):
        "a relative report path is resolved in the study's database folder; the browser's is that folder "
        'while it shows the study',
    ('DicomStudy.swift', 'reportURL', 'set'):
        "a report path inside the study's database folder is kept relative to it; the same folder while the "
        'browser shows the study',
    ('DicomStudy+Report.swift', 'archiveValidatedReportAsDICOMPDF', 'validated report'):
        "the DICOM PDF of a validated report is written in the data folder of the study's database and indexed "
        "there; the browser's while it shows the study, and for a study of a database it does not show the PDF no "
        'longer goes to a scratch database in the temporary folder, so a shared database sends it to its server',
    ('DicomStudy.swift', 'writeWindowsStateAsDICOMSR', 'windows state SR'):
        "the windows state SR is written in the data folder of the study's database and indexed there; "
        "the browser's while it shows the study, and for a study of a database it does not show the SR "
        'no longer lands in the folder and the index of the one shown',
    ('DicomStudy.swift', 'archiveAnnotationsAsDICOMSR', 'annotations SR'):
        "the annotations SR is written in the data folder of the study's database and indexed there; the "
        "browser's while it shows the study, and for a study of a database it does not show the SR no longer "
        'goes to a scratch database in the temporary folder, where no server or rebuild ever read it',
    ('DicomStudy.swift', 'archiveReportAsDICOMSR', 'report SR'):
        "the report SR is written in the data folder of the study's database and indexed there; the "
        "browser's while it shows the study, and for a study of a database it does not show the SR no longer "
        'goes to a scratch database in the temporary folder, so a shared database still sends the report to its server',
}

# --- the sources -------------------------------------------------------------------
for name, expected in CASES.items():
    path = SOURCES / name
    if not path.is_file():
        fail(f'{name} is gone')
        continue
    code = indicator.swift_code(path.read_text(encoding='utf-8'))
    lines = code.splitlines()
    for number, line in enumerate(lines, 1):
        if indicator.AXIS_B_SWIFT['current_browser'].search(line):
            fail(f'{name}:{number} reaches the browser singleton again')
        if re.search(r'\bDicomDatabase\s*\.\s*(?:default|activeLocal)\s*\(', line):
            fail(f'{name}:{number} reads the default or the active database outside the source')
    for needle, count in expected.items():
        found = sum(needle in line for line in lines)
        if found != count:
            fail(f'{name}: {found} lines read {needle}, expected {count}')
    reads = sum(SOURCE_READ in line for line in lines)
    if reads != sum(expected.values()):
        fail(f'{name}: {reads} lines read the source, the table lists {sum(expected.values())}')

study = indicator.swift_code((SOURCES / 'DicomStudy.swift').read_text(encoding='utf-8'))


def body(text, start, end):
    begin = text.find(start)
    if begin < 0:
        return ''
    finish = text.find(end, begin + len(start))
    return text[begin:finish if finish >= 0 else len(text)]


report_url = body(study, '@objc public dynamic var reportURL: String!', '@objc public dynamic var stateText')
getter, _, setter = report_url.partition('        set {')
state_text = body(study, '@objc public dynamic var stateText', '@objc public dynamic var ')
validated_pdf = body(indicator.swift_code((SOURCES / 'DicomStudy+Report.swift').read_text(encoding='utf-8')),
                     'func archiveValidatedReportAsDICOMPDF()', '\n    }\n\n')
windows_state = body(study, '@nonobjc func writeWindowsStateAsDICOMSR()', 'public dynamic func archiveReportAsDICOMSR')
annotations_sr = body(study, '@objc public dynamic func archiveAnnotationsAsDICOMSR()', '@objc public dynamic func archiveWindowsStateAsDICOMSR()')
report_sr = body(study, '@objc public dynamic func archiveReportAsDICOMSR()', '\n    }\n\n')
where = {
    ('DicomStudy.swift', 'reportURL', 'get'): getter,
    ('DicomStudy.swift', 'reportURL', 'set'): setter,
    ('DicomStudy+Report.swift', 'archiveValidatedReportAsDICOMPDF', 'validated report'): validated_pdf,
    ('DicomStudy.swift', 'writeWindowsStateAsDICOMSR', 'windows state SR'): windows_state,
    ('DicomStudy.swift', 'archiveAnnotationsAsDICOMSR', 'annotations SR'): annotations_sr,
    ('DicomStudy.swift', 'archiveReportAsDICOMSR', 'report SR'): report_sr,
}
for case, reason in SWAPS.items():
    if len(reason.split()) < 4:
        fail(f'{case}: the swap has no reason')
    if OBJECT not in where.get(case, ''):
        fail(f"{case}: does not read the study's own database")
if 'GeneratedSeriesImport.process.add(into: database)' not in windows_state or BROWSER_DATABASE in windows_state \
        or 'uniquePathForNewDataFile' in windows_state:
    fail("the windows state SR does not take its path in the study's database and index it there (GeneratedSeriesImport's add(into:writing:))")
for name, archive, call in (('annotations SR', annotations_sr, 'GeneratedSeriesImport.process.add(into: database, writing:'),
                            ('report SR', report_sr, 'GeneratedSeriesImport.process.add(into: database, at: dstPath, writing:'),
                            ("validated report's PDF", validated_pdf, 'GeneratedSeriesImport.process.add(into: database, writing:')):
    if call not in archive or STORE in archive or BROWSER_DATABASE in archive or 'tmpDirPath' in archive \
            or 'tmpFilePathInTmp' in archive or 'DicomDatabase(atPath' in archive:
        fail(f"the {name} does not take its path in the study's database and index it there "
             "(GeneratedSeriesImport's add(into:at:writing:indexing:)), or still reaches the scratch database")
if state_text.count('self.archiveValidatedReportAsDICOMPDF()') != 1 or SOURCE_READ in state_text:
    fail("validating the report does not write its DICOM PDF through archiveValidatedReportAsDICOMPDF, or the status "
         'still reads the browser')

process_graph = (ROOT / 'tests/test-process-graph.py').read_text(encoding='utf-8')
if "'Horos/Sources/BrowserDatabaseSource.swift':" not in process_graph or \
        "static let process = BrowserDatabaseSource(processGraph: ProcessGraph.process)" not in process_graph:
    fail('the source is not a composition point of tests/test-process-graph.py')

selection = indicator.swift_code((ROOT / SELECTION).read_text(encoding='utf-8'))
for selector, call in (('childrenArray:onlyImages:', 'DatabaseItemChildren.children(of: item, onlyImages: onlyImages)'),
                       ('childrenArray:', 'DatabaseItemChildren.children(of: item)')):
    found = re.search(r'@objc\(' + re.escape(selector) + r'\)\s*nonisolated func childrenArray\([^)]*\) -> \[Any\]! \{\s*(.*?)\s*\}',
                      selection, re.S)
    if not found or found.group(1).strip() != call:
        fail(f'BrowserController.{selector} is not a one-line façade over DatabaseItemChildren ({call})')
reports = indicator.swift_code((SOURCES / 'Reports.swift').read_text(encoding='utf-8'))
paths = body(reports, 'private func firstSeriesImagePaths', 'private func dicomValue')
if 'DatabaseItemChildren.children(of:' not in paths or 'perform(' in paths:
    fail('the reports do not read the paths of the first series through DatabaseItemChildren')

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(1 if failures else SKIPPED)

# --- the source, compiled as it is -----------------------------------------------------
SOURCE_DOUBLES = r'''
import CoreData

// The databases: each over a context of its own, which knows its database as
// N2ManagedObjectContext does; two of them may share a folder and a store.
class N2ManagedDatabase: NSObject, @unchecked Sendable {
    var managedObjectContext: NSManagedObjectContext!
}
final class N2ManagedObjectContext: NSManagedObjectContext, @unchecked Sendable {
    weak var database: N2ManagedDatabase!
}
final class DicomDatabase: N2ManagedDatabase, @unchecked Sendable {
    let baseDirPath: String
    init(baseDirPath: String, coordinator: NSPersistentStoreCoordinator) {
        self.baseDirPath = baseDirPath
        super.init()
        // The driver runs on the main thread.
        let context = N2ManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.database = self
        managedObjectContext = context
    }
    func uniquePathForNewDataFile(withExtension ext: String) -> String { "\(baseDirPath)/DATABASE.noindex/1.\(ext)" }
}

// The process graph: the databases it answers from any thread, read when asked.
final class ProcessGraph: @unchecked Sendable {
    static let process = ProcessGraph()
    nonisolated(unsafe) var shown: DicomDatabase?
    nonisolated(unsafe) var active: DicomDatabase?
    var browserDatabase: DicomDatabase? { shown }
    var activeLocalDatabase: DicomDatabase? { active }
}
'''

SOURCE_DRIVER = r'''
import CoreData

func expect(_ condition: Bool, _ what: String) {
    if !condition {
        print("FAIL: \(what)")
        exit(1)
    }
}

let model = NSManagedObjectModel()
let entity = NSEntityDescription()
entity.name = "Study"
entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
model.entities = [entity]

@MainActor func store() -> NSPersistentStoreCoordinator {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    _ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
    return coordinator
}

@MainActor func study(in database: DicomDatabase) -> NSManagedObject {
    NSManagedObject(entity: entity, insertInto: database.managedObjectContext)
}

let source = BrowserDatabaseSource.process
let graph = ProcessGraph.process
let shownStore = store(), otherStore = store()
let shown = DicomDatabase(baseDirPath: "/Shown", coordinator: shownStore)
let independent = DicomDatabase(baseDirPath: "/Shown", coordinator: shownStore)
let other = DicomDatabase(baseDirPath: "/Other", coordinator: otherStore)
let loose = NSManagedObject(entity: entity, insertInto: nil)

// read when asked, from any thread
expect(source.browserDatabase == nil && source.activeLocalDatabase == nil, "databases before the graph has any")
graph.shown = shown
graph.active = other
let lock = NSLock()
nonisolated(unsafe) var seen = Set<ObjectIdentifier>()
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    let read = BrowserDatabaseSource.process
    guard let browser = read.browserDatabase, let active = read.activeLocalDatabase else { return }
    lock.lock(); seen.insert(ObjectIdentifier(browser)); seen.insert(ObjectIdentifier(active)); lock.unlock()
}
expect(seen == [ObjectIdentifier(shown), ObjectIdentifier(other)], "the databases are not the graph's from other threads")
expect(source.activeLocalDatabase === other, "the active local database is not the graph's")

// a row of the browser's database: the same answer either way
let row = study(in: shown)
expect(source.database(of: row) === shown, "a row of the browser's database does not answer that database")
expect(source.isInBrowserDatabase(row), "a row of the browser's database is not in it")
let sameStore = study(in: independent)
let own = source.database(of: sameStore)
expect(own === independent, "a row of a context of its own does not answer its database")
expect(own?.baseDirPath == source.browserDatabase?.baseDirPath, "a row of the same store answers another folder")
expect(own?.uniquePathForNewDataFile(withExtension: "dcm") == source.browserDatabase?.uniquePathForNewDataFile(withExtension: "dcm"),
       "a row of the same store writes its files elsewhere")
expect(source.isInBrowserDatabase(sameStore), "a row of the same store is not in the browser's database")

// a row of another database: its own database counts
let elsewhere = study(in: other)
expect(source.database(of: elsewhere) === other, "a row of another database answers the browser's")
expect(!source.isInBrowserDatabase(elsewhere), "a row of another database is in the browser's")

// without a context: the browser's database; in it only while there is none
expect(source.database(of: loose) === shown, "an object without a context does not answer the browser's database")
expect(source.database(of: nil) === shown, "no object does not answer the browser's database")
expect(!source.isInBrowserDatabase(loose), "an object without a context is in the browser's database")

// the browser switches: the rows keep their database, the reads follow
graph.shown = other
expect(source.database(of: row) === shown, "a row follows the browser to another database")
expect(source.isInBrowserDatabase(elsewhere) && !source.isInBrowserDatabase(row), "the store comparison was kept from an earlier read")
expect(source.database(of: loose) === other, "the browser's database was kept from an earlier read")
graph.shown = nil
expect(source.isInBrowserDatabase(loose), "two nils are no longer the same store")
expect(source.database(of: loose) == nil, "a database for an object without one while the browser has none")
print("PASS")
'''

# --- the children of a row ---------------------------------------------------------
MODEL_DOUBLES = r'''
import CoreData

@objc(DicomImage) final class DicomImage: NSManagedObject {
    @objc func type() -> String! { "Image" }
}
@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @objc func type() -> String! { "Series" }
    @objc func isDistant() -> Bool { false }
    var images: [Any] = []
    @objc(sortedImages) func sortedImagesArray() -> NSArray! { images as NSArray }
    func sortedImages() -> [Any]! { sortedImagesArray() as? [Any] }
}
@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @objc func type() -> String! { "Study" }
    @objc func isDistant() -> Bool { false }
    var pictures: [Any] = [], documents: [Any] = []
    @objc func imageSeries() -> NSArray! { pictures as NSArray }
    // Documents first, as the series numbers would sort them.
    @objc func allSeries() -> NSArray! { (documents + pictures) as NSArray }
    class func imagesBeforeDocuments(_ series: NSArray) -> NSArray {
        let all = series as? [AnyObject] ?? []
        func isPicture(_ series: AnyObject) -> Bool { (series as? DicomSeries)?.images.isEmpty == false }
        return (all.filter(isPicture) + all.filter { !isPicture($0) }) as NSArray
    }
}
// A row of a distant study, and something else with a type.
final class DistantNode: NSObject {
    @objc func isDistant() -> Bool { true }
    @objc func type() -> String! { "Study" }
}
final class Other: NSObject {
    @objc func type() -> String! { "Other" }
}

// The guards of HorosObjCException+Guards.swift, running each body.
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) { body() }
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? { body(); return nil }
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T { body() }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}

enum BrowserObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool = false, _ function: String) {}
    static func literallyEqual(_ a: String?, _ b: String?) -> Bool { a != nil && a == b }
}
'''

CHILDREN_DRIVER = r'''
import CoreData

func expect(_ condition: Bool, _ what: String) {
    if !condition {
        print("FAIL: \(what)")
        exit(1)
    }
}

func entity(_ name: String) -> NSEntityDescription {
    let entity = NSEntityDescription()
    entity.name = name
    entity.managedObjectClassName = name
    return entity
}
let model = NSManagedObjectModel()
let studyEntity = entity("DicomStudy"), seriesEntity = entity("DicomSeries"), imageEntity = entity("DicomImage")
model.entities = [studyEntity, seriesEntity, imageEntity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
// The driver runs on the main thread.
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

let browser = FormerBrowser()
func same(_ a: [Any]?, _ b: [Any]?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.count == b.count && zip(a, b).allSatisfy { $0 as AnyObject === $1 as AnyObject }
}

do {
    let images = (0..<3).map { _ in DicomImage(entity: imageEntity, insertInto: context) }
    let series = DicomSeries(entity: seriesEntity, insertInto: context)
    series.images = images
    let report = DicomSeries(entity: seriesEntity, insertInto: context)
    let study = DicomStudy(entity: studyEntity, insertInto: context)
    study.pictures = [series]
    study.documents = [report]
    let gone = DicomSeries(entity: seriesEntity, insertInto: context)
    gone.images = images
    try! context.save()
    context.delete(gone)
    expect(gone.isDeleted, "the deleted row is not deleted")

    let items: [(String, Any?)] = [("series", series), ("study", study), ("document series", report), ("deleted series", gone),
                                   ("image", images[0]), ("distant study", DistantNode()), ("other", Other()), ("nil", nil)]
    for (label, item) in items {
        for onlyImages in [true, false] {
            let former = browser.childrenArray(item, onlyImages: onlyImages) as [Any]?
            let now = DatabaseItemChildren.children(of: item, onlyImages: onlyImages)
            expect(same(former, now), "\(label), onlyImages \(onlyImages): \(String(describing: former)) became \(String(describing: now))")
        }
        expect(same(browser.childrenArray(item) as [Any]?, DatabaseItemChildren.children(of: item)), "\(label): the images-only default differs")
    }
    expect(same(DatabaseItemChildren.children(of: study, onlyImages: false), [series, report]), "the documents are not after the pictures")
    expect(same(DatabaseItemChildren.children(of: series), images), "the series does not give its sorted images")
}
print("PASS")
'''


def extract_former_children():
    head = subprocess.run(['git', '-C', str(ROOT), 'show', 'HEAD:' + SELECTION], capture_output=True, text=True)
    if head.returncode == 0 and OLD_MARK in head.stdout:
        text = head.stdout
    else:
        reference = history_reference.before_text_removed(SELECTION, OLD_MARK)
        if reference is None:
            return None
        text = history_reference.show(reference, SELECTION).decode('utf-8')
    start = text.index('    @discardableResult\n    @objc(childrenArray:onlyImages:)')
    end = text.index('    @discardableResult\n    @objc(imagesArray:preferredObject:onlyImages:)')
    helpers = ''.join(re.search(r'nonisolated private func ' + name + r'\(.*?\n}\n', text, re.S).group(0)
                      for name in ('send', 'isType'))
    return helpers + '\nfinal class FormerBrowser: NSObject {\n' + text[start:end] + '}\n'


def run(work, name, sources):
    binary = work / name
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *map(str, sources), '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        fail(f'{name} does not compile:\n{built.stderr[-3000:]}')
        return
    ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    if ran.returncode or 'PASS' not in ran.stdout:
        fail(f'{name}: {ran.stdout.strip()} {ran.stderr.strip()[-1500:]}')


former = extract_former_children()
with tempfile.TemporaryDirectory(prefix='isix-browser-database-source-') as directory:
    work = Path(directory)
    (work / 'doubles.swift').write_text(SOURCE_DOUBLES)
    (work / 'main.swift').write_text(SOURCE_DRIVER)
    run(work, 'source', [work / 'doubles.swift', SOURCE, work / 'main.swift'])

    children = work / 'children'
    children.mkdir()
    if former is None:
        print('skipped: the comparison of the children needs the history before they left BrowserController', file=sys.stderr)
    else:
        (children / 'doubles.swift').write_text(MODEL_DOUBLES)
        (children / 'former.swift').write_text('import CoreData\n' + former)
        (children / 'main.swift').write_text(CHILDREN_DRIVER)
        run(children, 'children', [children / 'doubles.swift', children / 'former.swift', CHILDREN, children / 'main.swift'])

if failures:
    print(f'FAIL: {len(failures)} problem(s)')
    sys.exit(1)
if former is None:
    sys.exit(SKIPPED)
print('PASS: the browser database comes from the registered source, case by case, and the children of a row are their own type')
