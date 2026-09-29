#!/usr/bin/env python3
"""MPR 4D time steps refresh ROI intensity caches through Swift, not #227 text."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
# MPRController and MPRDCMView are Swift since #823: they call the Swift helper directly.
controller = sources.source_text('MPRController')
view = sources.source_text('MPRDCMView')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
helper = root / 'Horos/Sources/ROITemporalStatistics.swift'

if not helper.is_file():
    print('FAIL: ROITemporalStatistics.swift is missing', file=sys.stderr)
    sys.exit(1)
if 'ROITemporalStatistics.swift' not in project:
    print('FAIL: project.pbxproj does not compile ROITemporalStatistics.swift', file=sys.stderr)
    sys.exit(1)

start = controller.index('private func setCurMovieIndexValue(_ m: Int32)')
method = controller[start:controller.index('@objc(performMovieAnimation:)', start)]
needed = [
    'ROITemporalStatistics',
    'ROITemporalStatistics.cachedValuesRemainValid(previousTimeIndex:',
    'previousMovieIndex',
    'geometryUnchanged: true',
    'r.recompute()',
    'mprView1',
    'mprView2',
    'mprView3',
    'hiddenVRController?.setMovieFrame',
    'updateViewsAccordingToFrame',
]
missing = [item for item in needed if item not in controller]
if missing:
    print('FAIL: MPRController is missing', ', '.join(missing), file=sys.stderr)
    sys.exit(1)
for item in needed[1:]:
    if item not in method:
        print('FAIL: setCurMovieIndex does not', item, file=sys.stderr)
        sys.exit(1)
if 'stringTex' in method or 'HorosROILabelPresentation' in method:
    print('FAIL: 4D ROI values must not touch the #227/#245 label matrix', file=sys.stderr)
    sys.exit(1)

if 'ROITemporalStatistics.' not in view:
    print('FAIL: MPRDCMView does not reach the Swift ROI statistics helper', file=sys.stderr)
    sys.exit(1)
if 'mustRefreshCachedValuesAfterReconstructedBufferChange' not in view:
    print('FAIL: MPRDCMView does not refresh ROI caches after a reconstructed buffer change', file=sys.stderr)
    sys.exit(1)
if 'r.recompute()' not in view and 'roi.recompute()' not in view:
    print('FAIL: MPRDCMView never invalidates ROI intensity caches', file=sys.stderr)
    sys.exit(1)
if 'stringTex' in view[view.find('mustRefreshCachedValuesAfterReconstructedBufferChange'):
                       view.find('mustRefreshCachedValuesAfterReconstructedBufferChange') + 800]:
    print('FAIL: reconstructed-buffer refresh must not touch string textures', file=sys.stderr)
    sys.exit(1)

print('PASS: MPR 4D time changes invalidate ROI intensity caches through Swift')
