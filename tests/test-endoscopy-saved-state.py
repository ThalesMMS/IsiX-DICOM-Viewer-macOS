#!/usr/bin/env python3
"""The endoscopy window ignores a saved state it cannot read, and keeps the shading its state holds.

The endoscopy window saves its 3D state (camera, colour and opacity tables,
shading values and flag) per series, in a VRENDOSCOPY-… file, and reads it when
it opens:

* the view reads the values as the Objective-C did, so a damaged file, or an
  old one with a value of another type, raises an Objective-C exception. The
  volume rendering window catches it; the endoscopy did not, and the exception
  left through the opening of the window. It is now caught around the view's
  reading: logged, the state left aside, and the window opens as for a series
  without one. A table name of another type falls back to the default too;
* the state never named a shading preset, so every opening applied the
  «Endoscopy» preset over the shading values the view had just taken from the
  state: the shading of an endoscopy never came back. The preset is now the
  one VolumeRenderingOpening.endoscopyShadingPreset gives: none when the state
  holds shading values.

The rule is IsiXImaging's, tested in its package (VolumeRenderingOpeningTests);
the window's part is read from EndoscopyVRController.swift.

    python3 tests/test-endoscopy-saved-state.py [<git revision>]

A revision reads the files from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
RULE = 'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeRenderingOpening.swift'


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else ''
    return (ROOT / path).read_text(encoding='utf-8')


failures = []
controller = read('Horos/Sources/EndoscopyVRController.swift')
start = controller.find('    public override func load3DState() {')
load = controller[start:controller.index('\n    }\n', start)] if start >= 0 else ''

if not re.search(r'if let e = HorosObjCException\.caught\(\{ view\?\.set3DStateDictionary\(dict as\? \[AnyHashable: Any\]\) \}\) \{\s*'
                 r'_N2LogExceptionImpl\(e, false, "-\[EndoscopyVRController load3DState\]"\)\s*'
                 r'NSLog\([^\n]*\)\s*state = nil\s*view\?\.set3DStateDictionary\(nil\)\s*\}', load):
    failures.append('a saved state the view cannot read raises through the opening of the endoscopy window: it must be '
                    'caught, logged and left aside')
if load.count('set3DStateDictionary(dict as? [AnyHashable: Any])') != 1:
    failures.append('the endoscopy hands its saved state to the view outside the catch')
if 'applyCLUTString((state?.object(forKey: "CLUTName") as? String) ?? "Endoscopy")' not in load or \
        'applyOpacityString((state?.object(forKey: "OpacityName") as? String) ?? "Logarithmic Table")' not in load:
    failures.append('a table name of another type in the saved state does not fall back to the endoscopy\'s default table')
if not re.search(r'let holdsShading = \(state\?\.object\(forKey: "ShadingValues"\) as\? \[Any\]\)\?\.count == 4\s*'
                 r'let shadingName = VolumeRenderingOpening\.endoscopyShadingPreset\(savedName: state\?\.object\(forKey: "shading"\) as\? String,\s*'
                 r'stateHoldsShadingValues: holdsShading\)', load):
    failures.append('the endoscopy applies its «Endoscopy» shading preset at every opening, over the shading values its '
                    'saved state holds')
if re.search(r'shadingName = "Endoscopy"', load):
    failures.append('the endoscopy still falls back to the «Endoscopy» preset by itself')
if not re.search(r'where shadingName != nil \{\s*if \(\(shading as AnyObject\)\.value\(forKey: "name"\) as\? String\) == shadingName \{\s*'
                 r'presets\?\.setSelectedObjects\(\[shading\]\)\s*applyShading\(nil\)', load):
    failures.append('the preset the rule gives is the one selected and applied, and none when it gives none')

# What the view saves and reads: the values the rule relies on.
state = read('Horos/Sources/VRView+State.swift')
if 'forKey: "ShadingValues" as NSString)' not in state or 'savedArray(dict["ShadingValues"])' not in state:
    failures.append('premise: the view saves and reads the shading values under ShadingValues')

rule = read(RULE)
if 'static func endoscopyShadingPreset(savedName: String?, stateHoldsShadingValues: Bool) -> String?' not in rule:
    failures.append('the choice of the shading preset must be IsiXImaging\'s VolumeRenderingOpening.endoscopyShadingPreset')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a saved state the view cannot read is caught, logged and left aside, with the default tables for names of '
      'another type; the endoscopy\'s shading preset is applied only when the state holds no shading values')
