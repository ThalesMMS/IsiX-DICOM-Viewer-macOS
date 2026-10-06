#!/usr/bin/env python3
"""The Curved MPR's Path Assistant, path simplification and 4D times.

CurvedMPRPathAssistant is compiled with CurvedMPRPath.swift and run:
- a segment the assistant could not trace gives the user's node, and a
  failed last segment the user's last node, where the path took the last
  point of an old or empty centerline (the volume's origin);
- the cheapest node to remove is none when every cost is NaN or MAXFLOAT,
  where the first node went;
- the simplification target is counted signed, so a centerline of fewer than
  3 points does not wrap, and the simplification stops when a step changes
  nothing, where it looped forever.
CPRController is read for the rest:
- -addMoviePixList:: stores a time after the last one, within MAX4D, where it
  wrote over the first;
- the assistant keeps a segment found after the distance transform finished,
  not the centerlines of the unfinished one;
- removeNode and onSliderMove use the helpers above;
- the image exports all take the view the user selected, as JPEG did;
- CPR.xib no longer connects shadingsPresetsController, which the controller
  does not have.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path],
                                           stderr=subprocess.DEVNULL).decode('utf-8')
        except subprocess.CalledProcessError:
            return ''
    full = root / path
    return full.read_text(encoding='utf-8') if full.exists() else ''


def code(text):
    """Without comments, so that what they recall is not taken for a call."""
    text = '\n'.join(line.split('//')[0] for line in text.split('\n'))
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


DRIVER = r'''
import Foundation

var wrong: [String] = []
func expect(_ ok: Bool, _ message: String) {
    if !ok { wrong.append(message) }
}

// Nodes and centerline points as numbers: the user's nodes are 0, 100, 200;
// the assistant's points between them are 0...4 and 100...104.
let user = [0, 100, 200]
let traced = [0, 1, 2, 3, 4]
let traced2 = [100, 101, 102, 103, 104]

var path = CurvedMPRPathAssistant.assembledPath(segments: [traced, traced2], userNodes: user)
expect(path == [0, 1, 2, 3, 100, 101, 102, 103, 104], "two traced segments give \(path)")

path = CurvedMPRPathAssistant.assembledPath(segments: [traced, nil], userNodes: user)
expect(path == [0, 1, 2, 3, 100, 200], "a failed last segment keeps the user's nodes, got \(path)")

path = CurvedMPRPathAssistant.assembledPath(segments: [nil, traced2], userNodes: user)
expect(path == [0, 100, 101, 102, 103, 104], "a failed first segment keeps the user's first node, got \(path)")

path = CurvedMPRPathAssistant.assembledPath(segments: [[], []], userNodes: user)
expect(path == [0, 100, 200], "empty centerlines keep the user's nodes, got \(path)")

path = CurvedMPRPathAssistant.assembledPath(segments: [[7]], userNodes: [0, 100])
expect(path == [7], "a one-point centerline gives its point once, got \(path)")

let maxFloat = Float.greatestFiniteMagnitude
expect(CurvedMPRPathAssistant.cheapestRemovableNode(costs: [maxFloat, 4, 2, 2, maxFloat]) == 2,
       "the first cheapest interior node is removed")
expect(CurvedMPRPathAssistant.cheapestRemovableNode(costs: [maxFloat, .nan, .nan, maxFloat]) == nil,
       "NaN costs remove no node, not the first")
expect(CurvedMPRPathAssistant.cheapestRemovableNode(costs: []) == nil, "no cost, no node")

expect(CurvedMPRPathAssistant.simplificationTarget(centerlineCount: 23, sliderPercent: 100) == 23, "100 % keeps every point")
expect(CurvedMPRPathAssistant.simplificationTarget(centerlineCount: 23, sliderPercent: 0) == 3, "0 % keeps 3 nodes")
expect(CurvedMPRPathAssistant.simplificationTarget(centerlineCount: 23, sliderPercent: 50) == 13, "50 % keeps half")
let short = CurvedMPRPathAssistant.simplificationTarget(centerlineCount: 1, sliderPercent: 100)
expect(short == 1, "a one-point centerline asks for 1 node, not a wrapped count: \(short)")

// A path of 6 nodes, of which 2 can go, with 1 removal to undo.
var nodes = 6, removable = 2, undoable = 1, steps = 0
func remove() { steps += 1; if removable > 0 { removable -= 1; undoable += 1; nodes -= 1 } }
func restore() { steps += 1; if undoable > 0 { undoable -= 1; removable += 1; nodes += 1 } }
CurvedMPRPathAssistant.simplify(toward: 5, nodeCount: { nodes }, removeNode: remove, restoreNode: restore)
expect(nodes == 5, "the path is simplified to the target, \(nodes) nodes")
steps = 0
CurvedMPRPathAssistant.simplify(toward: 3, nodeCount: { nodes }, removeNode: remove, restoreNode: restore)
expect(nodes == 4 && steps == 2, "no removable node stops the removal: \(nodes) nodes after \(steps) steps")
steps = 0
CurvedMPRPathAssistant.simplify(toward: Int(Int32.max), nodeCount: { nodes }, removeNode: remove, restoreNode: restore)
expect(nodes == 7 && steps == 4, "no removal left to undo stops the restoring: \(nodes) nodes after \(steps) steps")

print(wrong.joined(separator: "\n"))
'''

helpers = read('Horos/Sources/CurvedMPRPath.swift')
if 'enum CurvedMPRPathAssistant' not in helpers:
    failures.append('CurvedMPRPath.swift has no CurvedMPRPathAssistant')
elif shutil.which('xcrun') is None:
    print('skipped the helper run: needs xcrun (swiftc)', file=sys.stderr)
else:
    with tempfile.TemporaryDirectory(prefix='horos-cpr-assistant-') as tmp:
        tmp = Path(tmp)
        (tmp / 'CurvedMPRPath.swift').write_text(helpers)
        (tmp / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc', str(tmp / 'CurvedMPRPath.swift'), str(tmp / 'main.swift'),
                                '-o', str(tmp / 'assistant')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the helpers did not compile: ' + built.stderr[-1500:])
        else:
            result = subprocess.run([str(tmp / 'assistant')], capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                failures.append('the helper run failed: ' + (result.stderr or result.stdout)[-800:])
            for line in result.stdout.split('\n'):
                if line.strip():
                    failures.append(line)

controller = code(read('Horos/Sources/CPRController.swift'))
check(bool(controller), 'no CPRController.swift')

movie = block(controller, 'func addMoviePixList(')
store = movie.find('pixListStorage[Int(_maxMovieIndex)].object = pix')
increment = movie.find('self.maxMovieIndex += 1')
check(0 <= increment < store, '-addMoviePixList:: stores the time before counting it, over the first one')
guard = movie.find('FourDSeriesGuard.canStoreTime(at: next, capacity: Int(MAX4D))')
check(0 <= guard < increment and 'return' in movie[guard:increment],
      '-addMoviePixList:: stores a time past MAX4D')

assisted = block(controller, 'func assistedCurvedPath(')
retries = block(assisted, 'while k < 5')
check(assisted != '' and 'newCP.addPatientNode' not in retries,
      'the assistant adds the centerline of an unfinished distance transform')
check('CurvedMPRPathAssistant.assembledPath(' in assisted,
      'the assistant appends the last point of an old or empty centerline')
check('centerline?.lastObject' not in assisted, 'the assistant still reads the last centerline point blindly')

# -removeNode's steps, without the views, are removeCheapestNode().
remove = block(controller, 'func removeCheapestNode()') or block(controller, 'func removeNode()')
check('CurvedMPRPathAssistant.cheapestRemovableNode(' in remove and 'guard let' in remove,
      'removeNode removes the first node when no cost is below MAXFLOAT')
slider = block(controller, 'func onSliderMove(')
check('CurvedMPRPathAssistant.simplificationTarget(' in slider and 'CurvedMPRPathAssistant.simplify(' in slider
      and '&- 3' not in slider and 'while' not in slider,
      'onSliderMove wraps the target or loops without end')

for name, signature in [('e-mail', 'func sendMail('), ('JPEG', 'func exportJPEG('),
                        ('Photos', 'func export2iPhoto('), ('TIFF', 'func exportTIFF(')]:
    body = block(controller, signature)
    check('selectedViewOnlyMPRView(false)' in body and 'selectedView()' not in body,
          'the %s export does not take the view the user selected' % name)

for xib in ['Horos/Resources/en.lproj/CPR.xib', 'Horos/Resources/ja-JP.lproj/CPR.xib']:
    text = read(xib)
    check(bool(text) and 'shadingsPresetsController' not in text,
          '%s connects shadingsPresetsController, which CPRController does not have' % xib)
check(re.search(r'\bvar\s+shadingsPresetsController\b', controller) is None,
      'CPRController has a shadingsPresetsController; the xib connection may stay')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Path Assistant keeps the user\'s nodes for failed segments, simplification stops, '
      '4D times are stored after the first, and the exports take the selected view')
