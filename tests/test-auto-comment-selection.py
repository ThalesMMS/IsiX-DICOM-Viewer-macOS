#!/usr/bin/env python3
""""Regenerate Auto Comments" on a selection walks each selected row once and fills each study once.

AutoCommentRegenerator.swift's selection walk and its comment pass (from the
doc comment of `selection()` to the end of the class, and the settings struct)
are compiled as they are, with doubles for the browser, the database objects
and the DICOM file, against the real IsiXDatabase (AutoCommentRule), and
driven as the menu item drives them:
- rows: an outline of eight rows with 1, 2 and 3 non-contiguous rows selected
  must give exactly those rows, in ascending order, each once. The walk took
  the first row and then asked `integerGreaterThan(0)` again for every further
  row, so a second and third row repeated one of them.
- study and series: a study selected together with one of its series, then
  two series of one study, then a study and a series of another study. Each
  study and series must be listed once, and the study's comment must be the
  one read from its first image after the pass. A study listed twice was
  filled twice: the second time the candidate is no longer than the text
  just written, AutoCommentRule answers nil, and the comment was cleared.

`<git revision>` as an optional argument reads AutoCommentRegenerator.swift
from that revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import isix_modules
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/AutoCommentRegenerator.swift'

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

text = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{PATH}']).decode()
        if revision else (root / PATH).read_text())

settings = re.search(r'^private struct AutoCommentSettings\b.*?^}\n', text, re.M | re.S)
start = re.search(r'^    ///[^\n]*\n(?:    ///[^\n]*\n)*    private func selection\(\)', text, re.M)
end = text.rstrip().rfind('\n}')
if not (settings and start and end > start.start()):
    print(f'FAIL: {PATH} has no AutoCommentSettings or selection() to compile', file=sys.stderr)
    sys.exit(1)
# The members are private to the class; the driver below, in the same file, calls them.
members = re.sub(r'\bprivate\b', 'fileprivate', text[start.start():end])

DOUBLES = r'''
import AppKit
import CoreData
import IsiXDatabase

final class BrowserController {
    var horos_databaseOutline: NSOutlineView?
}

/// The real one reads the file; here an image's path is "comment:<text>".
final class DicomFile {
    let comment: String?
    init?(_ path: String?) {
        guard let path, path.hasPrefix("comment:") else { return nil }
        comment = String(path.dropFirst("comment:".count))
    }
    func element(forKey key: String) -> Any? { key == "commentsAutoFill" ? comment : nil }
}

enum DICOMSOPClass {
    static func isImageStorage(_ uid: String?) -> Bool { true }
    static func isPDF(_ uid: String?) -> Bool { false }
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
    static func log(_ exception: NSException, _ context: String) {}
    static func log(_ exception: NSException, stack: Bool, _ context: String) {}
}

extension Thread {
    var progress: CGFloat { get { 0 } set {} }
}

@objc(DicomImage) final class DicomImage: NSObject {
    let path: String
    init(_ path: String) { self.path = path }
    func completePath() -> String? { path }
}

@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @NSManaged var name: String?
    @NSManaged var series: NSSet?
    func imageSeries() -> NSArray! {
        ((series?.allObjects as? [DicomSeries]) ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") } as NSArray
    }
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @NSManaged var name: String?
    @NSManaged var study: DicomStudy?
    @NSManaged var seriesSOPClassUID: String?
    var images: NSSet? = nil
}
'''

DRIVER = r'''
@MainActor final class AutoCommentRegenerator {
    fileprivate unowned let browser: BrowserController
    init(browser: BrowserController) { self.browser = browser }
''' + members + r'''
}

/// An outline whose rows are the items given, flat.
final class Rows: NSObject, NSOutlineViewDataSource {
    let items: [AnyObject]
    init(_ items: [AnyObject]) { self.items = items }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
}

@MainActor func outline(_ rows: Rows, selecting selected: [Int]) -> NSOutlineView {
    let view = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
    view.addTableColumn(column)
    view.outlineTableColumn = column
    view.allowsMultipleSelection = true
    view.dataSource = rows
    view.reloadData()
    view.selectRowIndexes(IndexSet(selected), byExtendingSelection: false)
    return view
}

func model() -> NSManagedObjectModel {
    func attribute(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name; a.attributeType = .stringAttributeType; a.isOptional = true; return a
    }
    let study = NSEntityDescription(), series = NSEntityDescription()
    study.name = "Study"; study.managedObjectClassName = "DicomStudy"
    series.name = "Series"; series.managedObjectClassName = "DicomSeries"
    let toSeries = NSRelationshipDescription(), toStudy = NSRelationshipDescription()
    toSeries.name = "series"; toSeries.destinationEntity = series; toSeries.minCount = 0; toSeries.maxCount = 0
    toSeries.deleteRule = .cascadeDeleteRule; toSeries.isOptional = true
    toStudy.name = "study"; toStudy.destinationEntity = study; toStudy.maxCount = 1; toStudy.isOptional = true
    toSeries.inverseRelationship = toStudy; toStudy.inverseRelationship = toSeries
    study.properties = [attribute("name"), attribute("comment"), toSeries]
    series.properties = [attribute("name"), attribute("comment"), attribute("seriesSOPClassUID"), toStudy]
    let model = NSManagedObjectModel(); model.entities = [study, series]
    return model
}

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok    " : "FAIL  ") + what)
    if !ok { failures += 1 }
}

// rows: 1, 2 and 3 non-contiguous rows of eight.
let plain = Rows((0..<8).map { "row \($0)" as NSString })
for selected in [[2], [1, 4], [0, 3, 6]] {
    let walked = AutoCommentRegenerator.rows(of: outline(plain, selecting: selected))
    check(walked == selected, "rows \(selected) walked as \(walked)")
}
check(AutoCommentRegenerator.rows(of: outline(plain, selecting: [])) == [], "no selection, no rows")

// study and series: two studies of two series each, flat in the outline.
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model())
_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

@MainActor func make(_ name: String) -> (DicomStudy, DicomSeries, DicomSeries) {
    let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
    study.name = name
    func series(_ number: Int) -> DicomSeries {
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as! DicomSeries
        series.name = "\(name) \(number)"
        series.study = study
        series.images = NSSet(object: DicomImage("comment:\(name) DESCRIPTION \(number)"))
        return series
    }
    return (study, series(1), series(2))
}
let (a, a1, a2) = make("A")
let (b, b1, _) = make("B")
try! context.save()
let flat = Rows([a, a1, a2, b, b1])
fileprivate let studyLevel = AutoCommentSettings(field: "comment", studyLevel: true, seriesLevel: false, fromImages: true)

for (selected, what, filled) in [([0, 1], "study A and its series A 1", [a]),
                                 ([1, 2], "series A 1 and A 2", [a]),
                                 ([0, 4], "study A and series B 1", [a, b])] {
    for study in [a, b] { study.setValue("by hand", forKey: "comment") }
    let browser = BrowserController()
    browser.horos_databaseOutline = outline(flat, selecting: selected)
    let subjects = AutoCommentRegenerator(browser: browser).selection()
    check(subjects.studies == filled.map(\.objectID), "\(what): studies listed once each (\(subjects.studies.count))")
    check(Set(subjects.series).count == subjects.series.count, "\(what): series listed once each (\(subjects.series.count))")
    AutoCommentRegenerator.regenerate(studies: subjects.studies, series: subjects.series, settings: studyLevel, in: context)
    for study in filled {
        let comment = study.value(forKey: "comment") as? String
        check(comment == "\(study.name!) DESCRIPTION 1", "\(what): study \(study.name!) comment \(comment ?? "nil")")
    }
    if !filled.contains(b) {
        check(b.value(forKey: "comment") as? String == "by hand", "\(what): study B untouched")
    }
}

exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-auto-comment-') as tmp:
    tmp = Path(tmp)
    flags = isix_modules.module_flags('IsiXDatabase', tmp / 'modules')
    (tmp / 'doubles.swift').write_text(DOUBLES)
    (tmp / 'main.swift').write_text('import AppKit\nimport CoreData\nimport IsiXDatabase\n\n' + settings.group(0) + DRIVER)
    binary = tmp / 'harness'
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Harness', *flags,
                            str(tmp / 'doubles.swift'), str(tmp / 'main.swift'), '-o', str(binary)],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr, file=sys.stderr)
        print(f'FAIL: {PATH} ({revision or "working tree"}) does not compile in the harness', file=sys.stderr)
        sys.exit(1)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    print(result.stdout + result.stderr, end='')
    print(('PASS' if result.returncode == 0 else 'FAIL') + f': {PATH} ({revision or "working tree"})')
    sys.exit(0 if result.returncode == 0 else 1)
