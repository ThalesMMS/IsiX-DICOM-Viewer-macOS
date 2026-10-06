#!/usr/bin/env python3
"""Float volumes and ROI masks keep their indexes and bounds.

- -volumeDataForSliceAtIndex: negated the unsigned index, so each slice's
  translation was about 1.8e19; a slice past the volume pointed past its data.
- -initWithSortedIndexData: counted bytes, not indexes, and compared every
  index with indexes[1]; a run grew only from its first index.
- -convexHull kept maxDepth at NSIntegerMin: MAX compared it unsigned.
- -getFloatRun: asserted x + length < width, which a run ending at the last
  column fails, and Release copied past the volume.
- -getFloatData:floatCount: copied the whole data, whatever the count.
- -linearInterpolateVolumeVectors:… read N3Vector's CGFloats as floats.

Checked in the sources. `<git revision>` as an optional argument reads them
from that revision, the negative control. The fixed methods were exercised in
the running app over lldb.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, start):
    at = text.find(start)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []
volume = code(read('Horos/Sources/CPRVolumeData.swift'))
mask = code(read('Horos/Sources/OSIROIMask.swift'))
pixels = code(read('Horos/Sources/OSIROIFloatPixelData.swift'))

slice_ = block(volume, 'func volumeDataForSlice(at z: UInt)')
if '0 &- z' in slice_ or 'guard z < _pixelsDeep' not in slice_:
    failures.append('a slice is still translated by the negated unsigned index, or a slice past the volume is not refused')

sorted_ = block(mask, 'convenience init(sortedIndexData')
if 'MemoryLayout<OSIROIMaskIndex>.size' not in sorted_:
    failures.append('-initWithSortedIndexData: still counts bytes, not indexes')
if 'indexes![1]' in sorted_:
    failures.append('-initWithSortedIndexData: still compares every index with indexes[1]')
if 'NSMaxRange(maskRun.widthRange)' not in sorted_:
    failures.append('-initWithSortedIndexData: runs do not grow from their end')

hull = block(mask, 'func convexHull()')
if 'UInt(bitPattern: maxDepth)' in hull or not re.search(r'maxDepth = macroMax\(maxDepth,', hull):
    failures.append('-convexHull still compares maxDepth unsigned')

run = block(volume, 'public func getFloatRun(')
if 'x &+ length < _pixelsWide' in run or 'length <= _pixelsWide &- x' not in run:
    failures.append('-getFloatRun: refuses the last column or reads past the volume')

data = block(pixels, 'public func getFloatData(')
if re.search(r'getBytes\(buffer, length: floatData\?\.length', data):
    failures.append('-getFloatData:floatCount: still copies the whole data')

interpolate = block(volume, 'public func linearInterpolateVolumeVectors(')
if 'assumingMemoryBound(to: Float.self)' in interpolate.split('outputValues[')[0] or \
        'CPRVolumeDataLinearInterpolatedFloatAtVolumeCoordinateForSwift' not in interpolate:
    failures.append('-linearInterpolateVolumeVectors:… still reads N3Vectors as floats')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: slices, mask indexes, hull depth, float runs, float copies and interpolation stay in bounds')
