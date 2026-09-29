#!/usr/bin/env python3
"""CPR load-path accepts a patient-space xyz file without replacing Curved MPR."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text
# CPRController is Swift since #825: its public interface is the Swift class.
controller = source_text('CPRController')
header = controller
swift = (root / 'Horos/Sources/CPRCenterlineImport.swift').read_text()
path_session = (root / 'Horos/Sources/CurvedMPRPath.swift').read_text()
needed = [
    'importPatientSpaceCenterlineFromFile',
    'CPRCenterlineImport.importPatientSpaceText(',
    'importPatientSpaceText',
    'addPatientNode',
    'curvedPathCreationMode = false',
]
missing = [item for item in needed if item not in controller]
if missing:
    print('FAIL: CPRController is missing', ', '.join(missing), file=sys.stderr)
    sys.exit(1)
if '@objc(importPatientSpaceCenterlineFromFile:)\n    public dynamic func' not in header:
    print('FAIL: CPRController.h does not declare the patient-space import', file=sys.stderr)
    sys.exit(1)
load = controller[controller.index('func loadBezierPathFromFile('):
                  controller.index('func loadBezierPathFromFile(') + 1800]
if 'importPatientSpaceCenterline(fromFile: path)' not in load:
    print('FAIL: loadBezierPathFromFile does not fall through to xyz import', file=sys.stderr)
    sys.exit(1)
# Decoded with secure coding as a CPRCurvedPath since #818; the class used to
# be checked after decoding.
if 'unarchivedObject(ofClass: CPRCurvedPath.self' not in load:
    print('FAIL: archive load must still require a CPRCurvedPath', file=sys.stderr)
    sys.exit(1)
open_panel = controller[controller.index('func loadBezierPath('):
                        controller.index('func loadBezierPath(') + 800]
for ext in ('curvedPath', 'txt', 'xyz', 'csv'):
    if ext not in open_panel:
        print('FAIL: loadBezierPath panel is missing', ext, file=sys.stderr)
        sys.exit(1)
if 'selectCurvedPathDrawingTool' not in controller:
    print('FAIL: patient-space import must not remove the Curved MPR tool selection', file=sys.stderr)
    sys.exit(1)
if 'CurvedMPRPathSession' not in swift or 'addPatientNodeX' not in swift:
    print('FAIL: import must reuse the interactive path session', file=sys.stderr)
    sys.exit(1)
if 'origin in patient space is a drawable node' not in path_session and 'Origin is valid' not in path_session:
    if 'NaN is not' not in path_session:
        print('FAIL: CurvedMPRPath.swift contract was rewritten', file=sys.stderr)
        sys.exit(1)
print('PASS: xyz import is wired through loadBezierPath; Curved MPR session remains')
