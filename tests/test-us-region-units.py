#!/usr/bin/env python3
"""Both ultrasound region unit strings are decided, whatever the tags say.

A ROI inside an ultrasound region labels its position and length with a unit per
axis, read from Physical Units X Direction (0018,6024) and Y Direction
(0018,6026). The two are independent, but the code once chose them in one
if/else-if chain:

    if (X out of range)      unitsX = "unknown";   // unitsY never assigned
    else if (Y out of range) unitsY = "unknown";   // unitsX never assigned
    else                     both = table[...];

so an out-of-range value on either axis left the *other* string uninitialised,
and the uninitialised pointer was then formatted into the label and compared
with isEqualToString:. Undefined behaviour in a measurement label.

The units are IsiXROI's (ROIUltrasoundUnits): this runs its selection for every
value either axis can carry, including the out-of-range ones, and requires each
axis to come out decided for itself; both label sites of the ROI ask it once
per axis.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402
from sources import class_text  # noqa: E402

failures = []
roi = class_text('ROI')
if roi.count('ROIUltrasoundUnits.name(of: unitsXCode)') != 2 or roi.count('ROIUltrasoundUnits.name(of: unitsYCode)') != 2:
    failures.append('the two label sites do not ask each axis its unit on its own')

DRIVER = r'''
import IsiXROI

var bad = false
let table = ROIUltrasoundUnits.names
precondition(table.count == 13)
for x in Int32(-2)...14 {
    for y in Int32(-2)...14 {
        let unitsX = ROIUltrasoundUnits.name(of: x), unitsY = ROIUltrasoundUnits.name(of: y)
        // A value outside 0..12 has no entry in the table, and only that axis may fall back.
        let xKnown = (0...12).contains(x), yKnown = (0...12).contains(y)
        if xKnown && unitsX != table[Int(x)] { print("FAIL: x=\(x) is in range but unitsX is \(unitsX)"); bad = true }
        if !xKnown && unitsX != "unknown" { print("FAIL: x=\(x) is out of range but unitsX is \(unitsX)"); bad = true }
        if yKnown && unitsY != table[Int(y)] { print("FAIL: y=\(y) is in range but unitsY is \(unitsY)"); bad = true }
        if !yKnown && unitsY != "unknown" { print("FAIL: y=\(y) is out of range but unitsY is \(unitsY)"); bad = true }
    }
}
if !bad { print("every axis pair decides both unit strings") }
exit(bad ? 1 : 0)
'''

with tempfile.TemporaryDirectory(prefix='horos-us-units-') as tmp:
    path = Path(tmp)
    (path / 'main.swift').write_text('import Foundation\n' + DRIVER)
    module = isix_modules.module_flags('IsiXROI', path / 'module')
    build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), *module, '-o', str(path / 'test')], capture_output=True, text=True)
    if build.returncode != 0:
        failures.append('the selection does not compile:\n%s' % build.stderr[-1200:])
    else:
        run = subprocess.run([str(path / 'test')], capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            failures.append('the selection left a unit undecided')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: ultrasound region units are decided per axis at both sites')
