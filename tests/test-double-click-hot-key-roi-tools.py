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
# The mouse buttons are Swift, in DCMView+Mouse.swift.
view = (root / 'Horos/Sources/DCMView+Mouse.swift').read_text()
failures = []


def body(signature):
    """A Swift method, from its @objc name to the brace that closes its body."""
    start = view.index(signature)
    depth = 0
    for end in range(view.index('{', start), len(view)):
        if view[end] == '{':
            depth += 1
        elif view[end] == '}':
            depth -= 1
            if depth == 0:
                return view[start:end]
    raise ValueError(signature)


helper = body('@objc(discardROIStartedByFirstClickOf:)')
for needle in ('if event.clickCount != 2 || self.horos_curROI == nil || self.horos_drawingROI == false || self.is2DViewer() == false { return false }',
               '"dbl-click + cmd"', '"dbl-click + alt"', '"dbl-click"',
               'if DCMView.horos_static__hotKeyDictionary?.object(forKey: key as NSString) == nil { return false }',
               'let points = (started.points ?? NSMutableArray())',
               'if !ViewInput.allPoints(points, within: tolerance, of: point) { return false }',
               'inputPost(.OsirixRemoveROI, object: started)',
               'self.removeROI(fromSliceOrVolume: started)',
               'inputMessages(self.windowController())?.inputRemoveLastItemFromUndoQueue()'):
    if needle not in helper:
        failures.append(f'the discarded ROI lost: {needle}')

down = body('private func mouseDownWithImages(')
hit = down.find('if self.click(inROI: tempPt) != nil { roiHit = true }')
discard = down.find('if self.discardROIStarted(byFirstClickOf: event) { roiHit = false }')
dispatch = down.find('self.actionForHotKey("dbl-click")')
if not (0 < hit < discard < dispatch):
    failures.append('the started ROI must go after the hit test and before the double-click hot keys')
for key in ('dbl-click + cmd', 'dbl-click + alt', 'dbl-click'):
    if not re.search(r'clickCount == 2 && roiHit == false && .*self\.actionForHotKey\("' + re.escape(key) + r'"\)', down):
        failures.append(f'the {key} hot key is no longer dispatched for a click off any ROI')
if 'let roiWin = ROIWindow(roi: roi, self.windowController() as? ViewerController)' not in view:
    failures.append('a double-click on a finished ROI no longer opens its information')
# Declared in ViewerController.h, or implemented in Swift
# (ViewerController+UndoQueue.swift) with its selector.
undo_queue = root / 'Horos/Sources/ViewerController+UndoQueue.swift'
if 'removeLastItemFromUndoQueue' not in (root / 'Horos/Sources/ViewerController.h').read_bytes().decode('latin1') and not (
        undo_queue.is_file() and '@objc(removeLastItemFromUndoQueue)\n    func removeLastItemFromUndoQueue()' in undo_queue.read_text()):
    failures.append('the viewer no longer removes its last undo step')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a ROI started by the first click of a hot-key double-click goes, with its undo step, and the hot key runs')
