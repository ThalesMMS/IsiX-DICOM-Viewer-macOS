#!/usr/bin/env python3
"""Subtraction, multiplication and division between series of one study with other matrices.

The panel a series dropped on a viewer opens used to grey out Subtraction and
Multiplication whenever the two images differed in width or height, which is
the rule rather than the exception between two MR sequences of one study. Both
now stay available within a study: the dropped series is first resampled onto
the viewer's grid, as the panel's Resample does, and the arithmetic pairs each
image with the resampled image of the same index, without the sync that could
move the viewer off it. Between studies the resampling has no common frame, so
the two stay grey there.

Division, the ratio map beside them (blending type 13, the Division button of
every copy of ViewerPanels.xib), goes the same way as multiplication: one loop
that resamples and pairs by index for both, the pixel rule in IsiXImaging's
ImageArithmetic.quotient, and the same grey between studies.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
viewer = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('utf-8').replace('\r\n', '\n')
# The fusion's work is ViewerFusion's; ViewerController+Blending.swift keeps the selectors.
blending = (root / 'Horos/Sources/ViewerFusion.swift').read_text(encoding='utf-8')

if '- (void) completeDragOperation:(ViewerController*) vc' in viewer:
    start = viewer.index('- (void) completeDragOperation:(ViewerController*) vc')
    panel = viewer[start:viewer.index('// Prepare fusion plug-ins menu', start)]
    size = panel.index('pheight] != [[imageView curDCM] pheight])')
    gated = panel[size:panel.index('[blendingTypeRGB setEnabled: NO];', size)]
    assert re.search(r'if\( sameStudy == NO\)\s*\{\s*\[blendingTypeMultiply setEnabled: NO\];\s*\[blendingTypeSubtract setEnabled: NO\];',
                     gated), 'other matrices grey out subtraction even within a study'
    assert 'BOOL sameStudy = [[self studyInstanceUID] isEqualToString: [vc studyInstanceUID]];' in panel
    assert 'if( sameStudy == NO)\n        [blendingResample setEnabled: NO];' in panel, 'Resample lost its study rule'
else:
    # The panel is prepared by ViewerFusion, for the drop the viewer receives.
    drop = blending
    start = drop.index('func completeDragOperation(_ vc: ViewerController!)')
    panel = drop[start:drop.index('// Prepare the menu of the fusion plug-ins.', start)]
    size = panel.index('(viewer.horos_imageView?.curDCM?.pheight ?? 0) {')
    gated = panel[size:panel.index('viewer.blendingTypeRGB?.isEnabled = false', size)]
    assert re.search(r'if sameStudy == false \{\s*viewer\.blendingTypeMultiply\?\.isEnabled = false\s*viewer\.blendingTypeSubtract\?\.isEnabled = false',
                     gated), 'other matrices grey out subtraction even within a study'
    assert 'let sameStudy = viewerSameString(viewer.studyInstanceUID(), vc?.studyInstanceUID())' in panel
    assert re.search(r'if sameStudy == false \{\s*viewer\.blendingResample\?\.isEnabled = false', panel), 'Resample lost its study rule'

operand = blending[blending.index('private func horos_arithmeticOperand'):blending.index('func blend(withViewer')]
assert 'own.pwidth != other.pwidth || own.pheight != other.pheight' in operand
assert 'viewer.resampleSeries(bc, rescale: true)' in operand, 'other matrices are not resampled onto this grid'
assert 'return nil' in operand, 'a failed resampling still runs the arithmetic'

def case_body(case):
    start = blending.index(case + '\n' if case == 'case 2:' else case, blending.index('func blend(withViewer'))
    return blending[start:blending.index('\n        case ', start + len(case))]


body = case_body('case 2:')
assert 'guard let arithmetic = horos_arithmeticOperand(bc) else { break }' in body, 'case 2:'
assert 'subtract(operand?.imageView()' in body and 'bc?.' not in body, \
    'case 2: combines with the dropped series, not the resampled one'
assert 'operand?.imageView()?.setIndex(Int(truncatingIfNeeded: i))' in body, 'case 2: does not pair by index'

# Multiplication and division share one loop, which resamples and pairs.
combine = blending[blending.index('    private func horos_combineImages('):blending.index('    func blendingSlider(')]
assert 'guard let arithmetic = horos_arithmeticOperand(bc) else { return false }' in combine
assert 'operand?.imageView()?.setIndex(Int(truncatingIfNeeded: i))' in combine, 'the shared loop does not pair by index'
assert 'combine(viewer.horos_imageView, operand?.imageView())' in combine and 'bc?.' not in combine, \
    'the shared loop combines with the dropped series, not the resampled one'
for case, call in (('case 3:', 'view?.multiply(operand)'),
                   ('case ViewerFusion.divisionBlendingType:', 'view.curDCM?.divide(by: operand?.curDCM)')):
    body = case_body(case)
    assert 'horos_combineImages(bc)' in body and call in body and 'bc?.' not in body, case
assert 'static let divisionBlendingType: Int32 = 13' in blending
assert 'if divided { viewer.horos_imageView?.setWLWW(0, 0) }' in case_body('case ViewerFusion.divisionBlendingType:'), \
    'the ratio keeps a window set for other values'
assert re.search(r'viewer\.blendingTypeSubtract\?\.isEnabled = false\s*\(viewer\.horos_blendingTypeWindow\?\.contentView\?'
                 r'\.viewWithTag\(Int\(ViewerFusion\.divisionBlendingType\)\) as\? NSControl\)\?\.isEnabled = false', gated), \
    'division stays available between studies of other matrices'

pix = (root / 'Horos/Sources/DCMPix+Subtraction.swift').read_text(encoding='utf-8')
divide = pix[pix.index('    final func divide(by sub: DCMPix?)'):pix.index('    final func product(of')]
assert 'sub.pwidth == horos_width, sub.pheight == horos_height' in divide, 'an image of another size is divided'
assert 'ImageArithmetic.quotient(image, other, width: horos_width, height: horos_height' in divide

# Every copy of the panel has the button, which ends the sheet with type 13.
import xml.etree.ElementTree as ET
copies = sorted((root / 'Horos/Resources').glob('*.lproj/ViewerPanels.xib'))
assert copies, 'no ViewerPanels.xib'
for xib in copies:
    window = next(w for w in ET.parse(xib).getroot().iter('window') if w.find('.//button[@id="834"]') is not None)
    buttons = [b for b in window.iter('button') if b.get('tag') == '13']
    assert len(buttons) == 1, f'{xib.parent.name}: no Division button beside Multiplication'
    division = buttons[0]
    assert division.find('buttonCell').get('tag') == '13', xib.parent.name
    action = division.find('connections/action')
    assert action.get('selector') == 'endBlendingType:' and action.get('target') == '-2', xib.parent.name
    frames = {b.get('id'): b.find('rect') for b in window.iter('button')}
    row = [frames[i] for i in ('832', '833', '834', division.get('id'))]
    assert len({r.get('y') for r in row}) == 1, f'{xib.parent.name}: Division is not on the row of Multiplication'
    assert [float(r.get('x')) for r in row] == sorted(float(r.get('x')) for r in row), xib.parent.name
assert 'if !pairedByIndex {\n                        operand?.imageView()?.sendSyncMessage(0)' in blending, \
    'the resampled series syncs while it is paired'
print('PASS: subtraction, multiplication and division resample other matrices within a study and pair by index; '
      f'the Division button ends the sheet with type 13 in {len(copies)} copies of ViewerPanels.xib')
