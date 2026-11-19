#!/usr/bin/env python3
"""The database window's Meta-Data opens on an image and keeps its controller.

XMLController lets itself go when its window closes (-windowWillClose:
autoreleases it), the design of the former manual reference counting, in which
the code that made it left it the +1 of its alloc. Under ARC, -viewXML: of the
database window has to hand that +1 back with Unmanaged.passRetained, as the
viewer's Meta-Data does: without it the controller went as soon as -viewXML:
returned, its window stayed on screen, and the outline, whose data source is
weak, showed nothing.

The image comes from the first selected thumbnail that has loaded: an image as
it is, a series by its first image in the series' order (no longer any image
of its unordered set). Without one, the first selected thumbnail still loading
answers, since its cell names its row before its icon loads: a refresh of the
row puts the highlighted cells back while they load, and the window has to
show what is highlighted, not the first series. Without a selected thumbnail
that names a row, the row whose thumbnails the browser shows answers, the
first selected one (not the last clicked): a series by its first image, a
study by the first image of its first series.

-viewXML:, DatabaseMetadataWindow and DatabaseRowImage
(BrowserController+DICOMObjects.swift), -firstObjectForDatabaseMatrixSelection
(BrowserController+SplitView.swift) and -selectedOutlineItem
(BrowserController+OutlineSelection.swift) run compiled with xcrun swiftc
against stand-ins: a browser with a matrix and an outline, model objects that
answer their type, and an XMLController that releases itself in its
-windowWillClose: and counts its deinits. Each case runs -viewXML: in an
autorelease pool, then closes the window in another; the controller must
outlive the first pool and go once in the second. The stand-in series answers,
for its unordered set, every image but its first in order, so a choice made
from the set shows. `<git revision>` as an optional argument reads the sources
of that revision, the negative control.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
OBJECTS = 'Horos/Sources/BrowserController+DICOMObjects.swift'
SPLIT = 'Horos/Sources/BrowserController+SplitView.swift'
SELECTION = 'Horos/Sources/BrowserController+OutlineSelection.swift'
failures = []


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else ''
    return (root / path).read_text(encoding='utf-8')


def block(source, signature, end):
    """The text from the line of `signature` to the first `end` after it, or None."""
    start = source.find(signature)
    if start < 0:
        return None
    start = source.rfind('\n', 0, start) + 1
    stop = source.find(end, start)
    return source[start:stop + len(end)] if stop >= 0 else None


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

objects = read(OBJECTS)
split = read(SPLIT)
view_xml = block(objects, '    @objc(viewXML:)\n', '\n    }\n')
first_object = block(split, '    @objc(firstObjectForDatabaseMatrixSelection)\n', '\n    }\n')
selected_item = block(read(SELECTION), '    func selectedOutlineItem() -> Any? {\n', '\n    }\n')
# The types -viewXML: opens the window with; a revision without them does without.
helpers = ''.join(block(objects, f'enum {name} {{', '\n}\n') or '' for name in ('DatabaseMetadataWindow', 'DatabaseRowImage'))
if view_xml is None or first_object is None or selected_item is None:
    print(f'FAIL: -viewXML: in {OBJECTS}, -firstObjectForDatabaseMatrixSelection in {SPLIT} or '
          f'-selectedOutlineItem in {SELECTION} is no longer where this test reads it; this test needs a new look')
    sys.exit(1)

STAND_INS = r'''
import Foundation

// No CoreData here: the model objects are plain objects that answer their
// type by key, as the database's do.
class NSManagedObject: NSObject {}

final class DicomImage: NSManagedObject {
    let name: String
    init(_ name: String) { self.name = name }
    @objc var type: String { "Image" }
    @objc func completePath() -> String! { "/database/\(name).dcm" }
}

final class DicomSeries: NSManagedObject {
    let sorted: [DicomImage]
    init(_ sorted: [DicomImage]) { self.sorted = sorted }
    @objc var type: String { "Series" }
    // Every image but the first in order: any of them comes before the first.
    @objc var images: NSSet { NSSet(array: Array(sorted.dropFirst())) }
    func sortedImages() -> [Any]! { sorted }
}

final class DicomStudy: NSManagedObject {
    let series: [DicomSeries]
    init(_ series: [DicomSeries]) { self.series = series }
    @objc var type: String { "Study" }
}

/// The database's children: the series of a study in the order of its
/// thumbnails, the sorted images of a series.
enum DatabaseItemChildren {
    static func children(of item: Any?, onlyImages: Bool = true) -> [Any]? {
        if let series = item as? DicomSeries { return series.sortedImages() }
        if let study = item as? DicomStudy { return study.series }
        return nil
    }
}

final class ViewerController: NSObject {}

/// A thumbnail: enabled once its icon has loaded. Its row, as its tag names
/// it, is there from the start; nil for a cell that names none.
final class Cell: NSObject {
    let row: Any?
    var isEnabled: Bool
    init(_ row: Any?, loaded: Bool) { self.row = row; self.isEnabled = loaded }
}

final class Matrix { var selectedCells: [Cell] = [] }

/// The list: `clicked` its selected rows in the order they were clicked.
/// selectedRow is the last one clicked, as NSTableView's.
final class Outline {
    var rows: [Any] = []
    var clicked: [Int] = []
    var selectedRow: Int { clicked.last ?? -1 }
    var selectedRowIndexes: IndexSet { IndexSet(clicked) }
    func item(atRow row: Int) -> Any? { rows.indices.contains(row) ? rows[row] : nil }
}

enum ViewerOpener {
    static func thumbnailRow(_ cell: Cell, of rows: [Any]?) -> Any? { cell.row }
}

var made = 0, shown = 0, released = 0
var shownImage: DicomImage?
weak var lastController: XMLController?

/// The meta-data controller: nil without an image, and released by its own
/// -windowWillClose:, as the real one is.
final class XMLController: NSObject {
    init?(image: DicomImage!, windowName name: String!, viewer v: ViewerController!) {
        guard let image else { return nil }
        super.init()
        made += 1
        shownImage = image
        lastController = self
    }
    func showWindow(_ sender: Any?) { shown += 1 }
    func windowWillClose() { _ = Unmanaged.passUnretained(self).autorelease() }
    deinit { released += 1 }
}

@MainActor final class BrowserController: NSObject {
    var horos_oMatrix: Matrix? = Matrix()
    var horos_databaseOutline: Outline? = Outline()
    var horos_matrixViewArray: [Any]? = []
}
'''

DRIVER = r'''
var problems: [String] = []
var cases = 0

/// -viewXML: with `rows` in the outline, `selected` its selected rows in the
/// order they were clicked, and `cells` the selected thumbnails; `expected`
/// the image the window must show, nil for no window.
@MainActor func check(_ what: String, rows: [Any], selected: [Int], cells: [Cell], expected: DicomImage?) {
    cases += 1
    made = 0; shown = 0; released = 0; shownImage = nil; lastController = nil
    let browser = BrowserController()
    browser.horos_databaseOutline?.rows = rows
    browser.horos_databaseOutline?.clicked = selected
    browser.horos_oMatrix?.selectedCells = cells
    autoreleasepool { browser.viewXML(nil) }

    guard let expected else {
        if made != 0 || shown != 0 { problems.append("\(what): a window opened") }
        return
    }
    guard made == 1, shown == 1 else {
        problems.append("\(what): \(made) controllers made, \(shown) windows shown, not one")
        return
    }
    if shownImage !== expected {
        problems.append("\(what): the window shows \(shownImage?.name ?? "nothing"), not \(expected.name)")
    }
    guard lastController != nil, released == 0 else {
        problems.append("\(what): the controller was released when -viewXML: returned, its window left empty")
        return
    }
    // No strong reference of this function's: the pool's is the last one.
    autoreleasepool { lastController?.windowWillClose() }
    if released != 1 {
        problems.append("\(what): closing the window released the controller \(released) times, not once")
    }
}

@MainActor func run() -> Int32 {
    let ct1 = DicomImage("ct-1"), ct2 = DicomImage("ct-2"), ct3 = DicomImage("ct-3")
    let pet1 = DicomImage("pet-1"), pet2 = DicomImage("pet-2")
    let ct = DicomSeries([ct1, ct2, ct3]), pet = DicomSeries([pet1, pet2])
    let study = DicomStudy([ct, pet]), empty = DicomStudy([])
    let mri1 = DicomImage("mri-1")
    let other = DicomStudy([DicomSeries([mri1])])

    check("a study with an image thumbnail selected", rows: [study], selected: [0],
          cells: [Cell(ct2, loaded: true)], expected: ct2)
    check("a study with a series thumbnail selected", rows: [study], selected: [0],
          cells: [Cell(pet, loaded: true)], expected: pet1)
    check("a loaded series thumbnail after one still loading", rows: [study], selected: [0],
          cells: [Cell(ct, loaded: false), Cell(pet, loaded: true)], expected: pet1)
    check("a study just selected, its first thumbnail still loading", rows: [study], selected: [0],
          cells: [Cell(ct, loaded: false)], expected: ct1)
    check("a refreshed study whose highlighted series is still loading", rows: [study], selected: [0],
          cells: [Cell(pet, loaded: false)], expected: pet1)
    check("a refreshed series row whose highlighted image is still loading", rows: [study, pet], selected: [1],
          cells: [Cell(pet2, loaded: false)], expected: pet2)
    check("a selected cell that names no row", rows: [study], selected: [0],
          cells: [Cell(nil, loaded: false)], expected: ct1)
    check("a study with no thumbnail selected", rows: [study], selected: [0], cells: [], expected: ct1)
    check("two studies selected, the second one last", rows: [study, other], selected: [0, 1],
          cells: [], expected: ct1)
    check("a study without series", rows: [empty], selected: [0], cells: [], expected: nil)
    check("no row selected", rows: [study], selected: [], cells: [Cell(ct1, loaded: true)], expected: nil)

    for problem in problems { print("FAIL: \(problem)") }
    if problems.isEmpty { print("ok (\(cases) cases)") }
    return problems.isEmpty ? 0 : 1
}
exit(MainActor.assumeIsolated { run() })
'''

swift = (STAND_INS + '\nextension BrowserController {\n' + first_object + '\n' + selected_item + '\n' + view_xml + '}\n\n'
         + helpers + '\n' + DRIVER)

with tempfile.TemporaryDirectory(prefix='horos-metadata-window-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(swift)
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(work / 'main.swift'), '-o', str(work / 'run')],
                              capture_output=True, text=True)
    if compiled.returncode:
        print(compiled.stderr.strip()[-2000:])
        failures.append('-viewXML: and its helpers did not compile in the stand-in')
    else:
        ran = subprocess.run([str(work / 'run')], capture_output=True, text=True, timeout=60)
        output = (ran.stdout + ran.stderr).strip()
        print(output[-3000:])
        if ran.returncode:
            failures.append('the Meta-Data of the database window does not open as it should')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
