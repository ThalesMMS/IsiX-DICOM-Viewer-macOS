#!/usr/bin/env python3
"""A still click at the cross's centre moves nothing, and a click on a node leaves no second node on it.

The planes of the 3D MPR and of the curved MPR catch the centre of their cross
within a box of a few points. The press sent itself to -mouseDragged:, which
put the centre under the pointer: a click that did not move shifted the cross
by where in the box it fell, the three planes with it, and in the curved MPR
left their cameras to undo. The press now keeps the distance from the pointer
to the centre (ReconstructionCrossDrag.offset) and a drag puts the centre at
the pointer plus that distance (ReconstructionCrossDrag.centre): nothing moves
until the pointer does, and a drag has no jump at its start.

In the curved MPR:

* with the Curved Path tool marking a path, a click over the cross's lines or
  its centre marks the node instead of catching the cross;
* a click that does not catch a node and falls within half a screen point of
  the last one is refused (the refusal compared with 1e-10 mm, which a click
  never met, and left a second node 0.04 mm from the first).

ReconstructionCrossDrag is compiled as it is, with stand-ins of the plane and
of the vector; the planes' mouse down and drag are read from their sources.

    python3 tests/test-cross-centre-drag.py [<git revision>]

A revision reads the sources from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        if shown.returncode:
            print(f'FAIL: {revision} has no {path}')
            sys.exit(1)
        return shown.stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


STUBS = r'''
import AppKit

struct N3Vector { var x: CGFloat, y: CGFloat, z: CGFloat }
func N3VectorDistance(_ a: N3Vector, _ b: N3Vector) -> CGFloat {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
}

final class Pix { var pixelSpacingX = 0.4, pixelSpacingY = 0.5 }

/// A plane 400 x 300 points whose image is drawn at 1.5 points a pixel from (20, 30).
final class DCMView: NSView {
    var curDCM: Pix? = Pix()
    func convert(fromGL2NSView a: NSPoint) -> NSPoint { NSPoint(x: 20 + a.x * 1.5, y: 30 + a.y * 1.5) }
}
'''

DRIVER = r'''
import AppKit

var failures: [String] = []
func check(_ condition: Bool, _ what: String) { if !condition { failures.append(what) } }
func event(_ x: CGFloat, _ y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

@MainActor func run() {
    let plane = DCMView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    // The centre at pixel (100, 80): 40 mm and 40 mm in the image, (170, 150) in the view.
    let centre = NSPoint(x: 100 * 0.4, y: 80 * 0.5)
    for press in [NSPoint(x: 170, y: 150), NSPoint(x: 163, y: 158), NSPoint(x: 179.5, y: 141)] {
        let offset = ReconstructionCrossDrag.offset(ofCentre: centre, from: event(press.x, press.y), in: plane)
        let still = ReconstructionCrossDrag.centre(at: event(press.x, press.y), offset: offset, in: plane)
        check(abs(still.x - 170) < 1e-9 && abs(still.y - 150) < 1e-9,
              "a press at \(press) that does not move puts the centre at \(still), not where it is, (170, 150)")
        let dragged = ReconstructionCrossDrag.centre(at: event(press.x + 12, press.y - 7), offset: offset, in: plane)
        check(abs(dragged.x - 182) < 1e-9 && abs(dragged.y - 143) < 1e-9,
              "a drag of (12, -7) from \(press) puts the centre at \(dragged), not at (182, 143)")
    }
    plane.curDCM = nil
    check(ReconstructionCrossDrag.offset(ofCentre: centre, from: event(170, 150), in: plane) == .zero,
          "a plane without an image gives a distance to its centre")

    let last = N3Vector(x: 10, y: 20, z: 30)
    check(ReconstructionCrossDrag.isOnTop(N3Vector(x: 10.0387, y: 20, z: 30), of: last, pointLength: 0.3),
          "a node 0.0387 mm from the last one, at 0.3 mm a point, is not refused")
    check(!ReconstructionCrossDrag.isOnTop(N3Vector(x: 10.16, y: 20, z: 30), of: last, pointLength: 0.3),
          "a node more than half a point from the last one is refused")
    check(!ReconstructionCrossDrag.isOnTop(N3Vector(x: 10, y: 20, z: 30.2), of: last, pointLength: 0.3),
          "a node at the last one's place in another slice is refused")
    check(!ReconstructionCrossDrag.isOnTop(last, of: nil, pointLength: 0.3), "the first node is refused")
}
MainActor.assumeIsolated { run() }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

failures = []
helper = read('Horos/Sources/ReconstructionCrossDrag.swift')
with tempfile.TemporaryDirectory(prefix='horos-cross-drag-') as directory:
    p = Path(directory)
    (p / 'Stubs.swift').write_text(STUBS)
    (p / 'ReconstructionCrossDrag.swift').write_text(helper)
    (p / 'main.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'Stubs.swift'),
                            str(p / 'ReconstructionCrossDrag.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print('FAIL: ReconstructionCrossDrag does not compile with the stand-ins')
        sys.exit(1)
    ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    failures += [line[6:] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
    if ran.returncode != 0 and not failures:
        failures.append('the harness ended with ' + str(ran.returncode) + ': ' + ran.stderr.strip()[-400:])

for name, path in [('curved MPR', 'Horos/Sources/CPRMPRDCMView.swift'), ('3D MPR', 'Horos/Sources/MPRDCMView.swift')]:
    view = read(path)
    press = re.search(r'if mouseOnLines == 2 \{(.*?)\} else if mouseOnLines == 1 \{', view, re.S)
    if not press:
        failures.append(f'{name}: the press on the centre of the cross moved; the test needs a new look')
        continue
    if 'mouseDragged(' in press.group(1):
        failures.append(f'{name}: a press on the centre of the cross is sent to -mouseDragged:, which moves the centre to the pointer')
    if 'moveCenterOffset = ReconstructionCrossDrag.offset(ofCentre: self.centerLines(), from: theEvent, in: self)' not in press.group(1):
        failures.append(f'{name}: a press on the centre of the cross does not keep the distance from the pointer to the centre')
    drag = re.search(r'\} else if _moveCenter \{(.*?)_vrView\?\.setWindowCenter\(', view, re.S)
    if not drag or 'ReconstructionCrossDrag.centre(at: theEvent, offset: moveCenterOffset, in: self)' not in drag.group(1):
        failures.append(f'{name}: a drag of the centre puts it at the pointer, not at the pointer and the distance the press found')

curved = read('Horos/Sources/CPRMPRDCMView.swift')
if not re.search(r'let marksPath = self\.getTool\(theEvent\) == \.tCurvedROI && \(windowControllerIvar\?\.curvedPathCreationMode \?\? false\)\s*'
                 r'let mouseOnLines = theEvent\.type == \.rightMouseDown \|\| marksPath \? 0 : self\.mouseOnLines\(', curved):
    failures.append('curved MPR: with the Curved Path tool marking a path, a click over the lines of the cross catches the cross')
if not re.search(r'let onTop = ReconstructionCrossDrag\.isOnTop\(patientNode, of: \(_curvedPath\?\.nodes\.lastObject as\? NSValue\)\?\.n3VectorValue\(\), '
                 r'pointLength: pointLength\).*?if decision\.accepted == false \|\| onTop \{.*?self\.sendDidEditCurvedPath\(\)\s*return', curved, re.S):
    failures.append('curved MPR: a click within half a point of the last node adds a second node on it')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a press on the centre of the cross moves nothing until the pointer does, in the 3D MPR and the curved MPR; '
      'the Curved Path tool marks a node over the lines, and not a second one on top of the last')
