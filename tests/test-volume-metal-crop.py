#!/usr/bin/env python3
"""A crop draws in Metal, clipped as VTK clips it, and a refusal says why.

The host's crop reaches VTK as clipping planes on the mapper: the box widget's,
or a saved camera's through `setCamera:`, possibly turned. `PrepareMPRGeometry`
refused every plane that cut into the voxel centres, so a cropped volume always
drew on the CPU, under one reason for every cause. Checked here, in the sources:

* the VR hook lets the mapper take such planes (`PrepareMPRGeometry(..., true)`),
  which then sets up VTK's own voxel-space planes as the CPU render would
  (`InitializeRayInfo`); the snapshot hands the renderer those planes
  (`GetVoxelClippingPlanes`), only the ones that cut into the voxel centres, at
  most 32, instead of the box widget's axis-aligned bounds, which a turned box
  does not have;
* the kernel clips each ray against them. The rule itself is measured against
  an oracle in `tests/test-volume-metal-renderer.py`, and the planes against the
  ones VTK's own render uses in `tests/test-mpr-metal-geometry.py`;
* the clipping range draws in Metal too: the snapshot hands the renderer the
  camera's own range, [0, thickness], and samples a projection from it as VTK
  does;
* VTK's cropping regions, which the host never turns on, draw in Metal when
  they are a subvolume, one box: its six planes in voxel index space, added to
  the mapper's; any other set of regions stays with VTK, with its reason;
  the MPR plane still refuses a crop, which its reslice does not clip;
* a geometry refusal names its cause (crop, no viewport, no rows to cast) for
  the VR and the MPR, and every frame the original renderer draws in their
  place leaves its reason in the performance trace (`vr.refusal`,
  `mpr.refusal`), which is how they were counted in use.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text()


failures = []
header = read('Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.h')
mapper = read('Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx')
# The host is Swift over the VTK adapter, with its rules in IsiXVolumeRendering.
bridge = read('Horos/Sources/VRView+VolumeHost.swift')
scene = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeScene.mm')
planes = read('Modules/IsiXVolumeRendering/Sources/VolumeCropPlanes.swift')
view = read('Horos/Sources/VRView.swift')
mpr = read('Horos/Sources/MPRDCMView+MetalPlane.swift')  # the MPR's Metal plane, Swift
renderer = read('Horos/Sources/VolumeMetalRenderer.swift')
trace = read('Horos/Sources/MetalPerformanceTrace.swift')

# The mapper: planes accepted on request, VTK's own voxel planes handed out, the cause kept.
for needle, why in [('bool PrepareMPRGeometry(vtkRenderer *, vtkVolume *, bool acceptClippingPlanes = false)', 'the geometry cannot take the crop planes'),
                    ('int GetVoxelClippingPlanes(const float **planes) const', 'VTK\'s voxel-space planes are not handed out'),
                    ('GeometryClippingPlane, GeometryNoRows', 'the geometry does not keep why it refused'),
                    ('GetGeometryRefusal()', 'the geometry does not keep why it refused')]:
    if needle not in header:
        failures.append(why)
prepare = mapper[mapper.index('PrepareMPRGeometry(vtkRenderer *ren'):mapper.index('::Render(')] if 'PrepareMPRGeometry(vtkRenderer *ren' in mapper else ''
if '!acceptClippingPlanes' not in prepare:
    failures.append('a plane that cuts the voxel centres still refuses a caller that clips its rays')
if prepare.find('this->InitializeRayInfo(vol);') < prepare.find('ComputeRowBounds') or 'this->InitializeRayInfo(vol);' not in prepare:
    failures.append('the geometry does not set up the voxel planes the CPU render would cast with')
for cause in ('GeometryNoInput', 'GeometryNoViewport', 'GeometryClippingPlane', 'GeometryNoRows', 'GeometryAccepted'):
    if 'this->LastGeometryRefusal = %s;' % cause not in prepare:
        failures.append('the geometry never records ' + cause)

# The VR hook and snapshot.
hook = bridge[bridge.index('private func renderMetalImage(in scene: IsiXVTKVolumeScene, fused: Bool) -> Bool {'):
              bridge.index('private static func geometryRefusalReason(')]
if 'try scene.prepareGeometry(acceptingClippingPlanes: true)' not in hook or \
        'mapper->PrepareMPRGeometry(renderer, volume, accept)' not in scene:
    failures.append('the VR hook still refuses a crop')
if 'sampling.cropping' in hook or 'readSampling' in hook:
    failures.append('the VR hook still refuses VTK cropping regions')
if 'clipRangeActivated' in hook:
    failures.append('the VR hook still refuses the clipping range')
if 'projection: renderingMode != 0)' not in bridge:
    failures.append('a projection under the clipping range is not sampled from the camera\'s own range')
if 'MetalPerformanceTrace.recordRefusal(fused ? "vr.fusion.refusal" : "vr.refusal", reason: reason)' not in hook:
    failures.append('a refused VR frame leaves no reason in the trace')
# The planes are read by a helper both volumes share; the rule is the module's.
helper = bridge[bridge.index('private static func cuttingPlanes('):bridge.index('private static func shading(')]
snapshot = bridge[bridge.index('@objc func horosVolumeSnapshot() -> NSDictionary {'):]
for needle, why in [('try scene.voxelClippingPlanes()', 'the snapshot does not read VTK\'s voxel planes'),
                    ('VolumeCropPlanes.cuttingPlanes(voxelPlanes: planes, cropping: cropping', 'the snapshot does not keep only the cutting planes')]:
    if needle not in helper:
        failures.append(why)
for needle, why in [('mapper->GetVoxelClippingPlanes(&values)', 'the adapter does not read VTK\'s voxel planes'),
                    ('sampling->croppingSubvolume = mapper->GetCroppingRegionFlags() == VTK_CROP_SUBVOLUME ? YES : NO;',
                     'the adapter does not say whether the cropping regions are one box')]:
    if needle not in scene:
        failures.append(why)
for needle, why in [('cuts = distance < -1e-4', 'the snapshot passes planes that do not cut the voxel centres'),
                    ('guard cropping.subvolume else { throw .regionsNotSubvolume }', 'a set of cropping regions that is not one box is not refused'),
                    ('let low = (cropping.planes[2 * axis] - origin[axis]) / spacing[axis]',
                     'a subvolume\'s bounds are not turned into voxel index planes')]:
    if needle not in planes:
        failures.append(why)
for needle, why in [('try Self.cuttingPlanes(scene, sampling: sampling, width: first.pwidth, height: first.pheight, depth: pix.count)',
                     'the snapshot does not read VTK\'s voxel planes'),
                    ('case .failure(let refusal): return ["error": refusal.reason]', 'a set of cropping regions the renderer cannot draw is drawn anyway'),
                    ('VolumeRendererBridge.maximumClippingPlanes', 'the snapshot does not bound the planes it passes'),
                    ('"clippingPlanes": Self.numbers(clippingPlanes)', 'the snapshot does not carry the planes')]:
    if needle not in snapshot:
        failures.append(why)
if 'getCroppingBox' in snapshot:
    failures.append('the snapshot still reads the box widget\'s axis-aligned bounds, which a turned box does not have')
if 'clippingPlanes: snapshot["clippingPlanes"] as? [NSNumber]' not in read('Horos/Sources/VRController+VolumeMetal.swift'):
    failures.append('the render does not receive the crop planes')
for reason in ('The crop uses the original renderer.', 'The ray caster has no rows to cast.', 'The view has no size yet.'):
    if reason not in bridge:
        failures.append('a geometry refusal has no reason of its own: ' + reason)

# The MPR plane: its own reasons, and still no crop.
if 'vrView.horosMPRGeometryRefusalWidth(width, height: height)' not in mpr:
    failures.append('the MPR plane does not say why its geometry is refused')
if 'MetalPerformanceTrace.recordRefusal("mpr.refusal", reason: reason)' not in mpr:
    failures.append('a refused MPR plane leaves no reason in the trace')
refusal = bridge[bridge.index('@objc public func horosMPRGeometryRefusalWidth('):bridge.index('@objc public func horosMPRFusedGeometryRefusalWidth(')]
plane = bridge[bridge.index('private func preparedPlane('):bridge.index('@objc public func horosMPRFusedVolume(')]
if 'return preparedPlane(scene, width: width, height: height)' not in refusal or \
        'try scene.prepareGeometry(acceptingClippingPlanes: false)' not in plane:
    failures.append('the MPR plane takes a crop its reslice does not clip')

# The renderer and the trace.
for needle, why in [('public let clippingPlanes: [SIMD4<Float>]', 'the request has no crop planes'),
                    ('for (uint i = 0; hit && i < p.clipping.x; ++i) {', 'the kernel does not clip against the planes'),
                    ('clippingPlanes: [NSNumber] = []', 'the facade does not take the planes')]:
    if needle not in renderer:
        failures.append(why)
if '@objc(recordRefusal:reason:)' not in trace:
    failures.append('the trace cannot record a refusal')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('volume metal crop: the crop planes, a cropping subvolume and the clipping range reach Metal as VTK clips them; other cropping regions and the MPR crop stay refused; '
      'each geometry refusal has its reason, in the fallback and in the trace')
