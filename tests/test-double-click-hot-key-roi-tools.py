#!/usr/bin/env python3
"""A double-click that Hot Keys gives an action runs it with any ROI tool.

With Angle (and any ROI drawn click by click) the first click of a double-click
starts a ROI: the second click either lands on it, and -mouseDown: never
reached the double-click hot keys, or misses it, and the action refused to run
while a ROI was being drawn (full screen does). The ROI the first click started, whose
points are all under the double-click, is discarded with the undo step that
click recorded, and the hot key runs. A ROI drawn further (an angle with its
second point, a polygon with its points) keeps its double-click, which ends it;
a double-click on a finished ROI still opens its information; with no action
for the double-click nothing changes.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
failures = []


def body(signature):
    start = view.index(signature)
    return view[start:view.index('\n}\n', start)]


helper = body('- (BOOL)discardROIStartedByFirstClickOf:(NSEvent*)event')
for needle in ('event.clickCount != 2 || curROI == nil || drawingROI == NO || [self is2DViewer] == NO) return NO;',
               '@"dbl-click + cmd"', '@"dbl-click + alt"', '@"dbl-click"',
               'if ([_hotKeyDictionary objectForKey:key] == nil) return NO;',
               'for (MyPoint *p in [curROI points])',
               'if (fabs(p.x - point.x) > tolerance || fabs(p.y - point.y) > tolerance) return NO;',
               'postNotificationName:OsirixRemoveROINotification object:started',
               '[self removeROIFromSliceOrVolume:started];',
               '[[self windowController] removeLastItemFromUndoQueue];'):
    if needle not in helper:
        failures.append(f'the discarded ROI lost: {needle}')

down = body('- (void) mouseDown:(NSEvent *)event')
hit = down.find('if( [self clickInROI: tempPt]) roiHit = YES;')
discard = down.find('if( [self discardROIStartedByFirstClickOf: event]) roiHit = NO;')
dispatch = down.find('[self actionForHotKey: @"dbl-click"]')
selection = down.find('if( clickCount > 1)\n')
if not (0 < hit < discard < dispatch):
    failures.append('the started ROI must go after the hit test and before the double-click hot keys')
for key in ('dbl-click + cmd', 'dbl-click + alt', 'dbl-click'):
    if not re.search(r'clickCount == 2 && roiHit == NO && .*\[self actionForHotKey: @"' + re.escape(key) + r'"\]', down):
        failures.append(f'the {key} hot key is no longer dispatched for a click off any ROI')
if 'ROIWindow* roiWin = [[ROIWindow alloc] initWithROI: roi :[self windowController]];' not in down:
    failures.append('a double-click on a finished ROI no longer opens its information')
if 'removeLastItemFromUndoQueue' not in (root / 'Horos/Sources/ViewerController.h').read_bytes().decode('latin1'):
    failures.append('the viewer no longer removes its last undo step')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a ROI started by the first click of a hot-key double-click goes, with its undo step, and the hot key runs')
