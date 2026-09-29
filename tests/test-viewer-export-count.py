#!/usr/bin/env python3
"""The "%d images" of the 2D viewer's DICOM and QuickTime sheets is the number
of images the export makes (#918).

-exportDICOMSetNumber: and -exportQuicktimeSetNumber: counted
(|To - From| + 1) / interval. The DICOM series walks From, From + interval, ...
up to To, |To - From| / interval + 1 images: from 1 to 10 by 3 the sheet said
"3 images" and the export made 4 (1, 4, 7, 10). The movie walked From +
interval - 1, From + 2 * interval - 1, ...: from 1 to 10 by 3 it took 3, 6
and 9, and left out From. It now starts at From, as the DICOM series and the
print do, and makes the images its sheet counts.

The pieces are copied from ViewerController+Export.swift and
ViewerController+Export+PrintMovie.swift and compiled with swiftc inside a
Swift double of the viewer:

- dicom: the count of -exportDICOMSetNumber: and the maximum of the progress
  bar of -endExportDICOMFileSettings: (#925), which was (To - From + 1) /
  interval rounded down, against the images its loop exports for the same
  fields;
- movie: the count of -exportQuicktimeSetNumber: against the frames
  -imageForFrame:maxFrame: gives for the range -endQuicktime: hands
  -exportQuicktimeIn:::::mode:, and the first of them is From.

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

export = source('Horos/Sources/ViewerController+Export.swift')
printing = source('Horos/Sources/ViewerController+Export+PrintMovie.swift')


def method(text, selector):
    start = text.index(f'    @objc({selector})')
    start = text.index('{\n', start) + 2
    return text[start:text.index('\n    }\n', start)]


def between(text, first, last, start=0):
    a = text.index(first, start)
    return text[a:text.index(last, a)]


def helper(text, name):
    at = text.index(f'fileprivate func {name}(')
    return text[at:text.index('\n}\n', at) + 3].replace('fileprivate ', '')


dicom_count = method(export, 'exportDICOMSetNumber:')
dicom_range = between(method(export, 'endExportDICOMFileSettings:'),
                      'var from: Int32, to: Int32, interval: Int32', 'let splash = Wait(')
# The maximum of the export's progress bar, as an expression (#925).
dicom_progress = between(method(export, 'endExportDICOMFileSettings:'),
                         'splash?.progress()?.maxValue = ', '\n')[len('splash?.progress()?.maxValue = '):]


def helper_if_any(text, name):
    return helper(text, name) if f'fileprivate func {name}(' in text else ''
movie_count = method(printing, 'exportQuicktimeSetNumber:')
movie_range = between(method(printing, 'endQuicktime:'), 'var from: Int, to: Int, interval: Int', 'self.exportQuicktime(in:')
movie_start = between(method(printing, 'exportQuicktimeIn:::::mode:'), 'self.horos_qt_dimension = ', 'let mov: QuicktimeExport')
frame = method(printing, 'imageForFrame:maxFrame:')
movie_step = between(frame, 'self.horos_current_qt_interval &-= 1', '\n        if export {')

PROGRAM = r'''
import AppKit
var failed = false
func check(_ condition: Bool, _ what: String) { if !condition { print("failed: " + what); failed = true } }
''' + helper(export, 'cDiv') + helper(export, 'cAbs') + helper_if_any(export, 'dicomSeriesImageCount') + r'''
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
    var horos_dcmFrom: Field? = Field(), horos_dcmTo: Field? = Field(), horos_dcmInterval: Field? = Field()
    var horos_dcmNumber: Field? = Field()
    var horos_dcmSelection: Matrix? = Matrix(1)
    var horos_quicktimeFrom: Field? = Field(), horos_quicktimeTo: Field? = Field(), horos_quicktimeInterval: Field? = Field()
    var horos_quicktimeNumber: Field? = Field()
    var horos_quicktimeMode: Matrix? = Matrix(1)
    var horos_curMovieIndex: Int16 = 0
    var horos_qt_dimension: Int32 = 0, horos_qt_allViewers: Int32 = 0
    var horos_qt_from: Int32 = 0, horos_qt_to: Int32 = 0, horos_qt_interval: Int32 = 0, horos_current_qt_interval: Int32 = 0
    func horos_pixList(at index: Int) -> NSArray? { return NSArray(array: Array(repeating: 0, count: 40)) }
    func getNumberOfImages() -> Int { return 40 }
    func maxMovieIndex() -> Int { return 1 }

    func dicomLabel() {
''' + dicom_count + r'''
    }
    /// The images, 1-based, the DICOM series exports.
    func dicomImages() -> [Int32] {
''' + dicom_range + r'''
        var images: [Int32] = []
        var i = from
        while i < to { images.append(i + 1); if images.count > 1000 { break }; i = i &+ interval }
        return images
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
        let dimension = self.horos_quicktimeMode?.selectedCell()?.tag ?? 0
        let allViewers = false
''' + movie_start + r'''
        var images: [Int32] = []
        var cur: Int32 = 0
        while cur < self.horos_qt_to &- self.horos_qt_from {
            var export = true
''' + movie_step + r'''
            if export { images.append(cur &+ self.horos_qt_from &+ 1) }
            cur += 1
        }
        _ = (interval, dimension, allViewers)
        return images
    }
}
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
        print('FAIL: #918 image counts, #925 progress bar')
        sys.exit(1)
print('PASS: #918 image counts, #925 progress bar')
