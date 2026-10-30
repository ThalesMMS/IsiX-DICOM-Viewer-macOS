#!/usr/bin/env python3
"""Metal is the only renderer in the 2D viewer, the MPR and volume rendering.

Source level, with `<git revision>` as an optional argument for the negative
control:

* the 2D viewer and the MPR always ask Metal: no preference, per-window flag or
  toggle leads to the original renderer any more;
* volume rendering has no engine to choose: no MAPPERMODEVR default, no board
  probe writing one, no engine list in Settings, the VR or the endoscopy
  toolbar, and the blended volume keeps its mapper;
* the planar Metal 4 pilot stays opt-in, as measured and decided.
"""
from pathlib import Path
from xml.etree import ElementTree
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def body(source, signature):
    """The method body that follows `signature`, up to its closing brace."""
    start = source.find(signature)
    if start < 0:
        return ''
    start = source.find('{', start)
    return source[start:source.find('\n}', start)]


failures = []

# --- the MPR and the 2D viewer always ask Metal -----------------------------
# The bridges are Swift: the MPR window's (MPRController+MetalHost.swift),
# its views' (MPRDCMView+MetalPlane.swift) and the 2D view's (DCMView+PlanarHost.swift).
mpr = read('Horos/Sources/MPRController+MetalHost.swift') + read('Horos/Sources/MPRDCMView+MetalPlane.swift')
if 'func horosMPRMetalEnabled() -> Bool {\n        MPRCubicDisplayObserver.start()\n        return true\n    }' not in mpr:
    failures.append('the MPR does not always reconstruct with Metal')
for gone in ('toggleMPRMetal', 'HorosMPRMetal"'):
    if gone in mpr:
        failures.append('the MPR still has a way back to the original renderer: %s' % gone)
viewer = read('Horos/Sources/DCMView+PlanarHost.swift')
if 'func horosPlanarMetalEnabled() -> Bool { true }' not in viewer:
    failures.append('the 2D viewer does not always draw with Metal')
if 'Original renderer (Metal paused)' in class_text('DCMView'):
    failures.append('the 2D view still announces the original renderer')

# --- no engine to choose ------------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
for key in ('MAPPERMODEVR', 'HorosMPRMetal'):
    if key in defaults:
        failures.append('a default is still registered for %s' % key)
if 'HorosPlanarMetal4Pilot' in defaults:
    failures.append('the Metal 4 pilot is registered as a default; it stays opt-in')
def optional(path):
    """The file, or nothing where the revision does not have it."""
    try:
        return read(path)
    except (OSError, subprocess.CalledProcessError):
        return ''


def vr_objc():
    """VRView.m of a revision that still has it; nothing once the class is Swift."""
    return optional('Horos/Sources/VRView.m')


# The engines of the VR view are Swift (VRView+Engine.swift), an extension of
# the class; a revision that still has them in VRView.m is read there.
def vr_body(objc, swift):
    found = body(vr_objc(), objc)
    if found:
        return found
    try:
        engine = read('Horos/Sources/VRView+Engine.swift')
    except (OSError, subprocess.CalledProcessError):
        return ''
    start = engine.find(swift)
    if start < 0:
        return ''
    start = engine.find('{', start)
    return engine[start:engine.find('\n    }\n', start)]


probe = vr_body('+ (void) testGraphicBoard', 'static func testGraphicBoard()')
if not probe:
    failures.append('the graphics board probe is gone')
elif 'MAPPERMODEVR' in probe:
    failures.append('the board probe still writes an engine')
blending = vr_body('- (void) setBlendingEngine: (long) engineID showWait:', 'func setBlendingEngine(_ engineID: Int, showWait: Bool)')
if not ('case 2' in blending or '2: // Metal' in blending) or 'vtkGPUVolumeRayCastMapper' in vr_objc() + optional('Horos/Sources/VRView.swift'):
    failures.append('the blended volume lost its mapper, or VTK\'s GPU mapper is still there')
for path, marker in [
        ('Preference Panes/OSI3DPreferencePane/Base.lproj/OSI3DPreferencePanePref.xib', 'values.MAPPERMODEVR'),
        ('Preference Panes/OSI3DPreferencePane/ja-JP.lproj/OSI3DPreferencePanePref.xib', 'values.MAPPERMODEVR'),
        ('Preference Panes/OSI3DPreferencePane/Base.lproj/OSI3DPreferencePanePref.xib', 'values.HorosMPRMetal'),
        ('Preference Panes/OSI3DPreferencePane/ja-JP.lproj/OSI3DPreferencePanePref.xib', 'values.HorosMPRMetal'),
        ('Horos/Resources/en.lproj/VR.xib', 'selection.engine'),
        ('Horos/Resources/ja-JP.lproj/VR.xib', 'selection.engine'),
        ('Horos/Resources/en.lproj/Endoscopy.xib', 'self.engine'),
        ('Horos/Resources/ja-JP.lproj/Endoscopy.xib', 'self.engine')]:
    if marker in read(path):
        failures.append('%s still offers %s' % (path, marker))
    ElementTree.fromstring(read(path).encode('latin1'))
# EndoscopyViewer and VRController are Swift.
if 'EngineToolbarItemIdentifier' in class_text('VRController'):
    failures.append('VRController still has an Engine toolbar item')
if 'EngineToolbarItemIdentifier' in read('Horos/Sources/EndoscopyViewer.swift'):
    failures.append('Horos/Sources/EndoscopyViewer.swift still has an Engine toolbar item')

# --- the pilot is still chosen by hand --------------------------------------
if 'UserDefaults.standard.bool(forKey: PlanarBackend.pilotDefaultsKey)' not in read('Horos/Sources/PlanarHostRenderer.swift'):
    failures.append('the planar backend no longer reads the pilot preference as an opt-in')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: Metal is the only renderer in the viewer, the MPR and volume rendering, and the pilot stays opt-in')
