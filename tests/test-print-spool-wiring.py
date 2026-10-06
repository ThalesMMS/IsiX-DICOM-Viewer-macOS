#!/usr/bin/env python3
"""File > Print spools database pages without opening a viewer.

-printDatabaseSelection: is Swift (BrowserController+DatabaseDragExport+
Selection.swift); its declarations are in BrowserController+DatabaseDragExport.h.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
source = (root / 'Horos/Sources/PrintSelection.swift').read_text(encoding='utf-8')
browser = source_text('BrowserController+DatabaseDragExport+Selection')
header = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.h').read_bytes().decode('latin1')

start = browser.find('func printDatabaseSelection(_ sender: Any!)')
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
if 'PrintSelection.spool(' not in body:
    print('FAIL: printDatabaseSelection must call the Swift spooler')
    sys.exit(1)
if 'DCMPix' not in body:
    print('FAIL: database images must be rasterized with DCMPix, not a viewer')
    sys.exit(1)
if 'printOperationWithView' not in body and 'printDatabaseSpool' not in body:
    print('FAIL: spooled pages must reach NSPrintOperation')
    sys.exit(1)
if 'printDatabaseSpool' in body and 'printDatabaseSpool' not in header:
    print('FAIL: printDatabaseSpool must be declared')
    sys.exit(1)
if 'implementsRegisteredGIF' in source and 'return true' in source.split('implementsRegisteredGIF')[1][:80]:
    print('FAIL: GIF package B must not be claimed here')
    sys.exit(1)
print('PASS: database print spools raster/PDF pages without a viewer')
