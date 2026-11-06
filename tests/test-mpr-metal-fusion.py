#!/usr/bin/env python3
"""The 3D MPR reslices a fused series in Metal with the plane.

An MPR opened from a fused viewer used to refuse Metal («Fusion keeps the
original renderer.»): VTK cast both planes. Now the fused series' plane is
resliced from its own volume, where VTK casts it, and handed to the host's
blending branch, which composes the two planes as before:

* the fused volume as VTK reads it - the float buffer it converts to 16 bits
  from, placed by the blending reader's origin and spacing through the blending
  volume's matrix, the loop of -mprVoxelToWorldTransform - and the value a ray
  that misses it reads back as (-blendingOFFSET16);
* the blending mapper's own ray-cast geometry (PrepareMPRGeometry on the
  blending volume), origin (getOrigin:... blendedView:YES) and sample distance;
* both planes in Metal or both with VTK, never mixed, with one reason;
* the plane handed over as the malloc-owned buffer VTK's path hands over, not
  copied through an intermediate NSData; VTK renders the blended
  volume only when Metal did not reslice it;
* both reslices sample pixel (0, 0) at its centre. VTK casts each ray through
  the centre of its ray-cast pixel (ComputeRayInfo adds 1/viewport, "to center
  it"); -getOrigin: gives the image's upper-left corner. Checked here on those
  two formulas as the sources write them: the ray of pixel x lies at the corner
  plus (x + 0.5) pixels, for random viewports, image origins, sample distances
  and pixels. In the application the two engines' planes then match best
  unshifted, where they matched best half a pixel apart before
  for fusion.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import random
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
from sources import dependency_source
vtk_source = dependency_source('VTK')
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path], stderr=subprocess.DEVNULL).decode('latin1')
    return (root / path).read_bytes().decode('latin1').replace('\r\n', '\n')


failures = []
# The MPR's Metal plane is Swift (MPRDCMView+MetalPlane.swift); where pixel
# (0, 0) is sampled is IsiXImaging's MPRPlaneRules.
bridge = read('Horos/Sources/MPRDCMView+MetalPlane.swift')
rules = read('Modules/IsiXImaging/Sources/ViewerReconstruction/MPRPlaneRules.swift')
# MPRDCMView is Swift; an earlier revision has the Objective-C.
try:
    view = read('Horos/Sources/MPRDCMView.swift')
    view_is_swift = True
except (FileNotFoundError, subprocess.CalledProcessError):
    view = read('Horos/Sources/MPRDCMView.m')
    view_is_swift = False
# The 3D view's host is Swift over the VTK adapter (VRView+VolumeHost.swift).
host = read('Horos/Sources/VRView+VolumeHost.swift')
scene = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeScene.mm')
placement = read('Modules/IsiXVolumeRendering/Sources/VolumeCameraSnapshot.swift')
try:
    vr = read('Horos/Sources/VRView.m')
    objc_view = True
except (OSError, subprocess.CalledProcessError):
    # The class is Swift (VRView.swift); what the Metal host reads of it is in
    # VRView+VolumeHost.swift.
    vr = read('Horos/Sources/VRView.swift')
    objc_view = False
# The view's VTK objects are the adapter's (IsiXVTKVolumeView): the transform
# and the scenes are read there.
vr_pipeline = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')
vr_adapter = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm')
vtk = (vtk_source / 'Rendering/Volume/vtkFixedPointVolumeRayCastMapper.cxx').read_text(encoding='latin1')

# --- the bridge: fused plane, all or nothing, handed over -------------------
if 'Fusion keeps the original renderer' in bridge:
    failures.append('the MPR still refuses a fusion')
fused = bridge[bridge.find('private func metalFusedPlane('):]
for piece, why in [('vrView.horosMPRFusedVolume()', 'the fused volume as VTK reads it'),
                   ('vrView.horosMPRFusedGeometryRefusalWidth(&width, height: &height)', 'the blending mapper\'s geometry'),
                   ('vrView.getOrigin(&corner, windowCentered: true, sliceMiddle: true, blendedView: true)', 'the blended plane\'s origin'),
                   ('vrView.getResolution() * Double(vrView.blendingImageSampleDistance())', 'the blended plane\'s spacing'),
                   ('thickness: vrView.getClippingRangeThicknessInMm()', 'the slab'),
                   ('projection: Int(controller.clippingRangeMode)', 'the mode'),
                   ('MPRHostVolume.fused(snapshot: vrView.horosMPRFusedVolume() as NSDictionary?)', 'one validated conversion'),
                   ('sampleStep: volume.sampleStep', 'the fused volume\'s sample step'),
                   ('background: Double(volume.background)', 'the value of a missed ray')]:
    if not fused or piece not in fused[:fused.find('\n    // MARK:')]:
        failures.append('the fused plane does not take %s (%s)' % (why, piece))
copy = bridge[bridge.find('func horosMPRCopyImageWidth('):]
if 'if blending != nil && fused == nil { reslicer = nil }' not in copy:
    failures.append('a view may mix a Metal plane with a VTK fused plane')
success = copy[copy.find('background: Double(volume.background), into: image)'):copy.find('} catch {\n                    free(image)')]
if 'plane.fusedPlane = fused' not in success:
    failures.append('the fused plane is not kept for the blending branch once the plane succeeded')
take = bridge[bridge.find('func horosMPRTakeFusedImageWidth('):]
take = take[:take.find('\n    }\n')]
if 'plane.pixels = nil' not in take or 'memcpy' in take or 'plane.bytes' in bridge:
    failures.append('the fused plane is copied on its way to the host instead of handed over')
if bridge.count('MPRPlaneRules.pixelCentre(corner: corner, cosines: cosines, spacing: spacing)') != 2:
    failures.append('a reslice does not sample pixel (0, 0) at its centre')
centre = re.search(r'let half = 0\.5 \* spacing\s*'
                   r'return \(0\.\.<3\)\.map \{ i in Double\(corner\[i\]\)\.addingProduct\(half, Double\(cosines\[i\] \+ cosines\[i \+ 3\]\)\) \}', rules)
if not centre:
    failures.append('the pixel centre is not the corner plus half a pixel along the row and the column')

# --- the view: Metal's fused plane first, VTK's only without it --------------
if view_is_swift:
    branch = view[view.find('if let blendingView = self.blending {\n                blendingView.getWLWW('):]
    branch = branch[:branch.find('var porigin = [Float](repeating: 0, count: 3)')]
    if not re.search(r'var blendedImagePtr: UnsafeMutablePointer<Float>\? = _moveCenter \? nil : self\.horosMPRTakeFusedImageWidth\(&w, height: &h\)\s*'
                     r'if blendedImagePtr != nil \{\s*isRGB = false\s*\} else \{\s*_vrView\?\.renderBlendedVolume\(\)\s*\}', branch):
        failures.append('the blending branch renders the fused volume with VTK even when Metal resliced it')
    if not re.search(r'\} else if blendedImagePtr == nil \{\s*blendedImagePtr = _vrView\?\.image\(inFullDepthWidth: &w, height: &h, isRGB: &isRGB, blendingView: true\)', branch):
        failures.append('the blending branch reads VTK\'s plane over Metal\'s')
else:
    branch = view[view.find('if( blendingView)\n        {\n            [blendingView getWLWW:'):]
    branch = branch[:branch.find('float porigin[ 3];')]
    if not re.search(r'float \*blendedImagePtr = moveCenter \? nil : \[self horosMPRTakeFusedImageWidth: &w height: &h\];\s*'
                     r'if\( blendedImagePtr\)\s*isRGB = NO;\s*else\s*\[vrView renderBlendedVolume\];', branch):
        failures.append('the blending branch renders the fused volume with VTK even when Metal resliced it')
    if not re.search(r'else if\( blendedImagePtr == nil\)\s*blendedImagePtr = \[vrView imageInFullDepthWidth: &w height: &h isRGB: &isRGB blendingView: YES\];', branch):
        failures.append('the blending branch reads VTK\'s plane over Metal\'s')

# --- the fused volume, placed as VTK places it ------------------------------
if ('return [vtk voxelToWorldTransformWithFactor: factor];' if objc_view else
        'return horos_vtk.voxelToWorldTransform(withFactor: horos_factor)') not in vr:
    failures.append('-mprVoxelToWorldTransform no longer asks the adapter')
primary = vr_pipeline[vr_pipeline.find('- (NSArray<NSNumber *> *)voxelToWorldTransformWithFactor:'):]
primary = primary[:primary.find('\n}\n')]
volume = host[host.find('@objc public func horosMPRFusedVolume()'):]
volume = volume[:volume.find('\n    }\n')]
state = vr[vr.find('@implementation VRView (HorosVolumeHostState)'):] if objc_view else \
    host[host.find('// MARK: - What the Metal host reads of the view'):]
adapter_state = vr_adapter[vr_adapter.find('- (IsiXVTKVolumeScene *)volumeSceneFused:(BOOL)fused'):]
# The module's loop is -mprVoxelToWorldTransform's, element for element.
loop = re.compile(r'for \(int column = 0; column < 4; \+\+column\).*?\[transform addObject:@\(value\)\];', re.S)
module_loop = re.search(r'for column in 0\.\.<4 \{.*?transform\.append\(value\)', placement, re.S)
primary_loop = loop.search(primary)
normal = lambda text: re.sub(r'\s+', ' ', text)
def formula(text):
    text = normal(text).replace('matrix->GetElement(', 'element(').replace('double value = ', 'let value = ')
    return text[text.index('value = '):text.rindex('/ factor') + len('/ factor')]
if not primary_loop or not module_loop or formula(primary_loop.group(0)) != formula(module_loop.group(0)):
    failures.append('the fused transform is not -mprVoxelToWorldTransform\'s loop')
for piece, where, why in [('VolumePlacement.voxelToWorldColumns(matrix: Self.array(placement.matrix), origin: Self.array(placement.origin),', volume,
                           'the placement the adapter reads'),
                          ('objects.importer = o->blendingReader;', adapter_state, 'the blending reader'),
                          ('return [vtk volumeSceneFused: fused];' if objc_view else 'horos_vtk.volumeSceneFused(fused)', state,
                           'the adapter\'s scenes'),
                          ('if (vtkImageData *output = importer ? importer->GetOutput() : nullptr) {', scene, 'the blending reader\'s output'),
                          ('objects.volume = o->blendingVolume;', adapter_state, 'the blending volume'),
                          ('vtkMatrix4x4 *matrix = volume->GetMatrix();', scene, 'the blending volume\'s matrix'),
                          ('"background": NSNumber(value: -horosBlendingOffset)', volume, 'the value of a missed ray'),
                          ('- (float) horosBlendingOffset { return blendingOFFSET16; }' if objc_view else
                           'var horosBlendingOffset: Float { horos_blendingOFFSET16 }', state, 'the value of a missed ray'),
                          ('candidate.bytes == UnsafeRawPointer(blendingData)', volume, 'the buffer VTK converts from'),
                          ('blendingController.volumeData(i)', volume, 'the buffer VTK converts from')]:
    if piece not in where:
        failures.append('the fused volume does not use %s' % why)
geometry = host[host.find('@objc public func horosMPRFusedGeometryRefusalWidth'):]
geometry = geometry[:geometry.find('\n    }\n')]
if 'let scene = horosVTKScene(fused: true)' not in geometry or 'return preparedPlane(scene, width: width, height: height)' not in geometry or \
        'objects.mapper = o->blendingVolumeMapper;' not in adapter_state or 'mapper->PrepareMPRGeometry(renderer, volume, accept)' not in scene:
    failures.append('the fused plane does not take the blending mapper\'s geometry')

# --- the pixel centre, on the formulas as VTK and VRView write them ----------
if not re.search(r'(?:float|double) offsetX = 1\.0 / static_cast<(?:float|double)>\(imageViewportSize\[0\]\);', vtk) or \
        not re.search(r'viewRay\[0\] =\s*\(\(static_cast<float>\(x\) \+\s*static_cast<float>\(imageOrigin\[0\]\)\) /\s*'
                      r'imageViewportSize\[0\]\) \* 2\.0 -\s*1\.0 \+ offsetX;', vtk):
    failures.append('VTK no longer casts through the ray pixel\'s centre as this test models it')
# -getOrigin: is Swift (VRView+Camera.swift): the corner is the C int of
# viewport * window + imageOrigin * sampleDistance, fused as clang compiled it.
camera = read('Horos/Sources/VRView+Camera.swift')
origin = camera[camera.find('func getOrigin(_ origin: UnsafeMutablePointer<Float>!, windowCentered wc: Bool, sliceMiddle: Bool, blendedView: Bool)'):]
if 'let x1 = CConversion.int((Double(imageOrigin.0) * sampleDistance).addingProduct(viewport[0], Double(renWinWidth)))' not in origin \
        or 'var x = Double(x1) - Double(renWinWidth) / 2.0' not in origin:
    failures.append('-getOrigin: no longer gives the image\'s corner as this test models it')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

rng = random.Random(658)
checked = 0
for _ in range(20000):
    sample = rng.choice([1.0, 1.3, 1.6, 2.0, 2.5, 4.0, 7.0])
    viewport = rng.randint(16, 900)                   # ray pixels across the viewport
    window = viewport * sample                        # window pixels across it
    image_origin = rng.randint(0, viewport // 2)      # first in-use ray pixel
    x = rng.randint(0, viewport - image_origin - 1)
    # VTK: normalised device coordinate of pixel x's ray, then window pixels from the left edge.
    ndc = ((x + image_origin) / viewport) * 2.0 - 1.0 + 1.0 / viewport
    ray = (ndc + 1.0) / 2.0 * window
    # VRView: the corner, int(imageOrigin * sampleDistance) window pixels from the left edge.
    corner = int(image_origin * sample)
    # The reslicer samples pixel x at the corner plus (x + 0.5) pixels of `sample` window pixels.
    centre = corner + (x + 0.5) * sample
    if abs(ray - centre) > 1e-6 * window + abs(image_origin * sample - corner):
        print('FAIL: pixel %d of a %d-pixel viewport at %g: VTK casts at %.6f, the reslice samples %.6f' % (x, viewport, sample, ray, centre))
        raise SystemExit(1)
    checked += 1
print('PASS: the fused plane is resliced with the plane from the fused volume where VTK casts it, both or neither, handed over '
      'without a copy; %d ray positions at the pixel centre the reslice samples' % checked)
