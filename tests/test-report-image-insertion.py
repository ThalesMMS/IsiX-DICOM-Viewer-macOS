#!/usr/bin/env python3
"""Wire selected-image insertion into the Pages/Word report menu.

The placement math lives in ReportImagePlacement.swift. This check is the host
contract: the File > Report action, the study-local report, and a refusal that
does not walk the Pages→PDF conversion path.
"""
from pathlib import Path
import xml.etree.ElementTree as ET
from sources import source_text, class_text

root = Path(__file__).resolve().parents[1]
failures = []

swift = (root / 'Horos/Sources/ReportImagePlacement.swift').read_text()
for needle, reason in (
    ('end of body text', 'Pages must insert inline so a reopen cannot slide a box'),
    ('inline picture', 'Word must insert an inline picture, not a floating shape'),
    ('defaultBox', 'the figure size has to be one predictable box'),
    ('writeCopy', 'the source image has to be copied, not rewritten'),
    ('replaceItemAt', 'the original report is published only after a successful copy'),
    ('com.apple.Pages', 'modern Pages is asked for by identifier'),
    ('Microsoft Word', 'Word is a first-class report target, not a Pages leftover'),
    ('repeat with attempt from 1 to 60', 'the editor script must wait for the private copy'),
    ('on error errorMessage number errorNumber', 'a refused insert must capture the AppleScript number'),
    ('error -1712', 'a timeout is not swallowed as a generic insert failure'),
    ('error -609', 'a dropped Automation connection is not swallowed'),
    ('error -10024', 'a Pages container refusal must keep its number'),
):
    if needle not in swift:
        failures.append(reason)

browser = class_text('BrowserController')
# The action and the image rendering are Swift (BrowserController+ReportImport.swift);
# the generated interface, which BrowserController.h imports, declares them for
# the Objective-C callers.
report_import = (root / 'Horos/Sources/BrowserController+ReportImport.swift').read_text()
header = (root / 'Horos/Sources/BrowserController.h').read_bytes().decode('latin1')
if '#import "Horos-Swift.h"' not in header:
    failures.append('BrowserController.h does not expose the Swift actions')
if '@objc(insertSelectedImagesIntoReport:)' not in report_import:
    failures.append('BrowserController does not implement the insertion action')
start = report_import.find('@objc(insertSelectedImagesIntoReport:)')
action = report_import[start:report_import.find('\n    }\n}\n', start)] if start >= 0 else ''
if 'ReportImageInsertion.insert(' not in action:
    failures.append('the action does not call the Swift inserter')
if 'lastErrorMessage' not in action:
    failures.append('a failed insert does not show the captured AppleScript error')
if 'nsimage(false)' not in action:
    failures.append('a front viewer does not contribute the displayed image')
if 'files(forDatabaseMatrixSelection:' not in action:
    failures.append('database thumbnails are not the selected images when no viewer is open')
# -validateMenuItem: is BrowserController+Menus.swift.
menus = (root / 'Horos/Sources/BrowserController+Menus.swift').read_text()
if '#selector(insertSelectedImagesIntoReport(_:))' not in menus or 'ReportImageInsertion.kind(ofReportPath: report) != .unsupported' not in menus:
    failures.append('validateMenuItem does not know the new action')

# Stay off the Pages→PDF files and the conversion selectors.
# The DicomStudy (Report) category is Swift: ReportImageInsertion
# is the Swift name of HorosReportImageInsertion, and matches both.
report_mm = source_text('DicomStudy+Report')
if 'ReportImageInsertion' in report_mm or 'insertSelectedImagesIntoReport' in report_mm:
    failures.append('image insertion was wired through DicomStudy+Report, the Pages→PDF path')
if 'convertReportToPDF' in action:
    failures.append('insertion calls the PDF converter')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if 'ReportImagePlacement.swift in Sources' not in pbx:
    failures.append('ReportImagePlacement.swift is not in the app target')

menus = list((root / 'Horos/Resources').glob('*.lproj/MainMenu.xib'))
if len(menus) < 4:
    failures.append('localized main menus are missing')
for menu in menus:
    tree = ET.parse(menu)
    report = tree.find('.//menu[@id="12354"]')
    if report is None:
        failures.append(f'{menu} has no Report submenu')
        continue
    actions = report.findall('.//action[@selector="insertSelectedImagesIntoReport:"]')
    if len(actions) != 1 or actions[0].attrib.get('target') != '898':
        failures.append(f'{menu} does not expose one insertion action on the browser')
    pdf = report.findall('.//action[@selector="convertReportToPDF:"]')
    if len(pdf) != 1:
        failures.append(f'{menu} lost the existing PDF conversion item')

if failures:
    raise SystemExit('FAIL:\n- ' + '\n- '.join(failures))
print('PASS: File > Report inserts selected images into Pages/Word without touching the PDF path')
