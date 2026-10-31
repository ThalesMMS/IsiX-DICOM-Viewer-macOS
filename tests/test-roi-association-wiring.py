#!/usr/bin/env python3
"""Viewer imports .roi / .rois_series / JSON through the Swift association service.

A .roi archive names no image and a .rois_series archive only an order: the
viewer says so to the planner, with the displayed image, and the planner
decides. Nothing is written unless every ROI of the batch has a place.

-roiLoadFromSeries:, -roiLoadFromFiles: and -roiSaveSeries: are Swift
(ViewerController+ROI.swift), façades of ViewerROIFiles in the same file: the
menu paths are read there, in Swift spelling; so is the drag-and-drop path,
once ViewerController+DragAndDrop.swift has it.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text, source_text  # noqa: E402

controller = (((root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
# The ViewerController (ROIInterchange) category is Swift: the same
# checks, in Swift spelling. The public selectors are its @objc names.
impl = source_text('ViewerController+ROIInterchange')
# The selectors are the category's; the work is ViewerROIInterchange's.
work = source_text('ViewerROIInterchange')
roi_menu = source_text('ViewerController+ROI')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text(encoding='latin1', errors='replace')
# DCMView is Swift; its ROI loading is DCMView+ROIEditing.swift's, with the same selectors.
dcm = class_text('DCMView')


def fail(message):
    print('FAIL:', message, file=sys.stderr)
    sys.exit(1)

for name in ('ROIAssociation.swift', 'ROIArchiveFormat.swift'):
    if name not in pbx:
        fail(f'{name} is not in the app target')

if ('@objc(importROIArchiveFromPath:error:)\n    public func' not in impl
        or '@objc(importROIFiles:error:)\n    public func' not in impl):
    fail('archive import is not declared on the ROI interchange category')

# The selectors hand the panels and the files to ViewerROIFiles.
series_menu = roi_menu[roi_menu.index('@objc(roiLoadFromSeries:)'):roi_menu.index('@objc(roiLoadFromFiles:)')]
files_menu = roi_menu[roi_menu.index('@objc(roiLoadFromFiles:)'):roi_menu.index('@objc(roiSaveSeries:)')]
if 'ViewerROIFiles.loadSeries(' not in series_menu or 'ViewerROIFiles.chooseAndLoad(' not in files_menu:
    fail('the ROI menu items do not reach ViewerROIFiles')
load = roi_menu[roi_menu.index('    static func loadSeries('):roi_menu.index('    static func chooseAndSaveSeries(')]
if 'importROIArchive(fromPath:' not in load:
    fail('roiLoadFromSeries does not call the Swift-backed archive importer')
if (re.search(r'roisSeries\??\.count\s*>\s*x', load)
        or re.search(r'x\s*<\s*\(?\s*self\.horos_pixList\(at:\s*y\)', load)):
    fail('roiLoadFromSeries still assigns ROIs by slice index')

files = roi_menu[roi_menu.index('    static func load(_ urls: [URL]'):roi_menu.index('    static func loadSeries(')]
if 'roiLoad(fromFilesArray:' in files:
    fail('Import ROI(s) still dumps .roi files onto the current slice')
if 'importROIFiles(' not in files:
    fail('Import ROI(s) does not batch .roi files through the association planner')

if 'if( found == NO)' in controller:
    drag = controller[controller.index('if( found == NO)'):
                      controller.index('- (NSDragOperation)draggingEntered:')]
else:
    # The drop is Swift, in ViewerController+DragAndDrop.swift.
    drop = source_text('ViewerController+DragAndDrop')
    drag = drop[drop.index('if found == false {'):drop.index('@objc(draggingEntered:)')]
if 'roiLoadFromFilesArray' in drag:
    fail('drag-and-drop still dumps .roi files onto the current slice')
if 'importROIFiles:' not in drag and 'importROIFiles(' not in drag:
    fail('drag-and-drop does not batch .roi files through the association planner')

apply = work[work.index('static func apply('):
             work.index('static func integerValue(')]
if 'plan.canApply == false' not in apply:
    fail('applyAssociationItems does not require a complete identity plan')
if apply.find('add(toUndoQueue:') < apply.find('plan.canApply == false'):
    fail('undo is queued before the association plan is accepted')
if 'displayedIndex: displayed' not in apply or 'imageView().curImage' not in apply:
    fail('applyAssociationItems does not tell the planner which image is displayed')
if 'HorosROILabelPresentation' in apply or 'ROILabelPresentation' in apply or 'stringTex' in apply:
    fail('association import must not touch the ROI label matrix')

append = work[work.index('static func append('):
              work.index('static func target(')]
if 'placement = .seriesSlot' not in append or 'archiveSliceCount = slices.count' not in append:
    fail('a .rois_series archive does not reach the planner with its layout')
if 'placement = .displayedImage' not in append:
    fail('a .roi archive does not reach the planner as a list for the displayed image')

json_import = work[work.index('static func importInterchange(fromPath'):
                   work.index('static func unarchiveObject(')]
if 'ROIAssociation.plan(document:' not in json_import:
    fail('JSON import does not use ROIAssociation')
if json_import.find('add(toUndoQueue:') < json_import.find('plan.canApply == false'):
    fail('JSON import queues undo before the association plan is accepted')

archive = work[work.index('static func importArchive(fromPath'):
               work.index('static func importROIFiles(')]
needed = ['ROIArchiveKind.keyedArchive', 'inspectUnarchived(', 'The archive decoded but contains no ROIs']
missing = [item for item in needed if item not in archive]
if missing:
    fail('archive importer is missing ' + ', '.join(missing))

if 'roiLoadFromFilesArray:' not in dcm:
    fail('DCMView still owns the current-slice loader for other callers; do not delete it here')

if 'ROIAssociation' in xib or 'importROIArchiveFromPath' in xib:
    fail('Viewer.xib must stay untouched')

print('PASS: viewer imports ROI archives through the Swift association planner, with their layout and the displayed image')
