#!/usr/bin/env python3
"""VR 3D angle picks patient-space points and keeps the Swift angle after camera motion."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
view = (root / 'Horos/Sources/VRView.swift').read_text()
# The keyboard (Delete clears the angle) and the hot keys are Swift blocks of
# the view, which spell the tool `.tAngle`.
swift = '\n'.join(path.read_text(encoding='utf-8') for path in sorted((root / 'Horos/Sources').glob('VRView+*.swift')))
# The projection is the VTK adapter's, which draws the view's 2D actors.
actors = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeActors.mm').read_text(encoding='latin1')
# The press, the drag and the projection are Swift too (VRView+Mouse.swift,
# VRView+Measure.swift), over the view's angleMeasurementPatient.
needed = [
    'tool == .tAngle',
    'get3DPixelUnder2DPositionX',
    'VRMeasurementGeometry.angleDegrees(atX:',
    'vtk.projectPatientPoints(',
    'updateAngleMeasurementProjection',
    'horos_angleMeasurementPatient',
    'currentTool == .tAngle',
    'AngleHotKeyAction',
]
missing = [item for item in needed if item not in swift]
if 'angleMeasurementPatient' not in view:
    missing.append('angleMeasurementPatient')
if missing:
    print('FAIL: VRView is missing', ', '.join(missing), file=sys.stderr)
    sys.exit(1)
start = actors.index('static bool HorosProjectPatientPoints')
body = actors[start:actors.index('static IsiXVTKStoredLine *IsiXVTKNewStoredLine')]
if 'GetDirectionOfProjection' in body:
    print('FAIL: 3D angle projection must not hide on camera rotation', file=sys.stderr)
    sys.exit(1)
if 'factor' not in body:
    print('FAIL: patient millimetres must be scaled back to VTK world', file=sys.stderr)
    sys.exit(1)
print('PASS: tAngle stores patient-space points and reprojects without dropping the angle')
