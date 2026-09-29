#!/usr/bin/env python3
"""Workspace state keeps each flip axis apart and restores both (#598).

`+[ViewerController saveWindowsStateWithDICOMSR:name:]` used to write
`[view xFlipped]` under both keys, so a vertical flip never reached the saved
workspace, and the loader in `-[BrowserController databaseOpenStudy:]` never
read either key back. That loader is Swift since #831
(BrowserController+DatabaseDragExport.swift) and is read in its Swift spelling. The DICOM SR envelope archives the same property list
(`-[DicomStudy archiveWindowsStateAsDICOMSR]` reads `self.windowsState`), so
the producer is checked once and the archive path is checked to reuse it.
"""
import re
from pathlib import Path

from sources import source_text

root = Path(__file__).resolve().parents[1]
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
# The workspace loader in databaseOpenStudy: is Swift since #831.
browser = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.swift').read_text()
# DicomStudy is Swift since #721; the archive is read in its Swift spelling.
study = source_text('DicomStudy')

# Producer: one dictionary entry per axis, each read from its own property.
start = viewer.index('+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name')
producer = viewer[start:viewer.index('\n- (void) executeUndo:', start)]
writes = dict(re.findall(r'\[dict setObject: @\(\[view ([xy]Flipped)\]\) forKey:@"([xy]Flipped)"\];', producer))
assert writes == {'xFlipped': 'xFlipped', 'yFlipped': 'yFlipped'}, writes
assert 'forKey:@"windowsState"]' in producer and 'archiveWindowsStateAsDICOMSR' in producer

# Archive: the SR envelope wraps the very blob the producer stored.
archive = study[study.index('func archiveWindowsStateAsDICOMSR()'):]
archive = archive[:archive.index('\n    }\n')]
assert 'let windowsState = self.windowsState\n' in archive
assert 'SRAnnotation(windowsState: windowsState,' in archive

# Loader: each axis is applied from its own key, after the geometry, and an
# absent key (older workspaces) leaves the flip untouched.
start = browser.index('let rotation = objcFloatValue(objcValue(dict, "rotation"))')
loader = browser[start:browser.index('checkAllWindowsAreVisibleIsOff = false', start)]
for axis in 'xy':
    guard = 'if objcValue(dict, "%sFlipped") != nil {' % axis
    apply = 'v?.set%sFlipped(objcBoolValue(objcValue(dict, "%sFlipped")))' % (axis.upper(), axis)
    assert guard in loader, 'loader must guard the %s axis for older workspaces' % axis
    assert apply in loader, 'loader must restore the %s axis' % axis
    assert loader.index(guard) < loader.index(apply)
    assert loader.index('v?.setRotation(rotation)') < loader.index(apply)
print('workspace flip round trip: producer, archive and loader consistent')
