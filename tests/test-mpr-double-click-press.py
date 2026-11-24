#!/usr/bin/env python3
"""The double click that fills the window with a plane of the 3D MPR or of the orthogonal MPR spends its press.

A double click on a plane fills the window with it, and another brings the
three planes back. The view moves and changes size under the pointer, while
the point a press started at is kept in the view's coordinates. A move of the
mouse between the second press and its release was then measured from that
point as a drag of hundreds of points: with the window tool, the width fell
to almost nothing or the level left the image's range, and the window went to
the three planes.

* The branch of the double click that changes the layout marks the press.
* A marked press ignores the moves of the mouse and ends at its release
  without ending a tool.
* The next press starts unmarked.

    python3 tests/test-mpr-double-click-press.py [<git revision>]

A revision reads the source from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/MPRDCMView.swift'


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else ''
    return (ROOT / path).read_text(encoding='utf-8')


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening + 1:index]
    return ''


def statements(body):
    """The body without comments and blank lines, one statement a line."""
    lines = [re.sub(r'\s*//.*$', '', line).strip() for line in body.splitlines()]
    return [line for line in lines if line]


source = read(PATH)
down = block(source, 'public override dynamic func mouseDown(with theEvent: NSEvent)')
dragged = statements(block(source, 'public override dynamic func mouseDragged(with theEvent: NSEvent)'))
up = statements(block(source, 'public override dynamic func mouseUp(with theEvent: NSEvent)'))
failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


check('the view has the three mouse methods', bool(down and dragged and up))

# The double click: its branch that moves the dividers marks the press, the one that opens a ROI's information does not.
double = block(down, 'if clickCount == 2 && self.horos_drawingROI == false')
single = down[down.find(double) + len(double):] if double else ''
layout = double[double.find('} else {'):] if double else ''
information = double[:double.find('} else {')] if double else ''
check('the double click that moves the dividers marks the press',
      'setPosition' in layout and re.search(r'\bpressChangedLayout = true\b', layout) is not None)
check('the double click on a ROI does not mark it', 'pressChangedLayout' not in information)
check('a single press starts unmarked',
      re.search(r'\bpressChangedLayout = false\b', single) is not None
      and single.find('pressChangedLayout = false') < single.find('super.mouseDown'))

# A marked press: no move reaches a tool, and the release ends none.
check('a move of a marked press does nothing', bool(dragged) and dragged[0] == 'if pressChangedLayout { return }')
guard = next((i for i, line in enumerate(up) if line.startswith('if pressChangedLayout')), None)
tool = next((i for i, line in enumerate(up) if 'super.mouseUp' in line or '_vrView?.mouseUp' in line), None)
check('the release of a marked press ends no tool', guard is not None and tool is not None and guard < tool
      and up[guard + 1:guard + 4] == ['pressChangedLayout = false', 'dontCheckRoiChange = false', 'return'])
ended = next((i for i, line in enumerate(up) if 'planePressEnded' in line), None)
check('the release still ends the press of the plane', ended is not None and guard is not None and ended < guard)

# The orthogonal MPR: the same press, in its view.
orthogonal = read('Horos/Sources/OrthogonalMPRView.swift')
o_down = block(orthogonal, 'public override dynamic func mouseDown(with event: NSEvent)')
o_double = block(o_down, 'if event.clickCount == 2')
o_single = o_down[o_down.find(o_double) + len(o_double):] if o_double else ''
o_dragged = statements(block(orthogonal, 'public override dynamic func mouseDragged(with event: NSEvent)'))
o_up = statements(block(orthogonal, 'public override dynamic func mouseUp(with event: NSEvent)'))
check('orthogonal: the double click marks the press',
      'doubleClick' in o_double and re.search(r'\bpressChangedLayout = true\b', o_double) is not None)
check('orthogonal: a single press starts unmarked',
      'pressChangedLayout = false' in o_single and o_single.find('pressChangedLayout = false') < o_single.find('super.mouseDown'))
check('orthogonal: a move of a marked press does nothing',
      bool(o_dragged) and o_dragged[0] == 'if pressChangedLayout { return }')
check('orthogonal: the release unmarks the press and ends as any other',
      o_up[:2] == ['pressChangedLayout = false', 'super.mouseUp(with: event)'])

if failures:
    print('FAIL: ' + '; '.join(failures))
    sys.exit(1)
print('PASS: the double click that changes the layout of the 3D MPR and of the orthogonal MPR spends its press')
