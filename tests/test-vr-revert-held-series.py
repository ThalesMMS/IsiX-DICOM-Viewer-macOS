#!/usr/bin/env python3
"""Revert Series in a VR window whose 2D viewer changed plane reads the window's slices from their files.

A 2D viewer that changes plane (axial, coronal, sagittal) while a VR window is
open on its series gives itself the resliced slices and lets the VR window
keep the former ones (PreviousSeriesHold). The VR window's Revert Series asked
the 2D viewer for a revert of slices it no longer showed: nothing happened,
then (since the presentation was restored) an alert said the cuts stayed.

The window now reads the slices it kept from their files itself, when they
came from their files: its 2D viewer was not post-processed when it opened,
and every slice has a file, still the one it was decoded from (a file removed
or rewritten since would give nothing or other pixels). Each slice drops its
pixels and is decoded again into the volume the slices share, as the 2D
viewer's revert does, so the scissors, the bone removal, the filters and the
gantry tilt correction go. The slices are decoded as a 2D viewer's load
decodes them: one after the other when the series is not compressed (a file
of several frames is parsed once), on the loader's decoders otherwise. What
the files do not give back is kept: the slice interval (the formats that are
not DICOM set theirs again from their headers), and for a PET slice converted
to SUV its factor, by which it is converted again, and its stored window
level, which the file has in its own units. The windows on the volume draw it
again, the window's tilt mark goes, and no alert shows. The 2D viewer still
reads the slices it shows as read from their files; otherwise the copy kept
before the first filter brings the volume back, and the window warns when a
change stays: a cut made, or a filter applied, while there was no copy (a cut
before the first filter, which that copy holds), or the tilt correction. That
record follows -undo:, which takes back the last change only. A volume read
again forgets the undo copy, which -undo: would otherwise write over it.

The choice of the source is IsiXImaging's VolumeRevertSource, compiled here as
it is and driven with the window's cases; its own tests are in the package.
Read from the sources: the change of plane that keeps the former series for
the other windows, the 2D viewer's revert of the slices it shows only, a
slice's revert that is decoded into the shared volume again, and the window's
record at opening, its reading of the files and its Revert Series.
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
RULE = 'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeRevertSource.swift'


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    file = root / path
    return file.read_text() if file.exists() else ''


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


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []

# The scenario: the change of plane keeps the former series for the other
# windows, and the 2D viewer reverts only the slices it shows.
reslice = method(read('Horos/Sources/ViewerController+Reslice.swift'), '    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {')
if 'keepingPreviousSeriesForOtherWindows { changeImageData(' not in reslice or 'setPostprocessed(true)' not in reslice:
    failures.append('premise: a change of plane in place lets the other windows keep the former series')
load = read('Horos/Sources/ViewerSeriesLoad.swift')
hold = method(load, '    private func holdSeriesForOtherWindows() -> [AnyObject] {')
if 'viewer.horos_pixList(at: movie)' not in hold or 'PreviousSeriesHold.hold(series, releasedBy: viewer, for: window)' not in hold:
    failures.append('premise: the windows on the volume hold the former slices')
navigation = read('Horos/Sources/ViewerController+StudyNavigation.swift')
asked = method(navigation, '    func revert(asked note: Any?) {')
if 'where series === viewer.horos_pixList(at: x)' not in asked:
    failures.append('premise: the 2D viewer reverts only the slices it shows')
viewer_revert = method(navigation, '    func revert() -> Bool {')
if 'for pix in viewer.horos_pixArray(x) { pix.revert() }' not in viewer_revert or 'GantryTiltPolicy.clearCorrection(of: viewer)' not in viewer_revert:
    failures.append('premise: the 2D viewer\'s revert drops each slice\'s pixels, and the correction it records')
refusal = method(navigation, '    func revertUnlessPostprocessed() {')
if 'if viewer.horos_postprocessed {' not in refusal or 'You cannot revert it.' not in refusal:
    failures.append('premise: the 2D viewer refuses with an alert to revert a post-processed series')
# A slice dropped by -revert keeps the volume it reads into: the next load
# decodes the file there again. A resliced slice is a copy of the first one,
# file included, which is why only slices of the files may be read again.
pix_loading = read('Horos/Sources/DCMPix+Loading.swift')
dropped = method(pix_loading, '    final func revertLoading(reloadingAnnotations reloadAnnotations: Bool) {')
if 'if self.horos_fExternalOwnedImage == nil, let image = self.horos_fImage { free(image) }' not in dropped or \
        'self.horos_fImage = nil' not in dropped or 'horos_fExternalOwnedImage = nil' in dropped:
    failures.append('premise: a slice\'s revert drops its pixels and keeps the volume it is decoded into')
if 'load.externalImage = horos_fExternalOwnedImage' not in read('Horos/Sources/DCMPix+FrameLoading.swift'):
    failures.append('premise: a slice is decoded into the volume it was given')
copied = read('Horos/Sources/ViewerSeriesReslice.swift')
if 'let curPix = unsafeDowncast(firstPix.copy() as AnyObject, to: DCMPix.self)' not in copied:
    failures.append('premise: a resliced slice is a copy of the first slice (and of its file)')
if 'SUVConverted = false' not in dropped:
    failures.append('premise: a slice read again is no longer converted to SUV')
if 'self.horos_loadedFileRevision = nil' not in dropped:
    failures.append('premise: a slice\'s revert forgets the file it was decoded from')
loaded = method(pix_loading, '    final func loadIfNeeded() {')
if 'horos_loadedFileRevision = FileRevision(path: path)' not in loaded:
    failures.append('premise: a slice records the file as it was when it was decoded')
if 'return revision.matchesDisk()' not in method(read('Horos/Sources/DCMPix.swift'), '    func loadedFileMatchesDisk() -> Bool {'):
    failures.append('premise: a slice says whether its file is still the one it was decoded from')
if 'horos_sliceInterval = Double(pixdim[3])' not in read('Horos/Sources/DCMPix+NonDICOM.swift'):
    failures.append('premise: a slice of a format that is not DICOM sets its slice interval again from its header')
if 'horos_savedWL = load.storedWindowLevel' not in read('Horos/Sources/DCMPix+ImageAttributes.swift'):
    failures.append('premise: a DICOM slice read again takes its stored window level from its file')
if 'p.savedWL = scaling.scaled(p.savedWL)' not in read('Horos/Sources/ViewerWindowLevel.swift'):
    failures.append('premise: the conversion to SUV gives the stored window level in SUV')
loader = read('Horos/Sources/SeriesImageLoader.swift')
decoding = re.search(r'\nenum SeriesDecoding \{.*?\n\}\n', loader, re.S)
decoding = decoding.group(0) if decoding else ''
if not re.search(r'if isDecodedConcurrently\(slices\.first\?\.srcFile\) \{\s*decodeConcurrently\(slices, progress: progress\)\s*\} else \{\s*'
                 r'decodeInOrder\(slices, progress: progress\)', decoding) or \
        'if compressed.boolValue && BrowserController.isItCD(file) {' not in decoding or \
        'SeriesLoadRules.compressedDecoders(processors: ProcessInfo.processInfo.processorCount)' not in decoding:
    failures.append('SeriesDecoding: an uncompressed series, or one on a disc, in order, a compressed one on the loader\'s decoders')
if 'SeriesDecoding.decode(request.frames.flatMap { $0 }, progress: progress)' not in loader:
    failures.append('a 2D viewer\'s load decodes its slices by SeriesDecoding')

controller = read_controller()
undo = method(controller, '    public override final func undo(_ sender: Any!) {')
if 'if let undo = undodata[i]' not in undo or 'multiThreadedImageConvert("16UToF"' not in undo:
    failures.append('premise: -undo: writes the undo copy over the volume')

# The window records at opening whether its slices are the files' own.
adopt = method(controller, '    private final func adoptVolume(')
if 'horosSlicesFromFiles = vC.map { !$0.postprocessed() } ?? false' not in adopt or \
        adopt.find('horosSlicesFromFiles') > adopt.find('finishInit('):
    failures.append('the window must record at opening whether its 2D viewer was post-processed')

shows = method(controller, '    final func horosViewerShowsSeries() -> Bool {')
for part in ['guard let viewer = viewer2DStorage else { return false }', 'pixLists[Int(curMovieIndexStorage)]',
             '(0..<max(viewer.horos_movieCount, 0)).contains { viewer.horos_pixList(at: $0) === shown }']:
    if part not in shows:
        failures.append(f'-horosViewerShowsSeries: {part}')

readable = method(controller, '    final func horosSlicesReadableFromFiles() -> Bool {')
if 'horosSlicesFromFiles &&' not in readable or \
        'slices.allSatisfy { $0.srcFile != nil && $0.loadedFileMatchesDisk() }' not in readable or \
        '(0..<Int(maxMovieIndex))' not in readable:
    failures.append('-horosSlicesReadableFromFiles: slices read from their files at opening, each of every time with '
                    'its file, still the one it was decoded from')

reading = method(controller, '    final func horosReadSlicesFromFiles() {')
order = [reading.find(part) for part in [
    'let slices = (0..<Int(maxMovieIndex)).flatMap { (pixLists[$0] as? [DCMPix]) ?? [] }',
    'let kept = slices.map(VRSliceKeptState.init)',
    'for pix in slices { pix.revert() }',
    'SeriesDecoding.decode(slices)',
    'for (pix, state) in zip(slices, kept) { state.restore(into: pix) }',
    'if !GantryTiltSlices(slices: time).correct(progress: {}) { tiltGone = true }',
    'for (pix, state) in zip(slices, kept) { pix.sliceInterval = state.sliceInterval }',
    'horosAnnounceVolumes(readFromFiles: tiltGone)']]
if 'let corrected = horosTiltCorrection() != nil' not in reading or not re.search(r'if corrected \{\s*for i in 0\.\.<Int\(maxMovieIndex\)', reading):
    failures.append('-horosReadSlicesFromFiles: a gantry tilt corrected before is corrected again, every time of the volume')
if -1 in order or order != sorted(order):
    failures.append('-horosReadSlicesFromFiles: every slice of every time dropped, decoded again into the volume, '
                    'given back what its file does not give, then the windows on the volume told')

if 'checkLoad()' in controller or 'compressedDecoders' in controller:
    failures.append('the window decodes its slices by SeriesDecoding, as a 2D viewer\'s load does, and by no rule of its own')

kept = re.search(r'private struct VRSliceKeptState \{.*?\n\}\n', controller, re.S)
kept = re.sub(r'//[^\n]*', '', kept.group(0)) if kept else ''
for part in ['sliceInterval = pix.sliceInterval',
             'suv = pix.suvConverted ? (factor: pix.factorPET2SUV, level: pix.savedWL, width: pix.savedWW) : nil',
             'pix.sliceInterval = sliceInterval',
             'PETSUVConversion.scale(pixels, count: pix.pheight * pix.pwidth, by: suv.factor)',
             'pix.maxValueOfSeries = 0', 'pix.minValueOfSeries = 0']:
    if part not in kept:
        failures.append(f'VRSliceKeptState: {part}')
if not re.search(r'pix\.suvConverted = true\s*pix\.factorPET2SUV = suv\.factor\s*'
                 r'pix\.savedWL = suv\.level\s*pix\.savedWW = suv\.width', kept):
    failures.append('VRSliceKeptState: a slice converted again says so, with its factor and its window level in SUV')

announce = method(controller, '    final func horosAnnounceVolumes(readFromFiles tiltGone: Bool? = nil) {')
if 'for i in 0..<Int(maxMovieIndex)' not in announce or '.OsirixUpdateVolumeData, object: pixLists[i], userInfo: info' not in announce:
    failures.append('-horosAnnounceVolumes: every time of the volume, to the windows on it')

tilt = method(controller, '    final func horosTiltCorrection() -> NSNumber? {')
if 'horosVolumeReadAgain ? nil : GantryTiltPolicy.correctedDegrees(of: viewer2DStorage)' not in tilt:
    failures.append('-horosTiltCorrection: none once the window read its slices again')
mark = method(read('Horos/Sources/VRView+Volume.swift'), '    func tiltMarkText() -> String? {')
if 'if horos_controller?.horosVolumeReadAgain == true { return nil }' not in mark:
    failures.append('the VR view\'s tilt mark must go once the window read its slices again')

forget = method(controller, '    final func horosForgetUndo() {')
if not re.search(r'for i in 0\.\.<Int\(maxMovieIndex\) \{\s*free\(undodata\[i\]\)\s*undodata\[i\] = nil\s*\}', forget):
    failures.append('-horosForgetUndo: frees every frame\'s undo copy')

prepare = method(controller, '    public final func prepareUndo() {')
if not re.search(r'public final func prepareUndo\(\) \{\s*horosChangedWithoutFilterCopyBeforeUndoCopy = horosChangedWithoutFilterCopy\s*'
                 r'(?:horosCutAfterFilterBeforeUndoCopy = [^\n]*\s*)?if !horosApplyingFilter \{', prepare):
    failures.append('-prepareUndo: keeps the record of changes no copy takes back as it was before this change')
if not re.search(r'if let undo = undodata\[i\][^\n]*\{\s*horosChangedWithoutFilterCopy = horosChangedWithoutFilterCopyBeforeUndoCopy',
                 undo):
    failures.append('-undo: the record of changes no copy takes back goes back with the change it takes back')
if not re.search(r'if !horosApplyingFilter \{\s*horosFilterRestore\?\.noteCut\(\)\s*'
                 r'if horosFilterRestore == nil \{ horosChangedWithoutFilterCopy = true \}\s*\}', prepare):
    failures.append('-prepareUndo: a cut with no copy before a filter is one that copy cannot take back')

revert = method(controller, '    public final func revertSeries(_ sender: Any!) {')
if not re.search(r'let source = VolumeRevertSource\(viewerShowsSlices: horosViewerShowsSeries\(\),\s*'
                 r'viewerPostprocessed: viewer2DStorage\?\.postprocessed\(\) == true,\s*'
                 r'slicesFromFiles: horosSlicesReadableFromFiles\(\),\s*'
                 r'hasFilterCopy: horosFilterRestore != nil\)', revert):
    failures.append('Revert Series: the source from the 2D viewer, the slices\' files and the copy (VolumeRevertSource)')
cases = {name: body for name, body in re.findall(r'case \.(\w+):(.*?)(?=\n        case |\n        \})', revert, re.S)}
if '.OsirixRevertSeries, object: pixLists[Int(curMovieIndexStorage)]' not in cases.get('viewerReadsFiles', ''):
    failures.append('Revert Series: the 2D viewer that shows the slices unprocessed reads them from the files')
if 'horosReadSlicesFromFiles()' not in cases.get('windowReadsFiles', ''):
    failures.append('Revert Series: after a change of plane the window reads the slices it kept from their files')
if 'horosRestoreVolumeBeforeFilter()' not in cases.get('filterCopy', ''):
    failures.append('Revert Series: otherwise the copy before the first filter')
if 'break' not in cases.get('nothing', '') or len(cases) != 4:
    failures.append('Revert Series: without a source nothing is asked')
if 'OsirixRevertSeries' in ''.join(body for name, body in cases.items() if name != 'viewerReadsFiles'):
    failures.append('Revert Series: asks for a revert only from a 2D viewer that shows the slices unprocessed')
forgets = method(controller, '    final func horosVolumeWasReadFromFiles(tiltGone: Bool) {')
if not all(line in forgets for line in ('horosFilterRestore = nil', 'appliedConvolutionFilters?.removeAllObjects()',
                                        'horosChangedWithoutFilterCopy = false', 'horosRecordSliceGeometry()',
                                        'horosForgetUndo()', 'horosVolumeReadAgain = tiltGone')):
    failures.append('a volume read from its files again: every window on it forgets its filters, its copies and its undo')
if 'horosAnnounceVolumes(readFromFiles: tiltGone)' not in method(controller, '    final func horosReadSlicesFromFiles() {'):
    failures.append('the window that reads its slices again tells the windows on the volume that it did')
if not re.search(r'if source != \.nothing \{ horosForgetUndo\(\) \}\s*'
                 r'let changesStay = source\.keepsChanges\(changedWithoutCopy: horosChangedWithoutFilterCopy,\s*'
                 r'tiltCorrected: horosTiltCorrection\(\) != nil\)', revert):
    failures.append('Revert Series: a volume read again has no filter, cut nor undo copy left; the warning only for a change that stays')
if 'You cannot revert it.' in revert or revert.find('HorosAlertPanel') < revert.find('restoreOpeningPresentation()'):
    failures.append('Revert Series: no "cannot revert" alert, and none before the presentation is restored')
if not re.search(r'if changesStay \{\s*HorosAlertPanel\.run\(title: NSLocalizedString\("Revert Series", comment: ""\),\s*'
                 r'message: NSLocalizedString\("The color tables, the window level and the shading were restored, but not the volume: ',
                 revert):
    failures.append('Revert Series: after the presentation, a warning only when the volume keeps a change')

# The rule itself, compiled as it is: the window's cases.
DRIVER = r'''
typealias S = VolumeRevertSource
func source(_ shows: Bool, _ postprocessed: Bool, _ fromFiles: Bool, _ copy: Bool) -> S {
    S(viewerShowsSlices: shows, viewerPostprocessed: postprocessed, slicesFromFiles: fromFiles, hasFilterCopy: copy)
}
// Axial, the 2D viewer showing the window's slices: it reads them.
precondition(source(true, false, true, true) == .viewerReadsFiles)
// A change of plane: the window reads the slices it kept, filtered or not.
precondition(source(false, true, true, false) == .windowReadsFiles)
precondition(source(false, true, true, true) == .windowReadsFiles)
// A window opened on a resliced series: never the files, which hold others.
precondition(source(true, true, false, true) == .filterCopy)
precondition(source(false, true, false, false) == .nothing)
// Read from the files, nothing stays; from the copy, a cut before it or the tilt.
precondition(!S.windowReadsFiles.keepsChanges(changedWithoutCopy: true, tiltCorrected: true))
precondition(S.filterCopy.keepsChanges(changedWithoutCopy: true, tiltCorrected: false))
precondition(!S.filterCopy.keepsChanges(changedWithoutCopy: false, tiltCorrected: false))
precondition(S.nothing.keepsChanges(changedWithoutCopy: false, tiltCorrected: true))
print("rule ok")
'''
rule = read(RULE)
if not rule:
    failures.append('the choice of the source must be IsiXImaging\'s VolumeRevertSource')
else:
    with tempfile.TemporaryDirectory(prefix='horos-vr-revert-') as directory:
        p = Path(directory)
        (p / 'VolumeRevertSource.swift').write_text(rule)
        (p / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(p / 'VolumeRevertSource.swift'),
                                str(p / 'main.swift'), '-o', str(p / 'rule')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('VolumeRevertSource does not compile: ' + built.stderr.strip()[:400])
        elif subprocess.run([str(p / 'rule')], capture_output=True).returncode != 0:
            failures.append('VolumeRevertSource: the window\'s cases do not give their sources')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: after a change of plane Revert Series reads the window\'s slices from their unchanged files (pixels '
      'dropped and decoded into the shared volume as the loader decodes them, slice interval and SUV with its window '
      'level kept, tilt mark gone, no alert); the 2D viewer still reads the slices it shows; otherwise the filter copy '
      'or nothing, with a warning only for a change that stays, which -undo: takes back')
