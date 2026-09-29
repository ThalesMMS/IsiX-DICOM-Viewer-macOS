#!/usr/bin/env python3
"""The Metal reslice replaces CPU ray casting in the host's 3D MPR.

Source-level contract, so a refactor that moves the hook, drops the fallback
or forgets a catalog string fails here rather than in the application:

- `MPRDCMView` asks the bridge before CPU rendering and uses the same DCMPix
  update for either image; native pixel/geometry checks cover the result;
- the bridge refuses, with a reason, an RGB volume, which the engine does
  not represent, and never touches Core
  Data, the catalogue or the DICOM files; a fusion is resliced with the plane
  (#658, `tests/test-mpr-metal-fusion.py`);
- in volume rendering mode the plane is VTK's render with the 3D window's
  Metal ray cast filling its ray-cast image, asked for plane by plane on the
  MPR's hidden view, whose outcome becomes the view's notice (#724);
- the option defaults on, its menu item exists, and the notice the
  planar path shows when Metal is paused is reused unchanged;
- every new user-visible string is in the Italian and Spanish catalogs;
- the Swift and Objective-C files are in the Xcode target.
"""
import re
from pathlib import Path

import sources

root = Path(__file__).resolve().parents[1]
view = sources.source_text('MPRDCMView')
bridge = (root / 'Horos/Sources/MPRHostBridge.m').read_text()
header = (root / 'Horos/Sources/MPRHostBridge.h').read_text()
planar = (root / 'Horos/Sources/PlanarHostBridge.m').read_text()
dcmview = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

# Hook placement inside the non-blended branch of the reconstruction.
start = view.index('@objc(updateViewMPROnLoading::)')
body = view[start:view.index('@objc(updateViewMPROnLoading:)\n', start)]
hook = body.index('host.horosMPRCopyImageWidth(&w, height: &h)')
assert hook < body.index('_vrView?.render()')
assert 'if imagePtr == nil && self.frame.size.width > 0' in body
assert '} else if imagePtr == nil {\n                imagePtr = _vrView?.image(inFullDepthWidth:' in body
for setter in ('_pix?.setOrigin(&porigin)', '_pix?.pixelSpacingX = Double(resolution)', '_pix?.setOrientation(&orientation)',
               '_pix?.sliceThickness = _vrView?.getClippingRangeThicknessInMm() ?? 0'):
    assert hook < body.index(setter) < body.index('self.setWLWW(previousWL, previousWW)')
assert body.index('if let blendingView = self.blending {') > hook, 'the hook belongs to the primary plane, not the fused one'
# Swift reads the bridge's messages through the protocol its category adopts.
assert 'as! HorosMPRHostViewMessages' in view
assert '@interface MPRDCMView (HorosMPRHost) <HorosMPRHostViewMessages>' in header

# The bridge's refusals and what it may not touch.
assert 'RGB volumes keep the original renderer' in bridge, 'missing refusal: an RGB volume'
# Volume rendering mode (#724): no refusal; the hidden view's next render is
# the Metal ray cast, and the flag is cleared for every other plane.
for gone in ('Volume rendering keeps the original renderer', 'RGB planes keep the original renderer'):
    assert gone not in bridge, 'still refused: ' + gone
copy = bridge[bridge.index('- (float *)horosMPRCopyImageWidth'):bridge.index('- (void)horosMPRVolumeRendered')]
reset = copy.index('[vrView horosSetMPRVolumeMetal:NO];')
assert reset < copy.index('if (moveCenter) return NULL;'), \
    'the flag is cleared before a plane that is not volume rendering returns'
assert 'horosMPRMetalEnabled' not in copy, 'no switch leads a plane to the original renderer (#735)'
assert re.search(r'if \(controller\.clippingRangeMode < 1 \|\| controller\.clippingRangeMode > 3\) \{\s*'
                 r'\[vrView horosSetMPRVolumeMetal:YES\];\s*return NULL;\s*\}', copy), \
    'volume rendering mode asks the hidden view for the Metal ray cast'
rendered = bridge[bridge.index('- (void)horosMPRVolumeRendered'):]
assert '[vrView horosMPRVolumeMetalReasonDrawn:&drawn]' in rendered and '[self horosSetPlanarFallbackReason:reason];' in rendered
assert 'imagePtr = _vrView?.image(inFullDepthWidth: &w, height: &h, isRGB: &isRGB)\n            }\n            host.horosMPRVolumeRendered()' in view, \
    'the view reports the Metal ray cast after reading the plane'
vr = (root / 'Horos/Sources/VRHostBridge.mm').read_text()
assert 'if ((mprPlane ? !self.horosMPRVolumeMetal : engine != 2) || renderer != aRenderer ||' in vr, \
    'the ray-cast hook runs for the MPR\'s hidden view only when the MPR asks for it'
# A reversed stack is resliced through the voxel-to-world transform VTK places
# it by; only the interval's magnitude is checked (#724).
assert 'A reversed stack keeps the original renderer' not in bridge, 'a reversed stack is still refused'
assert 'double dz = fabs(first.sliceInterval);' in bridge
assert 'clippingRangeMode < 1 || controller.clippingRangeMode > 3' in bridge, 'only MIP, MinIP and mean reach the engine'
for forbidden in ('valueForKey', 'managedObjectContext', 'DicomImage', 'DicomSeries', 'DicomDatabase', 'sourceFile'):
    assert forbidden not in bridge, 'the bridge must not reach ' + forbidden
assert 'horosSetPlanarFallbackReason' in bridge and 'horosSetPlanarFallbackReason' in planar
assert 'Original renderer (Metal paused)' not in dcmview and 'self.horosEngineNotice' in dcmview, \
    'a plane computed on the CPU shows why, drawn by DCMView for every subclass (#735)'
assert 'into:image error:&error]' in bridge and 'free(image);' in bridge, \
    'return an owned image for the common DCMPix update, filled by the engine and freed when the reslice fails'
assert 'plane.bytes' not in bridge, 'the plane is copied once, into the image, not through an intermediate NSData (#620)'
assert '[vrView horosMPRGeometryRefusalWidth:width height:height]' in bridge, \
    'the plane asks the view why its geometry is refused, one reason per cause (#664)'
assert '[HorosMetalPerformanceTrace recordRefusal:@"mpr.refusal" reason:reason]' in bridge, \
    'every plane the original renderer draws leaves its reason in the trace (#664)'
assert '[vrView getOrigin:position windowCentered:YES sliceMiddle:YES]' in bridge
assert 'mprVoxelToWorldTransform' in bridge and 'voxelToWorld:transform' in bridge
assert 'uploadVolume:slices width:first.pwidth height:first.pheight depth:pix.count' in bridge
assert 'volume.length < expected' in bridge and 'expected != volume.length' not in bridge, \
    'the viewer buffer may exceed the slices; only a shorter buffer is refused'
assert 'NSWindowWillCloseNotification' in bridge and 'releaseVolume' in bridge, 'closing the window must free the GPU volume'
assert 'toggleMPRMetal:' not in bridge and 'HorosMPRMetal"' not in bridge, \
    'no preference or per-window switch leads back to the original renderer (#735)'
assert 'menuForEvent' not in bridge, 'the MPR options live in Settings → 3D, not in a contextual menu'
assert 'addObserver:observer forKeyPath:HorosMPRCubicDisplayKey' in bridge and '[controller horosMPRReconstructPlanes]' in bridge, \
    'an open MPR follows a change of its cubic display preference'
pane = (root / 'Preference Panes/OSI3DPreferencePane/Base.lproj/OSI3DPreferencePanePref.xib').read_text()
assert 'title="Use Metal in MPR"' not in pane and 'keyPath="values.HorosMPRMetal"' not in pane
assert 'HorosMPRMetal"' not in (root / 'Horos/Sources/DefaultsOsiriX.m').read_text(encoding='latin1')
assert '- (float *)horosMPRCopyImageWidth:(long *)width height:(long *)height;' in header
assert 'horosMPRReplacePixels' not in view + bridge + header

# NSView frames remain in points; VTK owns the sole backing-pixel conversion.
frame = view[view.index('@objc(checkForFrame)'):view.index('@objc(displayedScaleValue)')]
assert 'convertRectToBacking' not in frame and 'convertToBacking' not in frame
assert 'self.convert(self.bounds, to: nil)' in frame

# A216 on the CPR path: the curved views are DCMView subclasses whose ROI
# statistics go through -[DCMPix getROIValue:::], the one place that reads
# -computefImageForMeasurement. No CPR source may grow a measurement path of
# its own that would see the presentation filter again.
# CurvedMPR.m was here too, compiled by nothing and removed with the other dead sources (#652).
# The CPR views and controller are Swift since #824 and #825.
for name in sorted([*(root / 'Horos/Sources').glob('CPR*.m'), *(root / 'Horos/Sources').glob('CPR*.swift')]):
    text = name.read_bytes().decode('latin1')
    for forbidden in ('getROIValue', 'computefImage', 'applyConvolutionOnImage'):
        assert forbidden not in text, '%s must not reimplement the measurement path (%s)' % (name.name, forbidden)
roi = (root / 'Horos/Sources/ROI.m').read_bytes().decode('latin1')
assert 'getROIValue:no :self :nil]' in roi, 'ROI statistics must come from DCMPix'
dcmpix = (root / 'Horos/Sources/DCMPix.m').read_bytes().decode('latin1')
assert 'computedfImage = [self computefImageForMeasurement];' in dcmpix

# Strings and project membership.
for catalog in ('it-IT', 'es'):
    text = (root / 'Horos/Resources' / (catalog + '.lproj') / 'Localizable.strings').read_text(encoding='utf-8')
    assert '"Original renderer (Metal paused)" = "' not in text, 'the notice is gone with the original renderer (#735)'
for name in ('MPRHostBridge.m', 'MPRMetalReslicer.swift'):
    assert sum(name in line for line in project.splitlines()) == 4, name + " is not fully registered in the Xcode project"
print('mpr metal host wiring: hook, refusals, notice, strings and project membership in place')
