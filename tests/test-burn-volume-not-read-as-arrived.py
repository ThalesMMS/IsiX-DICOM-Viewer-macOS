#!/usr/bin/env python3
"""The volume a medium was just written to is not read as a disc that arrived.

The copy to a USB volume ends by renaming the volume, with the studies on it.
The list of sources read every renamed volume as it reads a mounted one, so
with the setting that asks about each disc the question came for the medium the
application had just written and ejected, and with that question up the burn
window did not close.

Which volumes are being written is VolumesBeingWritten of IsiXDatabase, held by
its module test. This test holds its use by the list and by the burn window.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

sources = source_text('SourceList')
burner = source_text('BurnerWindowController')
failures = []

change = sources[sources.index('private func volumeDidChange('):sources.index('func beginWriting(volumeAtPath')]
if 'writtenVolumes.renamed(from: oldPath, to: path)' not in change:
    failures.append('a volume being written is not followed through its rename')
elif change.index('writtenVolumes.renamed(') > change.index('guard SourceListRules.listsMountedVolumes'):
    failures.append('a volume being written is followed only when mounted volumes are listed')
if 'writtenVolumes.unmounted(path)' not in change:
    failures.append('an unmounted volume stays one being written')
if not re.search(r'if renamed, let path, !written \{ analyzeVolume\(atPath: path\) \}', change):
    failures.append('a renamed volume being written is read as a disc that arrived')
if not re.search(r'didMountNotification, let path, !written \{ analyzeVolume\(atPath: path\) \}', change):
    failures.append('a mounted volume being written is read as a disc that arrived')
analyzed = sources[sources.index('private func volumeAnalyzed('):sources.index('private func addVolume(')]
if '!writtenVolumes.contains(path)' not in analyzed:
    failures.append('a volume whose reading was pending when its writing began is listed')
begin = sources[sources.index('func beginWriting(volumeAtPath'):sources.index('func endWritingVolumes()')]
for call in ('writtenVolumes.begin(path)', 'volumeDiscovery.cancelPath(path)', 'removeVolume(atDevicePath: path)'):
    if call not in begin:
        failures.append('the beginning of a writing no longer does %s' % call)

burn = burner[burner.index('public func burn(_ sender: Any?)'):burner.index('private func burnJob(')]
if 'sourceList.beginWriting(volumeAtPath: volumePath)' not in burn:
    failures.append('a burn to a volume does not say that the volume is being written')
elif burn.index('sourceList.beginWriting(volumeAtPath: volumePath)') > burn.index('Thread(target: self, selector: #selector(self.performBurn'):
    failures.append('the volume is said to be written after the burn thread started')
ended = burner[burner.index('let result = (failed: failed, failure: burnFailure)'):burner.index('public func setAnonymizedCheck(')]
if 'sourceList.endWritingVolumes()' not in ended:
    failures.append('the end of a burn does not let the volume go')
closing = burner[burner.index('public func windowWillClose('):burner.index('public func windowShouldClose(')]
if 'sourceList.endWritingVolumes()' not in closing:
    failures.append('closing the burn window does not let the volume go')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: a volume being written is followed through its renames and not read as a disc that arrived, '
      'and the burn window says when the writing begins and ends')
