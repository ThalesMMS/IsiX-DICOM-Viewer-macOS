#!/usr/bin/env python3
"""The Metal volume renderer supplies the native VR mapper.

Source-level contract:

- the VRView snapshot reads the VTK camera, window, CLUT table, opacity
  curve, mode, clipping range, shading and crop box, divides VTK's scaled
  frame by the view's factor, and declines RGB, fusion and the 16-bit CLUT
  with a reason;
- the controller category uploads one volume per NSData buffer, renders
  through HorosVolumeRenderer, records the reason and the milliseconds, and
  frees the GPU volume when the window closes;
- the bridge never touches Core Data, DICOM files or the catalogue;
- the pilot's comparison window and its contextual menu are gone: the
  view draws with Metal itself, so there is nothing left to compare;
- the files are in the Xcode target.
"""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bridge = (root / 'Horos/Sources/VRHostBridge.mm').read_text()
header = (root / 'Horos/Sources/VRHostBridge.h').read_text()
renderer = (root / 'Horos/Sources/VolumeMetalRenderer.swift').read_text()
view = (root / 'Horos/Sources/VRView.mm').read_text()
mapper = (root / 'Horos/Sources/vtkHorosFixedPointVolumeRayCastMapper.cxx').read_text()
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

for needed in ('aCamera->GetPosition(position)', 'aCamera->GetParallelProjection()', 'aCamera->GetParallelScale() / factor',
               'position[i] / factor', 'clippingRangeThickness / factor', 'table[i][0] * 255', 'NSPointFromString(point)', 'pt.x - 1000',
               'HorosShading(aRenderer, volumeProperty)', 'GetVoxelClippingPlanes(&voxelPlanes)'):
    assert needed in bridge, 'snapshot must read: ' + needed
# An RGB volume draws in Metal too (tests/test-volume-metal-rgb.py).
assert 'RGB volumes keep the original renderer' not in bridge, 'an RGB volume is still refused'
# The 16-bit CLUT draws in Metal: VTK's own functions over the value range.
assert 'The 16-bit CLUT keeps the original renderer' not in bridge, 'the 16-bit CLUT is still refused'
assert 'colorTransferFunction->GetTable(from, to, entries, colours.data());' in bridge and \
    'opacityTransferFunction->GetTable(from, to, entries, alphas.data());' in bridge, 'the 16-bit CLUT is not VTK\'s own functions'
# A fused series ray-casts in Metal too, with its own renderer.
assert 'Fusion keeps the original renderer' not in bridge, 'fusion is still refused'
assert 'objc_getAssociatedObject(self, uploadedSlot) != volume || !renderer.isReady' in bridge, 'one upload per volume buffer'
for forbidden in ('valueForKey', 'managedObjectContext', 'DicomImage', 'DicomSeries', 'DicomDatabase', 'sourceFile', 'BrowserController'):
    assert forbidden not in bridge, 'the bridge must not reach ' + forbidden
assert 'volumeData[curMovieIndex]' in bridge and 'pixList[curMovieIndex]' in bridge, 'the volume comes from the controller\'s own buffers'
# The controller's own -windowWillClose: drops the renderers: an observer
# of the window's close notification cost the delegate its registration.
controller = (root / 'Horos/Sources/VRController.mm').read_bytes().decode('latin1')
closing = controller[controller.index('- (void)windowWillClose:(NSNotification *)notification'):]
closing = closing[:closing.index('\n}\n')]
assert '[self horosVolumeMetalDropRenderers];' in closing and 'releaseVolume' in bridge, 'closing the window must free the GPU volume'
# The comparison window of the pilot is gone, and with it the menu.
for gone in ('Compare in Metal (3D)', 'openVolumeMetalComparison', 'HorosVolumeComparison', 'HorosVolumeSource', 'menuForEvent'):
    assert gone not in bridge and gone not in header, gone + ' is back in the bridge'
assert not (root / 'Horos/Sources/VolumeComparison.swift').exists(), 'the comparison window is back'
assert 'renderWithCamera:snapshot[@"camera"] near:' in bridge and 'scalarOut:scalarOut' in bridge
assert '- (NSDictionary *)horosVolumeSnapshot;' in header and 'horosVolumeMetalRenderWithWidth' in header
assert 'SetImageRenderer(HorosRenderMetalVolume, self)' in view
assert 'case 2: volume->SetMapper( volumeMapper)' in view
assert 'horosRenderMetalImageForMapper' in bridge and 'CPU fallback: ' in bridge
assert 'imageRegion:region' in bridge and 'mprVoxelToWorldTransform' in bridge
assert mapper.index('this->RenderImage(this->RenderImageContext') < mapper.index('this->PerImageInitialization( ren, vol, 0')
for catalog in ('en', 'ja-JP'):
    xib = (root / 'Horos/Resources' / (catalog + '.lproj') / 'VR.xib').read_text()
    # The VR draws with Metal only: no engine list to pick it from.
    assert ET.fromstring(xib).find('.//*[@id="vr-metal-radio"]') is None

assert 'VolumeRenderingMode' in renderer and 'case composite = 0, maximum = 1, minimum = 2, mean = 3' in renderer, 'mode numbers follow the host'
assert 'makeAndReturnError' not in renderer or '@objc public static func make() throws' in renderer

for name in ('VRHostBridge.mm', 'VolumeMetalRenderer.swift'):
    assert sum(name in line for line in project.splitlines()) == 4, name + ' is not fully registered in the Xcode project'
print('volume metal host wiring: snapshot, refusals, upload, teardown, no comparison window, and project membership in place')
