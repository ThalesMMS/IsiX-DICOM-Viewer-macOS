#!/usr/bin/env python3
"""The comparison GIF is made of the viewer's own captures.

Source-level contract:

- the companion is the fused series from `blendingController`, the product of
  the Fusion dialog, and the blend is the host's own blend slider — no second
  renderer, no second registration and no viewer picked by name or order;
- the blend the user had is restored in a `defer`, so a capture that fails
  part-way leaves the viewer where it was;
- captures that arrive after the comparison moved are refused, not encoded;
- the animation reaches the clipboard as data through the shared policy: no
  temporary file is written, so none can be left behind or left invalid;
- the menu item, the Italian and Spanish strings and the Xcode membership are
  in place;
- and it stands in for none of the exports that have their own acceptance:
  fused DICOM, movie/codec, flythrough and drag file promises.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
# The bridge is Swift: ViewerController+RegisteredGIF.swift; the slider value
# of a blend is IsiXImaging's FusionComparison.
bridge = (root / 'Horos/Sources/ViewerController+RegisteredGIF.swift').read_text()
fusion = (root / 'Modules/IsiXImaging/Sources/ViewerFusion/FusionComparison.swift').read_text()
policy = (root / 'Horos/Sources/RegisteredGIFExport.swift').read_text()
# AppController is Swift: it calls the installer in Swift.
app = source_text('AppController')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
italian = (root / 'Horos/Resources/it-IT.lproj/Localizable.strings').read_text()
spanish = (root / 'Horos/Resources/es.lproj/Localizable.strings').read_text()

# The comparison is the host's fusion, not a second one.
assert 'let companion = blending()?.horosSeriesDICOMUID() ?? ""' in bridge, \
    'the companion must be the fused series of the Fusion dialog'
assert 'horosRegistrationSession()' in bridge, 'the session is the one the longitudinal registration publishes'
for forbidden in ('get2DViewers', 'patientName', 'BrowserController', 'CGContext', 'MTLDevice', 'vtk'):
    assert forbidden not in bridge, 'the bridge must not reach for ' + forbidden
assert 'imageView()?.nsimage(false)' in bridge, 'the frames are the captures the viewer already draws'
assert 'let slider = blendingSlider()' in bridge and 'sliderFusion' not in bridge \
    and 'FusionComparison.sliderValue(stop: blend, minimum: low, maximum: high)' in bridge \
    and 'minimum.addingProduct(stop, maximum - minimum)' in fusion, \
    'the blend is the Fusion panel blend slider, not the slab thickness slider'

# The viewer goes back to where the user left it, even when a capture fails.
capture = bridge[bridge.index('private func captureBlendFrames('):]
capture = capture[:capture.index('\n    }\n')]
restore = capture[capture.index('defer {'):capture.index('defer {') + 160]
assert 'slider?.doubleValue = previous' in restore and 'blendingSlider(slider)' in restore, \
    'the blend the user had must be restored in a defer, not only on success'
assert capture.index('defer {') < capture.index('nsimage(false)'), 'the capture loop runs under the defer'

# Captures from a comparison that moved are not this comparison.
assert 'RegisteredGIF.refusalForApplying(plan, to: horosRegistrationSession())' in bridge, \
    'a comparison that changed while being captured must refuse its captures'
assert bridge.index('refusalForApplying(plan') > bridge.index('let frames = captureBlendFrames('), \
    'the check belongs after the captures, which is when the change can have happened'

# The clipboard route is a data route.
assert 'RegisteredGIF.copy(data, to: NSPasteboard.general)' in bridge, \
    'the animation goes to the general pasteboard through the shared policy'
for forbidden in ('NSTemporaryDirectory', 'temporaryDirectory', 'write(to', 'NSSavePanel', 'createFile'):
    assert forbidden not in bridge, 'the clipboard route must not write a file: ' + forbidden
assert 'writesTemporaryFiles() -> Bool { false }' in policy

# A panel-free core, so the capture can be exercised without a modal answer.
assert '@objc(horosRegisteredComparisonGIFWithBlendStops:delaySeconds:refusal:)' in bridge \
    and 'refusal: AutoreleasingUnsafeMutablePointer<NSString?>?' in bridge, 'the capture must be callable without a panel'
core = bridge[bridge.index('func registeredComparisonGIF('):bridge.index('@IBAction @objc(copyRegisteredComparisonGIF:)')]
for forbidden in ('NSAlert', 'runModal', 'NSPasteboard'):
    assert forbidden not in core, 'the panel-free core must not ' + forbidden

# Menu, catalogs, project.
assert 'ViewerController.installRegisteredGIFMenuItems()' in app and '@objc class func installRegisteredGIFMenuItems()' in bridge, \
    'the menu item must be installed'
assert 'menu.horosItem(sending: #selector(copyROIsFromFusedSeries(_:)))' in bridge, 'the item sits with the other fusion items'
assert 'item.target = nil' in bridge, 'the item goes to the front viewer through the responder chain'
for catalog, language in ((italian, 'it-IT'), (spanish, 'es')):
    for key in ('Copy Registered Comparison as GIF', 'The Comparison Was Not Copied',
                'The registered comparison could not be copied to the clipboard.'):
        assert '"%s"' % key in catalog, '%s is missing from %s' % (key, language)
assert sum('ViewerController+RegisteredGIF.swift' in line for line in project.splitlines()) == 4, \
    'ViewerController+RegisteredGIF.swift is not fully registered in the Xcode project'
assert sum('RegisteredGIFExport.swift' in line for line in project.splitlines()) == 4, \
    'RegisteredGIFExport.swift is not fully registered in the Xcode project'

# It replaces nothing that has its own acceptance.
for name in ('replacesFusedDICOMExport', 'replacesMovieExport', 'replacesFlythrough', 'replacesDragFilePromises'):
    assert '%s() -> Bool { false }' % name in policy, name + ' must stay false'
for other in ('QuicktimeExport', 'DICOMExport', 'flythrough', 'filePromise'):
    assert other not in bridge, 'the comparison GIF must not take over ' + other

print('PASS: the comparison GIF is the viewer\'s own captures at the host\'s own blend, restored in a defer, '
      'refused when the comparison moved, and copied to the clipboard as data with no file written')
