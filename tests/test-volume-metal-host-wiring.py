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

The host is Swift (VRView+VolumeHost.swift, VRController+VolumeMetal.swift)
over the VTK adapter (Adapters/VTK/IsiXVTKVolumeScene) and IsiXVolumeRendering.
"""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
# The host is Swift over the VTK adapter: the view's side reads VTK through
# IsiXVTKVolumeScene, the rules are IsiXVolumeRendering's, and the controller's
# side keeps the renderers.
host = (root / 'Horos/Sources/VRView+VolumeHost.swift').read_text()
metal = (root / 'Horos/Sources/VRController+VolumeMetal.swift').read_text()
scene = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeScene.mm').read_text()
module = ''.join(path.read_text() for path in sorted((root / 'Modules/IsiXVolumeRendering/Sources').glob('*.swift')))
bridge = host + metal
renderer = (root / 'Horos/Sources/VolumeMetalRenderer.swift').read_text()
view = (root / 'Horos/Sources/VRView.swift').read_text()
mapper = (root / 'Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx').read_text()
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
# What the host reads of the view, in VRView+VolumeHost.swift.
state = host[host.index('// MARK: - What the Metal host reads of the view'):]
# The scenes are made by the VTK adapter's volume view, which holds the objects.
volume_view = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm').read_text()
adapter_state = volume_view[volume_view.index('- (IsiXVTKVolumeScene *)volumeSceneFused:(BOOL)fused'):]

for needed, where in (('camera->GetPosition(state->position)', scene), ('camera->GetParallelProjection()', scene),
                      ('objects.camera = o->aCamera;', adapter_state), ('func horosVTKScene(fused: Bool) -> IsiXVTKVolumeScene { horos_vtk.volumeSceneFused(fused) }', state), ('camera.parallelScale / factor', module),
                      ('camera.position[i] / factor', module), ('far = clipThickness / factor', module),
                      ('clipThickness: clipRangeActivated ? clippingRangeThickness : nil', host),
                      ('VolumeColourTable.rgba(colours: horosColourTable, count: 256)', host), ('var horosColourTable: UnsafePointer<Double> { UnsafePointer(horos_table) }', state),
                      ('fmin(255, fmax(0, channel * 255 + 0.5))', module), ('NSPointFromString(string)', host),
                      ('point.x - 1000', module), ('Self.shading(scene, sampling: sampling)', host),
                      ('mapper->GetVoxelClippingPlanes(&values)', scene), ('try scene.voxelClippingPlanes()', host)):
    assert needed in where, 'snapshot must read: ' + needed
# An RGB volume draws in Metal too (tests/test-volume-metal-rgb.py).
assert 'RGB volumes keep the original renderer' not in bridge, 'an RGB volume is still refused'
# The 16-bit CLUT draws in Metal: VTK's own functions over the value range.
assert 'The 16-bit CLUT keeps the original renderer' not in bridge, 'the 16-bit CLUT is still refused'
assert 'try scene.colourTable(from: from, to: to, count: entries)' in host and \
    'try scene.opacityTable(from: from, to: to, count: entries)' in host and \
    'objects.colour = o->colorTransferFunction;' in adapter_state and 'objects.opacity = o->opacityTransferFunction;' in adapter_state and \
    scene.count('function->GetTable(from, to, entries, values);') == 2, 'the 16-bit CLUT is not VTK\'s own functions'
# A fused series ray-casts in Metal too, with its own renderer.
assert 'Fusion keeps the original renderer' not in bridge, 'fusion is still refused'
assert 'VolumeMetalSlots.get(self, uploadedSlot) as? NSData !== volume || !renderer.isReady' in metal, 'one upload per volume buffer'
# The upload is skipped by the buffer's identity, which a Data bridged from
# the NSData does not keep: every frame uploaded the volume again.
# VRController is Swift: the buffers stay NSData objects, never bridged to Data.
controller = (root / 'Horos/Sources/VRController.swift').read_text()
assert 'public final func horosVolumeData() -> NSObject? { volumeData[Int(curMovieIndexStorage)] }' in controller and \
    'var volumeData = [NSData?](repeating: nil, count: Int(MAX4D))' in controller and \
    'controller.horosVolumeData() as? NSData' in bridge, \
    'the volume reaches the Swift host as Data, a new object each frame'
for forbidden in ('valueForKey', 'value(forKey', 'managedObjectContext', 'DicomImage', 'DicomSeries', 'DicomDatabase', 'sourceFile',
                  'BrowserController'):
    assert forbidden not in bridge, 'the bridge must not reach ' + forbidden
assert 'curPixList()' in metal, 'the volume comes from the controller\'s own buffers'
# The controller's own -windowWillClose: drops the renderers: an observer
# of the window's close notification cost the delegate its registration.
closing = controller[controller.index('    public override func windowWillClose(_ notification: Notification) {'):]
closing = closing[:closing.index('\n    }\n')]
assert 'horosVolumeMetalDropRenderers()' in closing and 'releaseVolume()' in metal, 'closing the window must free the GPU volume'
# The comparison window of the pilot is gone, and with it the menu.
for gone in ('Compare in Metal (3D)', 'openVolumeMetalComparison', 'HorosVolumeComparison', 'HorosVolumeSource', 'menuForEvent'):
    assert gone not in bridge, gone + ' is back in the bridge'
assert not (root / 'Horos/Sources/VolumeComparison.swift').exists(), 'the comparison window is back'
assert 'try renderer.render(camera: snapshot["camera"] as? [NSNumber] ?? [], near:' in metal and 'scalarOut: scalarOut)' in metal
assert '@objc func horosVolumeSnapshot() -> NSDictionary' in metal and \
    '@objc(horosVolumeMetalRenderWithWidth:height:scalarOut:error:)' in metal
# The ray caster asks the adapter, which asks the view's hook with the scene
# of the volume being cast.
pipeline = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm').read_text()
assert 'o->volumeMapper->SetImageRenderer(IsiXVTKVolumeViewRenderMetal, (__bridge void *)self);' in pipeline
assert re.search(r'horos_vtk\.setMetalImageRenderer \{ \[unowned\(unsafe\) self\] _, fused in\s+self\.horosRenderMetalImageFused\(fused\)\s+\}', view)
# The engine switch is Swift (VRView+Engine.swift), an extension of VRView.
engine = (root / 'Horos/Sources/VRView+Engine.swift').read_text()
assert 'case 0, 2: horos_vtk.attachVolumeMapper()' in engine
# The hook itself is Swift (VRView+Render.swift), an extension of VRView.
view_render = (root / 'Horos/Sources/VRView+Render.swift').read_text()
assert 'return horosRenderMetalImage(in: scene, fused: fused, mprPlane: mprPlane)' in view_render and \
    'guard let scene = horos_vtk.renderingScene() else { return false }' in view_render and 'CPU fallback: ' in host
assert 'imageRegion: region' in host and 'mprVoxelToWorldTransform()' in host
assert mapper.index('this->RenderImage(this->RenderImageContext') < mapper.index('this->PerImageInitialization( ren, vol, 0')
for catalog in ('en', 'ja-JP'):
    xib = (root / 'Horos/Resources' / (catalog + '.lproj') / 'VR.xib').read_text()
    # The VR draws with Metal only: no engine list to pick it from.
    assert ET.fromstring(xib).find('.//*[@id="vr-metal-radio"]') is None

assert 'VolumeRenderingMode' in renderer and 'case composite = 0, maximum = 1, minimum = 2, mean = 3' in renderer, 'mode numbers follow the host'
assert 'makeAndReturnError' not in renderer or '@objc public static func make() throws' in renderer

for name in ('VRView+VolumeHost.swift', 'VRController+VolumeMetal.swift', 'IsiXVTKVolumeScene.mm', 'VolumeMetalRenderer.swift'):
    assert sum(name in line for line in project.splitlines()) == 4, name + ' is not fully registered in the Xcode project'
# Composite rays walk one unit of VTK's scaled frame, pixelSpacingX / superSampling
# millimetres, whatever the slice interval: slices closer than the pixels gave
# rays more samples than VTK's and made the 3D view of thin-slice series slow.
step = re.search(r'public static func composite\(spacingX: Double, superSampling: Double\) -> Double \{\s*superSampling > 0 \? spacingX / superSampling : spacingX\s*\}', module)
assert step, 'the composite step is not VTK\'s unit'
assert host.count('VolumeSamplingStep.composite(spacingX: sx, superSampling: superSampling)') == 2, 'the image and the fused series do not both take VTK\'s step'
# While the view draws its low-resolution image (a drag), the rays step as much
# coarser as the image; the still image, at LOD or finer, keeps VTK's step.
assert re.search(r'public static func interactionScale\(minimumImageSampleDistance: Double, lod: Double\) -> Double \{\s*'
                 r'lod > 0 && minimumImageSampleDistance > lod \? minimumImageSampleDistance / lod : 1', module), 'no interaction step scale'
assert 'interactionScale(minimumImageSampleDistance: scene.hasMapper ? sampling.minimumImageSampleDistance : 0,' in host and \
    'sampling->minimumImageSampleDistance = mapper->GetMinimumImageSampleDistance();' in scene, 'the image does not coarsen its step while moving'
assert 'interactionScale(minimumImageSampleDistance: sampling.minimumImageSampleDistance, lod: Double(lod()))' in host, 'the fused series does not coarsen its step while moving'
print('volume metal host wiring: snapshot, refusals, upload, teardown, no comparison window, and project membership in place')
