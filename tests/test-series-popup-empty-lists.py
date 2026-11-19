#!/usr/bin/env python3
"""The series menu reads the first file and the first series of lists that may be empty.

The series menu of a 2D viewer (ViewerController+SeriesPopup.swift) read the
first file of each time point, and the first series of a study, at index 0 of
its list. A list is empty while the window closes or once its series left the
database, and index 0 of an empty list raises NSRangeException: building the
menu, or choosing a series or a study in it, then stopped on the exception.

Checked here:

1. the file no longer reads index 0 of a list: the first file of a time
   point and the first series of a study are read as the list's first object,
   and a study without a series ends the choice;
2. viewerSeries(checkingNil:listed:), extracted and compiled with stand-ins
   for the viewer, its files and their series, leaves out a time point without
   a file and tells the time point of each series it lists; with files it
   answers as before: with `checkingNil` a first file without a series is left
   out, without it that file is still handed to viewerArrayAdd as nil;
3. the choice of a series the viewer shows at another time point moves the
   viewer to that time point, not to the place of the series in the list,
   which differs once a time point is left out.

`<git revision>` as an optional argument reads the file from that revision:
that is the negative control.

Exit 2 when there is no Swift compiler.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
relative = 'Horos/Sources/ViewerController+SeriesPopup.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
if revision is None:
    source = (root / relative).read_text(encoding='utf-8')
else:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                     stderr=subprocess.DEVNULL).decode('utf-8')
failures = []


def body(signature, text=source):
    start = text.index(signature)
    return text[start:text.index('\n    }\n', start) + len('\n    }\n')]


# 1. No read at index 0.
for number, line in enumerate(source.splitlines(), 1):
    if 'object(at: 0)' in line or 'objectAtIndex(0)' in line:
        failures.append(f'{relative}:{number}: reads index 0 of a list that may be empty: {line.strip()}')
build = body('    func build() {')
load = body('    func loadSelectedSeries(_ chosen: Any?, rightClick: Bool)')
select = body('    func select(_ sender: NSMenuItem?)')
for where, name, expected in (
        (build, 'build', 'viewer.horos_fileList(at: 0)?.firstObject as? DicomImage'),
        (load, 'loadSelectedSeries', 'guard let first = (s.imageSeriesContainingPixels(true) as NSArray?)?.firstObject else { return }'),
        (load, 'loadSelectedSeries', 'viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.firstObject as? DicomImage'),
        (select, 'select', 'guard let first = (s.imageSeries() as NSArray?)?.firstObject else { return }')):
    if expected not in where:
        failures.append(f'{name} no longer has `{expected}`')

# 3. The time point of a series chosen in 4D.
for expected in ('let viewerSeries = viewerSeries(checkingNil: true) { timePoints.append($0) }',
                 'viewer.setMovieIndex(Int16(truncatingIfNeeded: timePoints[idx]))'):
    if expected not in load:
        failures.append(f'loadSelectedSeries no longer has `{expected}`')

# 2. The series of each time point.
viewer_series = body('    func viewerSeries(checkingNil: Bool')
program = r'''
import Foundation

final class DicomSeries: NSObject {}
final class DicomImage: NSObject {
    let series: DicomSeries?
    init(_ series: DicomSeries?) { self.series = series }
}
// The viewer: the list of files of each time point.
final class Viewer {
    var lists: [NSMutableArray?] = []
    var horos_maxMovieIndex: Int16 { Int16(lists.count) }
    func horos_fileList(at index: Int) -> NSMutableArray? { lists[index] }
}
// The application's raises for a nil object; here it counts them.
nonisolated(unsafe) var nilAdded = 0
func viewerArrayAdd(_ object: Any?, to array: NSMutableArray) {
    guard let object else { nilAdded += 1; return }
    array.add(object)
}
struct Presenter {
    let viewer: Viewer
VIEWER_SERIES
}

var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}
func files(_ entries: Any...) -> NSMutableArray { NSMutableArray(array: entries) }
/// The series listed, the time point told for each and the nil objects added.
func listed(_ lists: [NSMutableArray?], checkingNil: Bool) -> (series: [DicomSeries], timePoints: [Int], nilAdded: Int) {
    let viewer = Viewer()
    viewer.lists = lists
    nilAdded = 0
    var timePoints: [Int] = []
    let series = Presenter(viewer: viewer).viewerSeries(checkingNil: checkingNil) { timePoints.append($0) }
    return (series.compactMap { $0 as? DicomSeries }, timePoints, nilAdded)
}

let a = DicomSeries(), b = DicomSeries(), c = DicomSeries()
for checkingNil in [true, false] {
    // Every time point has files: the list is the series in their order.
    let full = listed([files(DicomImage(a), DicomImage(a)), files(DicomImage(b)), files(DicomImage(c))], checkingNil: checkingNil)
    check(full.series == [a, b, c] && full.timePoints == [0, 1, 2] && full.nilAdded == 0, "three time points with files: \(full)")
    // A time point without a file is left out, and the others keep their time point.
    let emptied = listed([files(DicomImage(a)), files(), files(DicomImage(c))], checkingNil: checkingNil)
    check(emptied.series == [a, c] && emptied.timePoints == [0, 2] && emptied.nilAdded == 0, "an empty list in the middle: \(emptied)")
    let none = listed([files(), files()], checkingNil: checkingNil)
    check(none.series.isEmpty && none.timePoints.isEmpty && none.nilAdded == 0, "only empty lists: \(none)")
    check(listed([], checkingNil: checkingNil).series.isEmpty, "no time point")
}
// A first file without a series, a first object that is not a file, no list:
// left out with checkingNil, handed over as nil without it, as before.
for lists in [[files(DicomImage(a)), files(DicomImage(nil)), files(DicomImage(c))],
              [files(DicomImage(a)), files("not a file" as NSString), files(DicomImage(c))],
              [files(DicomImage(a)), nil, files(DicomImage(c))]] as [[NSMutableArray?]] {
    let checked = listed(lists, checkingNil: true)
    check(checked.series == [a, c] && checked.timePoints == [0, 2] && checked.nilAdded == 0, "no series at a time point, checking: \(checked)")
    let unchecked = listed(lists, checkingNil: false)
    check(unchecked.series == [a, c] && unchecked.nilAdded == 1, "no series at a time point, not checking: \(unchecked)")
}
// Without the closure, as the series list and the build of the menu call it.
let viewer = Viewer()
viewer.lists = [files(), files(DicomImage(b))]
check(Presenter(viewer: viewer).viewerSeries(checkingNil: false).isEqual(to: [b]), "called without the time points")
exit(failed ? 1 : 0)
'''.replace('VIEWER_SERIES', viewer_series)

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-series-popup-empty-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'series'),
                            str(folder / 'main.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('viewerSeries does not compile with its stand-ins:\n' + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(folder / 'series')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f'viewerSeries (exit {ran.returncode}):\n' + ran.stderr[-3000:].strip())

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: the series menu reads the first file of a time point and the first series of a study from lists that may '
      'be empty, and a series chosen in 4D is shown at its own time point')
