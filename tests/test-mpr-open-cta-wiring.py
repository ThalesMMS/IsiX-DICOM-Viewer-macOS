#!/usr/bin/env python3
"""3D MPR CTA crash path is gated before convertDICOMCoords.

horosproject/horos#391 is a SIGSEGV in MPRDCMView.subDrawRect while
VRController.computeMinMax presents a modal during hidden-MPR init.
horosproject/horos#359 recovered after a clean profile. This test keeps
that stack attached to the Swift geometry gate and refuses Universal Binary
as a cause.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []

# Public crash from horosproject/horos#391 (Horos 3.2.2, 2018-09-18).
# Full report stays off-git; this is the crashed thread only.
EXCERPT = """
Process:               Horos [50712]
Version:               3.2.2 (20180918)
Code Type:             X86-64 (Native)
OS Version:            Mac OS X 10.13.6 (17G2307)
Crashed Thread:        0  Dispatch queue: com.apple.main-thread
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
Exception Codes:       KERN_INVALID_ADDRESS at 0x00000000c5000018
Application Specific Information:
objc_msgSend() selector name: convertDICOMCoords:toSliceCoords:pixelCenter:
Performing @selector(mprViewer:) from sender NSMenuItem
Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
0   libobjc.A.dylib                objc_msgSend
1   Horos                          -[MPRDCMView subDrawRect:]
2   Horos                          -[DCMView drawRect:withContext:]
3   com.apple.AppKit               NSRunCriticalAlertPanel
4   Horos                          -[VRController computeMinMax]
5   Horos                          -[VRController initWithPix:::::style:mode:]
6   Horos                          -[MPRController initWithDCMPixList:filesList:volumeData:viewerController:fusedViewerController:]
7   Horos                          -[ViewerController openMPRViewer]
8   Horos                          -[ViewerController mprViewer:]
"""


def body(path, signature):
    # A file that is gone (ViewerController.m) has no body to give.
    source = path.read_bytes().decode('latin1') if path.exists() else ''
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


def check(condition, message):
    if not condition:
        failures.append(message)


check('EXC_BAD_ACCESS' in EXCERPT and 'SIGSEGV' in EXCERPT, 'keep the 3.2.2 SIGSEGV')
check('convertDICOMCoords:toSliceCoords:pixelCenter:' in EXCERPT, 'the selector is overlay conversion')
check('mprViewer:' in EXCERPT and 'computeMinMax' in EXCERPT, 'the modal is inside MPR open')
check('Universal Binary' not in EXCERPT, 'do not pin this crash on Universal Binary')
check('X86-64' in EXCERPT, 'architecture stays as printed')

swift = (root / 'Horos/Sources/MPROpenGeometry.swift').read_text(encoding='utf-8')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
viewer = root / 'Horos/Sources/ViewerController.m'
mpr = sources.source_path('MPRDCMView')
vr = root / 'Horos/Sources/VRController.swift'
scissor = (root / 'Horos/Sources/VRScissorBounds.swift').read_text(encoding='utf-8')
centerline = (root / 'Horos/Sources/CPRCenterlineImport.swift').read_text(encoding='utf-8')
curved = (root / 'Horos/Sources/CurvedMPRPath.swift').read_text(encoding='utf-8')

check('HorosMPROpenGeometry' in swift, 'Swift helper must stay @objc HorosMPROpenGeometry')
check('openingWithSliceCount:spacingX:spacingY:sliceInterval:minInterval:maxInterval:width:height:mismatchedSlices:roiCount:' in swift,
      'the ten-argument opener must stay')
check('mismatchedOrientations' in swift, 'IOP coherence stays on the existing helper')
check('images do not share a single orientation' in swift,
      'mixed IOP must keep a named diagnosis')
check('MPROpenGeometry.swift in Sources' in pbx, 'the helper must be in the Horos target')
check('class VRScissorBounds' in scissor, 'VRScissorBounds must stay')
check('class CPRCenterlineImport' in centerline, 'CPRCenterlineImport must stay')
check('class CurvedMPRPathSession' in curved, 'CurvedMPRPath must stay')

# The gathering moved out of -mprViewer: so the orthogonal MPR and the CPR could
# ask the same question instead of drawing empty planes.
# They are ThreeDViewerLauncher's (the viewer's selectors are its façade): each
# door runs the checks IsiXImaging's VolumeEligibility gives it, in its order.
launcher = root / 'Horos/Sources/ThreeDViewerLauncher.swift'
launcher_text = launcher.read_text(encoding='utf-8')
eligibility = (root / 'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeEligibility.swift').read_text(encoding='utf-8')
scan = (root / 'Modules/IsiXImaging/Sources/ViewerReconstruction/ReconstructionGeometryScan.swift').read_text(encoding='utf-8')
decision = body(launcher, 'func reconstructionOpeningDecision() -> MPROpenDecision')
check('MPROpenGeometry.opening(withSliceCount:' in decision, 'the shared decision must consult the Swift opening gate')
check('mismatchedOrientations: scan.mismatchedOrientations' in decision, 'the shared decision must pass the IOP mismatch count')
check('ReconstructionGeometryScan.scan(' in decision and 'static let orientationTolerance = 0.001' in scan,
      'IOP compare must use the same sensibility as isDataVolumicIn4D')

# The geometry checks ask the shared decision and name its diagnosis.
refusal = body(launcher, 'private func refusal(of check: VolumeEligibility.Check) -> VolumeEligibility.Refusal?')
for case in ('case .geometry:', 'case .calibratedGeometry:'):
    start = refusal.find(case)
    branch = refusal[start:refusal.find('case .', start + len(case))] if start >= 0 else ''
    check('reconstructionOpeningDecision()' in branch and 'diagnosis: geometry.diagnosis' in branch,
          'the %s check must ask the shared geometry decision and keep its diagnosis' % case[5:-1])
passes = body(launcher, 'private func passesChecks(_ reconstruction: VolumeEligibility.Reconstruction, sender: Any?) -> Bool')
check('case .geometry(let diagnosis), .fourDFrames(let diagnosis):' in passes and 'alert(Self.title(of: reconstruction), diagnosis)' in passes,
      'a refused geometry must surface the named geometry diagnosis, not an empty plane')

for action, door, kind in (('func openObliqueMPR(_ sender: Any?)', '.obliqueMPR', '.calibratedGeometry'),
                           ('func openOrthogonalMPR(_ sender: Any?)', '.orthogonalMPR', '.geometry'),
                           ('func openCurvedMPR(_ sender: Any?)', '.curvedMPR', '.geometry')):
    opened = body(launcher, action)
    listed = re.search(r'case %s:\s*return (\[[^\]]*\])' % re.escape(door), eligibility)
    check('passesChecks(%s, sender: sender)' % door in opened and listed is not None and kind in listed.group(1),
          '%s must ask the shared geometry decision' % action)

draw = body(mpr, 'public override dynamic func subDraw(_ r: NSRect)')
check('MPROpenGeometry.canConvertSliceCoords(' in draw, 'subDrawRect must consult the overlay gate')
check('canConvertSliceCoords' in draw, 'subDrawRect must not convert coords blindly')
check('_vrView != nil' in draw, 'overlay waits until the hidden VR view is attached')

minmax = body(vr, '    public final func computeMinMax() {')
check('shouldPresentHighDynamicPrompt' in minmax, 'hidden-MPR init must skip the high-dynamic modal')
check('noNib' in minmax, 'the skip is the hidden MPR style, not all VR')

wrapper = body(viewer,
               '- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c;')
# The volumic checks are Swift, in ViewerController+VolumeCheck.swift.
if not wrapper:
    wrapper = body(sources.source_path('ViewerController+VolumeCheck'),
                   'func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool) -> Bool')
check('check4D' in wrapper and ('tryToCorrect: YES' in wrapper or 'tryToCorrect: true' in wrapper),
      'the two-arg volumic wrapper must keep forwarding check4D')

if failures:
    for item in failures:
        print('FAIL:', item)
    sys.exit(1)
print('ok: the stack stays on convertDICOMCoords during computeMinMax; MPR gate is wired')
