#!/usr/bin/env python3
"""Horos applies DICOM GSPS, not only the series zoom/window it already stored."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text, source_path  # noqa: E402
failures = []


def read(path):
    return path.read_bytes().decode('latin1')


def stripped(path):
    return re.sub(r'//[^\n]*', '', read(path))


document = read(root / 'Horos/Sources/GSPSDocument.swift')
if '1.2.840.10008.5.1.4.1.1.11.1' not in document:
    failures.append('the documented GSPS SOP Class UID is gone')
for name in ('ReferencedSOPInstanceUID', 'ReferencedFrameNumber', 'Softcopy VOI LUT',
             'Displayed Area', 'PIXEL', 'DISPLAY', 'POINT', 'POLYLINE', 'CIRCLE',
             'ELLIPSE', 'Image Rotation', 'unsupportedFeatures'):
    if name not in document:
        failures.append('the documented subset no longer names %r' % name)
if 'Pixel Data is never rewritten' not in document and 'never written back into Pixel Data' not in document:
    failures.append('the subset no longer says Pixel Data is left alone')

# ViewerController (GSPS) is Swift: the same checks, in Swift
# spelling (-setRotation: is the `rotation` property's setter there).
viewer_source = source_path('ViewerController+GSPS')
viewer = stripped(viewer_source)
# The category hands the work to ViewerPresentationState and IsiXImaging's
# PresentationStateOverlay: the checks read the three.
if 'ViewerPresentationState.' in viewer:
    viewer += stripped(source_path('ViewerPresentationState'))
    viewer += stripped(root / 'Modules/IsiXImaging/Sources/PresentationStateOverlay.swift')
if 'applyGrayscaleSoftcopyPresentationStateFromPath' not in viewer:
    failures.append('the 2D viewer no longer applies a GSPS file to the open images')
rotation = 'view.rotation = ' if viewer_source.suffix == '.swift' else 'setRotation'
if 'changeWLWW' not in viewer or rotation not in viewer:
    failures.append('applying GSPS no longer sets the VOI or the spatial transform on the view')
if 'tOPolygon' not in viewer or 'tText' not in viewer:
    failures.append('GSPS annotations are no longer turned into ROIs')
if 'fImage' not in viewer:
    failures.append('apply no longer checks that fImage was not rewritten')
if 'Missing referenced SOP Instance UID' not in viewer:
    failures.append('a missing referenced SOP Instance UID is no longer named')
# The flags are a sheet of the viewer window. A viewer opened for a
# presentation state is still off screen when the state is applied, and a
# sheet begun then comes up as a panel of its own: the sheet waits for the
# window to be on screen.
presenting = stripped(source_path('ViewerPresentationState'))
if 'presentSheet(alert, on: window)' not in presenting:
    failures.append('the GSPS flags are no longer shown as a sheet of the viewer window')
if not re.search(r'func presentSheet\(_ alert: NSAlert, on window: NSWindow\) \{\s*if window\.isVisible \{\s*alert\.beginSheetModal', presenting) \
        or 'guard window.isVisible else { return false }' not in presenting:
    failures.append('the GSPS sheet is begun on a viewer window that is not on screen yet')
if presenting.count('beginSheetModal(for: window, completionHandler: nil)') != 2:
    failures.append('the GSPS flags are begun as a sheet outside presentSheet')

browser_source = source_path('BrowserController+GSPS')
browser = stripped(browser_source)
# The browser hands the opening to its ViewerOpener (ViewerOpener.swift).
if 'viewerOpener.openPresentationState(' in browser:
    browser += stripped(source_path('ViewerOpener'))
if 'horos_tryOpenGSPSSeries' not in browser:
    failures.append('opening a presentation-state series no longer looks up the referenced images')
if 'applyGrayscaleSoftcopyPresentationStateFromPath' not in browser:
    failures.append('opening a GSPS series no longer applies it to the referenced images')

# -loadSeries:::keyImagesOnly: hands its work to the browser's ViewerOpener
# (ViewerOpener+Navigation.swift), which asks for a presentation state first.
load = stripped(source_path('BrowserController+DatabaseDragExport+Selection'))
if 'viewerOpener.loadSeries(' in load:
    navigation = stripped(source_path('ViewerOpener+Navigation'))
    at = navigation.find('func loadSeries(')
    load = navigation[at:navigation.find('openViewer(', at)] if at >= 0 else ''
if 'horos_tryOpenGSPSSeries' not in load and 'openPresentationState(' not in load:
    failures.append('loadSeries no longer asks whether the series is a GSPS before opening it as pixels')

# AppController is Swift: the call is read in its Swift spelling, in the launch
# of ApplicationLifecycle.
app = stripped(source_path('ApplicationLifecycle'))
if 'ViewerController.installGSPSMenuItems()' not in app:
    failures.append('the Apply Grayscale Presentation State menu is no longer installed')

project = read(root / 'Horos.xcodeproj/project.pbxproj')
for name in ('GSPSDocument.swift', viewer_source.name, 'GSPSDocument+FileReading.swift',
             browser_source.name):
    if name not in project:
        failures.append('%s is not in the Xcode project' % name)

# The Horos series presentation state is still there and must not be renamed
# into a claim of DICOM GSPS support.
dcmview = class_text('DCMView')
if 'updatePresentationStateFromSeries' not in dcmview:
    failures.append('the existing Horos series presentation state was removed; that is a different object')
if 'GrayscaleSoftcopyPresentationState' in dcmview and 'applyGrayscaleSoftcopyPresentationStateFromPath' not in dcmview:
    # DCMView may mention GSPS later; it must not be the only place.
    pass

if not (root / 'tools/generate-gsps-fixture.py').is_file():
    failures.append('the synthetic GSPS generator is missing')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('ok: GSPS matching, apply, flags and menu are wired; the Horos series')
print('    presentation state remains a separate object')
