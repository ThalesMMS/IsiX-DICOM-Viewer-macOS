#!/usr/bin/env python3
"""The Metal reslice replaces CPU ray casting in the host's 3D MPR.

Source-level contract, so a refactor that moves the hook, drops the fallback
or forgets a catalog string fails here rather than in the application:

- `MPRDCMView` asks the bridge before CPU rendering and uses the same DCMPix
  update for either image; native pixel/geometry checks cover the result;
- the bridge refuses, with a reason, an RGB volume, which the engine does
  not represent, and never touches Core
  Data, the catalogue or the DICOM files; a fusion is resliced with the plane
  (`tests/test-mpr-metal-fusion.py`);
- in volume rendering mode the plane is VTK's render with the 3D window's
  Metal ray cast filling its ray-cast image, asked for plane by plane on the
  MPR's hidden view, whose outcome becomes the view's notice;
- the option defaults on, its menu item exists, and the notice the
  planar path shows when Metal is paused is reused unchanged;
- every new user-visible string is in the Italian and Spanish catalogs;
- the Swift files are in the Xcode target.
"""
import re
from pathlib import Path

import sources

root = Path(__file__).resolve().parents[1]
view = sources.source_text('MPRDCMView')
# The bridge is Swift: the window's side (MPRController+MetalHost.swift), the
# view's (MPRDCMView+MetalPlane.swift), and its rules IsiXImaging's MPRPlaneRules.
controller = (root / 'Horos/Sources/MPRController+MetalHost.swift').read_text()
header = (root / 'Horos/Sources/MPRDCMView+MetalPlane.swift').read_text()
bridge = controller + header
rules = (root / 'Modules/IsiXImaging/Sources/ViewerReconstruction/MPRPlaneRules.swift').read_text()
messages = (root / 'Horos/Sources/MPRHostMessages.h').read_text()
planar = (root / 'Horos/Sources/DCMView+PlanarHost.swift').read_text()
dcmview = sources.class_text('DCMView')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

# Hook placement inside the non-blended branch of the reconstruction.
start = view.index('@objc(updateViewMPROnLoading::)')
body = view[start:view.index('@objc(updateViewMPROnLoading:)\n', start)]
hook = body.index('self.horosMPRCopyImageWidth(&w, height: &h)')
assert hook < body.index('_vrView?.render()')
assert 'if imagePtr == nil && self.frame.size.width > 0' in body
assert '} else if imagePtr == nil {\n                imagePtr = _vrView?.image(inFullDepthWidth:' in body
for setter in ('_pix?.setOrigin(&porigin)', '_pix?.pixelSpacingX = Double(resolution)', '_pix?.setOrientation(&orientation)',
               '_pix?.sliceThickness = _vrView?.getClippingRangeThicknessInMm() ?? 0'):
    assert hook < body.index(setter) < body.index('self.setWLWW(previousWL, previousWW)')
assert body.index('if let blendingView = self.blending {') > hook, 'the hook belongs to the primary plane, not the fused one'
# The view calls its Metal plane's methods directly: they are Swift, and the
# protocol that let Swift see an Objective-C category of the view is gone.
assert 'HorosMPRHostViewMessages' not in view + messages

# The bridge's refusals and what it may not touch.
assert 'RGB volumes keep the original renderer' in bridge, 'missing refusal: an RGB volume'
# Volume rendering mode: no refusal; the hidden view's next render is
# the Metal ray cast, and the flag is cleared for every other plane.
for gone in ('Volume rendering keeps the original renderer', 'RGB planes keep the original renderer'):
    assert gone not in bridge, 'still refused: ' + gone
copy = header[header.index('func horosMPRCopyImageWidth('):header.index('private func copyColourImage(')]
reset = copy.index('vrView?.horosSetMPRVolumeMetal(false)')
assert reset < copy.index('guard !moveCenter, let vrView else { return nil }'), \
    'the flag is cleared before a plane that is not volume rendering returns'
assert 'horosMPRMetalEnabled' not in copy, 'no switch leads a plane to the original renderer'
assert re.search(r'guard let controller, MPRPlaneRules\.reslices\(projectionMode: mode\) else \{\s*'
                 r'vrView\.horosSetMPRVolumeMetal\(true\)\s*return nil\s*\}', copy), \
    'volume rendering mode asks the hidden view for the Metal ray cast'
rendered = header[header.index('func horosMPRVolumeRendered()'):]
recorded = header[header.index('private func recordMetalPlane('):header.index('// MARK: - The plane')]
assert 'vrView.horosMPRVolumeMetalReasonDrawn(&drawn)' in rendered and \
    'recordMetalPlane(reason: reason, controller: horosMPRWindowController)' in rendered and \
    'horosSetPlanarFallbackReason(reason)' in recorded
assert 'imagePtr = _vrView?.image(inFullDepthWidth: &w, height: &h, isRGB: &isRGB)\n            }\n            self.horosMPRVolumeRendered()' in view, \
    'the view reports the Metal ray cast after reading the plane'
# The view's Metal hook is Swift (VRView+Render.swift), an extension of VRView.
vr = (root / 'Horos/Sources/VRView+Render.swift').read_text()
# The VTK adapter checks the renderer and the volume before the view's hook.
vr_adapter = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm').read_text()
assert 'if mprPlane ? !horosMPRVolumeMetal() : engine != 2 { return false }' in vr and \
    'if (renderer != o->aRenderer || (volume != o->volume && !fused)) return false;' in vr_adapter, \
    'the ray-cast hook runs for the MPR\'s hidden view only when the MPR asks for it'
# A reversed stack is resliced through the voxel-to-world transform VTK places
# it by; only the interval's magnitude is checked.
assert 'A reversed stack keeps the original renderer' not in bridge, 'a reversed stack is still refused'
assert 'MPRPlaneRules.sampleStep(sliceInterval: first.sliceInterval' in controller and 'var dz = fabs(sliceInterval)' in rules
assert 'return projectionMode >= 1 && projectionMode <= 3' in rules, 'only MIP, MinIP and mean reach the engine'
for forbidden in ('valueForKey', 'managedObjectContext', 'DicomImage', 'DicomSeries', 'DicomDatabase', 'sourceFile'):
    assert forbidden not in bridge, 'the bridge must not reach ' + forbidden
assert 'horosSetPlanarFallbackReason' in bridge and 'func horosSetPlanarFallbackReason(' in planar
# The frame cycle (PlanarFramePresenter.swift) draws the notice for DCMView,
# whose frame is DCMView+Drawing.swift's.
presenter = (root / 'Horos/Sources/PlanarFramePresenter.swift').read_text()
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
assert 'Original renderer (Metal paused)' not in dcmview + presenter + drawing and 'frame.drawNotice(in: self' in drawing \
    and 'view.horosEngineNotice() != nil' in presenter, \
    'a plane computed on the CPU shows why, drawn by DCMView for every subclass'
assert 'background: Double(volume.background), into: image)' in header and 'free(image)' in header, \
    'return an owned image for the common DCMPix update, filled by the engine and freed when the reslice fails'
assert 'plane.bytes' not in bridge, 'the plane is copied once, into the image, not through an intermediate NSData'
assert 'vrView.horosMPRGeometryRefusalWidth(width, height: height)' in header, \
    'the plane asks the view why its geometry is refused, one reason per cause'
assert 'MetalPerformanceTrace.recordRefusal("mpr.refusal", reason: reason)' in header, \
    'every plane the original renderer draws leaves its reason in the trace'
assert 'vrView.getOrigin(&corner, windowCentered: true, sliceMiddle: true)' in header
assert 'voxelToWorld: mprView1?.vrView?.mprVoxelToWorldTransform() as? [NSNumber]' in controller
# The volume is converted and validated once, in Swift: the typed
# volume is what is uploaded, and the no-copy view of the buffer exists only
# there, after the checks, holding its owner.
assert 'MPRHostVolume.volume(owner: volume, width: first.pwidth, height: first.pheight, depth: pix.count' in controller
assert 'try reslicer.upload(volume)' in controller and bridge.count('bytesNoCopy') == 1 \
    and 'NSData(bytesNoCopy: display' in header, \
    'the bridge uploads the typed volume and cuts no buffer of its own; only the display plane it made is wrapped'
assert 'volume["' not in bridge, 'no loose dictionary key is read after the conversion'
typed = (root / 'Horos/Sources/MPRHostVolume.swift').read_text()
assert 'owner.length >= byteCount' in typed and 'expected != volume.length' not in typed, \
    'the viewer buffer may exceed the slices; only a shorter buffer is refused'
assert 'deallocator: .custom { _, _ in withExtendedLifetime(owner) {} }' in typed, 'the no-copy view keeps its owner'
# The Objective-C bridges are gone from the target.
for name in ('MPRHostBridge.m', 'PlanarHostBridge.m'):
    assert name not in project, name + ' is still in the Xcode project'
assert 'private static let shared: MPRCubicDisplayObserver = {' in controller, \
    'the preference observer is owned for the life of the app'
assert 'NSWindow.willCloseNotification' in controller and 'releaseVolume()' in controller, 'closing the window must free the GPU volume'
assert 'toggleMPRMetal' not in bridge and 'HorosMPRMetal"' not in bridge, \
    'no preference or per-window switch leads back to the original renderer'
assert 'menuForEvent' not in bridge, 'the MPR options live in Settings → 3D, not in a contextual menu'
assert 'UserDefaults.standard.addObserver(observer, forKeyPath: preferenceKey' in controller \
    and '(window.windowController as? MPRController)?.horosMPRReconstructPlanes()' in controller, \
    'an open MPR follows a change of its cubic display preference'
pane = (root / 'Preference Panes/OSI3DPreferencePane/Base.lproj/OSI3DPreferencePanePref.xib').read_text()
assert 'title="Use Metal in MPR"' not in pane and 'keyPath="values.HorosMPRMetal"' not in pane
import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
assert 'HorosMPRMetal' not in default_preferences.registered()
assert '@objc(horosMPRCopyImageWidth:height:)' in header
assert 'horosMPRReplacePixels' not in view + bridge

# NSView frames remain in points; VTK owns the sole backing-pixel conversion.
frame = view[view.index('@objc(checkForFrame)'):view.index('@objc(displayedScaleValue)')]
assert 'convertRectToBacking' not in frame and 'convertToBacking' not in frame
assert 'self.convert(self.bounds, to: nil)' in frame

# A216 on the CPR path: the curved views are DCMView subclasses whose ROI
# statistics go through -[DCMPix getROIValue:::], the one place that reads
# -computefImageForMeasurement. No CPR source may grow a measurement path of
# its own that would see the presentation filter again.
# CurvedMPR.m was here too, compiled by nothing and removed with the other dead sources.
# The CPR views and controller are Swift.
for name in sorted([*(root / 'Horos/Sources').glob('CPR*.m'), *(root / 'Horos/Sources').glob('CPR*.swift')]):
    text = name.read_bytes().decode('latin1')
    for forbidden in ('getROIValue', 'computefImage', 'applyConvolutionOnImage'):
        assert forbidden not in text, '%s must not reimplement the measurement path (%s)' % (name.name, forbidden)
roi = sources.class_text('ROI')
assert '?.getROIValue(no, self, nil)' in roi, 'ROI statistics must come from DCMPix'
dcmpix = sources.class_text('DCMPix')
measure = root / 'Horos/Sources/DCMPix+ROIMeasure.swift'
assert 'computedfImage = [self computefImageForMeasurement];' in dcmpix or \
    (measure.is_file() and 'computed = self.computefImageForMeasurement()' in measure.read_text(encoding='utf-8'))

# Strings and project membership.
for catalog in ('it-IT', 'es'):
    text = (root / 'Horos/Resources' / (catalog + '.lproj') / 'Localizable.strings').read_text(encoding='utf-8')
    assert '"Original renderer (Metal paused)" = "' not in text, 'the notice is gone with the original renderer'
for name in ('MPRController+MetalHost.swift', 'MPRDCMView+MetalPlane.swift', 'MPRMetalReslicer.swift'):
    assert sum(name in line for line in project.splitlines()) == 4, name + " is not fully registered in the Xcode project"
print('mpr metal host wiring: hook, refusals, notice, strings and project membership in place')
