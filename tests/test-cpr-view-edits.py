#!/usr/bin/env python3
"""The CPR views edit the curve and tell their delegate as they should.

The three plane views of the Curved MPR (CPRMPRDCMView):
- the assisted-path message is sent to a delegate that answers it, not to
  one that answers -CPRViewDidEditCurvedPath:, which raised an unrecognized
  selector without the assisted method;
- Delete posts OsirixDeletedCurvedPathNotification only when the curve was
  deleted, not when the alert was cancelled;
- the mouse up moves the cross to a dragged node only, not to the node index
  -1 of a transverse section token;
- a flipped image swaps the arrows once: the key test is compiled from the
  source and run for each arrow and flip, where the second test swapped them
  back and both arrows moved the same way;
- the ROI manager and the 2D points are released: nothing is retained by hand.

The stretched and transverse views:
- a click on an end node of the stretched view sends no «will edit», and its
  mouse up now sends no «did edit»: the count went to -1 and undo stopped;
- without a centerline, the stretched view finds no node near the mouse,
  where a zero vector made a click near the origin insert one;
- the vectors and tangents of the transverse export lines are freed;
- the transverse view copies its display info, as its header declares, asks
  for a new slice only when the path's sections differ (the comparison is run
  by test-cpr-archive-and-fill.py), and leaves out a plane whose buffer it
  cannot acquire instead of releasing it and adding an empty DCMPix.

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


mpr = code(read('Horos/Sources/CPRMPRDCMView.swift'))
if not mpr:
    print('FAIL: no CPRMPRDCMView.swift')
    sys.exit(1)

# The assisted message goes to a delegate that answers it.
assisted = block(mpr, 'func sendDidEditAssistedCurvedPath()')
check('responds(to: #selector(CPRViewDelegate.cprViewDidEditAssistedCurvedPath(_:)))' in assisted
      and 'cprViewDidEditCurvedPath' not in assisted,
      'the assisted-path message is sent to a delegate asked for -CPRViewDidEditCurvedPath:')

# Delete notifies only a deletion.
delete = block(mpr, 'func deleteCurrentCurvedPath()')
check('-> Bool' in mpr[mpr.find('func deleteCurrentCurvedPath()'):][:80] and 'return true' in delete
      and 'return false' in delete,
      'deleteCurrentCurvedPath does not say whether the curve was deleted')
key_down = block(mpr, 'override dynamic func keyDown(with theEvent: NSEvent)')
posting = re.search(r'if\s+self\.deleteCurrentCurvedPath\(\)\s*\{[^{}]*OsirixDeletedCurvedPath', key_down)
check(posting is not None,
      'Delete posts OsirixDeletedCurvedPathNotification although the deletion was cancelled')

# The mouse up reads a node only for a node token.
mouse_up = block(mpr, 'override dynamic func mouseUp(with theEvent: NSEvent)')
at = mouse_up.find('nodes.object(at:')
guard = mouse_up[max(0, at - 400):at]
check(at >= 0 and 'controlTokenIsNode(draggedToken)' in guard and 'nodeIndex < nodes.count' in guard,
      'the mouse up reads the node of a transverse section token (index -1)')

# The ROI manager and the 2D points are not retained by hand.
check('passRetained' not in mpr, 'CPRMPRDCMView still retains an object by hand (ROI manager or 2D point)')
check(re.search(r'unowned\(unsafe\)\s+var\s+_ROIManager', mpr) is None,
      'the ROI manager is still held unretained, leaked')

# The stretched view pairs its edits.
stretched = code(read('Horos/Sources/CPRStretchedView.swift'))
down = block(stretched, 'override dynamic func mouseDown(with event: NSEvent)')
up = block(stretched, 'override dynamic func mouseUp(with event: NSEvent)')
end_node = block(down, 'if i == 0 || i == (_curvedPath?.nodes.count ?? 0) - 1')
check(end_node != '' and '_sendWillEditCurvedPath' not in end_node,
      'a click on an end node of the stretched view now sends «will edit»; the test expects none')
flags = down.count('_isEditingDraggedNode = true')
check(flags == 2, 'the stretched view does not record which node drags sent «will edit» (%d of 2)' % flags)
did = re.search(r'if\s+_isEditingDraggedNode\s*\{\s*self\._sendDidEditCurvedPath\(\)\s*\}', up)
check(did is not None, 'the stretched view sends «did edit» after a click on an end node, which sent no «will edit»')
check('_isEditingDraggedNode = false' in up, 'the stretched view keeps the edit flag of the last drag')
for name, signature in [('mouseDown', 'override dynamic func mouseDown(with event: NSEvent)'),
                        ('mouseMoved', 'override dynamic func mouseMoved(with theEvent: NSEvent)')]:
    body = block(stretched, signature)
    check('_centerlinePath?.relativePositionClosest' not in body and 'if let centerlinePath = _centerlinePath' in body,
          'the stretched view\'s %s measures the distance to a missing centerline from a zero vector' % name)
export_lines = stretched[stretched.find('if exportTransverseSliceInterval > 0 {'):]
export_lines = block(export_lines, 'if exportTransverseSliceInterval > 0 {')
check(re.search(r'defer\s*\{\s*free\(vectors\)\s*free\(tangents\)\s*\}', export_lines) is not None,
      'the stretched view leaks the vectors and tangents of the transverse export lines')

# The transverse view.
transverse = code(read('Horos/Sources/CPRTransverseView.swift'))
display_info = block(transverse, 'var displayInfo: CPRDisplayInfo!')
check('_displayInfo = displayInfo?.copy() as? CPRDisplayInfo' in display_info,
      'the transverse view retains the display info its header declares copy')
curved_path = block(transverse, 'var curvedPath: CPRCurvedPath!')
check('hasSameTransverseSections(as:' in curved_path and re.search(r'if\s+sameSections\s*==\s*false\s*\{\s*self\._setNeedsNewRequest\(\)', curved_path),
      'the transverse view asks for a new slice for every path, compared by identity with its copy')
generated = block(transverse, 'func generator(_ generator: CPRGenerator?, didGenerateVolume')
check('DCMPix()' not in generated and 'assert(false)' not in generated,
      'the transverse view adds an empty DCMPix for a plane without data')
acquire = generated.find('aquireInlineBuffer(&inlineBuffer)')
release = generated.find('releaseInlineBuffer(&inlineBuffer)')
check(acquire >= 0 and 'guard' in generated[max(0, acquire - 80):acquire] and 'continue' in generated[acquire:release],
      'the transverse view releases an inline buffer it never acquired')

# The arrows of a flipped image, compiled from keyDown.
start = key_down.find('if self.xFlipped {')
end = key_down.find('if c == NSDownArrowFunctionKey || c == NSUpArrowFunctionKey {')
if start < 0 or end < start:
    failures.append('the arrow flip of keyDown was not found')
elif shutil.which('xcrun') is None:
    print('skipped arrow run: needs xcrun (swiftc)', file=sys.stderr)
else:
    flip = key_down[start:end].replace('self.xFlipped', 'xFlipped').replace('self.yFlipped', 'yFlipped')
    driver = '''import AppKit

func arrow(_ key: Int, xFlipped: Bool, yFlipped: Bool) -> Int {
    var c = key
    %s
    return c
}

let left = NSLeftArrowFunctionKey, right = NSRightArrowFunctionKey
let up = NSUpArrowFunctionKey, down = NSDownArrowFunctionKey
let names = [left: "left", right: "right", up: "up", down: "down"]
var wrong: [String] = []
for xFlipped in [false, true] {
    for yFlipped in [false, true] {
        let expected = [left: xFlipped ? right : left, right: xFlipped ? left : right,
                        up: yFlipped ? down : up, down: yFlipped ? up : down]
        for (key, want) in expected {
            let got = arrow(key, xFlipped: xFlipped, yFlipped: yFlipped)
            if got != want {
                wrong.append("\\(names[key]!) with x flipped \\(xFlipped), y flipped \\(yFlipped) moves \\(names[got] ?? "?"), not \\(names[want]!)")
            }
        }
    }
}
print(wrong.sorted().joined(separator: "\\n"))
''' % flip
    with tempfile.TemporaryDirectory(prefix='horos-cpr-arrows-') as tmp:
        tmp = Path(tmp)
        (tmp / 'main.swift').write_text(driver)
        built = subprocess.run(['xcrun', 'swiftc', str(tmp / 'main.swift'), '-o', str(tmp / 'arrows')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the arrow flip did not compile: ' + built.stderr[-1500:])
        else:
            result = subprocess.run([str(tmp / 'arrows')], capture_output=True, text=True, check=True)
            for line in result.stdout.split('\n'):
                if line.strip():
                    failures.append('flipped arrows: ' + line)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the CPR plane views ask for the assisted message, notify only a deletion, '
      'move the cross to nodes only, swap flipped arrows once and release their ROI objects; '
      'the stretched view pairs its edits and frees its export lines; '
      'the transverse view copies its display info, compares sections and skips planes without data')
