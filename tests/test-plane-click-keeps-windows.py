#!/usr/bin/env python3
"""A click with a 2D tool in a plane of the curved MPR or of the 3D MPR leaves the other views' windows alone.

A plane handed every mouse down, drag and mouse up of a 2D tool to the 2D
view's own handling and then gave its window to the other views
(-propagateWLWW:), whether or not the event had changed it. After «Full
dynamic» each view of a MIP has an automatic window of its own, and a simple
click with the Length tool copied the clicked plane's over the seven views;
in VR the planes' 2D window went into their cameras, and from there into the
rendering's window. The plane now gives its window only when the event
changed it (propagatingWindowChange).

That function is compiled as each view has it, with a stand-in of the view;
its three uses are read from the sources.

    python3 tests/test-plane-click-keeps-windows.py [<git revision>]

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
        return subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True, check=True).stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


HARNESS = r'''
import Foundation

final class Window { var given = 0; func propagateWLWW(_ sender: Plane) { given += 1 } }

final class Plane {
    var curWL: Float = 40, curWW: Float = 400
    let windowControllerIvar: Window? = Window()

%(function)s
}

var failures: [String] = []
let plane = Plane()
plane.propagatingWindowChange {}
if plane.windowControllerIvar?.given != 0 { failures.append("an event that leaves the plane's window as it was gives it to the other views") }
plane.propagatingWindowChange { plane.curWL = 60 }
if plane.windowControllerIvar?.given != 1 { failures.append("an event that changes the plane's level does not give its window to the other views once") }
plane.propagatingWindowChange { plane.curWW = 350 }
if plane.windowControllerIvar?.given != 2 { failures.append("an event that changes the plane's width does not give its window to the other views once") }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

failures = []
for name, path in [('curved MPR', 'Horos/Sources/CPRMPRDCMView.swift'), ('3D MPR', 'Horos/Sources/MPRDCMView.swift')]:
    view = read(path)
    found = re.search(r'\n    private (func propagatingWindowChange\(_ work: \(\) -> Void\) \{\n.*?\n    \})\n', view, re.S)
    if not found:
        failures.append(f'{name}: the plane gives its window to the other views whatever the event did')
        continue
    with tempfile.TemporaryDirectory(prefix='horos-plane-window-') as directory:
        p = Path(directory)
        (p / 'main.swift').write_text(HARNESS % {'function': '    ' + found.group(1)})
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'main.swift'), '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr[-3000:])
            failures.append(f'{name}: propagatingWindowChange does not compile with the stand-in')
            continue
        ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
        failures += [f'{name}: ' + line[6:] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
    for event in ('mouseDown', 'mouseDragged', 'mouseUp'):
        if f'self.propagatingWindowChange {{ super.{event}(with: theEvent) }}' not in view:
            failures.append(f'{name}: -{event}: of a 2D tool does not go through propagatingWindowChange')
        if re.search(r'super\.%s\(with: theEvent\)\s*windowControllerIvar\?\.propagateWLWW\(self\)' % event, view):
            failures.append(f'{name}: -{event}: of a 2D tool gives the window whatever it did')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a mouse down, drag or mouse up of a 2D tool in a plane gives the plane\'s window to the other views only when it changed it, '
      'in the curved MPR and the 3D MPR')
