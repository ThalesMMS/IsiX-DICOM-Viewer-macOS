#!/usr/bin/env python3
"""The windows state of a viewer on a raster series saves without a DICOM series UID.

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
viewer = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
restore = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.swift').read_text()

failures = []
if '+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name' in viewer:
    start = viewer.index('+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name')
    body = viewer[start:viewer.index('\n}\n', start)]
    unguarded = re.findall(r'\[dict setObject: \[[^\]]*valueForKey:@"seriesDICOMUID"\] forKey:@"seriesDICOMUID"\]', body)
    guarded = re.search(r'NSString \*seriesDICOMUID = \[win\.currentSeries valueForKey:@"seriesDICOMUID"\];\s*'
                        r'if\( seriesDICOMUID\)\s*\[dict setObject: seriesDICOMUID forKey:@"seriesDICOMUID"\];', body)
    all_windows = 'if( [displayedViewers count] != [state count]) return;' in body
else:
    # The save is Swift since ViewerController+WindowsState.swift.
    swift = (root / 'Horos/Sources/ViewerController+WindowsState.swift').read_text()
    start = swift.index('    class func saveWindowsState(withDICOMSR DICOMSR: Bool, name: String?) {')
    body = swift[start:swift.index('\n    }\n', start)]
    unguarded = re.findall(r'dict\.setObject\([^)]*value\(forKey: "seriesDICOMUID"\)[^)]*\)', body)
    guarded = re.search(r'if let seriesDICOMUID = \(win\.currentSeries\(\) as NSObject\?\)\?\.value\(forKey: "seriesDICOMUID"\) \{\s*'
                        r'dict\.setObject\(seriesDICOMUID, forKey: "seriesDICOMUID" as NSString\)', body)
    all_windows = 'if displayedViewers.count != state.count { return }' in body
if unguarded:
    failures.append('seriesDICOMUID is stored without checking it exists')
if not guarded:
    failures.append('the guarded seriesDICOMUID store is missing')
if not all_windows:
    failures.append('the all-windows rule changed')
if '(seriesDICOMUID?.length ?? 0) > 0' not in restore:
    failures.append('the restore no longer tolerates an absent seriesDICOMUID')
if failures:
    print('FAIL: ' + '; '.join(failures))
    sys.exit(1)
print('PASS: seriesDICOMUID is stored only when the series has one; the restore finds the series by '
      'seriesInstanceUID and skips an absent seriesDICOMUID')
