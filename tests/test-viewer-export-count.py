#!/usr/bin/env python3
"""The "%d images" of the 2D viewer's DICOM and QuickTime sheets is the number
of images the export makes.

-exportDICOMSetNumber: and -exportQuicktimeSetNumber: counted
(|To - From| + 1) / interval. The DICOM series walks From, From + interval, ...
up to To, |To - From| / interval + 1 images: from 1 to 10 by 3 the sheet said
"3 images" and the export made 4 (1, 4, 7, 10). The movie walked From +
interval - 1, From + 2 * interval - 1, ...: from 1 to 10 by 3 it took 3, 6
and 9, and left out From. It now starts at From, as the DICOM series and the
print do, and makes the images its sheet counts.

The pieces are copied from ViewerImageExporter.swift (the DICOM export of
the 2D viewer), with the range it walks (ViewerExportRange.swift of
IsiXImaging), and ViewerMovieExport.swift (the movie of the 2D viewer, with
its plan), and compiled with swiftc inside a Swift double of the viewer:

- dicom: the count of the sheet (updateDICOMImageCount) and the maximum of the
  progress bar of the export (endDICOMSheet), which was (To - From + 1) /
  interval rounded down, against the images its loop exports for the same
  fields;
- movie: the count of the sheet (updateImageCount) against the frames the
  plan keeps (the ones image(forFrame:maxFrame:) captures) for the range the
  sheet hands the export (endSheet, export), and the first of them is From.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

export = source('Horos/Sources/ViewerImageExporter.swift')
export_range = source('Modules/IsiXImaging/Sources/ViewerExport/ViewerExportRange.swift')
movie = source('Horos/Sources/ViewerMovieExport.swift')


def between(text, first, last, start=0):
    a = text.index(first, start)
    return text[a:text.index(last, a)]


def body(text, signature):
    start = text.index('{\n', text.index(signature)) + 2
    return text[start:text.index('\n    }\n', start)]


dicom_count = body(export, '    func updateDICOMImageCount()')
dicom_sheet = body(export, '    func endDICOMSheet(')
dicom_range = between(dicom_sheet, 'var range = ViewerExportRange(first:', '\n                let keysAndROIs')
# The maximum of the export's progress bar, as an expression.
dicom_progress = between(dicom_sheet, 'splash?.progress()?.maxValue = ', '\n')[len('splash?.progress()?.maxValue = '):]
if 'for i in range.indices {' not in dicom_sheet:
    print('FAIL: the DICOM export does not walk the images of its range')
    sys.exit(1)


movie_plan = between(movie, '// MARK: - The plan', '// MARK: - The export')
movie_count = body(movie, '    func updateImageCount()')
movie_range = between(body(movie, '    func endSheet('), 'let dimension = viewer.horos_quicktimeMode', 'export(dimension:')
movie_start = between(body(movie, '    func export(dimension:'), 'let plan = ViewerMoviePlan(', 'keep(plan)')
frame = body(movie, '    func image(forFrame frame:')
if 'ViewerMoviePlan.countdown(viewer.horos_current_qt_interval, interval: plan.interval)' not in frame \
        or 'kept = kept && step.keeps' not in frame or 'viewer.horos_current_qt_interval = 1' not in movie:
    print('FAIL: the frames the movie captures are not the ones its plan keeps')
    sys.exit(1)

PROGRAM = r'''
import AppKit
var failed = false
func check(_ condition: Bool, _ what: String) { if !condition { print("failed: " + what); failed = true } }
''' + export_range + r'''
final class Field: NSObject {
    var intValue: Int32 = 0
    var stringValue: String = ""
    init(_ v: Int32 = 0) { intValue = v }
}
final class Cell: NSObject { let tag: Int; init(_ t: Int) { tag = t } }
final class Matrix: NSObject {
    let cell: Cell
    init(_ tag: Int) { cell = Cell(tag) }
    func selectedCell() -> Cell? { return cell }
}
final class Viewer: NSObject {
    var viewer: Viewer { self }
    var horos_dcmFrom: Field? = Field(), horos_dcmTo: Field? = Field(), horos_dcmInterval: Field? = Field()
    var horos_dcmNumber: Field? = Field()
    var horos_dcmSelection: Matrix? = Matrix(1)
    var horos_quicktimeFrom: Field? = Field(), horos_quicktimeTo: Field? = Field(), horos_quicktimeInterval: Field? = Field()
    var horos_quicktimeNumber: Field? = Field()
    var horos_quicktimeMode: Matrix? = Matrix(1)
    var horos_curMovieIndex: Int16 = 0
    var lastFrameZeroKept = false
    var movieFrameCount: Int32 = 0
    func horos_pixList(at index: Int) -> NSArray? { return NSArray(array: Array(repeating: 0, count: 40)) }
    func getNumberOfImages() -> Int { return 40 }
    func maxMovieIndex() -> Int16 { return 1 }
    func frameRate() -> Float { return 0 }
    func frame4DRate() -> Float { return 0 }

    func dicomLabel() {
''' + dicom_count + r'''
    }
    /// The images, 1-based, the DICOM series exports.
    func dicomImages() -> [Int32] {
''' + dicom_range + r'''
        return range.indices.prefix(1000).map { Int32($0) + 1 }
    }
    /// The maximum of the export's progress bar.
    func dicomProgressMax() -> Double {
''' + dicom_range + r'''
        return ''' + dicom_progress + r'''
    }
    func movieLabel() {
''' + movie_count + r'''
    }
    /// The images, 1-based, the movie takes.
    func movieImages() -> [Int32] {
''' + movie_range + r'''
        let from = range.from, to = range.to, interval = range.interval
        let allViewers = false, mode: String? = nil
''' + movie_start + r'''
        // The countdown starts at 1 and lives between the requests, which come in order.
        var images: [Int32] = []
        var remaining: Int32 = 1
        for cur in 0..<Int32(plan.frameCount) {
            let step = ViewerMoviePlan.countdown(remaining, interval: plan.interval)
            remaining = step.next
            if step.keeps { images.append(plan.sample(frame: cur) &+ 1) }
        }
        // QuicktimeExport asks for frame 0 once more at the end: it moves the viewer back only
        // when the countdown keeps it, as it always did (interval 1, or one that ends a step there).
        lastFrameZeroKept = ViewerMoviePlan.countdown(remaining, interval: plan.interval).keeps
        movieFrameCount = Int32(plan.frameCount)
        return images
    }
}
''' + movie_plan + r'''
let viewer = Viewer()
for (from, to, interval) in [(1, 10, 3), (1, 9, 2), (10, 1, 3), (1, 1, 1), (1, 10, 1), (1, 10, 20), (3, 7, 0), (1, 5, -2), (2, 40, 7)] as [(Int32, Int32, Int32)] {
    viewer.horos_dcmFrom?.intValue = from; viewer.horos_dcmTo?.intValue = to; viewer.horos_dcmInterval?.intValue = interval
    viewer.dicomLabel()
    let dicom = viewer.dicomImages()
    check(viewer.horos_dcmNumber?.stringValue == "\(dicom.count) images",
          "DICOM \(from)...\(to) by \(interval): the sheet says \(viewer.horos_dcmNumber?.stringValue ?? "") and the export makes \(dicom.count) (\(dicom))")
    check(viewer.dicomProgressMax() == Double(dicom.count),
          "DICOM \(from)...\(to) by \(interval): the progress bar counts to \(viewer.dicomProgressMax()) and the export makes \(dicom.count)")

    viewer.horos_quicktimeFrom?.intValue = from; viewer.horos_quicktimeTo?.intValue = to; viewer.horos_quicktimeInterval?.intValue = interval
    viewer.movieLabel()
    let movie = viewer.movieImages()
    check(viewer.horos_quicktimeNumber?.stringValue == "\(movie.count) images",
          "movie \(from)...\(to) by \(interval): the sheet says \(viewer.horos_quicktimeNumber?.stringValue ?? "") and the movie takes \(movie.count) (\(movie))")
    check(movie.first == min(from, to), "movie \(from)...\(to) by \(interval) starts at \(min(from, to)), not \(movie.first ?? 0)")
    check(movie == dicom, "movie \(from)...\(to) by \(interval) takes the images of the DICOM series: \(movie), \(dicom)")
    // The former countdown after the last of its frames 0...n-1: frame n-1 left it at
    // interval - (n-1) % interval, so the extra frame 0 was kept only when that was 1.
    let step = max(interval, 1), n = viewer.movieFrameCount
    check(viewer.lastFrameZeroKept == (n == 0 ? step == 1 : (n - 1) % step == step - 1),
          "movie \(from)...\(to) by \(interval): the extra request for frame 0 keeps it as the countdown did")
}
if failed { exit(1) }
print("PASS: the DICOM and QuickTime sheets count the images the export makes")
'''

with tempfile.TemporaryDirectory(prefix='horos-export-count-') as folder:
    d = Path(folder)
    (d / 'count.swift').write_text(PROGRAM)
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(d / 'count.swift'), '-o', str(d / 'count')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print('FAIL: the count program does not compile:\n' + build.stderr[-3000:])
        sys.exit(1)
    run = subprocess.run([str(d / 'count')], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    if run.returncode != 0:
        print('FAIL: image counts, progress bar')
        sys.exit(1)
print('PASS: image counts, progress bar')
