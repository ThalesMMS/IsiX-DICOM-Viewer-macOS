#!/usr/bin/env python3
"""After a DICOM export, the exported MPR view shows its lines and ROIs again (#846).

Two defects left the exported view of the MPR without its reference lines and
without the ROI drawn on it:
- a screen capture of a DCMView (-getRawPixelsViewWidth:..., with
  removeGraphical) sets the view's stringID to "export" while it draws, and put
  back the former one only if there was one. The MPR views have none, so they
  kept "export", and -[MPRDCMView subDrawRect:] draws nothing for it: no lines,
  no red square. The capture now always puts back the former stringID, nil
  included;
- a batch or a rotation moves the plane of the exported view, and
  -updateViewMPR takes the ROIs out of a view whose plane moves. The export now
  keeps the view's ROIs, and once the cameras are restored and the view shows
  its plane again, puts back those it lost, in that plane's geometry. 2D points
  are not put back: -detect2DPointInThisSlice mirrors them for each plane.
Checked in the sources.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision is None:
        data = (root / path).read_bytes()
    else:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                                       stderr=subprocess.DEVNULL)
    return data.decode('utf-8' if path.endswith('.swift') else 'latin1')


def code(text):
    """Without comments, so that what they recall is not taken for code."""
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


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

# The capture puts back the view's stringID, nil included.
view = code(read('Horos/Sources/DCMView.m'))
capture = block(view, '-(unsigned char*) getRawPixelsViewWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) offset isSigned:(BOOL*) isSigned')
start = capture.find('[self setStringID: @"export"];')
end = capture.find('[self setStringID: str];', start)
if start < 0 or end < 0:
    failures.append('the screen capture no longer sets and puts back the stringID')
else:
    condition = capture[:end].rstrip()
    condition = condition[condition.rfind('if('):]
    if not condition.replace(' ', '').startswith('if(removeGraphical)'):
        failures.append('the screen capture puts back the stringID only if the view had one: '
                        'a view without one keeps "export" and draws as if it still exported')

# The MPR export puts back the ROIs of the exported view.
controller = code(sources.source_text('MPRController') if revision is None
                  else read('Horos/Sources/MPRController.swift'))
export = block(controller, 'public dynamic func endDCMExportSettings(')
saved = export.find('let exportedROIs = ')
exporting = export.find('curExportView?.restoreCamera()')
restored = export.find('self.restoreExportedROIs(exportedROIs, in: curExportView)')
updated = export.find('self.updateViewsAccordingToFrame(nil)')
if saved < 0 or exporting < 0 or saved > exporting:
    failures.append('the export does not keep the ROIs of the exported view before it moves its plane')
if restored < 0 or updated < 0 or restored < updated:
    failures.append('the export does not put back the ROIs of the exported view once it shows its plane again')
helper = block(controller, 'private func restoreExportedROIs(')
for needed, what in [
        ('.t2DPoint', 'leave the 2D points to -detect2DPointInThisSlice'),
        ('indexOfObjectIdentical(to:', 'skip the ROIs the view still has'),
        ('setOriginAndSpacing(', 'give the ROIs the geometry of the plane shown again'),
        ('needsDisplay = true', 'redraw the view')]:
    if needed not in helper:
        failures.append(f'the ROIs put back do not {what}')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the exported MPR view gets back its stringID, and with it its lines, and the ROIs the export took out')
