#!/usr/bin/env python3
"""File > Print spools database pages without opening a viewer.

-printDatabaseSelection: and -printDatabaseSpool: are the browser's selectors
(BrowserController+DatabaseDragExport+Selection.swift); the work is
PrintSelection's (PrintSelection+DatabaseSelection.swift).
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
source = (root / 'Horos/Sources/PrintSelection.swift').read_text(encoding='utf-8')
facade = source_text('BrowserController+DatabaseDragExport+Selection')
browser = source_text('PrintSelection+DatabaseSelection')
if 'PrintSelection.printSelection(of: self' not in facade:
    print('FAIL: printDatabaseSelection: does not hand the print to PrintSelection')
    sys.exit(1)

start = browser.find('static func printSelection(of browser: BrowserController, sender: Any?)')
if start < 0:
    print('FAIL: printDatabaseSelection is missing')
    sys.exit(1)
brace = browser.find('{', start)
depth, index = 0, brace
while index < len(browser):
    if browser[index] == '{':
        depth += 1
    elif browser[index] == '}':
        depth -= 1
        if depth == 0:
            body = browser[brace:index + 1]
            break
    index += 1
else:
    print('FAIL: printDatabaseSelection has no body')
    sys.exit(1)

if 'requiresViewerToSpool' not in source or 'return true' in source.split('requiresViewerToSpool')[1][:80]:
    print('FAIL: database print must not require a viewer')
    sys.exit(1)
if 'Open a viewer to spool' in body:
    print('FAIL: printDatabaseSelection still asks the user to open a viewer')
    sys.exit(1)
if 'spool(job, directory:' not in body:
    print('FAIL: printDatabaseSelection must call the Swift spooler')
    sys.exit(1)
if 'DCMPix' not in browser or 'raster(of:' not in body:
    print('FAIL: database images must be rasterized with DCMPix, not a viewer')
    sys.exit(1)
if 'printOperationWithView' not in body and 'printDatabaseSpool' not in body:
    print('FAIL: spooled pages must reach NSPrintOperation')
    sys.exit(1)
if 'printDatabaseSpool' in body and ('@objc(printDatabaseSpool:)' not in facade or 'PrintSelection.printSpool(' not in facade):
    print('FAIL: printDatabaseSpool must be exported')
    sys.exit(1)
if 'implementsRegisteredGIF' in source and 'return true' in source.split('implementsRegisteredGIF')[1][:80]:
    print('FAIL: GIF package B must not be claimed here')
    sys.exit(1)
print('PASS: database print spools raster/PDF pages without a viewer')
