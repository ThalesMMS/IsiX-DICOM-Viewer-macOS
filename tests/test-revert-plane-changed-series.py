#!/usr/bin/env python3
"""Revert Series reads a series again when its only post-processing is a change of plane.

A change of plane of the 2D viewer makes its new slices of the volume as it
is: a cut or a filter a 3D window made before the change is in them, and
Revert Series refused the resliced series as post processed, so nothing took
the cut back. The viewer now remembers the slices a change of plane made of
slices read from their files (or of an earlier such change), and Revert Series
of them reads the series from its files again and changes the plane again.
Any other post-processed series, and a 4D one, is refused as before.

The wiring is read in the sources: the change of plane and the reading of a
series need the viewer, its window and the database.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def method(source, signature):
    start = source.find(signature)
    if start < 0:
        return ''
    end = source.find('\n    }\n', start)
    return source[start:end]


failures = []
orientation = read('Horos/Sources/ViewerController+Orientation.swift')
change = method(orientation, '    func change(to newOrientationTool: Int32) -> Bool {')
before = change.find('let ofFiles = !wasPostprocessed || viewer.geometryState.planeChangedSeries === viewer.horos_pixList(at: 0)')
reslice = change.find('succeed = viewer.reorient(change, newViewer: newViewer)')
failed = change.find('if !succeed {')
recorded = change.find('viewer.geometryState.planeChangedSeries = ofFiles ? viewer.horos_pixList(at: 0) : nil')
if not (-1 < before < reslice < failed < recorded):
    failures.append('a change of plane of slices read from their files, or of an earlier such change, is remembered once it is made, '
                    'by the slices the viewer then shows')
if 'planeChangedSeries' in change[failed:change.find('return succeed', failed)]:
    failures.append('a change of plane that could not be made leaves what the viewer remembered')
if not re.search(r'weak var planeChangedSeries: AnyObject\?', read('Horos/Sources/ViewerController+GeometryState.swift')):
    failures.append('the viewer does not keep alive the slices it remembers')

revert = method(orientation, '    func revertToFiles() -> Bool {')
guard = revert[:revert.find('else { return false }')]
for needed, what in (('viewer.horos_movieCount == 1', 'one time'),
                     ('viewer.geometryState.planeChangedSeries === shown', 'the slices the change of plane made'),
                     ('as? DicomImage)?.series, !series.isDeleted', 'a series still in the database')):
    if needed not in guard:
        failures.append('Revert Series of a change of plane: only for ' + what)
order = [revert.find(part) for part in (
    'let plane = Int32(viewer.horos_currentOrientationTool)',
    'viewer.horos_imageView?.getWLWW(&level, &width)',
    'viewer.horosSeriesLoad.keepingPreviousSeriesForOtherWindows {',
    '.load(series, into: viewer, keyImagesOnly: false)',
    'viewer.checkEverythingLoaded()',
    'if viewer.horos_pixList(at: 0) === shown { return false }',
    '_ = change(to: plane)',
    'viewer.horos_imageView?.setWLWW(level, width)')]
if -1 in order or order != sorted(order):
    failures.append('Revert Series of a change of plane: the series read from its files again, the other windows keeping the resliced '
                    'volume, then the plane and the window level it had')

navigation = read('Horos/Sources/ViewerController+StudyNavigation.swift')
unless = method(navigation, '    func revertUnlessPostprocessed() {')
if not re.search(r'if viewer\.horos_postprocessed \{\s*if ViewerPlaneChange\(viewer: viewer\)\.revertToFiles\(\) \{ return \}\s*'
                 r'HorosAlertPanel\.run\(title: NSLocalizedString\("Revert"', unless):
    failures.append('Revert Series of a post-processed series: the change of plane is reverted, any other is refused with its alert')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: Revert Series reads again a series whose only post-processing is a change of plane, and refuses the others')
