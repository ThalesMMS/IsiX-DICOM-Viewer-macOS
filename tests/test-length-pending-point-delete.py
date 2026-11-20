#!/usr/bin/env python3
"""Delete takes back the pending point of a two-click Length, and so does deleting every ROI.

The first click of the Length tool leaves a point pending, shown by a marker
that is in no list of ROIs. Clicked by mistake, only Escape took it back:
Backspace did nothing, since Delete walks the list of ROIs, and Delete All ROIs
in this Series removed every measure of the series and left the point.

Which keys take the point back is IsiXROI's TwoClickLengthPlacement.keyCancels,
with its tests in Modules/IsiXROI/Tests (ROIViewGestureTests). This reads how
the view and the viewer use it. What must stay true:

- with a point pending, -keyDown: asks the rule before anything else, puts the
  point away and returns: the press deletes no ROI, reaches no plugin and
  changes no image, as Escape's does not; pressed again, Delete deletes the
  selected ROIs;
- the rule is asked about the character -keyDown: itself reads, and knows every
  character its Delete branch answers to;
- Delete All ROIs in this Series puts away the point pending in any view of the
  viewer before it removes the ROIs;
- putting the point away forgets the click, the endpoint and the marker, and
  draws the view again.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


def code_of(text):
    return re.sub(r'//[^\n]*', '', text)


keyboard = code_of(source_text('DCMView+Keyboard'))
key_down = body(keyboard, 'func keyDown(with event: NSEvent)')
check(key_down, '-keyDown: not found')
pending = '(self.horos_lengthFirstEndpoint != nil || self.horos_lengthClickEvent != nil)'
rule = 'ViewROIEditing.LengthPlacement.keyCancels(keyCode: event.keyCode, character: event.characters?.utf16.first)'
first = key_down[1:].lstrip()
check(first.startswith(f'if {pending} && {rule} {{'),
      'with a point pending, -keyDown: does not ask first whether the key takes it back')
check(re.match(r'if [^\n]*\{\s*self\.cancelLengthPlacement\(\); return\s*\}', first) is not None,
      'the key that takes the pending point back goes on to do something else')
for later in ('self.event(toPlugins: event)', 'self.deleteSelectedROIs()', 'self.cancelOpeningScaleToFitForInteraction()'):
    check(0 < key_down.find(later) and key_down.find('self.cancelLengthPlacement(); return') < key_down.find(later),
          f'-keyDown: reaches {later} before the pending point is taken back')

# The characters the Delete branch answers to, and those the rule knows.
branch = re.search(r'if ([^\n]*) \{\s*self\.deleteSelectedROIs\(\)', key_down)
check(branch is not None, 'the Delete branch of -keyDown: is not where this test reads it')
names = set(re.findall(r'Int\(c\) == (\w+)', branch.group(1))) if branch else set()
CHARACTERS = {'NSDeleteFunctionKey': 0xF728, 'NSDeleteCharacter': 0x7F, 'NSBackspaceCharacter': 0x08, 'NSDeleteCharFunctionKey': 0xF73E}
check(names == set(CHARACTERS), f'the Delete branch answers to {sorted(names)}: the rule and this test know {sorted(CHARACTERS)}')
placement = code_of((root / 'Modules/IsiXROI/Sources/TwoClickLengthPlacement.swift').read_text())
cancels = body(placement, 'func keyCancels(keyCode: UInt16, character: UInt16?)')
check(cancels, 'TwoClickLengthPlacement.keyCancels not found')
known = {int(value, 16) for value in re.findall(r'0x[0-9A-Fa-f]+', cancels)}
check(known == set(CHARACTERS.values()), 'the rule does not know exactly the characters the Delete branch answers to')
check(re.search(r'escape: UInt16 = 53\b', cancels) is not None, 'the rule no longer takes Escape')

click = code_of(source_text('DCMView+LengthClick'))
cancel = body(click, 'func cancelLengthPlacement()')
for forgotten in ('self.releaseLengthClickEvent()', 'self.horos_lengthFirstEndpoint = nil', 'self.horos_lengthPendingMarker = nil',
                  'self.needsDisplay = true'):
    check(forgotten in cancel, f'putting the pending point away leaves out {forgotten}')

editing = code_of(source_text('ViewerController+ROI+Editing'))
action = body(editing, 'func roiDeleteAll(_ sender: Any!)')
check('ViewerROIPanels.deleteAllUnlocked(in: self)' in action, 'Delete All ROIs in this Series no longer goes through deleteAllUnlocked')
delete_all = body(editing, 'static func deleteAllUnlocked(in viewer: ViewerController)')
views = body(delete_all, 'for case let view as DCMView in viewer.imageViews() ?? []')
check('view.cancelLengthPlacement()' in views, 'deleting every ROI leaves the pending point of a view of the viewer')
check(0 < delete_all.find('view.cancelLengthPlacement()') < delete_all.find('list.remove(roi)'),
      'the pending point is not put away before the ROIs are removed')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: with a point of a two-click Length pending, Delete and Backspace take it back and do nothing else, as Escape, '
      'and deleting every ROI of the series takes it away in every view of the viewer')
