#!/usr/bin/env python3
"""The print helper is in the app target; File > Print is not the outline view.

The database print is Swift (BrowserController+DatabaseDragExport+
Selection.swift), exported to Objective-C under its selector.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
source = root / 'Horos/Sources/PrintSelection.swift'
browser = source_text('BrowserController+DatabaseDragExport+Selection')
policy = source.read_text(encoding='utf-8')

if 'PrintSelection.swift' not in pbx:
    print('FAIL: PrintSelection.swift is not in the app target')
    sys.exit(1)
if 'PrintSelection.swift in Sources' not in pbx:
    print('FAIL: PrintSelection.swift is not in a Sources build phase')
    sys.exit(1)
if '@objc(printDatabaseSelection:)' not in browser:
    print('FAIL: printDatabaseSelection: is not exported to Objective-C')
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
if 'longitudinal registration' not in policy:
    print('FAIL: GIF dependency on the longitudinal registration must stay explicit')
    sys.exit(1)
print('PASS: the print helper is compiled in; browser print uses the selection, not the table')
