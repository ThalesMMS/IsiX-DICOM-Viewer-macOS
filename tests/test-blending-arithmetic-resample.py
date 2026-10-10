#!/usr/bin/env python3
"""Subtraction and multiplication between series of one study with other matrices.

The panel a series dropped on a viewer opens used to grey out Subtraction and
Multiplication whenever the two images differed in width or height, which is
the rule rather than the exception between two MR sequences of one study. Both
now stay available within a study: the dropped series is first resampled onto
the viewer's grid, as the panel's Resample does, and the arithmetic pairs each
image with the resampled image of the same index, without the sync that could
move the viewer off it. Between studies the resampling has no common frame, so
the two stay grey there.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('utf-8').replace('\r\n', '\n')
blending = (root / 'Horos/Sources/ViewerController+Blending.swift').read_text(encoding='utf-8')

start = viewer.index('- (void) completeDragOperation:(ViewerController*) vc')
panel = viewer[start:viewer.index('// Prepare fusion plug-ins menu', start)]
size = panel.index('pheight] != [[imageView curDCM] pheight])')
gated = panel[size:panel.index('[blendingTypeRGB setEnabled: NO];', size)]
assert re.search(r'if\( sameStudy == NO\)\s*\{\s*\[blendingTypeMultiply setEnabled: NO\];\s*\[blendingTypeSubtract setEnabled: NO\];',
                 gated), 'other matrices grey out subtraction even within a study'
assert 'BOOL sameStudy = [[self studyInstanceUID] isEqualToString: [vc studyInstanceUID]];' in panel
assert 'if( sameStudy == NO)\n        [blendingResample setEnabled: NO];' in panel, 'Resample lost its study rule'

operand = blending[blending.index('private func horos_arithmeticOperand'):blending.index('@objc(blendWithViewer:blendingType:)')]
assert 'own.pwidth != other.pwidth || own.pheight != other.pheight' in operand
assert 'self.resampleSeries(bc, rescale: true)' in operand, 'other matrices are not resampled onto this grid'
assert 'return nil' in operand, 'a failed resampling still runs the arithmetic'

for case, call in (('case 2:', 'subtract(operand?.imageView()'), ('case 3:', 'multiply(operand?.imageView())')):
    start = blending.index(case + '\n' if case == 'case 2:' else case, blending.index('func blend(withViewer'))
    body = blending[start:blending.index('\n        case ', start + len(case))]
    assert 'guard let arithmetic = self.horos_arithmeticOperand(bc) else { break }' in body, case
    assert call in body and 'bc?.' not in body, f'{case} combines with the dropped series, not the resampled one'
    assert 'operand?.imageView()?.setIndex(Int16(truncatingIfNeeded: i))' in body, f'{case} does not pair by index'
assert 'if !pairedByIndex {\n                        operand?.imageView()?.sendSyncMessage(0)' in blending, \
    'the resampled series syncs while it is paired'
print('PASS: subtraction and multiplication resample other matrices within a study and pair by index')
