#!/usr/bin/env python3
"""A change of plane leaves the series it replaces to the 3D windows open on it.

An MPR, a volume rendering and the other 3D windows do not retain the slices,
the files or the volume they show: the 2D viewer that opened them owns them,
and they close when it announces that it lets them go. A change of plane in
the viewer used to be refused while such a window was open. It now gives the
viewer its new slices and leaves the former series to those windows, which
stay open: each takes a hold on it (PreviousSeriesHold) and is named in the
announcement, so that it does not close.

PreviousSeriesHold runs compiled with xcrun swiftc: what an owner holds lives
as long as the owner and no longer, a second hold does not drop the first, and
only a change of plane keeps a window: one that names it, or one of the viewer
whose former series it already holds. The sources are read for the
rest: the reslice asks for the hold, the viewer's series load takes it before
announcing the release and still refuses the other changes of series, and each
3D window asks whether it is kept before closing.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(text, signature, end='\n    }\n'):
    start = text.find(signature)
    if start < 0:
        return ''
    return text[start:text.index(end, start) + len(end)]


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

DRIVER = r'''
import Foundation

final class Owner: NSObject {}
final class Series: NSObject {}

func expect(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL: " + what) }
}

@main struct Driver {
    static func main() {
        let viewer = Owner(), fused = Owner()
        weak var first: Series?
        weak var second: Series?
        autoreleasepool {
            let owner = Owner()
            expect(!PreviousSeriesHold.owner(owner, holdsPreviousSeriesOf: viewer), "an owner holds a series before any was given")
            autoreleasepool {
                let series = Series()
                first = series
                PreviousSeriesHold.hold([series, NSMutableArray(), NSData()], releasedBy: viewer, for: owner)
            }
            expect(first != nil, "the series went while its owner lived")
            expect(PreviousSeriesHold.owner(owner, holdsPreviousSeriesOf: viewer), "the owner does not say it holds a series of the viewer")
            expect(!PreviousSeriesHold.owner(owner, holdsPreviousSeriesOf: fused), "the owner says it holds a series of another viewer")
            autoreleasepool {
                let series = Series()
                second = series
                PreviousSeriesHold.hold([series], releasedBy: viewer, for: owner)
            }
            expect(first != nil, "a second hold dropped the first")
            expect(second != nil, "the second series went while its owner lived")
        }
        expect(first == nil && second == nil, "the series outlived its owner")

        let kept = Owner(), other = Owner(), holder = Owner()
        PreviousSeriesHold.hold([Series()], releasedBy: viewer, for: holder)
        let name = Notification.Name("CloseViewerNotification")
        func plane(_ viewer: AnyObject, _ windows: [AnyObject]) -> Notification {
            Notification(name: name, object: viewer, userInfo: [PreviousSeriesHold.keptWindowsKey: windows])
        }
        let keeping = plane(viewer, [kept])
        expect(PreviousSeriesHold.window(kept, keepsSeriesReleasedBy: keeping), "a window the change of plane names is not kept")
        expect(!PreviousSeriesHold.window(other, keepsSeriesReleasedBy: keeping), "a window the change of plane does not name is kept")
        // The next changes of plane of the same viewer name nobody.
        expect(PreviousSeriesHold.window(holder, keepsSeriesReleasedBy: plane(viewer, [])), "a window holding the viewer's former series closes at its next change of plane")
        expect(!PreviousSeriesHold.window(other, keepsSeriesReleasedBy: plane(viewer, [])), "a window holding nothing is kept by a change of plane that names none")
        expect(!PreviousSeriesHold.window(holder, keepsSeriesReleasedBy: plane(fused, [])), "a window stays through the change of plane of a viewer it holds nothing of")
        let closing = Notification(name: name, object: viewer, userInfo: ["newStudyID": "x"])
        expect(!PreviousSeriesHold.window(kept, keepsSeriesReleasedBy: closing), "a window is kept by a release that is not a change of plane")
        expect(!PreviousSeriesHold.window(holder, keepsSeriesReleasedBy: closing), "a window holding a former series stays when another series takes its place")
        expect(!PreviousSeriesHold.window(holder, keepsSeriesReleasedBy: Notification(name: name, object: viewer)), "a window holding a former series stays when the viewer closes")
        expect(!PreviousSeriesHold.window(kept, keepsSeriesReleasedBy: nil), "a window is kept without an announcement")
        print("done")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-previous-series-') as folder:
    folder = Path(folder)
    (folder / 'Driver.swift').write_text(DRIVER)
    program = folder / 'driver'
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', str(sources / 'PreviousSeriesHold.swift'),
                            str(sources / 'IdentityToken.swift'),  # the key its holds are kept under
                            str(folder / 'Driver.swift'), '-o', str(program)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: PreviousSeriesHold does not compile with its driver:\n' + built.stderr[-3000:])
    ran = subprocess.run([str(program)], capture_output=True, text=True, timeout=60)
    check(ran.returncode == 0 and ran.stdout.strip().endswith('done'), 'the driver stopped: ' + (ran.stdout + ran.stderr)[-1000:])
    failures += [line for line in ran.stdout.splitlines() if line.startswith('FAIL')]

reslice = (sources / 'ViewerController+Reslice.swift').read_text(encoding='utf-8')
process = body(reslice, 'func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool')
asked = process.find('horosSeriesLoad.keepingPreviousSeriesForOtherWindows {')
check(0 <= asked < process.find('changeImageData(pixes, files, frame.volume, false)'),
      '-processReslice:: does not leave the series it replaces to the other windows')

load = (sources / 'ViewerSeriesLoad.swift').read_text(encoding='utf-8')
show = body(load, 'func show(_ given: GivenSeries, newViewerWindow: Bool)')
check('if !newViewerWindow && volumeIsUsedByOtherWindows && !otherWindowsKeepPreviousSeries {' in show,
      'the series load does not refuse the other changes of series under a 3D window, or refuses the change of plane')
replace = body(load, 'private func replace(_ given: GivenSeries')
held, announced, released = (replace.find(needle) for needle in (
    '= holdSeriesForOtherWindows()', 'postViewerNotification(.OsirixCloseViewer, viewer, closeInfo)', 'finalize(viewerStays: true)'))
check(0 <= held < announced < released, 'the series is not held for the other windows before it is announced as released and released')
check('closeInfo[PreviousSeriesHold.keptWindowsKey] = holdSeriesForOtherWindows()' in replace, 'the announcement does not name the windows that keep the series')
holding = body(load, 'private func holdSeriesForOtherWindows() -> [AnyObject]')
for needle in ('horos_pixList(at: movie)', 'horos_fileList(at: movie)', 'horos_roiList(at: movie)', 'horos_volumeData(at: movie)',
               'horos_maxMovieIndex'):
    check(needle in holding, 'the hold leaves out %s' % needle)

# Each 3D window asks before anything else in its answer to the announcement.
WINDOWS = {'MPRController': 'func CloseViewerNotification(', 'CPRController': 'func CloseViewerNotification(',
           'EndoscopyViewer': 'func CloseViewerNotification(', 'OrthogonalMPRViewer': 'func CloseViewerNotification(',
           'OrthogonalMPRPETCTViewer': 'func CloseViewerNotification(', 'SRController': 'func closeViewerNotification(',
           'VRController': 'func closeViewerNotification('}
for name, signature in WINDOWS.items():
    text = (sources / (name + '.swift')).read_bytes().decode('latin1').replace('\r\n', '\n')
    answer = body(text, signature)
    lines = [line.strip() for line in answer.splitlines()[1:] if line.strip() and not line.strip().startswith('//')]
    check(bool(lines) and lines[0] == 'if PreviousSeriesHold.window(self, keepsSeriesReleasedBy: note) { return }',
          '%s closes on the announcement without asking whether it keeps the series' % name)

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('PASS: a change of plane leaves the former series to the 3D windows, which hold it and stay open')
