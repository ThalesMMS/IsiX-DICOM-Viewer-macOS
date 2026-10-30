#!/usr/bin/env python3
"""-[VRController dealloc] removes only the shading observer that was added.

-[VRController initWithPix:::::style:mode:] observed the `selectedObjects` of
the shading presets' array controller only at its end, but -dealloc always
removed that observer. Its failures after the window is loaded ("Not enough
memory": the 3D engine refused the volume) autorelease the controller before
the observer is added, and EndoscopyVRController, whose initializer does not
call the superclass's, never added it: removing an observer that was not added
raises NSRangeException inside -dealloc.

The observer is now added by -horosObserveShadingSelection, which records it in
an instance variable that -dealloc reads. The endoscopy's controller adds it
too, at the end of its successful initializer: the shading panel's preset popup
in Endoscopy.xib, as in VR.xib, has no action and applies the chosen preset
only through that observer.

The controller keeps the array controller it observes retained while it
observes it. shadingsPresetsController is an outlet the controller does
not retain. In VR.xib the controller owns the nib, and -[NSWindowController
dealloc] releases the array controller after -[VRController dealloc] removed the
observer. In Endoscopy.xib both are top-level objects of the EndoscopyViewer:
the viewer released the array controller while an autorelease pool still held
the endoscopy's controller, whose -dealloc then removed its observer from a
freed object and brought the application down when the endoscopy was closed.

VRController is Swift: the controller holds the array controller it observes
(horosObservedShadings) and its deinit removes the observer from that object
only when it was added. The check runs: -horosObserveShadingSelection,
-observeValueForKeyPath:... and the observer lines of deinit are compiled, as
VRController.swift has them, into a stand-in controller, with NSZombieEnabled
so a message to a freed object stops the probe. A selection chosen in the
array controller must reach -applyShading:, and the two release orders must
both end with the observer removed and both objects freed:

- VR's order, the controller first (the control: it always works);
- the endoscopy's, the array controller first while a pool holds the controller.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8', errors='replace')


def block(source, signature):
    """The text of `signature` up to the brace that closes its body."""
    at = source.find(signature)
    if at < 0:
        return ''
    brace = source.find('{', at)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[at:index + 1]
    return ''


def code(text):
    """`text` without its // comments."""
    return re.sub(r'//[^\n]*', '', text)


ADD = 'addObserver(self, forKeyPath: "selectedObjects"'
REGISTER = 'horosObserveShadingSelection()'

vr_source = read('Horos/Sources/VRController.swift')
vr = code(vr_source)

check(re.search(r'\n    final var horosObservedShadings: ShadingArrayController\?\n', vr),
      'VRController must hold, strongly, the array controller it observes')

register = block(vr, '    final func horosObserveShadingSelection() {')
check(register, 'VRController.swift lost -horosObserveShadingSelection')
at_add = register.find('shadings.' + ADD)
at_set = register.find('horosObservedShadings = shadings')
check(at_add >= 0 and at_set > at_add,
      '-horosObserveShadingSelection must add the observer, then keep the object it observes')
check('guard horosObservedShadings == nil' in register, '-horosObserveShadingSelection must not add the observer twice')
whole = code(''.join(path.read_text() for path in sorted((root / 'Horos/Sources').glob('VRController*.swift'))))
check(whole.count(ADD) == 1,
      f'the shading observer is added {whole.count(ADD)} times in VRController; only -horosObserveShadingSelection may add it')

deinit = block(vr, '    isolated deinit {')
check(deinit, 'VRController.swift lost its deinit')
check(re.search(r'if let shadings = horosObservedShadings \{\s*shadings\.removeObserver\(self, forKeyPath: "selectedObjects"', deinit)
      and 'shadingsPresetsController' not in deinit,
      'deinit must remove the shading observer, only if it was added, from the object it observes')

finish = block(vr, '    private final func finishInit(renderingMode: String?) -> Bool {')
at_register = finish.find(REGISTER)
check(at_register >= 0, '-initWithPix:::::style:mode: must observe the shading presets through -horosObserveShadingSelection')
engine = finish.find('if err != 0 { return false }')
check(0 <= engine < at_register and 'return false' not in finish[at_register:],
      'the 3D engine failure must come before the shading observer is added')

endoscopy = code(read('Horos/Sources/EndoscopyVRController.swift'))
reinit = block(endoscopy, '    public func horosReinit(pix: NSMutableArray?, files f: NSArray?, volume vData: NSData?,')
check(reinit, 'EndoscopyVRController.swift lost -horosReinitWithPix:...')
check(ADD not in reinit, 'the endoscopy must observe through -horosObserveShadingSelection, which deinit knows of')
at_register = reinit.find(REGISTER)
check(at_register >= 0, "the endoscopy's controller must observe its shading presets, as its superclass does")
check(at_register > reinit.rfind('return false') and reinit.find('return true', at_register) >= 0,
      "the endoscopy's controller must observe its shading presets only once its reinitializer succeeds")

# The premise of the endoscopy's observer: its preset popup, as VR's, has no action.
for xib in ('Horos/Resources/en.lproj/Endoscopy.xib', 'Horos/Resources/en.lproj/VR.xib'):
    text = read(xib)
    controller = re.search(r'<outlet property="shadingsPresetsController" destination="([^"]+)"', text)
    check(controller, f'{xib} no longer connects shadingsPresetsController')
    if controller:
        popup = re.search(r'<popUpButton [^>]*>(?:(?!</popUpButton>).)*?<binding destination="' + re.escape(controller.group(1))
                          + r'" name="selectedIndex" keyPath="selectionIndex"(?:(?!</popUpButton>).)*</popUpButton>', text, re.S)
        check(popup, f"{xib} lost the shading presets' popup")
        if popup:
            check('<action ' not in popup.group(0),
                  f"{xib}: the shading presets' popup has an action now; the observer may no longer be needed")



# The ownership, run.
observe = block(vr_source, '    final func horosObserveShadingSelection() {')
notified = block(vr_source, '    public nonisolated override func observeValue(')
removal = re.search(r'NSLog\("Dealloc VRController"\)\n(\s*if let shadings = horosObservedShadings \{.*?\n        \}\n)', deinit, re.S)

PROBE = r"""
import AppKit

nonisolated(unsafe) var shadingsFreed = 0, controllersFreed = 0, appliedCount = 0

final class ShadingArrayController: NSArrayController {
    deinit { shadingsFreed += 1 }
}

final class VRController: NSObject {
    var shadingsPresetsController: ShadingArrayController?   // the nib's outlet
    var horosObservedShadings: ShadingArrayController?
    nonisolated(unsafe) static let shadingObservation = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    init(shadings: ShadingArrayController) { shadingsPresetsController = shadings }
    func applyShading(_ sender: Any?) { appliedCount += 1 }
@@OBSERVE@@
@@NOTIFIED@@
    deinit {
@@REMOVAL@@
        controllersFreed += 1
    }
}

let endoscopy = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "endoscopy"
autoreleasepool {
    // The nib's top-level objects.
    var shadings: ShadingArrayController? = ShadingArrayController(content: NSMutableArray(array: [["name": "a"], ["name": "b"]]))
    var controller: VRController? = VRController(shadings: shadings!)
    controller!.horosObserveShadingSelection()
    controller!.horosObserveShadingSelection()   // once only
    shadings!.setSelectionIndex(1)               // a preset chosen in the popup
    if endoscopy {
        // The viewer releases its top-level objects while a pool still holds the VR controller.
        autoreleasepool {
            _ = Unmanaged.passRetained(controller!).autorelease()
            controller!.shadingsPresetsController = nil
            shadings = nil
            controller = nil
        }
    } else {
        controller = nil
        shadings = nil
    }
}
print(appliedCount, controllersFreed, shadingsFreed)
"""

if not (observe and notified and removal):
    failures.append('VRController.swift no longer has the observer code this probe compiles; the test needs a new look')
elif shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
else:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / 'main.swift'
        source.write_text(PROBE.replace('@@OBSERVE@@', observe).replace('@@NOTIFIED@@', notified)
                          .replace('@@REMOVAL@@', removal.group(1)))
        binary = Path(tmp) / 'probe'
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(source), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            failures.append('the ownership probe does not compile')
        else:
            env = dict(os.environ, NSZombieEnabled='YES')
            for order in ('vr', 'endoscopy'):
                run = subprocess.run([str(binary), order], capture_output=True, text=True, timeout=60, env=env)
                if run.returncode:
                    detail = (run.stderr.strip().splitlines() or [''])[-1]
                    failures.append(f'{order} release order: the probe stopped with {run.returncode}'
                                    f' (a message to a freed object?): {detail}')
                    continue
                counts = tuple(int(value) for value in run.stdout.split())
                if counts != (1, 1, 1):
                    failures.append(f'{order} release order: presets applied, controllers freed, array controllers freed = '
                                    f'{counts}, not (1, 1, 1)')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: VRController removes only the shading observer it added, keeps the observed array controller alive until then, '
      'and the endoscopy adds it')
