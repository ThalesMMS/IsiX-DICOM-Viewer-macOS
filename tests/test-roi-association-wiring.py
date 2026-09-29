#!/usr/bin/env python3
"""Viewer imports .roi / .rois_series / JSON through the Swift identity service.

-roiLoadFromSeries:, -roiLoadFromFiles: and -roiSaveSeries: are Swift since
#832 (ViewerController+ROI.swift): the menu paths are read there, in Swift
spelling; the drag-and-drop path stays in ViewerController.m.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

controller = (root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')
# The ViewerController (ROIInterchange) category is Swift since #722: the same
# checks, in Swift spelling. The public selectors are its @objc names.
impl = source_text('ViewerController+ROIInterchange')
roi_menu = source_text('ViewerController+ROI')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text(encoding='latin1', errors='replace')
dcm = (root / 'Horos/Sources/DCMView.m').read_text(encoding='latin1')


def fail(message):
    print('FAIL:', message, file=sys.stderr)
    sys.exit(1)

for name in ('ROIAssociation.swift', 'ROIArchiveFormat.swift'):
    if name not in pbx:
        fail(f'{name} is not in the app target')

if ('@objc(importROIArchiveFromPath:error:)\n    public func' not in impl
        or '@objc(importROIFiles:error:)\n    public func' not in impl):
    fail('archive import is not declared on the ROI interchange category')

load = roi_menu[roi_menu.index('@objc(roiLoadFromSeries:)'):
                roi_menu.index('@objc(roiLoadFromFiles:)')]
if 'importROIArchive(fromPath:' not in load:
    fail('roiLoadFromSeries does not call the Swift-backed archive importer')
if (re.search(r'roisSeries\??\.count\s*>\s*x', load)
        or re.search(r'x\s*<\s*\(?\s*self\.horos_pixList\(at:\s*y\)', load)):
    fail('roiLoadFromSeries still assigns ROIs by slice index')

files = roi_menu[roi_menu.index('@objc(roiLoadFromFiles:)'):
                 roi_menu.index('@objc(roiSaveSeries:)')]
if 'roiLoad(fromFilesArray:' in files:
    fail('Import ROI(s) still dumps .roi files onto the current slice')
if 'importROIFiles(' not in files:
    fail('Import ROI(s) does not batch .roi files through identity matching')

drag = controller[controller.index('if( found == NO)'):
                  controller.index('- (NSDragOperation)draggingEntered:')]
if 'roiLoadFromFilesArray:' in drag:
    fail('drag-and-drop still dumps .roi files onto the current slice')
if 'importROIFiles:' not in drag:
    fail('drag-and-drop does not batch .roi files through identity matching')

apply = impl[impl.index('func applyAssociationItems('):
             impl.index('func importROIInterchange(fromPath')]
if 'plan.canApply == false' not in apply:
    fail('applyAssociationItems does not require a complete identity plan')
if apply.find('add(toUndoQueue:') < apply.find('plan.canApply == false'):
    fail('undo is queued before the association plan is accepted')
if 'HorosROILabelPresentation' in apply or 'ROILabelPresentation' in apply or 'stringTex' in apply:
    fail('association import must not touch the #227/#245 label matrix')

json_import = impl[impl.index('func importROIInterchange(fromPath'):
                   impl.index('func importROIArchive(fromPath')]
if 'ROIAssociation.plan(document:' not in json_import:
    fail('JSON import does not use ROIAssociation')
if json_import.find('add(toUndoQueue:') < json_import.find('plan.canApply == false'):
    fail('JSON import queues undo before the association plan is accepted')

archive = impl[impl.index('func importROIArchive(fromPath'):
               impl.index('func importROIFiles(')]
needed = ['ROIArchiveKind.keyedArchive', 'inspectUnarchived(', 'The archive decoded but contains no ROIs']
missing = [item for item in needed if item not in archive]
if missing:
    fail('archive importer is missing ' + ', '.join(missing))

if 'roiLoadFromFilesArray:' not in dcm:
    fail('DCMView still owns the current-slice loader for other callers; do not delete it here')

if 'ROIAssociation' in xib or 'importROIArchiveFromPath' in xib:
    fail('Viewer.xib must stay untouched')

print('PASS: viewer imports ROI archives through Swift identity matching, not slice index or current-slice dump')
