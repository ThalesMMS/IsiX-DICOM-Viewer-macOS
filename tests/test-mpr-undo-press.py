#!/usr/bin/env python3
"""A click in a plane of the 3D MPR that changes nothing leaves nothing to undo, and a new move empties the redo.

Every mouse down in a plane put the three cameras on the window's undo queue
and nothing looked at them again: a few clicks that changed nothing used up
the Cmd-Z. And nothing emptied the redo queue, so after a Cmd-Z and a new
move a redo brought an old state back over it.

* The press's entry stays at its mouse up only when the cameras or the lines'
  angles are no longer those of the entry (ReconstructionUndoEntries.sameCameras,
  within the rounding of a camera read back from the rendering).
* An entry put on the queue empties the redo queue; a press settles it at its
  end, so that a click that changes nothing keeps what can be redone.
* A press whose release never came ends at the next press or at Cmd-Z.

The queue's functions are compiled as MPRController.swift has them, with
ReconstructionUndoEntries as it is and stand-ins of the planes and cameras.

    python3 tests/test-mpr-undo-press.py [<git revision>]

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
            return text[opening:index + 1]
    return ''


controller = read('Horos/Sources/MPRController.swift')
helper = read('Horos/Sources/ReconstructionUndoEntries.swift')
entries = re.search(r'\n(@MainActor\nenum ReconstructionUndoEntries \{.*?\n\})\n', helper, re.S)
PIECES = {name: block(controller, signature) for name, signature in [
    ('add', 'public override dynamic func add(toUndoQueue string: String!)'),
    ('began', 'func planePressBegan()'), ('ended', 'func planePressEnded()'),
    ('prepare', 'public dynamic func prepareObject(forUndo string: String!) -> Any!'),
    ('execute', 'private dynamic func executeUndo(_ u: NSMutableArray!)'),
    ('undo', '@IBAction public override dynamic func undo(_ sender: Any!)'),
    ('redo', '@IBAction public override dynamic func redo(_ sender: Any!)')]}
missing = [name for name, body in PIECES.items() if not body] + ([] if entries else ['ReconstructionUndoEntries'])
if missing:
    print(f'FAIL: the 3D MPR has no press to settle its undo entry: {", ".join(missing)} not found')
    sys.exit(1)

HARNESS = r'''
import AppKit

final class Point3D: NSObject {
    var x: Float, y: Float, z: Float
    init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
}
final class Camera: NSObject, NSCopying {
    var position: Point3D! = Point3D(0, 0, 300), focalPoint: Point3D! = Point3D(0, 0, 0), viewUp: Point3D! = Point3D(0, 1, 0)
    var parallelScale: Float = 250, viewAngle: Float = 30, clippingRangeNear: Float = 0, clippingRangeFar: Float = 2
    var wl: Float = 300, ww: Float = 1200, fusionPercentage: Float = 0
    var movieIndexIn4D = 0
    func copy(with zone: NSZone? = nil) -> Any {
        let c = Camera()
        c.position = Point3D(position.x, position.y, position.z); c.focalPoint = Point3D(focalPoint.x, focalPoint.y, focalPoint.z)
        c.viewUp = Point3D(viewUp.x, viewUp.y, viewUp.z); c.parallelScale = parallelScale; c.viewAngle = viewAngle
        c.clippingRangeNear = clippingRangeNear; c.clippingRangeFar = clippingRangeFar; c.wl = wl; c.ww = ww
        c.fusionPercentage = fusionPercentage; c.movieIndexIn4D = movieIndexIn4D
        return c
    }
}
final class Plane { var camera: Camera? = Camera(); var angleMPR: Float = 0 }
struct Key { let value: Int }
enum ReconstructionPreferences { static let undoQueueSize = Key(value: 20) }
struct Store { subscript(key: Key) -> Int { key.value } }
func addObject(_ array: NSMutableArray, _ object: Any?) { if let object { array.add(object) } }

%(entries)s

@MainActor final class MPRController {
    var undoQueue: NSMutableArray? = NSMutableArray(), redoQueue: NSMutableArray? = NSMutableArray()
    var pressInPlane = false
    weak var pressEntry: AnyObject?
    let preferenceStore = Store()
    var mprView1: Plane? = Plane(), mprView2: Plane? = Plane(), mprView3: Plane? = Plane()
    func updateViewsAccordingToFrame(_ sender: Any?) {}

    func add(toUndoQueue string: String!)
%(add)s

    func planePressBegan()
%(began)s

    func planePressEnded()
%(ended)s

    func prepareObject(forUndo string: String!) -> Any!
%(prepare)s

    func executeUndo(_ u: NSMutableArray!)
%(execute)s

    func undo(_ sender: Any!)
%(undo)s

    func redo(_ sender: Any!)
%(redo)s
}

var failures: [String] = []
func expect(_ condition: Bool, _ what: @autoclosure () -> String) { if !condition { failures.append(what()) } }

@MainActor func run() {
    func press(_ window: MPRController, _ work: () -> Void) { window.planePressBegan(); work(); window.planePressEnded() }
    func depth(_ window: MPRController) -> Float { window.mprView1?.camera?.position.z ?? -1 }
    func move(_ window: MPRController, by step: Float) {
        for plane in [window.mprView1, window.mprView2, window.mprView3] {
            let camera = plane?.camera?.copy() as? Camera
            camera?.position.z += step; camera?.focalPoint.z += step
            plane?.camera = camera
        }
    }
    let window = MPRController()
    press(window) {}
    expect(window.undoQueue?.count == 0, "a click that changed nothing left \(window.undoQueue?.count ?? -1) entries to undo")
    // A camera read back from the rendering differs by rounding.
    press(window) { window.mprView2?.camera?.position.x += 1e-4; window.mprView2?.camera?.ww *= 1 + 1e-6 }
    expect(window.undoQueue?.count == 0, "a click whose cameras came back rounded left \(window.undoQueue?.count ?? -1) entries to undo")
    press(window) { move(window, by: 5) }
    press(window) { window.mprView1?.angleMPR += 15 }
    press(window) { window.mprView3?.camera?.parallelScale *= 0.8 }
    press(window) { window.mprView1?.camera?.wl = 40 }
    expect(window.undoQueue?.count == 4, "a move, a turn of the lines, a zoom and a windowing left \(window.undoQueue?.count ?? -1) entries to undo, not 4")
    window.undo(nil); window.undo(nil); window.undo(nil)
    expect(window.redoQueue?.count == 3 && window.mprView1?.angleMPR == 0 && depth(window) == 305,
           "three Cmd-Z left \(window.redoQueue?.count ?? -1) to redo, the lines at \(window.mprView1?.angleMPR ?? -1) and the planes at \(depth(window))")
    press(window) {}
    expect(window.redoQueue?.count == 3 && window.undoQueue?.count == 1, "a click that changed nothing left \(window.redoQueue?.count ?? -1) to redo, not the three undone")
    press(window) { move(window, by: 2) }
    expect(window.redoQueue?.count == 0, "a move after three Cmd-Z left \(window.redoQueue?.count ?? -1) entries to redo, not none")
    window.redo(nil)
    expect(depth(window) == 307, "a redo after a new move put the planes at \(depth(window)), not where the move left them, 307")
    // A wheel step, outside a press: its entry, and nothing to redo.
    window.undo(nil)
    window.add(toUndoQueue: "mprCamera")
    expect(window.redoQueue?.count == 0, "a wheel step after a Cmd-Z left \(window.redoQueue?.count ?? -1) entries to redo")
    // A press whose release never came ends at Cmd-Z, which undoes what it did.
    let before = depth(window)
    window.planePressBegan()
    move(window, by: 9)
    window.undo(nil)
    expect(depth(window) == before, "the Cmd-Z of a move whose release never came left the planes at \(depth(window)), not at \(before)")
}
MainActor.assumeIsolated { run() }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-mpr-undo-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(HARNESS % dict(PIECES, entries=entries.group(1)))
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print('FAIL: the undo queue of the 3D MPR does not compile with the stand-ins')
        sys.exit(1)
    ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    failures += [line[6:] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
    if ran.returncode != 0 and not failures:
        failures.append('the harness ended with ' + str(ran.returncode) + ': ' + ran.stderr.strip()[-400:])

view = read('Horos/Sources/MPRDCMView.swift')
down, up = block(view, 'override dynamic func mouseDown(with theEvent: NSEvent)'), block(view, 'override dynamic func mouseUp(with theEvent: NSEvent)')
if down.count('windowControllerIvar?.planePressBegan()') != 1 or 'add(toUndoQueue: "mprCamera")' in down:
    failures.append("a plane's mouse down does not begin the press once, or still puts the cameras on the queue itself")
if not re.match(r'\{\s*self\.checkCursor\(\)\s*defer \{ windowControllerIvar\?\.planePressEnded\(\) \}', up):
    failures.append("a plane's mouse up does not end the press whatever the click did")

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: in the 3D MPR a click that changes nothing leaves nothing to undo and keeps the redo, a press that moves, turns, zooms or '
      'windows leaves one entry, and a new move or wheel step after a Cmd-Z empties the redo')
