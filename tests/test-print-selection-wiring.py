#!/usr/bin/env python3
"""#384 A print helper is in the app target; File > Print is not the outline view.

The database print is Swift since #831 (BrowserController+DatabaseDragExport+
Selection.swift), declared for the target without Swift in
BrowserController+DatabaseDragExport.h.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
source = root / 'Horos/Sources/PrintSelection.swift'
browser = source_text('BrowserController+DatabaseDragExport+Selection')
header = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.h').read_bytes().decode('latin1')
policy = source.read_text(encoding='utf-8')

if 'PrintSelection.swift' not in pbx:
    print('FAIL: PrintSelection.swift is not in the app target')
    sys.exit(1)
if 'PrintSelection.swift in Sources' not in pbx:
    print('FAIL: PrintSelection.swift is not in a Sources build phase')
    sys.exit(1)
if 'printDatabaseSelection' not in header:
    print('FAIL: BrowserController+DatabaseDragExport.h does not declare printDatabaseSelection')
    sys.exit(1)
if 'printDatabaseSelection' not in browser:
    print('FAIL: BrowserController+DatabaseDragExport+Selection.swift does not implement printDatabaseSelection')
    sys.exit(1)
if 'PrintSelection.job(from:' not in browser:
    print('FAIL: BrowserController must ask the Swift helper for the print job')
    sys.exit(1)
if 'mayPrintOutlineView' not in browser:
    print('FAIL: print: must refuse to print the outline view')
    sys.exit(1)
if 'implementsRegisteredGIF' in policy and 'return true' in policy.split('implementsRegisteredGIF')[1][:80]:
    print('FAIL: GIF package B must not be claimed here')
    sys.exit(1)
if '#378' not in policy:
    print('FAIL: GIF dependency on #378 must stay explicit')
    sys.exit(1)
print('PASS: #384 A helper is compiled in; browser print uses the selection, not the table')
