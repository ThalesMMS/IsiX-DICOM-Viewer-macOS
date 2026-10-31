#!/usr/bin/env python3
"""The print helper is in the app target; File > Print is not the outline view.

The database print's selector is the browser's
(BrowserController+DatabaseDragExport+Selection.swift), exported to
Objective-C; its work is PrintSelection's (PrintSelection+DatabaseSelection.swift).
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
source = root / 'Horos/Sources/PrintSelection.swift'
facade = source_text('BrowserController+DatabaseDragExport+Selection')
browser = source_text('PrintSelection+DatabaseSelection')
policy = source.read_text(encoding='utf-8')

if 'PrintSelection.swift' not in pbx:
    print('FAIL: PrintSelection.swift is not in the app target')
    sys.exit(1)
if 'PrintSelection.swift in Sources' not in pbx:
    print('FAIL: PrintSelection.swift is not in a Sources build phase')
    sys.exit(1)
if 'PrintSelection+DatabaseSelection.swift in Sources' not in pbx:
    print('FAIL: PrintSelection+DatabaseSelection.swift is not in a Sources build phase')
    sys.exit(1)
if '@objc(printDatabaseSelection:)' not in facade:
    print('FAIL: printDatabaseSelection: is not exported to Objective-C')
    sys.exit(1)
if 'PrintSelection.printSelection(of: self' not in facade or 'static func printSelection(of browser: BrowserController' not in browser:
    print('FAIL: printDatabaseSelection: does not hand the print to PrintSelection')
    sys.exit(1)
if 'job(from: records(of:' not in browser:
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
