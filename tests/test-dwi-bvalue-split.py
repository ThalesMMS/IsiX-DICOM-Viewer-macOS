#!/usr/bin/env python3
"""A diffusion series that stacks its b-values splits into one viewer per b-value.

Compiles DiffusionBValueSplit.swift with a driver for the b-value readers
(standard, Siemens, GE, Philips, sequence name) and the grouping, and checks
the wiring of 2D Viewer > Split Series by b-value.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


driver = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
typealias S = DiffusionBValueSplit
func b(_ standard: Any? = nil, siemens: Any? = nil, ge: Any? = nil, philips: Any? = nil, sequence: Any? = nil) -> Double? {
    S.bValue([standard, siemens, ge, philips, sequence])
}

check(S.tags == ["0018,9087", "0019,100C", "0043,1039", "2001,1003", "0018,0024"], "tag order")
check(b(NSNumber(value: 800.0)) == 800, "standard FD")
check(b(NSNumber(value: 0.0)) == 0, "b = 0 is a b-value")
check(b(siemens: "500") == 500, "Siemens IS")
check(b(siemens: "500".data(using: .ascii)!) == 500, "Siemens bytes read without a dictionary")
check(b(ge: "1000000800\\8\\0\\0") == 800, "GE with its 10^9 offset, first value")
check(b(ge: NSArray(array: [NSNumber(value: 1000)])) == 1000, "GE array without the offset")
var philips = Float(1500).bitPattern.littleEndian
check(b(philips: Data(bytes: &philips, count: 4)) == 1500, "Philips FL bytes")
check(b(philips: NSNumber(value: Float(1500))) == 1500, "Philips FL number")
check(b(sequence: "*ep_b1000t") == 1000, "Siemens sequence name")
check(b(sequence: "ep2d_diff") == nil, "a sequence name without a b-value")
check(b(NSNumber(value: 50.0), siemens: "800") == 50, "the standard tag wins")
check(b(nil, siemens: "", sequence: "*ep_b300t") == 300, "an empty value falls through")
check(b() == nil, "no b-value")

let stacked: [Double?] = [0, 0, 0, 500, 500, 500, 1000, 1000, 1000]
check(S.groups(stacked) == [S.Group(bValue: 0, indices: [0, 1, 2]),
                            S.Group(bValue: 500, indices: [3, 4, 5]),
                            S.Group(bValue: 1000, indices: [6, 7, 8])], "stacked b-values")
// Interleaved and out of order: lowest b first, each in the series' order.
check(S.groups([1000, 0, 1000.2, 0]) == [S.Group(bValue: 0, indices: [1, 3]),
                                       S.Group(bValue: 1000, indices: [0, 2])], "interleaved, rounded")
check(S.groups([0, nil, 800]) == [S.Group(bValue: 0, indices: [0]), S.Group(bValue: 800, indices: [2]),
                                  S.Group(bValue: nil, indices: [1])], "images without a b-value last")
check(S.groups([800, 800]).isEmpty, "one b-value is nothing to split")
check(S.groups([nil, nil]).isEmpty, "no b-value is nothing to split")
print("PASS: b-value readers and groups")
'''

with tempfile.TemporaryDirectory(prefix='horos-dwi-split-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(driver)
    if subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(sources / 'DiffusionBValueSplit.swift'),
                       str(work / 'main.swift'), '-o', str(work / 'check')]).returncode:
        fail('DiffusionBValueSplit.swift does not build with the driver')
    if subprocess.run([str(work / 'check')]).returncode:
        raise SystemExit(1)

split = (sources / 'ViewerController+BValueSplit.swift').read_text(encoding='utf-8')
for needle, why in (
    ('@objc(splitSeriesByBValue:)', 'is the menu action'),
    ('DiffusionBValueSplit.groups(', 'groups with the shared rule'),
    ('viewer: index == 0 ? self : nil', 'shows the first b-value in this viewer'),
    ('lastGroup: 0x2001', 'reads the headers up to the Philips group'),
    ('tileWindows(nil)', 'tiles the viewers'),
    ('window?.subtitle', 'names the b-value of each viewer'),
):
    if needle not in split:
        fail(f'the split no longer {why}: {needle!r} is missing')

menu = (root / 'Horos/Resources/en.lproj/MainMenu.xib').read_text(encoding='utf-8')
at = menu.index('id="Bvs-sp-Itm"')
if 'selector="splitSeriesByBValue:"' not in menu[at:menu.index('</menuItem>', at)]:
    fail('2D Viewer > Split Series by b-value does not send splitSeriesByBValue:')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ('DiffusionBValueSplit.swift', 'ViewerController+BValueSplit.swift'):
    if f'{name} in Sources' not in pbx:
        fail(f'{name} is not compiled into the app')
print('PASS: Split Series by b-value is wired to the viewer')
