#!/usr/bin/env python3
"""The endoscopy takes its camera's place, its basic step and its focal handle from EndoscopyNavigation.

Three places of the endoscopy read positions their own way:

* -setCameraPosition:focalPoint: gave a point of the fly path the place of the
  nearest slice. The path's points stand between slices, at the centre of a
  resampled voxel, so the camera stood half a slice off the path drawn. The
  point's place is now between the places the two slices give it
  (EndoscopyNavigation.slices, .blend).
* The basic mode's step read the slice from the resliced view's cross as
  count - 0.5 - row and the direction as minus the focal shift, which is the
  order of a stack whose sign is positive only. With the other order (a
  negative slice interval, or Flip Volume) it searched and moved in the
  mirrored slice. Both come from the stack's sign (.slice(atCrossRow:),
  .sliceDirection(ofRowShift:)), as the views' own overlays do.
* The handle of the focal point: a drag stored the shift in screen points and
  a move of the camera stored it in pixels of the image, and the handle was
  drawn and caught as screen points. The shift is in pixels of the image
  everywhere, and the handle is drawn at the view's scale (.focalHandle).

The rules themselves are tested in the module (IsiXImagingTests,
EndoscopyNavigationTests); this test reads their uses.

    python3 tests/test-endoscopy-navigation-wiring.py [<git revision>]
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True, check=True).stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []
viewer = read('Horos/Sources/EndoscopyViewer.swift')
view = read('Horos/Sources/EndoscopyMPRView.swift')

camera = block(viewer, 'public dynamic func setCameraPosition(_ position: OSIVoxel!, focalPoint: OSIVoxel!)')
if not re.search(r'EndoscopyNavigation\.slices\(around: Double\(voxel\.z\), count: sliceCount\).*?'
                 r'EndoscopyNavigation\.blend\(lower, upper, at: at\.fraction\)', camera, re.S) \
        or 'pos = patientPoint(position)' not in camera or 'fp = patientPoint(focalPoint)' not in camera:
    failures.append('the camera takes a path point at the place of one slice, not between the two slices it lies between')
if '.rounded()' in camera:
    failures.append('the camera still rounds a path point to the nearest slice')

step = block(viewer, 'public dynamic func flyThruAssistantGoForward(_ note: Notification?)')
if not re.search(r'let sign = mprController\?\.sign\(\) \?\? 0\s*pt\.z = EndoscopyNavigation\.slice\(atCrossRow: .*?sign: sign\)', step, re.S):
    failures.append('the basic step reads its slice from the cross as if every stack had the same order')
if not re.search(r'dir\.z = EndoscopyNavigation\.sliceDirection\(ofRowShift: .*?sign: sign\)', step):
    failures.append('the basic step reads its direction along the stack as if every stack had the same order')

handle = 'EndoscopyNavigation.focalHandle(shift: (Float(_focalShiftX), Float(_focalShiftY))'
if handle not in block(view, 'public override dynamic func subDraw(_ aRect: NSRect)'):
    failures.append('the handle of the focal point is drawn from a shift taken for screen points')
if handle not in block(view, 'private func onFocalHandle(_ mouseLocStart: NSPoint) -> Bool'):
    failures.append('the handle of the focal point is caught from a shift taken for screen points')
drag = block(view, 'public override dynamic func mouseDown(with event: NSEvent)')
if not re.search(r'_focalShiftX = cLong\(Double\(mouseLoc\.x\) - Double\(self\.crossPositionX\(\)\)\)\s*'
                 r'_focalShiftY = cLong\(Double\(mouseLoc\.y\) - Double\(self\.crossPositionY\(\)\)\)', drag):
    failures.append('a drag of the handle stores the focal shift in screen points, and a move of the camera in pixels of the image')

flip = block((ROOT / 'Horos/Sources/OrthogonalMPRController.swift').read_text(encoding='utf-8'), 'public dynamic func flipVolume()')
if not (-1 < flip.find('_sign = -_sign') < flip.find('self.reslice(') < flip.find('(_viewer as? EndoscopyViewer)?.setCameraRepresentation()')):
    failures.append('a flip of the volume leaves the endoscopy\'s camera drawn in the views as the former order of the stack put it')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the endoscopy places its camera between the two slices of a path point, steps in the right slice in both orders of the stack, '
      'and keeps the focal shift in pixels of the image for the handle')
