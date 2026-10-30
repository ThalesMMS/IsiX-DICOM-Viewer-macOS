#!/usr/bin/env python3
"""The point-based registration gives the matrix the VTK one gave.

HornRegistration (ViewerController+Registration.swift registers a series onto
another by pairs of 3D points) computed its matrix with vtkLandmarkTransform in
its similarity mode. It is Swift now, over PointSetRegistration (IsiXImaging),
which ports that arithmetic.

The former HornRegistration.mm and its header, read from the history, are
built against the VTK of the Debug build (exit 2 without that build or that
history) in a driver that registers point sets; the Swift class, built with its
module, registers the same sets in a second driver. Each prints the twelve
values -computeVTK: writes (the rotation row by row, then the translation),
and the two must agree within 1e-9, relative to the size of the values: the
compilers contract multiplications and additions differently. The sets cover
one to seven points, rotations with scaling and shifts, collinear and
coincident points, a reflection, and unequal or empty sets (nothing written).
"""
import math
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT  # noqa: E402
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

VTK = BUILD / 'VTK.build/Install'
if not (VTK / 'include/vtkLandmarkTransform.h').exists() or not (VTK / 'wlib/libVTK.a').exists():
    print('skipped: needs the VTK of a Debug build from script/build_and_run.sh --verify')
    raise SystemExit(2)
FORMER = history_reference.before_removal('Horos/Sources/HornRegistration.mm')
if FORMER is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:Horos/Sources/HornRegistration.mm'],
                                     capture_output=True).returncode == 0:
    FORMER = 'HEAD'
if FORMER is None:
    print('skipped: the history does not reach HornRegistration.mm')
    raise SystemExit(2)


def rotation(ax, ay, az):
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    return [[cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz],
            [cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz],
            [-sy, sx * cy, cx * cy]]


def moved(points, matrix, scale, shift, noise, rng):
    return [[scale * sum(matrix[r][c] * p[c] for c in range(3)) + shift[r] + rng.uniform(-noise, noise)
             for r in range(3)] for p in points]


rng = random.Random(1492)
CASES = []
for count in range(1, 8):
    model = [[rng.uniform(-120, 120) for _ in range(3)] for _ in range(count)]
    matrix = rotation(rng.uniform(-3, 3), rng.uniform(-1.5, 1.5), rng.uniform(-3, 3))
    CASES.append((model, moved(model, matrix, rng.uniform(0.5, 2), [rng.uniform(-50, 50) for _ in range(3)], 0.5, rng)))
line = [[t, 2 * t, -t] for t in (0.0, 10.0, 25.0, 40.0)]
CASES.append((line, moved(line, rotation(0.3, 0.2, 0.1), 1.0, [5, 6, 7], 0.0, rng)))
CASES.append(([[1.0, 2.0, 3.0]] * 4, [[4.0, 5.0, 6.0]] * 4))
square = [[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [10.0, 10.0, 0.0], [0.0, 10.0, 0.0]]
CASES.append((square, [[5.0, 0.0, 0.0], [5.0, 10.0, 0.0], [5.0, 10.0, 11.0], [5.0, 0.0, 10.0]]))
CASES.append((square, [[-x, y, z] for x, y, z in square]))
CASES.append((square, square[:3]))
CASES.append(([], []))


def literal(points):
    return '{' + ', '.join('{%r, %r, %r}' % tuple(p) for p in points) + '}' if points else '{}'


def objc_cases():
    lines = []
    for index, (model, sensor) in enumerate(CASES):
        lines.append('    {')
        lines.append('        HornRegistration *horn = [[HornRegistration alloc] init];')
        for p in model:
            lines.append('        [horn addModelPointX:%r Y:%r Z:%r];' % tuple(p))
        for p in sensor:
            lines.append('        [horn addSensorPointX:%r Y:%r Z:%r];' % tuple(p))
        lines.append('        report(horn);')
        lines.append('        [horn release];')
        lines.append('    }')
    return '\n'.join(lines)


def swift_cases():
    lines = []
    for model, sensor in CASES:
        lines.append('do {')
        lines.append('    let horn = HornRegistration()')
        for p in model:
            lines.append('    horn.addModelPointX(%r, y: %r, z: %r)' % tuple(p))
        for p in sensor:
            lines.append('    horn.addSensorPointX(%r, y: %r, z: %r)' % tuple(p))
        lines.append('    report(horn)')
        lines.append('}')
    return '\n'.join(lines)


FORMER_DRIVER = '''
#import <Foundation/Foundation.h>
#import "HornRegistration.h"
#include <math.h>
#include <stdio.h>
static void report(HornRegistration *horn)
{
    double values[12];
    for (int i = 0; i < 12; i++) values[i] = NAN;
    printf("%d", [horn numberOfPoint]);
    [horn computeVTK:values];
    for (int i = 0; i < 12; i++) printf(" %.17g", values[i]);
    printf("\\n");
}
int main(void) { @autoreleasepool {
CASES
} return 0; }
'''.replace('CASES', objc_cases())

SWIFT_DRIVER = '''
import Foundation
func report(_ horn: HornRegistration) {
    var values = [Double](repeating: .nan, count: 12)
    var text = "\\(horn.numberOfPoint())"
    values.withUnsafeMutableBufferPointer { horn.computeVTK($0.baseAddress) }
    for value in values { text += " " + String(format: "%.17g", value) }
    print(text)
}
CASES
'''.replace('CASES', swift_cases())


def run(command):
    done = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if done.returncode:
        print('FAIL: %s\n%s' % (' '.join(map(str, command[:3])), (done.stderr or done.stdout)[-4000:]))
        raise SystemExit(1)
    return done.stdout


with tempfile.TemporaryDirectory(prefix='isix-horn-') as folder:
    work = Path(folder)
    (work / 'HornRegistration.h').write_bytes(history_reference.show(FORMER, 'Horos/Sources/HornRegistration.h'))
    (work / 'HornRegistration.mm').write_bytes(history_reference.show(FORMER, 'Horos/Sources/HornRegistration.mm'))
    (work / 'former.mm').write_text(FORMER_DRIVER)
    run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', str(work / 'former.mm'), str(work / 'HornRegistration.mm'),
         '-I' + str(work), '-I' + str(VTK / 'include'), str(VTK / 'wlib/libVTK.a'), '-framework', 'Cocoa',
         '-o', str(work / 'former')])
    (work / 'main.swift').write_text(SWIFT_DRIVER)
    run(['xcrun', 'swiftc', '-swift-version', '6', str(ROOT / 'Horos/Sources/HornRegistration.swift'), str(work / 'main.swift'),
         *isix_modules.module_flags('IsiXImaging', work / 'modules'), '-o', str(work / 'current')])
    former = run([str(work / 'former')]).split('\n')
    current = run([str(work / 'current')]).split('\n')

failures = 0
compared = 0
for index, (a, b) in enumerate(zip(former, current)):
    if not a and not b:
        continue
    left, right = a.split(), b.split()
    if left[0] != right[0]:
        print('FAIL: case %d counts %s pairs, the former %s' % (index, right[0], left[0]))
        failures += 1
        continue
    x, y = [float(v) for v in left[1:]], [float(v) for v in right[1:]]
    scale = max([1.0] + [abs(v) for v in x if not math.isnan(v)])
    for i, (u, v) in enumerate(zip(x, y)):
        if math.isnan(u) or math.isnan(v):
            same = math.isnan(u) and math.isnan(v)
        else:
            same = abs(u - v) <= 1e-9 * scale
        if not same:
            print('FAIL: case %d value %d is %r, the former %r' % (index, i, v, u))
            failures += 1
    compared += 1
if len(former) != len(current):
    print('FAIL: %d results, the former %d' % (len(current), len(former)))
    failures += 1
if failures:
    raise SystemExit(1)
print('PASS: %d point sets register to the matrix of the former vtkLandmarkTransform (%s)' % (compared, FORMER[:12]))
