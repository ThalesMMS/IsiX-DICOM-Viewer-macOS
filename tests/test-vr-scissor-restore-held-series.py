#!/usr/bin/env python3
"""After a change of plane, the VR window's scissors restore (Tab) reads the window's own slices from their files.

The 3D Cut's restore puts back, inside the ROI drawn, the pixels the slices
have in their files: -deleteRegion asks the first of the window's own slices
for -prepareRestore, which reads every slice of its series again from its
file. The window refused it whenever its 2D viewer was post-processed. A
change of plane post-processes the 2D viewer and lets the window keep the
slices it opened with (PreviousSeriesHold), so the window refused a restore
its own slices could do.

The window now decides from its own slices, as Revert Series does: read from
their files when it opened, not post-processed since by the 2D viewer that
still shows them (a flip or a rotation changes them in place, which the
former test refused and still does), not turned in place by it before a
change of plane gave it other slices (their geometry, recorded when the
window opened and whenever the slices are read again, changed), and every
file still the one it was decoded from (-horosSlicesReadableFromFiles). It
says why it refuses: the slices are post-processed (a slice made in memory,
with no file or no record of one, too), or files were removed or changed
since they were read (a text in the twelve catalogs, translated). A window
opened without a 2D viewer has no record of where its slices came from and is
not refused, as before.

The window's rule (-horosScissorRestoreRefusal) and what it asks of the
window's slices are compiled as written into a harness that drives its cases
over stand-ins for the slices; the rest is read from the sources.
`<git revision>` as an optional argument reads the files from that revision:
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
LANGUAGES = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans']
POSTPROCESSED = 'This dataset has been post processed (reslicing, MPR, ...). You cannot restore it.'
FILES_CHANGED = 'Files of this dataset were removed or changed since it was read. You cannot restore it.'


def read_bytes(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout if result.returncode == 0 else b''
    file = root / path
    return file.read_bytes() if file.exists() else b''


def read(path):
    return read_bytes(path).decode('utf-8')


def read_controller():
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', revision,
                                         'Horos/Sources/']).decode().split()
    else:
        names = [str(p.relative_to(root)) for p in (root / 'Horos/Sources').glob('VRController*.swift')]
    return ''.join(read(name) for name in sorted(names) if re.fullmatch(r'Horos/Sources/VRController(\+\w+)?\.swift', name))


def method(text, signature):
    match = re.search(re.escape(signature) + r'.*?\n    }\n', text, re.S)
    return re.sub(r'//[^\n]*', '', match.group(0)) if match else ''


def catalog(language):
    data = read_bytes(f'Horos/Resources/{language}.lproj/Localizable.strings')
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', text, re.M))


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []

# The premises: a change of plane in place post-processes the 2D viewer and
# lets the other windows keep the former series; the restore reads the
# window's own slices from their files.
reslice = method(read('Horos/Sources/ViewerController+Reslice.swift'), '    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {')
if 'keepingPreviousSeriesForOtherWindows { changeImageData(' not in reslice or 'setPostprocessed(true)' not in reslice:
    failures.append('premise: a change of plane post-processes the 2D viewer and lets the other windows keep the former series')
scissors = read('Horos/Sources/VRView+Scissors.swift')
if not re.search(r'if let first = controller\.curPixList\(\)\?\.object\(at: 0\) \{[^\n]*\.prepareRestore\(\) \}', scissors):
    failures.append('premise: the scissors restore from the window\'s own slices (-prepareRestore of its first slice)')
prepare = method(read('Horos/Sources/DCMPix+ROIFill.swift'), '    public dynamic func prepareRestore() -> Bool {')
if 'let slices = pixArray ?? []' not in prepare or 'DCMPix(path: source.srcFile' not in prepare:
    failures.append('premise: -prepareRestore reads every slice of the series again from its file')
# The 2D viewer's flips and rotations turn every slice of every time point in
# place, orientation and pixels; those that bring a change of plane upright
# turn the new slices, after the reslice. The gantry tilt correction moves the
# origins only. A slice records the file it was decoded from when the file is
# there.
transforms = read('Horos/Sources/ViewerController+SeriesTransforms.swift')
flip = method(transforms, '    func flip(_ step: SeriesReorientation.Step) {')
rotate = method(transforms, '    func rotate(_ constant: Int32) {')
if any(not re.search(r'for dcm in stacks\.joined\(\) \{.*?dcm\.setOrientationDouble\(&o\)', body, re.S) for body in (flip, rotate)) or \
        'DataSetTransform(stacks: (0..<max(Int(horos_maxMovieIndex), 0)).map { horos_pixArray($0) })' not in transforms:
    failures.append('premise: the 2D viewer\'s flips and rotations change the orientation of every slice of every time point')
orientation = read('Horos/Sources/ViewerController+Orientation.swift')
if not (-1 < orientation.find('succeed = processReslice(') < orientation.find('case .flipVertically: vertFlipDataSet(self)')):
    failures.append('premise: a change of plane turns the slices of its reslice, not the former ones')
gantry = method(read('Horos/Sources/ViewerController+GantryTilt.swift'), '    func correct(onto modelIndex: Int? = nil, progress: () -> Void) -> Bool {')
if not gantry or 'setOrigin' not in gantry or 'setOrientation' in gantry:
    failures.append('premise: the gantry tilt correction moves the slices\' origins, not their orientation')
if not re.search(r'horos_loadedFileRevision = nil\s*if horos_fImage != nil, let path = srcFile \{\s*'
                 r'horos_loadedFileRevision = FileRevision\(path: path\)', read('Horos/Sources/DCMPix+Loading.swift')):
    failures.append('premise: a slice records the file it was decoded from, when the file is there')

# The key: the window's own slices decide, not the 2D viewer's post-processing.
keyboard = read('Horos/Sources/VRView+Keyboard.swift')
cut = re.search(r'&& currentTool == \.t3DCut \{(?P<body>.*?)\n        \} else if isDeleteKey\(c\) && currentTool == \.t3Dpoint', keyboard, re.S)
body = re.sub(r'//[^\n]*', '', cut['body']) if cut else ''
if not re.search(r'\} else if c == NSTabCharacter, let refusal = horos_controller\?\.horosScissorRestoreRefusal\(\) \{\s*'
                 r'HorosAlertPanel\.run\(title: NSLocalizedString\("Restore", comment: ""\), message: refusal,', body) or \
        'postprocessed()' in body:
    failures.append('3D Cut, Tab: the window says whether its own slices can be restored, the 2D viewer is not asked')

controller = read_controller()
readable = method(controller, '    final func horosSlicesReadableFromFiles() -> Bool {')
if 'horosSlicesFromFiles &&' not in readable or '$0.srcFile != nil && $0.loadedFileMatchesDisk()' not in readable:
    failures.append('-horosSlicesReadableFromFiles: read from their files at opening, every file unchanged since')
adopt = method(controller, '    private final func adoptVolume(')
if not (-1 < adopt.find('pixLists[0] = pix') < adopt.find('horosRecordSliceGeometry()') < adopt.find('finishInit(')):
    failures.append('the window records the geometry of its slices when it opens')
revert = method(controller, '    public final func revertSeries(_ sender: Any!) {')
if 'horosRecordSliceGeometry()' not in method(controller, '    final func horosVolumeWasReadFromFiles(tiltGone: Bool) {'):
    failures.append('Revert Series: slices read again from their files have their files\' geometry, recorded again')
if len(re.findall(r'^\s*(?:self\.)?horosSliceGeometryAsRead = ', controller, re.M)) != 1:
    failures.append('the geometry of the slices as read is recorded in one place (-horosRecordSliceGeometry)')

# The window's rule and what it asks of its slices, as written, between
# stand-ins for its 2D viewer, whether that viewer shows its slices, and the
# slices (their files, the record of the file each was decoded from, their
# geometry).
HARNESS = r'''
import Foundation
final class FileRevision {
    nonisolated(unsafe) static var existing: Set<String> = []
    init?(path: String) { if !FileRevision.existing.contains(path) { return nil } }
}
final class ViewerController {
    var processed = false
    func postprocessed() -> Bool { processed }
}
final class DCMPix: NSObject {
    var srcFile: String!
    var orientation: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    var pwidth = 4
    var pheight = 3
    var revision: AnyObject?
    var matchesDisk = true
    init(_ path: String?) {
        srcFile = path
        revision = path.map { $0 as NSString }
    }
    func orientationDouble(_ c: UnsafeMutablePointer<Double>!) { for i in 0..<9 { c[i] = orientation[i] } }
    func loadedFileRevision() -> Any! { revision }
    // Decoded slices: no record is not to be trusted.
    func loadedFileMatchesDisk() -> Bool { revision == nil ? false : matchesDisk }
}
final class VRController {
    var viewer2DStorage: ViewerController?
    var horosSlicesFromFiles = false
    var horosSliceGeometryAsRead: [Double] = []
    var pixLists = [NSMutableArray?](repeating: nil, count: 4)
    var maxMovieIndex: Int16 = 0
    var shows = false
    func horosViewerShowsSeries() -> Bool { shows }
%s
}
func slices(_ time: Int, orientation: [Double], width: Int) -> [DCMPix] {
    (0..<3).map {
        let pix = DCMPix("/series/\(time)/\($0).dcm")
        pix.orientation = orientation
        pix.pwidth = width
        return pix
    }
}
/// A window as it opens: its slices read from their files, one or two times.
func window(viewer: Bool = true, postprocessed: Bool = false, shows: Bool, fromFiles: Bool = true, times: Int = 1,
            orientation: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1], width: Int = 4) -> VRController {
    let window = VRController()
    if viewer {
        let viewer = ViewerController()
        viewer.processed = postprocessed
        window.viewer2DStorage = viewer
    }
    for time in 0..<times {
        let list = slices(time, orientation: orientation, width: width)
        FileRevision.existing.formUnion(list.compactMap { $0.srcFile })
        window.pixLists[time] = NSMutableArray(array: list)
    }
    window.maxMovieIndex = Int16(times)
    window.shows = shows
    window.horosSlicesFromFiles = fromFiles
    window.horosRecordSliceGeometry()
    return window
}
func each(_ window: VRController, _ change: (DCMPix) -> Void) {
    for i in 0..<Int(window.maxMovieIndex) { for case let pix as DCMPix in window.pixLists[i] ?? [] { change(pix) } }
}
func pix(_ window: VRController, _ time: Int, _ index: Int) -> DCMPix { window.pixLists[time]![index] as! DCMPix }
let post = "%s"
let files = "%s"
var w: VRController

// No 2D viewer: not refused, as before.
precondition(window(viewer: false, shows: false, fromFiles: false).horosScissorRestoreRefusal() == nil)
// The 2D viewer shows the window's slices as read from their files: restored, as before.
precondition(window(shows: true).horosScissorRestoreRefusal() == nil)
// ...post-processed in place since (a flip): refused, as before.
w = window(shows: true)
w.viewer2DStorage?.processed = true
each(w) { $0.orientation[0] = -1; $0.orientation[1] = 0; $0.orientation[2] = 0 }
precondition(w.horosScissorRestoreRefusal() == post)
// A change of plane: the 2D viewer post-processed, with other slices; the window's are the files'.
precondition(window(postprocessed: true, shows: false).horosScissorRestoreRefusal() == nil)
// A flip in place, then a change of plane: the window's slices stay flipped.
w = window(shows: true)
each(w) { $0.orientation[0] = -1 }
w.viewer2DStorage?.processed = true
w.shows = false
precondition(w.horosScissorRestoreRefusal() == post)
// ...a quarter turn: the orientation and the size change.
w = window(postprocessed: true, shows: false)
each(w) { $0.orientation = [0, 1, 0, -1, 0, 0, 0, 0, 1]; ($0.pwidth, $0.pheight) = ($0.pheight, $0.pwidth) }
precondition(w.horosScissorRestoreRefusal() == post)
// ...flipped twice: the slices are the files' again.
w = window(postprocessed: true, shows: false)
each(w) { $0.orientation[0] = -1 }
each(w) { $0.orientation[0] = 1 }
precondition(w.horosScissorRestoreRefusal() == nil)
// ...read again from their files (Revert Series): their geometry recorded again.
w = window(postprocessed: true, shows: false)
each(w) { $0.orientation[4] = -1 }
w.horosRecordSliceGeometry()
precondition(w.horosScissorRestoreRefusal() == nil)
// A slice with no orientation (none in its file) keeps it when flipped: the 2D
// viewer that shows it says it post-processed it; a quarter turn changes its size.
w = window(shows: true, orientation: [Double](repeating: 0, count: 9), width: 3)
w.viewer2DStorage?.processed = true
precondition(w.horosScissorRestoreRefusal() == post)
w = window(postprocessed: true, shows: false, orientation: [Double](repeating: 0, count: 9))
each(w) { ($0.pwidth, $0.pheight) = ($0.pheight, $0.pwidth) }
precondition(w.horosScissorRestoreRefusal() == post)
// A file rewritten since it was read, after a change of plane or not, at any time.
w = window(postprocessed: true, shows: false)
pix(w, 0, 1).matchesDisk = false
precondition(w.horosScissorRestoreRefusal() == files)
w = window(shows: true, times: 2)
pix(w, 1, 2).matchesDisk = false
precondition(w.horosScissorRestoreRefusal() == files)
// A file removed, or missing when its slice was read (no record of it).
w = window(postprocessed: true, shows: false)
FileRevision.existing.remove(pix(w, 0, 0).srcFile)
pix(w, 0, 0).matchesDisk = false
precondition(w.horosScissorRestoreRefusal() == files)
w = window(shows: true)
FileRevision.existing.remove(pix(w, 0, 2).srcFile)
pix(w, 0, 2).revision = nil
precondition(w.horosScissorRestoreRefusal() == files)
// A slice made in memory: no file, or a file it was not decoded from.
w = window(shows: true)
pix(w, 0, 1).srcFile = nil
precondition(w.horosScissorRestoreRefusal() == post)
w = window(postprocessed: true, shows: false, times: 2)
pix(w, 1, 0).revision = nil
precondition(w.horosScissorRestoreRefusal() == post)
// The window opened from a post-processed 2D viewer, before or after a change of plane.
precondition(window(postprocessed: true, shows: true, fromFiles: false).horosScissorRestoreRefusal() == post)
precondition(window(shows: false, fromFiles: false).horosScissorRestoreRefusal() == post)
print("rule ok")
'''
NAMES = ('horosSlicesReadableFromFiles', 'horosSlicesCameFromFiles', 'horosSliceGeometry',
         'horosRecordSliceGeometry', 'horosSlicesKeepGeometryAsRead', 'horosScissorRestoreRefusal')
members = [re.search(r'\n    (?:final |static )func ' + name + r'\(.*?\n    \}\n', controller, re.S) for name in NAMES]
if not all(members):
    failures.append('the window must have a rule for the 3D Cut restore (-horosScissorRestoreRefusal) '
                    'and what it asks of its slices: ' + ', '.join(n for n, m in zip(NAMES, members) if not m))
else:
    with tempfile.TemporaryDirectory(prefix='horos-vr-scissor-restore-') as directory:
        p = Path(directory)
        (p / 'main.swift').write_text(HARNESS % (''.join(m.group(0) for m in members), POSTPROCESSED, FILES_CHANGED))
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(p / 'main.swift'), '-o', str(p / 'rule')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('-horosScissorRestoreRefusal does not compile on its own: ' + built.stderr.strip()[:600])
        elif subprocess.run([str(p / 'rule')], capture_output=True).returncode != 0:
            failures.append('-horosScissorRestoreRefusal: not refused without a 2D viewer, after a change of plane '
                            '(the window\'s slices from their unchanged files, as read) or while the 2D viewer shows them as read; '
                            'refused as post-processed when the window opened so, the 2D viewer changed or turned them in place '
                            'since, or a slice was made in memory, as files changed when one was removed or rewritten')

# The new text, translated in the twelve catalogs; the old one still there.
for language in LANGUAGES:
    strings = catalog(language)
    if POSTPROCESSED not in strings:
        failures.append(f'{language}: the post-processed refusal is still used')
    value = strings.get(FILES_CHANGED)
    if not value:
        failures.append(f'{language}: no text for the refusal of changed files')
    elif language != 'en' and value == FILES_CHANGED:
        failures.append(f'{language}: the refusal of changed files is not translated')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: after a change of plane the VR window\'s 3D Cut restore (Tab) reads its own slices from their files; with '
      'a 2D viewer it is refused only for slices post-processed (at opening, in place by the 2D viewer showing them, '
      'turned in place before a change of plane, made in memory) or with a file removed or rewritten, and says which')
