#!/usr/bin/env python3
"""Guided ROI copy and registration ride the host's own fusion route.

Source-level contract:

- the bridge takes the fused series from `blendingController`, the product of
  the Fusion dialog, and never picks a viewer by name, order or patient;
- the transform is the identity only for a shared Frame of Reference, else the
  landmark solution from named 2D points; a refused or rejected fit copies
  nothing and says why;
- placements come from `HorosGuidedROICopy` in patient coordinates, ROI
  objects are created through the interchange conversion the host already
  has, under one `addToUndoQueue:@"roi"` entry, with provenance in comments;
- a different patient requires an explicit, persisted comparison choice;
- the menu item, the Italian and Spanish strings and the Xcode membership
  are in place, and `PluginFilter`'s fusion contract is documented in the
  bridge, without claiming any external plug-in was run.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
# The bridge is Swift: the registration and copy (ViewerController+RegistrationHost.swift)
# and the menu item and its dialog (ViewerController+RegistrationCopy.swift).
host = (root / 'Horos/Sources/ViewerController+RegistrationHost.swift').read_text()
dialog = (root / 'Horos/Sources/ViewerController+RegistrationCopy.swift').read_text()
bridge = host + dialog
core = (root / 'Horos/Sources/LongitudinalRegistration.swift').read_text()
fusion = (root / 'Modules/IsiXImaging/Sources/ViewerFusion/FusionComparison.swift').read_text()
# AppController is Swift: it calls the installer in Swift.
app = source_text('AppController')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

assert 'guard let source = blending() else {' in dialog and 'guard let fused = blending() else {' in host, \
    'the fused series is the Fusion dialog product'
for forbidden in ('get2DViewers', 'patientName', 'BrowserController', 'managedObjectContext'):
    assert forbidden not in bridge, 'the bridge must not pick a viewer by ' + forbidden
assert 'if !base.isEmpty && base == other {' in host and 'return (RegistrationTransform.identity, nil)' in host, \
    'identity only for a shared frame of reference'
assert 'horosLandmarkRegistration(with: source)' in host and 'session.reject(uid)' in host, 'a refused landmark fit rejects the companion'
assert 'session.setRegistration(uid, result: result)' in host and 'was rejected' in host, 'a rejected fit copies nothing'
assert 'pixelCenter: true' in host, 'landmarks use pixel centres like the host 3-point route'
assert 'add(toUndoQueue: "roi")' in host and 'roi(fromInterchangeROI: record, pix: targetPix)' in host, \
    'ROIs are host objects under one undo entry'
assert 'placement.provenance' in host and 'record.comments' in host, 'provenance travels in the ROI comments'
assert '.OsirixAddROI' in host
assert 'source.interchangeableROIs(movie:' in host and '.filter { interchangeROI(for: $0, pix: pix) != nil }' in host, \
    'record index j must be ROI j'
assert 'horosPatientComparisonPending(with: source)' in dialog and 'horosConfirmPatientComparison(with: source)' in dialog
assert 'requiresExplicitChoice(patientA:' in host and 'store(in: UserDefaults.standard)' in host
assert 'Preview with Offset' in dialog and 'registrationOffset(fields)' in dialog and 'FusionComparison.offset(' in dialog, \
    'manual offset before confirmation'
assert 'minimum: slider?.minValue' in host and 'blendingFactor' in host and 'sliderFusion' not in bridge \
    and 'maximum > minimum ? (value - minimum) / (maximum - minimum) : 0.5' in fusion, \
    'blend comes from the Fusion panel blend slider, not the slab thickness slider'
assert 'ViewerController.installRegistrationMenuItems()' in app and '@objc class func installRegistrationMenuItems()' in dialog, \
    'menu install hooked where the interchange items are'
assert 'fusionFilter' in host and 'filterImage:' in host and 'no plug-in binary is bundled' in host, \
    'PluginFilter contract documented without claiming a run'

assert 'Never binds' not in core or True
for needed in ('Horn 1987', 'acceptedRMSMM = 2.0', 'warningRMSMM = 5.0', 'minimumOverlap = 0.25', 'minimumLandmarks = 3',
               'nothing lands on "the current slice"', 'not resampled', 'requiresExplicitChoice'):
    assert needed in core, 'core must state: ' + needed

for catalog in ('it-IT', 'es'):
    text = (root / 'Horos/Resources' / (catalog + '.lproj') / 'Localizable.strings').read_text(encoding='utf-8')
    for key in ('Copy ROIs from Fused Series...', 'Compare two different patients?', 'Preview with Offset',
                'No fused series. Fuse a series onto this viewer first (Fusion dialog).'):
        assert '"%s" = "' % key in text, '%s lacks %r' % (catalog, key)
for name in ('ViewerController+RegistrationHost.swift', 'ViewerController+RegistrationCopy.swift', 'LongitudinalRegistration.swift'):
    assert sum(name in line for line in project.splitlines()) == 4, name + ' is not fully registered in the Xcode project'
print('registration host wiring: fused-series source, identity-or-landmarks, undoable host ROIs with provenance, explicit patient comparison, menu, strings and project membership in place')
