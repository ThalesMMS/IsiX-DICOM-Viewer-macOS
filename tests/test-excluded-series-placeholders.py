#!/usr/bin/env python3
"""Series a DICOMweb node's rules leave out are placeholders, not a notice.

ExcludedSeriesPlaceholders.swift is compiled with the real RetrievePlan.swift
and stand-ins for the node lookup, and run against a temporary database
folder:

- what one node left out replaces what it left out before, and keeps what
  another node left out; a series kept keeps its picture;
- the placeholders come in series number order, without the series already in
  the database, those of a node no longer in Locations, and those its rules no
  longer leave out; nor those whose middle instance is in the database, as the
  study's localizers gathered into one series are;
- a file written before the optional fields existed is read, and one with all
  of them comes back the same;
- a picture that is not an image is not kept; one that is is kept beside the
  study's file, and forgetting the study removes both;
- the title is name, date (the study's when the series has none), images and
  "Click to retrieve"; the picture has the size asked for, with or without the
  node's.

The sources are checked for the rest: no notice for a left-out series or for
one retrieved by itself; the viewer and the browser show placeholders after
the series and outside the arrays every other use reads; a study deleted
forgets them; a DICOMweb study retrieve records them, with the series' date,
time and modality, now asked for by its listing.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / 'Horos/Sources/ExcludedSeriesPlaceholders.swift', root / 'Horos/Sources/RetrievePlan.swift']

STUBS = r'''
import AppKit
final class DICOMwebNode {
    let excludedSeries: [String]
    init(_ rules: [String]) { excludedSeries = rules }
    nonisolated(unsafe) static var nodes: [String: DICOMwebNode] = [:]
    static func node(withIdentifier identifier: String, in defaults: UserDefaults) -> DICOMwebNode? { nodes[identifier] }
}
enum DICOMwebSources {
    static func server(for node: DICOMwebNode) -> [String: Any] { ["DICOMwebNode": "stub"] }
}
extension UserDefaults {
    @objc class func formatDateTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
'''

DRIVER = r'''
import AppKit
var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL line \(line): \(what)"); failures += 1 } }
let database = CommandLine.arguments[1]
let study = "1.2.3"
func uids(_ list: [ExcludedSeries]) -> [String] { list.map(\.seriesInstanceUID) }

DICOMwebNode.nodes = ["A": DICOMwebNode(["scout", "dose"]), "B": DICOMwebNode(["localizer"])]
ExcludedSeries.record(study: study, node: "A", database: database, series: [
    ["series": "s.dose", "description": "Dose Report", "rule": "dose", "number": NSNumber(value: 999), "instances": NSNumber(value: 1),
     "date": "20260102", "time": "101500", "modality": "SR", "middleInstance": "i.d"],
    ["series": "s.scout", "description": "Scout", "rule": "scout", "number": NSNumber(value: 1), "instances": NSNumber(value: 3)],
    ["series": "", "description": "no uid"],
])
ExcludedSeries.record(study: study, node: "B", database: database, series: [
    ["series": "s.loc", "description": "Localizer", "rule": "localizer", "number": NSNumber(value: 2)],
])
var shown = ExcludedSeries.placeholders(study: study, database: database, localSeries: [])
check(uids(shown) == ["s.scout", "s.loc", "s.dose"], "number order: \(uids(shown))")
check(uids(ExcludedSeries.placeholders(study: study, database: database, localSeries: ["s.scout"])) == ["s.loc", "s.dose"], "a local series is not a placeholder")
DICOMwebNode.nodes["B"] = nil
check(uids(ExcludedSeries.placeholders(study: study, database: database, localSeries: [])) == ["s.scout", "s.dose"], "a node no longer there")
DICOMwebNode.nodes["A"] = DICOMwebNode(["scout"])
check(uids(ExcludedSeries.placeholders(study: study, database: database, localSeries: [])) == ["s.scout"], "a rule that no longer leaves it out")
DICOMwebNode.nodes = ["A": DICOMwebNode(["scout", "dose"]), "B": DICOMwebNode(["localizer"])]
check(ExcludedSeries.placeholders(study: "other", database: database, localSeries: []).isEmpty, "another study")
// A series gathered into another (the study's localizers) is known by its middle instance.
var asked: Set<String> = []
let left = ExcludedSeries.withoutLocalInstances(ExcludedSeries.placeholders(study: study, database: database, localSeries: [])) { asked = $0; return ["i.d"] }
check(uids(left) == ["s.scout", "s.loc"] && asked == ["i.d"], "a placeholder whose middle instance is here: \(uids(left)) \(asked)")
check(uids(ExcludedSeries.withoutLocalInstances(left) { _ in fatalError("nothing to ask") }) == ["s.scout", "s.loc"], "no middle instance, nothing asked")

// Pictures.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let png = rep.representation(using: .png, properties: [:])!
ExcludedSeries.setThumbnail(Data("not an image".utf8), series: "s.scout", study: study, database: database)
check(ExcludedSeries.seriesWithoutThumbnail(study: study, node: "A", database: database).count == 2, "not an image: not kept")
ExcludedSeries.setThumbnail(png, series: "s.scout", study: study, database: database)
let missing = ExcludedSeries.seriesWithoutThumbnail(study: study, node: "A", database: database)
check(uids(missing) == ["s.dose"] && missing.first?.middleInstance == "i.d", "picture kept: \(uids(missing))")
let folder = ExcludedSeries.folder(database: database)
let pictures = { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".thumbnail") } ?? [] }
check(pictures().count == 1, "picture file")

// A new retrieve from A that leaves out only the scout: the dose goes, the scout keeps its picture, B's stays.
ExcludedSeries.record(study: study, node: "A", database: database, series: [["series": "s.scout", "description": "Scout", "rule": "scout", "number": NSNumber(value: 1)]])
shown = ExcludedSeries.placeholders(study: study, database: database, localSeries: [])
check(uids(shown) == ["s.scout", "s.loc"], "replaced: \(uids(shown))")
check(shown.first?.record.thumbnail != nil && pictures().count == 1, "the kept series keeps its picture")
ExcludedSeries.record(study: study, node: "A", database: database, series: [])
check(uids(ExcludedSeries.placeholders(study: study, database: database, localSeries: [])) == ["s.loc"] && pictures().isEmpty, "nothing left out by A")

// Titles and pictures.
let dose = ExcludedSeries(study: study, database: database, record: .init(series: "s", node: "A", description: "Dose Report", rule: "dose",
                          number: 999, instances: 12, date: "20260102", time: "101500", modality: "SR"))
check(dose.title(studyDate: nil) == "Dose Report\r2026-01-02 10:15\r12 Images\rClick to retrieve", dose.title(studyDate: nil))
let bare = ExcludedSeries(study: study, database: database, record: .init(series: "s", node: "A", description: "", rule: "x"))
let studyDate = ExcludedSeries.date("20251231", "0800")!
check(bare.title(studyDate: studyDate) == "Unnamed\r2025-12-31 08:00\r\rClick to retrieve", bare.title(studyDate: studyDate))
check(bare.image(size: NSSize(width: 64, height: 48)).size == NSSize(width: 64, height: 48), "grey frame size")
ExcludedSeries.setThumbnail(png, series: "s.loc", study: study, database: database)
let loc = ExcludedSeries.placeholders(study: study, database: database, localSeries: []).first!
check(loc.image(size: NSSize(width: 70, height: 70)).tiffRepresentation != nil, "the node's picture, greyed")

// Files of other versions of the app.
let old = #"{"version":1,"study":"9.9","series":[{"series":"s1","node":"A","description":"Scout","rule":"scout"}]}"#
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try! Data(old.utf8).write(to: ExcludedSeries.file(study: "9.9", database: database))
check(uids(ExcludedSeries.placeholders(study: "9.9", database: database, localSeries: [])) == ["s1"], "a file without the optional fields")
let full = ExcludedSeries.File(study: "9.9", series: [dose.record])
let decoded = try! JSONDecoder().decode(ExcludedSeries.File.self, from: JSONEncoder().encode(full))
check(decoded.series == full.series && decoded.study == "9.9", "round trip with every field")

ExcludedSeries.forget(study: study, database: database)
check(!FileManager.default.fileExists(atPath: ExcludedSeries.file(study: study, database: database).path) && pictures().isEmpty, "forgotten")
check(FileManager.default.fileExists(atPath: ExcludedSeries.file(study: "9.9", database: database).path), "another study kept")

if failures > 0 { exit(1) }
print("PASS: store")
'''

with tempfile.TemporaryDirectory(prefix='horos-excluded-series-') as folder:
    p = Path(folder)
    (p / 'stubs.swift').write_text(STUBS)
    (p / 'main.swift').write_text(DRIVER)
    (p / 'db').mkdir()
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', *map(str, sources), str(p / 'stubs.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'store')], check=True)
    result = subprocess.run([str(p / 'store'), str(p / 'db')], capture_output=True, text=True)
    sys.stdout.write(result.stdout + result.stderr)
    if result.returncode != 0:
        sys.exit('FAIL: the store driver failed')

# The query node is Swift, split by responsibility into DCMTKQueryNode+*.swift;
# its query identifiers come from IsiXDICOMNetwork.
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402
node = class_text('DCMTKQueryNode')


def method(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start)]


for signature in ('func noteExcludedSeries(_ excluded: [String: [String]], everything: Bool)',
                  'func noteExplicitRetrieveOfSeriesExcluded(byRule rule: String)'):
    body = method(node, signature)
    assert 'errorMessage' not in body and 'postNotice' not in body and 'NSLog' in body \
        and 'Thread.current.status = text' in body, signature
retrieve = method(node, 'func retrieveDICOMweb() -> Bool')
assert 'recordPlaceholdersOfExcludedSeries(excluded' in retrieve, 'a DICOMweb study retrieve records its placeholders'
record = method(node, 'func recordPlaceholdersOfExcludedSeries(')
assert 'ExcludedSeries.record(study: study, node: identifier' in record and 'client.previewImage(study: study' in record
assert 'NodeRequestLimiter.shared.acquire(node: limiterNode' in record and 'NodeRequestLimiter.shared.release(node: limiterNode)' in record, \
    'pictures take a slot of the node'
identifiers = (root / 'Modules/IsiXDICOMNetwork/Sources/QueryIdentifier.swift').read_text()
listing = identifiers[identifiers.index('public static func seriesListing('):]
listing = listing[:listing.index('return identifier')]
assert 'QueryIdentifiers.seriesListing(study: studyInstanceUID)' in method(node, 'func queryImagesHierarchically(')
for tag in ('.seriesDate', '.seriesTime', '.modality'):
    assert tag in listing, tag
click = method(node, 'class func retrieveExcludedSeries(_ object: Any?)')
assert 'DCMTKSeriesQueryNode(dataset: identifier.dataset()' in click and 'QueryController.retrieveStudies([series]' in click
assert 'series.lastRetrieveIncomplete' in click and 'not retrieved. Click its thumbnail to try again.' in click \
    and 'errorMessage' not in click and 'postNotice' not in click, 'a click that brought nothing says so in its Activity row'
viewer = (((root / 'Horos/Sources/ViewerController.m').read_text()) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
if '- (void) buildMatrixPreview: (BOOL) showSelected' in viewer:
    build = viewer[viewer.index('- (void) buildMatrixPreview: (BOOL) showSelected'):]
    build = build[:build.index('\n}\n')]
    assert '[BrowserController horosExcludedSeriesOfLocalStudy: s database:' in build, 'the viewer leaves out placeholders whose middle instance is here'
    assert 'i += excluded.count;' in build and '[seriesArray addObject: [[BrowserController currentBrowser] childrenArray: s]];' in build
    assert 'matrixPreviewRetrieveExcludedSeries:' in build and 'O2ViewerThumbnailsMatrixRepresentedObject object: excluded' in build
else:
    # The series list is Swift: ViewerController+SeriesThumbnails.swift builds it,
    # with the studies and series of ViewerController+SeriesPopup.swift.
    build = (root / 'Horos/Sources/ViewerController+SeriesThumbnails.swift').read_text()
    build = build[build.index('func buildMatrixPreview(_ showSelected: Bool)'):build.index('func matrixPreviewSelectCurrentSeries()')]
    studies = (root / 'Horos/Sources/ViewerController+SeriesPopup.swift').read_text()
    assert 'BrowserController.horosExcludedSeries(ofLocalStudy: s, database:' in build, 'the viewer leaves out placeholders whose middle instance is here'
    assert 'i += excluded.count' in build and 'viewerArrayAdd(BrowserController.currentBrowser()?.childrenArray(local), to: seriesArray)' in studies
    assert 'matrixPreviewRetrieveExcludedSeries(_:)' in build and 'O2ViewerThumbnailsMatrixRepresentedObject.object(excluded)' in build
thumbnails = (root / 'Horos/Sources/O2ViewerThumbnailsMatrix.swift').read_text()
assert 'O2ViewerThumbnailsMatrixRepresentedObject)?.object is DicomSeries' in thumbnails, 'only a series is dragged'

browser = (root / 'Horos/Sources/BrowserController+ExcludedSeries.swift').read_text()
assert 'ExcludedSeries.withoutLocalInstances(pending)' in browser and 'compressedSopInstanceUID IN %@' in browser
assert 'static let firstTag = -1000' in browser and 'cell.tag = ExcludedSeriesCells.firstTag - k' in browser
preview = (root / 'Horos/Sources/BrowserController+Preview.swift').read_text()
assert 'let cellCount = (horos_matrixViewArray?.count ?? 0) + horosExcludedSeries.count' in preview
selection = (root / 'Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift').read_text()
assert 'cell.tag >= 0 && cell.tag < (matrixViewArray?.count ?? 0)' in selection, 'the matrix selection reads series by tag'
# Deleting a study and showing a selection's thumbnails are Swift:
# BrowserController+Deletion.swift and BrowserController+OutlineSelection.swift.
deletion = (root / 'Horos/Sources/BrowserController+Deletion.swift').read_text()
selection = (root / 'Horos/Sources/BrowserController+OutlineSelection.swift').read_text()
assert 'ExcludedSeries.forget(study: uid, database: folder)' in deletion
assert 'self.horosPrepareExcludedSeries(of: item)' in selection
print('PASS: no notice; placeholders after the series, outside the arrays other uses read; recorded, pictured, forgotten')
