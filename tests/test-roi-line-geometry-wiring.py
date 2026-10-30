#!/usr/bin/env python3
"""Selected line ROI asks Swift for physical constructions and adds the three marks."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
controller = (((root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
swift_geometry = '- (IBAction) generateGeometryFromSelectedLine:' not in controller
# The constructions are Swift (ViewerController+ROIGeometry.swift) once they
# left ViewerController.m.
source = (root / 'Horos/Sources/ViewerController+ROIGeometry.swift').read_text() if swift_geometry else controller
start = source.index('    @objc(generateGeometryFromSelectedLine:)' if swift_geometry else '- (IBAction) generateGeometryFromSelectedLine:')
method = source[start:start + 2500]
menus = controller
menu_action = 'generateGeometryFromSelectedLine:'
if '-(NSMenu*)contextualMenuForROI:(ROI*)roi\n{' in controller:
    menu = controller[controller.index('-(NSMenu*)contextualMenuForROI:(ROI*)roi\n{'):
                         controller.index('- (IBAction) generateGeometryFromSelectedLine:')]
    point_check = 'type == tMesure'
else:
    # The contextual menus are Swift (ViewerController+ContextualMenus.swift).
    menus = (root / 'Horos/Sources/ViewerController+ContextualMenus.swift').read_text()
    menu = menus[menus.index('    @objc(contextualMenuForROI:)'):menus.index('    @objc(roiContextualMenuActionRemove:)')]
    menu_action = 'ViewerController.generateGeometryFromSelectedLine(_:)'
    point_check = 'type == .tMesure'
needed = [
    'HorosROILineGeometry constructionFromLineA',
    'generateGeometryFromSelectedLine:',
    'tMesure',
    't2DPoint',
    'NSLocalizedString(@"Perpendicular"',
    'NSLocalizedString(@"Parallel"',
    'NSLocalizedString(@"Midpoint"',
    'addToUndoQueue: @"roi"',
] if not swift_geometry else [
    'ROILineGeometry.construction(from:',
    'generateGeometryFromSelectedLine:',
    '.tMesure',
    '.t2DPoint',
    'NSLocalizedString("Perpendicular"',
    'NSLocalizedString("Parallel"',
    'NSLocalizedString("Midpoint"',
    'add(toUndoQueue: "roi")',
]
missing = [item for item in needed if item not in source]
if missing:
    print('FAIL: ViewerController is missing', ', '.join(missing), file=sys.stderr)
    sys.exit(1)
if menu_action not in menu:
    print('FAIL: contextual menu does not offer line geometry', file=sys.stderr)
    sys.exit(1)
if point_check not in menu:
    print('FAIL: ROI contextual menu does not special-case a line', file=sys.stderr)
    sys.exit(1)
if 'stringTex' in method or 'HorosROILabelPresentation' in method:
    print('FAIL: line geometry must not touch the ROI label matrix', file=sys.stderr)
    sys.exit(1)
print('PASS: selected line builds perpendicular, parallel and midpoint from Swift physical geometry')
