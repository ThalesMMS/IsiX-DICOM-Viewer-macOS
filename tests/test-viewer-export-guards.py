#!/usr/bin/env python3
"""The 2D viewer's export and print blocks guard their intervals, divisors and paths.

The blocks are Swift (the image and DICOM export of the viewer,
ViewerImageExporter.swift, with the range it walks, ViewerExportRange.swift of
IsiXImaging, and the print and the movie of the viewer, ViewerPrintJob.swift
and ViewerMovieExport.swift, with their plans). The pieces that carry each guard are
copied out of the methods as they stand and compiled with swiftc inside Swift
doubles of the viewer:

- an interval of 0 in the DICOM export and in the print (endpoints and page
  count) ended in a loop that never moved; it now takes every image;
- a DICOM export with "From" after "To" left out both ends (5...1 took
  images 2 to 4, 2...1 none); it now swaps them as the print and the movie do;
- -exportAllImages: added the empty dictionary of a failed write, whose missing
  file reached the database as an NSNull among the paths; the export keeps
  only the files written;
- -exportQuicktimeSetNumber: and -imageForFrame:maxFrame: divided by an interval
  of 0 and by maxFrame - 1 of 0 (cDiv here counts every zero divisor); now
  the movie takes From, From + interval, ... and 1...9 by 2 counts the 5
  images it takes (tests/test-viewer-export-count.py);
- -endExportImage: (endImageSheet) ignored a failed JPEG or TIFF write when a
  file was already at the path (a read-only folder here), and added EXIF to the
  old file;
- -exportTextFieldDidChange: (exportFieldDidChange) bounded the "From", "To" and interval fields
  of the DICOM and QuickTime sheets only by the maximum of their sliders, so 0
  and negative values passed. It runs here on real NSTextFields and NSSliders
  with the bounds of Viewer.xib, and the helper it shares with the orthogonal
  viewers (OrthogonalFusionSliceExport.exportFieldValue) is copied from its
  source.

What only a live viewer shows is read from the source: -endPrint: puts the
window constraint back, -exportCroppedSeries: no longer leaks its Wait window,
and SeriesView hands each DCMView the viewer's file list itself, not a copy
(the helper that does it is compiled against a double of DCMView).

--export-source, --range-source, --print-source, --movie-source, --retrieve-source,
--series-source and --fusion-source take other sources of those files.
"""
import argparse
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path

import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from sources import source_path

parser = argparse.ArgumentParser()
parser.add_argument('--export-source', type=Path, default=source_path('ViewerImageExporter'))
parser.add_argument('--range-source', type=Path,
                    default=source_path('ViewerImageExporter').parents[2] / 'Modules/IsiXImaging/Sources/ViewerExport/ViewerExportRange.swift')
parser.add_argument('--print-source', type=Path, default=source_path('ViewerPrintJob'))
parser.add_argument('--movie-source', type=Path, default=source_path('ViewerMovieExport'))
parser.add_argument('--retrieve-source', type=Path, default=source_path('ViewerController+RetrieveAndView'))
parser.add_argument('--series-source', type=Path, default=source_path('SeriesView'))
parser.add_argument('--fusion-source', type=Path, default=source_path('OrthogonalFusionSliceExport'))
args = parser.parse_args()
export = args.export_source.read_text(encoding='utf-8')
export_range = args.range_source.read_text(encoding='utf-8')
printing = args.print_source.read_text(encoding='utf-8')
movie = args.movie_source.read_text(encoding='utf-8')
retrieve = args.retrieve_source.read_text(encoding='utf-8')
series = args.series_source.read_text(encoding='utf-8')
fusion = args.fusion_source.read_text(encoding='utf-8')

failures = []


def check(condition, what):
    if not condition:
        failures.append(what)


def method(source, selector):
    start = source.index(f'    @objc({selector})')
    end = source.index('    @objc(', start + len(selector) + 10)
    return source[start:end]


def between(text, first, last, start=0):
    a = text.index(first, start)
    return text[a:text.index(last, a)]


def statement(text, first, last):
    """From the line holding `first` to the end of the next line holding `last`."""
    a = text.rindex('\n', 0, text.index(first)) + 1
    b = text.index('\n', text.index(last, a))
    return text[a:b]


DOUBLES = r'''
import AppKit
var zeroDivisions = 0
func cDiv(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { zeroDivisions += 1; return 0 }
    return a.dividedReportingOverflow(by: b).partialValue
}
func cRem(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { zeroDivisions += 1; return a }
    return a.remainderReportingOverflow(dividingBy: b).partialValue
}
func cAbs(_ a: Int32) -> Int32 { return a < 0 ? 0 &- a : a }
func objcBoolValue(_ object: Any?) -> Bool { return (object as? NSNumber)?.boolValue ?? false }
var failed = false
func check(_ condition: Bool, _ what: String) { if !condition { print("failed: " + what); failed = true } }
final class Field: NSObject {
    var intValue: Int32 = 0
    var stringValue: String? = nil
    init(_ v: Int32) { intValue = v }
}
// Every sender of -selectedCell and -tag of the loops counts: a loop that never
// moves asks forever, and the double ends it.
var cellQueries = 0
final class Cell: NSObject {
    let value: Int
    init(_ v: Int) { value = v }
    var tag: Int { cellQueries += 1; if cellQueries > 100_000 { print("failed: a loop never ends"); exit(1) }; return value }
}
final class Matrix: NSObject {
    let cell: Cell
    init(_ tag: Int) { cell = Cell(tag) }
    func selectedCell() -> Cell? { return cell }
}
final class Layout: NSObject { var selectedItem: Cell? = Cell(4) }
final class ImageView: NSObject { var curImage = 0; var flippedData = false }
func steps(_ from: Int32, _ to: Int32, _ interval: Int32) -> Int {
    var n = 0, i = from
    while i < to { n += 1; if n > 10_000 { return -1 }; i = i &+ interval }
    return n
}
'''

# ---------------------------------------------------------------- export
def member(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start) + 7]


dicom = member(export, '    func endDICOMSheet(')
dicomRange = between(dicom, '                var range = ViewerExportRange(first:', '\n                let keysAndROIs')
check('for i in range.indices {' in dicom, 'the DICOM export loop no longer walks its range')
exportAll = statement(member(export, '    func exportAllImages('), 'let s = viewer.exportDICOMFileInt(', 'producedFiles.append(')
writtenFile = member(export, '    private static func writtenFile(')
image = member(export, '    func endImageSheet(')
imageWrite = between(image, '            } else if formatTag == ViewerImageFormat.jpeg.rawValue {',
                     '\n        }\n\n        // Rendering each export frame')
imageEnd = between(image, '        if formatTag == ViewerImageFormat.jpeg.rawValue || formatTag == ViewerImageFormat.tiff.rawValue {',
                   '\n    }\n')
imageFormats = between(export, 'enum ViewerImageFormat: Int {', '\n}\n') + '\n}\n'

export_program = DOUBLES + export_range + imageFormats + r'''
enum ImageExportPath {
    static func path(selection: String, index: Int, fileExtension: String) -> String {
        return ((selection as NSString).deletingPathExtension as NSString).appendingPathExtension(String(format: "%4.4d.%@", index, fileExtension))!
    }
}
var exifAdded = 0, alerts = 0
enum JPEGExif { static func addExif(_ url: URL, properties: [AnyHashable: Any], format: String) { exifAdded += 1 } }
enum HorosAlertPanel {
    @discardableResult static func run(title: String, message: String, defaultButton: String, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
enum SeriesExportSettings { enum Format: Int32 { case memory = 0, screenCapture = 1, screenCapture16Bit = 2 } }
enum ReconstructionPreferences { static let opensViewer = "OPENVIEWER" }
/// The preferences: the file written is not opened.
struct Preferences { subscript(_ key: String) -> Bool { false } }
final class Panel: NSObject { var url: URL? }
final class Viewer: NSObject {
    var viewer: Viewer { self }
    let preferences = Preferences()
    var horos_dcmFrom: Field?, horos_dcmTo: Field?, horos_dcmInterval: Field?, horos_dcmSelection: Matrix?
    var horos_dcmSeriesName: Field? = Field(0)
    var horos_curMovieIndex: Int16 = 0
    var results: [[AnyHashable: Any]] = []
    func horos_pixList(at index: Int) -> NSArray? { return NSArray(array: Array(repeating: 0, count: 9)) }
    func horos_fileList(at index: Int) -> NSArray? { return nil }
    func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!, allViewers: Bool) -> [AnyHashable: Any]! {
        return results.removeFirst()
    }
    static func exifProperties(_ image: Any?) -> [AnyHashable: Any] { return [:] }
    static func jpegProperties() -> [NSBitmapImageRep.PropertyKey: Any] { return [:] }
''' + writtenFile + r'''
    func range() -> (Int32, Int32, Int32) {
''' + dicomRange + r'''
        return (range.from, range.to, range.interval)
    }
    func exportAll(_ producedFiles: inout [String]) {
''' + exportAll + r'''
    }
    func write(format: Int, count: Int32, to url: URL, image im: NSImage?) -> Bool {
        let formatTag = format
        let numberOfExportedImages = Int(count)
        let panel = Panel(); panel.url = url
        var fileIndex: Int32 = 1
        var fileExportFailed = false
        var bitmapData: Data?
        let firstImage = { nil as Any? }
        let representations: [NSImageRep] = im?.representations ?? []
        if false {
''' + imageWrite + r'''
''' + imageEnd + r'''
        _ = (fileIndex, bitmapData, firstImage)
        return fileExportFailed
    }
}
let viewer = Viewer()
viewer.horos_dcmSelection = Matrix(1)
for (from, to, interval, expected) in [(1, 5, 0, 5), (1, 5, -2, 5), (1, 9, 2, 5), (5, 1, 1, 5), (2, 1, 1, 2), (3, 3, 1, 1)] as [(Int32, Int32, Int32, Int)] {
    viewer.horos_dcmFrom = Field(from); viewer.horos_dcmTo = Field(to); viewer.horos_dcmInterval = Field(interval)
    let (f, t, i) = viewer.range()
    check(i >= 1 && steps(f, t, i) == expected, "DICOM export of \(from)...\(to) by \(interval) takes \(expected) images")
    check(cDiv(t &- f, i) > 0, "the DICOM export's progress has a maximum")
}
var produced: [String] = []
viewer.results = [["file": "/a.dcm"], [:], ["file": "/b.dcm"]]
for _ in 0..<3 { viewer.exportAll(&produced) }
check(produced == ["/a.dcm", "/b.dcm"], "a failed write leaves no hole among the exported paths: \(produced)")

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let picture = NSImage(size: NSSize(width: 4, height: 4)); picture.addRepresentation(rep)
for (format, ext) in [(0, "jpg"), (1, "tif")] {
    let writable = root.appendingPathComponent("writable-\(ext)")
    try! FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
    alerts = 0; exifAdded = 0
    let ok = viewer.write(format: format, count: 1, to: writable.appendingPathComponent("image.\(ext)"), image: picture)
    check(!ok && alerts == 0 && exifAdded == (format == 0 ? 1 : 0), "a written .\(ext) raises no alert")

    let locked = root.appendingPathComponent("locked-\(ext)")
    try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let old = locked.appendingPathComponent("image.\(ext)")
    try! Data("earlier file".utf8).write(to: old)
    try! FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: old.path)
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    alerts = 0; exifAdded = 0
    _ = viewer.write(format: format, count: 1, to: old, image: picture)
    check(alerts == 1, "a failed .\(ext) write over an earlier file raises the export alert")
    check(exifAdded == 0, "no EXIF goes to the earlier file of a failed .\(ext) write")
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
}
if failed { exit(1) }
print("PASS: export intervals, paths and write results")
'''

# ---------------------------------------------------------------- fields of the sheets
changed = member(export, '    static func exportFieldDidChange(') + member(export, '    private static func boundExportField(')
field_value = fusion[fusion.index('    @objc(exportFieldValue:minValue:maxValue:)'):]
field_value = field_value[field_value.index('\n') + 1:]
field_value = field_value[:field_value.index('\n    }\n') + 7].replace('public static func', 'static func')

fields_program = r"""
import AppKit
var failed = false
func check(_ condition: Bool, _ what: String) { if !condition { print("failed: " + what); failed = true } }
enum OrthogonalFusionSliceExport {
""" + field_value + r"""
}
func slider(_ max: Double) -> NSSlider? {
    let s = NSSlider(); s.minValue = 1; s.maxValue = max; s.doubleValue = 1; return s
}
typealias ViewerController = Viewer
final class Viewer: NSObject {
    let horos_dcmIntervalText: NSTextField? = NSTextField(), horos_dcmFromText: NSTextField? = NSTextField(), horos_dcmToText: NSTextField? = NSTextField()
    let horos_quicktimeIntervalText: NSTextField? = NSTextField(), horos_quicktimeFromText: NSTextField? = NSTextField(), horos_quicktimeToText: NSTextField? = NSTextField()
    // The bounds of the sliders in Viewer.xib.
    let horos_dcmInterval = slider(50), horos_dcmFrom = slider(90), horos_dcmTo = slider(90)
    let horos_quicktimeInterval = slider(50), horos_quicktimeFrom = slider(90), horos_quicktimeTo = slider(90)
}
enum ViewerImageExporter {
""" + changed + r"""
}
let viewer = Viewer()
let pairs: [(String, NSTextField?, NSSlider?)] = [
    ("DICOM interval", viewer.horos_dcmIntervalText, viewer.horos_dcmInterval),
    ("DICOM From", viewer.horos_dcmFromText, viewer.horos_dcmFrom),
    ("DICOM To", viewer.horos_dcmToText, viewer.horos_dcmTo),
    ("QuickTime interval", viewer.horos_quicktimeIntervalText, viewer.horos_quicktimeInterval),
    ("QuickTime From", viewer.horos_quicktimeFromText, viewer.horos_quicktimeFrom),
    ("QuickTime To", viewer.horos_quicktimeToText, viewer.horos_quicktimeTo),
]
func type(_ text: String, in field: NSTextField) {
    field.stringValue = text
    ViewerImageExporter.exportFieldDidChange(Notification(name: NSControl.textDidChangeNotification, object: field), of: viewer)
}
for (name, field, slider) in pairs {
    guard let field = field, let slider = slider else { continue }
    let max = Int32(slider.maxValue)
    for (typed, kept) in [("0", "1"), ("-5", "1"), ("-2147483648", "1"), ("1", "1"), ("7", "7"),
                          (String(max), String(max)), (String(max + 1), String(max)), ("2147483647", String(max))] {
        type(typed, in: field)
        check(field.stringValue == kept && slider.intValue == Int32(kept)!,
              "\(name) \(typed) keeps \(kept), not \(field.stringValue) (slider \(slider.intValue))")
    }
    type("7", in: field)
    type("", in: field)
    check(field.stringValue == "", "\(name): an empty field is left alone while it is typed in, not \(field.stringValue)")
    type("3", in: field)
    check(field.stringValue == "3" && slider.intValue == 3, "\(name): typing after an empty field keeps what is typed")
}
let other = NSTextField()
other.stringValue = "0"
ViewerImageExporter.exportFieldDidChange(Notification(name: NSControl.textDidChangeNotification, object: other), of: viewer)
check(other.stringValue == "0", "a field outside the sheets is left alone")
if failed { exit(1) }
print("PASS: the fields of the DICOM and QuickTime sheets keep the bounds of their sliders")
"""

# ---------------------------------------------------------------- print and movie
print_plan = between(printing, '// MARK: - The plan', '/// The choices of the print sheet')
movie_plan = between(movie, '// MARK: - The plan', '// MARK: - The export')
update_pages = between(printing, '    func updatePageCount(', '    /// Follows a range slider')
capture = between(printing, '    private func capturePages(', '    func finish(pages:')
check('for index in plan.indices' in update_pages and 'for index in plan.indices' in capture,
      'the print loops no longer walk the images of the plan')
check('ViewerPrintPlan.pageCount(images: count, perPage: perPage)' in update_pages, 'the page count is not the plan\'s')
check('ViewerMoviePlan.imageCount(' in movie and 'ViewerMoviePlan.blendingValue(sample: sample, frames: maxFrame?.int32Value ?? 0)' in movie,
      'the movie sheet and the blending frames are not the plan\'s')

print_program = r'''
import Foundation
var failed = false
func check(_ condition: Bool, _ what: String) { if !condition { print("failed: " + what); failed = true } }
func steps(_ from: Int32, _ to: Int32, _ interval: Int32) -> Int {
    var n = 0, i = from
    while i < to { n += 1; if n > 10_000 { return -1 }; i = i &+ interval }
    return n
}
''' + print_plan + movie_plan + r'''
for (from, to, interval, expected) in [(1, 5, 0, "5 images"), (5, 1, -1, "5 images"), (1, 9, 2, "5 images")] as [(Int32, Int32, Int32, String)] {
    check("\(ViewerMoviePlan.imageCount(from: from, to: to, interval: interval)) images" == expected, "a movie of \(from)...\(to) by \(interval) counts \(expected)")
}
for (cur, max, expected) in [(0, 1, -256), (0, 20, -256), (19, 20, 256), (0, 0, -256)] as [(Int32, Int32, Int32)] {
    check(ViewerMoviePlan.blendingValue(sample: cur, frames: max) == expected, "blending frame \(cur) of \(max) sets \(expected)")
}
for (from, to, interval, expected) in [(1, 5, 0, 5), (5, 1, 0, 5), (1, 5, -3, 5), (1, 9, 3, 3)] as [(Int32, Int32, Int32, Int)] {
    let plan = ViewerPrintPlan(selection: 2, currentImage: 0, count: 9, first: from, last: to, step: interval)
    check(plan.indices.count == expected, "the page count of \(from)...\(to) by \(interval) takes \(expected) images")
    check(plan.interval >= 1 && steps(plan.from, plan.to, plan.interval) == expected, "printing \(from)...\(to) by \(interval) takes \(expected) images")
    check(plan.progressMaximum > 0, "the print's progress has a maximum")
}
let nothing = ViewerPrintPlan(selection: 7, currentImage: 3, count: 9, first: 1, last: 9, step: 0)
check(nothing.indices.isEmpty && nothing.progressMaximum == 0, "a choice the sheet does not have prints nothing and never loops")
for (images, perPage, expected) in [(5, 0, 5), (5, 4, 2), (8, 4, 2), (0, 4, 0), (1, 1, 1)] as [(Int32, Int32, Int32)] {
    check(ViewerPrintPlan.pageCount(images: images, perPage: perPage) == expected, "\(images) images \(perPage) to a page make \(expected) pages")
}
if failed { exit(1) }
print("PASS: movie and print intervals and divisors")
'''

# ---------------------------------------------------------------- read from the source
constrain = [m.start() for m in re.finditer(r'OSIWindow\.setDontConstrain\(', capture)]
check(len(constrain) == 2 and 'OSIWindow.setDontConstrain(true)' not in capture[constrain[-1]:constrain[-1] + 40]
      and constrain[-1] > capture.index('for index in plan.indices'),
      'the print puts the window constraint back after the pages are prepared')
check('OSIWindow.dontConstrainWindow()' in capture[:constrain[0]], 'the print keeps the constraint it found')

cropped = method(retrieve, 'exportCroppedSeries:')
check('passRetained' not in cropped and 'wait?.close()' in cropped, '-exportCroppedSeries: leaves its Wait window to be released')

setpixels_calls = re.findall(r'\.setPixels\([^\n]*', series)
check(setpixels_calls == [], 'SeriesView sends -setPixels:files:... through the bridge that keeps the file list: ' + '; '.join(setpixels_calls))
check(len(re.findall(r'dcmViewSetPixels\(\w+, \w+, files: (?:files|dcmFilesList), ', series)) == 3,
      'SeriesView hands the three -setPixels:files: of its views the list it holds')

series_program = None
if 'func dcmViewSetPixels(' in series:
    helper = series[series.rindex('\n', 0, series.index('func dcmViewSetPixels(')) + 1:]
    helper = helper[:helper.index('\n}\n') + 3]
    series_program = r'''
import AppKit
class DCMView: NSObject {
    var received: NSArray?
    @objc(setPixels:files:rois:firstImage:level:reset:)
    func setPixels(_ pixels: NSMutableArray?, files: NSArray?, rois: NSMutableArray?, firstImage: Int, level: CChar, reset: Bool) { received = files }
}
''' + helper + r'''
let list = NSMutableArray(array: ["a", "b", "c"])
let view = DCMView()
dcmViewSetPixels(view, NSMutableArray(), files: list, rois: nil, firstImage: 0, level: 0, reset: true)
list.exchangeObject(at: 0, withObjectAt: 2)
if view.received !== list || (view.received?.firstObject as? String) != "c" { print("failed: the view holds a copy of the file list"); exit(1) }
print("PASS: the view holds the viewer's file list")
'''
else:
    check(False, 'SeriesView has no bridge that hands a DCMView the file list itself')

with tempfile.TemporaryDirectory(prefix='horos-export-guards-') as directory:
    d = Path(directory)
    programs = [('export', export_program), ('fields', fields_program), ('print', print_program)]
    if series_program:
        programs.append(('series', series_program))
    for name, code in programs:
        (d / f'{name}.swift').write_text(code)
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(d / f'{name}.swift'), '-o', str(d / name)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            failures.append(f'{name} program does not compile:\n{build.stderr[-3000:]}')
            continue
        work = d / f'{name}-files'
        work.mkdir()
        run = subprocess.run([str(d / name), str(work), '-OPENVIEWER', 'NO'], capture_output=True, text=True, timeout=120)
        print(run.stdout.strip())
        if run.returncode != 0:
            failures.append(f'{name} program failed')
        for path in work.rglob('*'):
            if path.is_dir():
                os.chmod(path, stat.S_IRWXU)

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('PASS: export and print guards')
