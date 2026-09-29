#!/usr/bin/env python3
"""Metal is the only renderer in the 2D viewer, the MPR and volume rendering.

Source level, with `<git revision>` as an optional argument for the negative
control:

* the 2D viewer and the MPR always ask Metal: no preference, per-window flag or
  toggle leads to the original renderer any more (#728, #735);
* volume rendering has no engine to choose: no MAPPERMODEVR default, no board
  probe writing one, no engine list in Settings, the VR or the endoscopy
  toolbar, and the blended volume keeps its mapper;
* the planar Metal 4 pilot stays opt-in, as #609 measured and decided.
"""
from pathlib import Path
from xml.etree import ElementTree
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]


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
mpr = read('Horos/Sources/MPRHostBridge.m')
getter = body(mpr, '- (BOOL)horosMPRMetalEnabled')
if not getter or 'return YES;' not in getter:
    failures.append('the MPR does not always reconstruct with Metal')
for gone in ('toggleMPRMetal:', 'HorosMPRMetal"'):
    if gone in mpr:
        failures.append('the MPR still has a way back to the original renderer: %s' % gone)
viewer = body(read('Horos/Sources/PlanarHostBridge.m'), '- (BOOL)horosPlanarMetalEnabled')
if not viewer or 'return YES;' not in viewer:
    failures.append('the 2D viewer does not always draw with Metal')
if 'Original renderer (Metal paused)' in read('Horos/Sources/DCMView.m'):
    failures.append('the 2D view still announces the original renderer')

# --- no engine to choose ------------------------------------------------------
defaults = read('Horos/Sources/DefaultsOsiriX.m')
for key in ('MAPPERMODEVR', 'HorosMPRMetal"'):
    if key in defaults:
        failures.append('a default is still registered for %s' % key.strip('"'))
if 'HorosPlanarMetal4Pilot' in defaults:
    failures.append('the Metal 4 pilot is registered as a default; #609 decided it stays opt-in')
probe = body(read('Horos/Sources/VRView.mm'), '+ (void) testGraphicBoard')
if not probe:
    failures.append('the graphics board probe is gone')
elif 'MAPPERMODEVR' in probe:
    failures.append('the board probe still writes an engine')
blending = body(read('Horos/Sources/VRView.mm'), '- (void) setBlendingEngine: (long) engineID showWait:')
if 'case 2' not in blending or 'vtkGPUVolumeRayCastMapper' in read('Horos/Sources/VRView.mm'):
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
# EndoscopyViewer is Swift since #827.
for path in ('Horos/Sources/VRController.mm', 'Horos/Sources/EndoscopyViewer.swift'):
    if 'EngineToolbarItemIdentifier' in read(path):
        failures.append('%s still has an Engine toolbar item' % path)

# --- the pilot is still chosen by hand --------------------------------------
if 'UserDefaults.standard.bool(forKey: PlanarBackend.pilotDefaultsKey)' not in read('Horos/Sources/PlanarHostRenderer.swift'):
    failures.append('the planar backend no longer reads the pilot preference as an opt-in')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: Metal is the only renderer in the viewer, the MPR and volume rendering, and the pilot stays opt-in')
