#!/usr/bin/env python3
"""VR, crop and scissors consume VTK display pixels, not AppKit frame points."""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
failures = []


def strip(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


volume = strip((root / 'Horos/Sources/VRView.swift').read_text(encoding='utf-8'))
# The crop box toggle is Swift (VRView+Crop.swift), an extension of VRView.
volume_crop = strip((root / 'Horos/Sources/VRView+Crop.swift').read_text(encoding='utf-8'))
# The mouse, the hover field and the scissors are Swift too (VRView+Mouse.swift,
# VRView+Gestures.swift).
volume_mouse = strip('\n'.join((root / 'Horos/Sources' / name).read_text(encoding='utf-8')
                                for name in ('VRView+Mouse.swift', 'VRView+Gestures.swift')))
# The crop box and its planes are the VTK adapter's (IsiXVTKVolumeCrop.mm).
crop = strip((root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeCrop.mm').read_bytes().decode('latin1'))
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
geometry = (root / 'Horos/Sources/VTKRetinaGeometry.swift').read_text()
interaction = (root / 'Horos/Sources/VRInteractionGeometry.swift').read_text()
# CPRController is Swift.
curved = source_text('CPRController')
path = (root / 'Horos/Sources/CurvedMPRPath.swift').read_text()


def need(condition, message):
    if not condition:
        failures.append(message)


need('HorosVTKRetinaGeometry' in geometry, 'VTKRetinaGeometry must keep its ObjC name')
need('displaySizeOfView' in geometry, 'display size must be backing pixels')
need('backingPoint' in interaction, 'window-to-view backing conversion must remain')
need('VTKRetinaGeometry.displaySize(of: self)' in volume_mouse,
     'VRView window-center and clip-range math must use displaySizeOfView')
need('VTKRetinaGeometry.resizeHandleDisplayThreshold(pointThreshold: 20,' in volume_mouse,
     'The viewport resize corner must be 20 points in display pixels')
need('VTKRetinaGeometry.scissorsDragThreshold(pointThreshold: 5,' in volume_mouse,
     'Scissors sampling must use a point threshold converted to display pixels')
need('VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)' in volume_mouse,
     'VR mouse paths must keep the backing conversion')
need('vtk.setCropBoxEnabled(true)' in volume_crop and 'vtk.setCropBoxEnabled(false)' in volume_crop
     and 'box->On()' in crop and 'box->Off()' in crop,
     'Crop remains a vtkBoxWidget, not a 2D matrix clip')
need('setCurrentTool(.t3DRotate)' in volume_crop, 'Enabling crop must keep the 3D rotate tool')
need('VTKRetinaGeometry.swift' in project, 'The new Swift file must be in the app target')
need('selectCurvedPathDrawingTool' in curved, 'Do not drop Curved MPR tool selection')
need('HorosCurvedMPRPathSession' in path, 'Do not drop CurvedMPRPath')
need('SetClippingPlanes' in crop, 'Crop must still clip the volume through vtkPlanes')

# The MPR and CPR panes and the hidden VRView they show can be on screens of
# different scales: the view renders, and takes points, at the pane's scale.
panes = {name: strip((root / 'Horos/Sources' / f'{name}.swift').read_text(encoding='utf-8'))
         for name in ('MPRDCMView', 'CPRMPRDCMView')}
render = strip((root / 'Horos/Sources/VRView+Render.swift').read_text(encoding='utf-8'))
need('hostBackingScale > 0 ? VTKRetinaGeometry.backingRect(rect, hostScale: hostBackingScale)' in volume,
     'VRView must convert to the backing of the window that shows its pictures')
need(volume.count('public override func convertToBacking(') == 3,
     'VRView must answer the rect, size and point conversions alike')
need('hostBackingScale > 0 ? hostBackingScale' in render, 'The render window must follow the same scale')
for name, text in panes.items():
    frame_check = text[text.index('func checkForFrame()'):]
    need('_vrView?.setHostBackingScale(backingScaleFactor)' in frame_check[:frame_check.index('.frame = ')],
         f'{name} must give the VRView its scale before its frame')
    need('func viewDidChangeBackingProperties()' in text, f'{name} must render again on a change of screen')
    need('setWindowCenter(center)' not in text and 'setWindowCenter(point)' in text.replace('self.convertToBacking(point)', 'point'),
         f'{name} must send setWindowCenter: backing pixels')

if failures:
    print('FAIL:')
    print('\n'.join(failures))
    sys.exit(1)
print('PASS: VR crop and scissors use VTK display pixels; Curved MPR untouched')
