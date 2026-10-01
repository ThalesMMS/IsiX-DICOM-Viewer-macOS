#!/usr/bin/env python3
"""The windows state of a viewer on a raster series saves without a DICOM series UID (#1020).

A series imported from a TIFF or JPEG file has no DICOM Series Instance UID, so
seriesDICOMUID is nil. +[ViewerController saveWindowsStateWithDICOMSR:name:] put
it in the state dictionary unconditionally; the exception left every window
unsaved. The key is written only when present, and the restore
(-[BrowserController databaseOpenStudy:]) already looks a series up by
seriesInstanceUID first and uses seriesDICOMUID only when it is not empty.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
viewer = (root / 'Horos/Sources/ViewerController.m').read_text()
start = viewer.index('+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name')
body = viewer[start:viewer.index('\n}\n', start)]
restore = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.swift').read_text()

failures = []
unguarded = re.findall(r'\[dict setObject: \[[^\]]*valueForKey:@"seriesDICOMUID"\] forKey:@"seriesDICOMUID"\]', body)
if unguarded:
    failures.append('seriesDICOMUID is stored without checking it exists')
guarded = re.search(r'NSString \*seriesDICOMUID = \[win\.currentSeries valueForKey:@"seriesDICOMUID"\];\s*'
                    r'if\( seriesDICOMUID\)\s*\[dict setObject: seriesDICOMUID forKey:@"seriesDICOMUID"\];', body)
if not guarded:
    failures.append('the guarded seriesDICOMUID store is missing')
if 'if( [displayedViewers count] != [state count]) return;' not in body:
    failures.append('the all-windows rule changed')
if '(seriesDICOMUID?.length ?? 0) > 0' not in restore:
    failures.append('the restore no longer tolerates an absent seriesDICOMUID')
if failures:
    print('FAIL: ' + '; '.join(failures))
    sys.exit(1)
print('PASS: seriesDICOMUID is stored only when the series has one; the restore finds the series by '
      'seriesInstanceUID and skips an absent seriesDICOMUID')
