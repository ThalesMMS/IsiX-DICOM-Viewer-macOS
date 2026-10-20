#!/usr/bin/env python3
"""The irregular slice interval warning measures along the normal, with a tolerance.

A step-and-shoot head CT with a -3.5 degree gantry tilt (8 acquisitions of 16
slices of 1.25 mm, the table moved 20 mm per acquisition) warned "varying from
1.215 mm to 1.252 mm": the steps were straight distances between origins, and
any two consecutive ones 0.01 mm apart raised it. Along the slice normal the
slices are 1.2500 mm apart, 1.2127 mm at the 7 boundaries, and no slice is more
than 0.031 mm from a uniform grid - a tenth of a pixel.

HorosSliceIntervalRegularity is compiled and run on synthetic positions only:
that stack does not warn and reports 1.2127/1.2500; a regular stack and a
0.625 mm stack written with two decimals do not warn; a missing slice and a mix
of 1.25 and 2.5 mm do. ViewerController's warning is checked to use it.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

DRIVER = r'''
import Foundation
func run(_ name: String, _ origins: [Double], _ normal: [Double], _ spacing: Double) {
    let r = SliceIntervalRegularity.regularity(origins: origins, normal: normal, pixelSpacing: spacing)
    print("\(name)\t\(r.isIrregular ? "warn" : "ok") \(String(format: "%.4f %.4f %.4f", r.minimumInterval, r.maximumInterval, r.largestGridDeviation))")
}
// The CT: x, y fixed; z steps 1.25/cos(3.5 deg) inside an acquisition, 20 mm per acquisition.
let tilt = 3.497 * Double.pi / 180
let normal = [0, sin(tilt), cos(tilt)]
var tilted: [Double] = []
for a in 0..<8 { for s in 0..<16 { tilted += [-120.0, -98.0, 5.3379 + 20.0 * Double(a) + Double(s) * 1.25 / cos(tilt)] } }
run("tilted", tilted.map { ($0 * 10000).rounded() / 10000 }, normal, 0.431)
var regular: [Double] = []
for i in 0..<100 { regular += [0, 0, -Double(i) * 1.25] }
run("regular", regular, [0, 0, 1], 0.7)
var rounded: [Double] = []
for i in 0..<200 { rounded += [0, 0, (Double(i) * 0.625 * 100).rounded() / 100] }
run("rounded", rounded, [0, 0, 1], 0.5)
var missing: [Double] = []
for i in 0..<60 where i != 30 { missing += [0, 0, Double(i) * 1.25] }
run("missing", missing, [0, 0, 1], 0.7)
var mixed: [Double] = []
var z = 0.0
for i in 0..<60 { mixed += [0, 0, z]; z += i < 30 ? 1.25 : 2.5 }
run("mixed", mixed, [0, 0, 1], 0.7)
run("single", [0, 0, 0], [0, 0, 1], 0.7)
'''

with tempfile.TemporaryDirectory(prefix='horos-interval-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/SliceIntervalRegularity.swift'), str(work / 'main.swift'),
                            '-o', str(work / 'interval')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the regularity check does not compile:\n' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(work / 'interval')], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t') for line in run.stdout.splitlines() if '\t' in line)
        expected_state = {'tilted': 'ok', 'regular': 'ok', 'rounded': 'ok', 'missing': 'warn', 'mixed': 'warn', 'single': 'ok'}
        for key, state in expected_state.items():
            if not results.get(key, '').startswith(state):
                failures.append('%s: expected %s, got %r' % (key, state, results.get(key)))
        values = results.get('tilted', '').split()
        if len(values) < 4 or abs(float(values[1]) - 1.2127) > 0.0003 or abs(float(values[2]) - 1.2500) > 0.0003:
            failures.append('the tilted stack reports %r instead of the intervals along the normal' % values[1:3])
        elif not float(values[3]) < 0.035:
            failures.append('the tilted stack is %s mm off its grid' % values[3])

viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
at = viewer.index('- (void) displayAWarningIfNonTrueVolumicData')
body = viewer[at:viewer.index('\n- (', at + 10)]
if 'HorosSliceIntervalRegularity regularityOfOrigins:' not in body:
    failures.append('the warning does not use the regularity check')
if '* 100.' in body:
    failures.append('the warning still compares intervals to 0.01 mm')
if 'minimumInterval' not in body or 'maximumInterval' not in body:
    failures.append('the warning does not report the intervals along the normal')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the slice interval warning measures along the normal with a relative and a half-pixel tolerance')
