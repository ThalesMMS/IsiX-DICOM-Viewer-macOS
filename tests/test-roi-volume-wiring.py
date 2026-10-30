#!/usr/bin/env python3
"""Host volume uses Swift physical trapezoid; mesh decimation does not."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
# -computeVolume:... of the 2D viewer, in Swift; the thinning of the points is IsiXROI's.
controller = (root / 'Horos/Sources/ViewerController+ROIVolume.swift').read_text(encoding='utf-8')
points = (root / 'Modules/IsiXROI/Sources/ROIValueStatistics.swift').read_text(encoding='utf-8')
volume = (root / 'Horos/Sources/ROIVolume.swift').read_text(encoding='utf-8')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text(encoding='latin1', errors='replace')
start = controller.index('@objc(computeVolume:points:generateMissingROIs:generatedROIs:computeData:error:)')
method = controller[start:controller.index('\nextension ViewerController {', start)]
needed = [
    'ROIVolumeGeometry.volume(from:',
    'ROIPatientPoint(',
    'interpolateMissing: false',
    'pic.originX',
    'pic.originY',
    'pic.originZ',
    'componentCount: imageCount',
    'roiMorphingBetween(',
    'generateMissingROIs',
    'Display-only decimation',
    'ROIVolumePoints.keptIndices(',
]
missing = [item for item in needed if item not in method]
if 'static let displayLimit = 7000' not in points:
    missing.append('the 7000-point display limit')
if missing:
    print('FAIL: computeVolume is missing', ', '.join(missing), file=sys.stderr)
    sys.exit(1)
if 'location = x * sliceInterval' in method:
    print('FAIL: computeVolume still locates slices by index × sliceInterval', file=sys.stderr)
    sys.exit(1)
if 'Only ONE ROI per image supported' in method:
    print('FAIL: computeVolume still rejects disconnected components on one slice', file=sys.stderr)
    sys.exit(1)
if 'stringTex' in method or 'HorosROILabelPresentation' in method:
    print('FAIL: volume must not touch the ROI label matrix', file=sys.stderr)
    sys.exit(1)
if 'ROIVolumeGeometry.volume(from:' not in volume:
    print('FAIL: ROIVolume does not use the documented Swift volume', file=sys.stderr)
    sys.exit(1)
if 'sliceLocation' in volume and 'ROIVolumeGeometry' not in volume:
    print('FAIL: ROIVolume still volumes from sliceLocation alone', file=sys.stderr)
    sys.exit(1)
if 'ROIVolumeGeometry.swift' not in pbx:
    print('FAIL: ROIVolumeGeometry.swift is not in the app target', file=sys.stderr)
    sys.exit(1)
if 'computeVolume' in xib:
    print('FAIL: Viewer.xib must stay untouched', file=sys.stderr)
    sys.exit(1)
print('PASS: computeVolume and ROIVolume use IPP trapezoid; gaps stay explicit; mesh is display-only')
