#!/usr/bin/env python3
"""A 3D MPR window whose first plane VTK draws opens without reading a picture that is not there.

A plane of the 3D MPR is resliced by Metal, or, when Metal refuses it, read
from the picture the VTK ray caster rendered last. The first plane of every
opening is asked before its camera is set ("The plane axes are collinear"),
and a volume a 3D texture cannot hold is refused for good: both read the ray
caster. The opening skips the render, so a ray caster that had rendered
nothing yet had no picture, and the reading forced one out of nil: the
application went down on opening the window. What is checked:

- the reading of the ray caster's picture answers nil when there is none,
  which its callers take for "no picture", and forces nothing;
- a plane VTK draws is rendered before it is read when the ray caster has no
  picture yet, during the opening too, and as before otherwise;
- the renderer says whether it has a picture through the protocol the MPR
  views talk to it by;
- the reason Metal refused a plane is logged once for each reason, where a
  report can read it.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]


def text(path):
    return (root / path).read_text(encoding='utf-8')


capture = text('Horos/Sources/VRView+Capture.swift')
view = text('Horos/Sources/MPRDCMView.swift')
plane = text('Horos/Sources/MPRDCMView+MetalPlane.swift')
messages = text('Horos/Sources/MPRHostMessages.h')
update = view[view.index('private dynamic func updateViewMPR(onLoading isLoading: Bool'):view.index('public dynamic func updateViewMPR(onLoading isLoading: Bool)')]
render, read = update.find('_vrView?.render()'), update.find('_vrView?.image(inFullDepthWidth:')
checks = [
    ('guard let im = vtk.rayCastImageFused(blendingView) else { return nil }' in capture, 'the reading answers nil without a picture'),
    (not re.search(r'rayCastImageFused\([^)]*\)\s*!(?!=)', capture), 'the picture of the ray caster is not forced out of nil'),
    ('@objc(hasFullDepthPicture) func hasFullDepthPicture() -> Bool' in capture and 'vtk.hasVolumeMapper && vtk.rayCastImageFused(false) != nil' in capture
     and '- (BOOL) hasFullDepthPicture;' in messages, 'the renderer says whether it has a picture to read'),
    ('if isLoading == false || _vrView?.hasFullDepthPicture() != true {\n                    _vrView?.render()' in update,
     'a plane VTK draws is rendered first when there is no picture yet, during the opening too'),
    (0 <= render < read, 'the render comes before the reading'),
    (update.count('_vrView?.render()') == 1, 'one render for a plane'),
    ('if let reason, reason != controller?.metalHost.fallbackReason {' in plane and '%{public}@", reason)' in plane,
     'the reason of a refusal is logged once, readable in a report'),
]
failures = [what for ok, what in checks if not ok]
if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: a plane VTK draws at the opening is rendered before it is read when there is no picture, and a missing picture is nil')
