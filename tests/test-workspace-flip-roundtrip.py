#!/usr/bin/env python3
"""Workspace state keeps each flip axis apart and restores both.

`+[ViewerController saveWindowsStateWithDICOMSR:name:]` used to write
`[view xFlipped]` under both keys, so a vertical flip never reached the saved
workspace, and the loader in `-[BrowserController databaseOpenStudy:]` never
read either key back. That loader is Swift
(the browser's ViewerOpener, ViewerOpener.swift) and is read in its Swift spelling. The DICOM SR envelope archives the same property list
(`-[DicomStudy archiveWindowsStateAsDICOMSR]` reads `self.windowsState`), so
the producer is checked once and the archive path is checked to reuse it.
"""
import re
from pathlib import Path

from sources import source_text

root = Path(__file__).resolve().parents[1]
viewer = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
# The workspace loader of databaseOpenStudy: is the browser's ViewerOpener's.
browser = (root / 'Horos/Sources/ViewerOpener.swift').read_text()
# DicomStudy is Swift; the archive is read in its Swift spelling.
study = source_text('DicomStudy')

# Producer: one dictionary entry per axis, each read from its own property.
if '+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name' in viewer:
    start = viewer.index('+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name')
    producer = viewer[start:viewer.index('\n- (void) executeUndo:', start)]
    writes = dict(re.findall(r'\[dict setObject: @\(\[view ([xy]Flipped)\]\) forKey:@"([xy]Flipped)"\];', producer))
    stored = 'forKey:@"windowsState"]' in producer
else:
    # The producer is Swift: the viewer's ViewerWorkspaceArchiver writes one
    # ViewerWorkspaceEntry per viewer, whose keys are the dictionary's.
    swift = (root / 'Horos/Sources/ViewerWorkspaceArchiver.swift').read_text()
    start = swift.index('    func save(asDICOMSR: Bool, name: String?) {')
    producer = swift[start:swift.index('\n    /// The former @catch', start)]
    writes = dict(re.findall(r'\b([xy]Flipped): view\.([xy]Flipped)\b', producer))
    stored = 'study.windowsState = ' in producer
    entry = (root / 'Modules/IsiXImaging/Sources/ViewerWorkspace/ViewerWorkspaceEntry.swift').read_text()
    keys = entry[entry.index('    enum CodingKeys: String, CodingKey {'):]
    keys = keys[:keys.index('\n    }\n')]
    # Each axis is its own member and keeps its own key.
    assert re.search(r'\bxFlipped, yFlipped\b', keys) and 'xFlipped =' not in keys and 'yFlipped =' not in keys, keys
assert writes == {'xFlipped': 'xFlipped', 'yFlipped': 'yFlipped'}, writes
# The archive is -archiveWindowsStateAsDICOMSR, or the Swift member it calls.
archiver = next((name for name in ('writeWindowsStateAsDICOMSR', 'archiveWindowsStateAsDICOMSR') if name in producer), None)
assert stored and archiver, producer

# Archive: the SR envelope wraps the very blob the producer stored.
archive = study[study.index('func %s()' % archiver):]
archive = archive[:archive.index('\n    }\n')]
assert 'SRAnnotation(windowsState: self.windowsState,' in archive or (
    'let windowsState = self.windowsState\n' in archive and 'SRAnnotation(windowsState: windowsState,' in archive), archive

# Loader: each axis is applied from its own key, after the geometry, and an
# absent key (older workspaces) leaves the flip untouched.
start = browser.index('let rotation = plistFloat(dict["rotation"])')
loader = browser[start:browser.index('checkAllWindowsAreVisibleIsOff = false', start)]
for axis in 'xy':
    guard = 'if dict["%sFlipped"] != nil {' % axis
    apply = 'v?.set%sFlipped(plistBool(dict["%sFlipped"]))' % (axis.upper(), axis)
    assert guard in loader, 'loader must guard the %s axis for older workspaces' % axis
    assert apply in loader, 'loader must restore the %s axis' % axis
    assert loader.index(guard) < loader.index(apply)
    assert loader.index('v?.setRotation(rotation)') < loader.index(apply)
print('workspace flip round trip: producer, archive and loader consistent')
