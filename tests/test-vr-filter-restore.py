#!/usr/bin/env python3
"""A convolution filter applied in the 3D window does not stay in the 2D series.

The 3D window renders the float buffer of its 2D viewer, and a filter is
written into that buffer. VRFilterRestore.swift is compiled as it is and
driven as VRController drives it:
- copy: two volumes (two movie frames of a 4D series) are copied, overwritten
  as a filter would, and written back byte for byte; a volume whose size
  changed since, or one past those copied, is left alone.
- close: no copy or a closing 2D viewer does nothing; only filters restore;
  a cut after the first filter asks; a cut before it (no copy yet) is not
  recorded.
- wiring: VRController keeps the copy before the 2D buffer is filtered (menu
  and presets), records cuts only from callers other than a filter, settles
  the filters when its window closes, never when the 2D viewer closes, and
  a post-processed series reverts from the copy.

`<git revision>` as an optional argument reads VRController.mm from that
revision, the negative control.
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

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

if revision:
    controller = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/VRController.mm']).decode('latin1')
else:
    controller = (root / 'Horos/Sources/VRController.mm').read_bytes().decode('latin1')


def method(signature):
    match = re.search(re.escape(signature) + r'.*?\n}\n', controller, re.S)
    return match.group(0) if match else ''


failures = []
apply = method('- (IBAction) applyConvolution:(id) sender')
if not apply or apply.find('horosKeepVolumeBeforeFilter') < 0 or apply.find('horosKeepVolumeBeforeFilter') > apply.find('applyConvolutionOnSource'):
    failures.append('applyConvolution: must keep the copy before it filters the 2D buffer')
if '[sender title]' in apply[apply.find('applyConvolutionOnSource'):]:
    failures.append('applyConvolution: must read the title before filtering rebuilds the menu that holds its item')
if 'horosApplyingFilter = YES' not in apply:
    failures.append('applyConvolution: must not count its own -prepareUndo as a cut')
preset = re.search(r'NSArray \*convolutionFilters = \[preset objectForKey:@"convolutionFilters"\];.*?applyConvolutionOnSource', controller, re.S)
if not preset or 'horosKeepVolumeBeforeFilter' not in preset.group(0):
    failures.append('a preset with filters must keep the copy before it filters the 2D buffer')
undo = method('- (void) prepareUndo')
if 'noteCut' not in undo or 'horosApplyingFilter == NO' not in undo:
    failures.append('-prepareUndo must record a cut, except for a filter')
close = method('- (void)windowWillClose:(NSNotification *)notification')
if 'horosSettleFiltersOnClose' not in close:
    failures.append('-windowWillClose: must settle the filters')
viewer = method('- (void) CloseViewerNotification: (NSNotification*) note')
if viewer.find('horosViewerClosing = YES') < 0 or viewer.find('horosViewerClosing = YES') > viewer.find('[[self window] close]'):
    failures.append('the 2D viewer closing must be known before the 3D window closes')
revert = method('-(void) revertSeries:(id) sender')
if 'postprocessed' not in revert or 'horosRestoreVolumeBeforeFilter' not in revert:
    failures.append('Revert Series must restore the copy of a post-processed series')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

DRIVER = r'''
import Foundation

func volume(_ values: [Float]) -> NSMutableData {
    let data = NSMutableData(length: values.count * MemoryLayout<Float>.size)!
    values.withUnsafeBytes { data.replaceBytes(in: NSRange(location: 0, length: data.length), withBytes: $0.baseAddress!) }
    return data
}
func floats(_ data: NSData) -> [Float] {
    Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: data.length / 4))
}
func filter(_ data: NSData) {
    let p = UnsafeMutableRawPointer(mutating: data.bytes).assumingMemoryBound(to: Float.self)
    for i in 0..<(data.length / 4) { p[i] = p[i] * 0.5 + 1 }
}

// copy and restore, two movie frames, exact down to a subnormal
let first: [Float] = [-1024, 0, 3071.5, .leastNonzeroMagnitude, 42, 7]
let second: [Float] = [1, 2, 3, 4, 5, 6]
let a = volume(first), b = volume(second)
let restore = VRFilterRestore(volumes: [a, b])!
precondition(restore.volumeCount == 2 && !restore.cutAfterFilter)
filter(a); filter(b)
precondition(floats(a) != first, "the filter must change the volume")
precondition(restore.restore(into: [a, b]) == 2)
precondition(floats(a).map(\.bitPattern) == first.map(\.bitPattern), "frame 1 not restored: \(floats(a))")
precondition(floats(b) == second, "frame 2 not restored")

// a volume whose size changed, and one past those copied, are left alone
let resized = volume([9, 9]), extra = volume([8, 8, 8])
precondition(restore.restore(into: [resized, a, extra]) == 1)
precondition(floats(resized) == [9, 9] && floats(extra) == [8, 8, 8])

restore.noteCut()
precondition(restore.cutAfterFilter)

// close decisions
typealias R = VRFilterRestore
precondition(R.closeAction(hasCopy: false, cutAfterFilter: false, viewerClosing: false) == .none)
precondition(R.closeAction(hasCopy: false, cutAfterFilter: true, viewerClosing: false) == .none)
precondition(R.closeAction(hasCopy: true, cutAfterFilter: false, viewerClosing: false) == .restore)
precondition(R.closeAction(hasCopy: true, cutAfterFilter: true, viewerClosing: false) == .ask)
precondition(R.closeAction(hasCopy: true, cutAfterFilter: false, viewerClosing: true) == .none)
precondition(R.closeAction(hasCopy: true, cutAfterFilter: true, viewerClosing: true) == .none)

// an empty list (no volume yet) keeps nothing and restores nothing
let empty = VRFilterRestore(volumes: [])!
precondition(empty.volumeCount == 0 && empty.restore(into: [a]) == 0)
print("PASS: the copy restores both frames exactly, leaves resized or extra volumes alone; close restores, asks after a cut, and does nothing without a copy or when the 2D viewer closes")
'''

with tempfile.TemporaryDirectory(prefix='horos-vr-filter-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-O',
                    str(root / 'Horos/Sources/VRFilterRestore.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
