#!/usr/bin/env python3
"""The ROIs read for each slice are reversed with the slices of a descending stack.

A viewer that opens a series whose slices go the other way reverses its
lists once the images are loaded: the images, their files and their ROIs. A
save then compares, slice by slice, the ROIs of the slice with the ROIs that
were read for it, and writes the slices that changed. The list of what was
read has a slice each too: left as it was, each slice was compared with what
was read for the slice that took its place, and an image whose ROIs had all
been deleted was found unchanged, so its ROIs came back when the series was
opened again.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/ViewerController+SliceInterval.swift').read_text()
start = source.index('    private func reverseSeries(sliceInterval interval: Double) {')
body = source[start:source.index('\n    }\n', start)]

failures = []
reversed_lists = re.search(r'for list in \[([^\]]*)\] \{\s*guard let list else \{ continue \}\s*'
                           r'for i in 0\.\.<min\(count, list\.count\) / 2 \{\s*'
                           r'list\.exchangeObject\(at: i, withObjectAt: list\.count - i - 1\)', body)
if not reversed_lists:
    failures.append('the reversal of the lists of the slices was not found in reverseSeries')
else:
    lists = [name.strip() for name in reversed_lists.group(1).split(',')]
    for needed in ('pixList', 'horos_fileList(at: x)', 'horos_roiList(at: x)', 'horos_copyRoiList(at: x)'):
        if needed not in lists:
            failures.append(f'{needed} is not reversed with the slices: {lists}')

# What the save compares: the ROIs of slice i with the copy read for slice i.
archives = (root / 'Horos/Sources/ViewerController+ROI.swift').read_text()
if 'let loaded = i < snapshot.copyRoiList.count ? snapshot.copyRoiList[i] : Data()' not in archives \
        or 'snapshot.roiList[i]' not in archives:
    failures.append('the save no longer compares the ROIs of a slice with the copy at the same index: review this test')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the ROIs read for each slice are reversed with the images, files and ROIs of a descending stack')
