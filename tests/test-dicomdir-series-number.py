#!/usr/bin/env python3
"""A DICOMDIR's series number is read once and used for both the series ID and the number.

The scan reads each element of a record by taking it out of the record, so an
element read twice reads nothing the second time: the series number has to be
read once, kept, and used for the series ID and for the series number. The
DICOMDIR entries are Swift (DicomDatabase+DicomDir.swift), the series identity
rule is IsiXDatabase's MediaScanRules: this checks that the number is taken
out once and handed to both, and runs the rule for zero, positive and negative
numbers. Its equivalence with the former Objective-C++ is
test-media-scan-rules-equivalence.py.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
entries = (root / 'Horos/Sources/DicomDatabase+DicomDir.swift').read_text(encoding='utf-8')
rules = root / 'Modules/IsiXDatabase/Sources/MediaScanRules.swift'
failures = []

code = re.sub(r'//[^\n]*', '', entries)
if code.count('elements.remove(DirectoryTag.seriesNumber)') != 1:
    failures.append('the series number is not taken out of the record exactly once')
if not re.search(r'let seriesNumberAttribute = elements\.remove\(DirectoryTag\.seriesNumber\)', code):
    failures.append('the series number read is not kept')
if not re.search(r'MediaScanRules\.seriesID\(seriesNumber: DirectoryElements\.string\(seriesNumberAttribute\)', code):
    failures.append('the series ID is not made of the number read')
if 'set(DirectoryElements.integerNumber(seriesNumberAttribute), "seriesNumber")' not in code:
    failures.append('the series number is not the number read')

program = r'''
import Foundation
for number in [0, 7, -1] {
    let id = MediaScanRules.seriesID(seriesNumber: String(number), seriesDICOMUID: "uid")
    guard id == String(format: "%8.8d uid", Int32(number)) else {
        print("FAIL: series identity formatting for \(number): \(id ?? "nil")")
        exit(1)
    }
}
print("PASS: DICOMDIR series numbers survive attribute removal (zero, positive, negative)")
'''
with tempfile.TemporaryDirectory(prefix='horos-dicomdir-number-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc', str(rules), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        failures.append('the rule does not compile:\n' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
        print(run.stdout, end='')
        if run.returncode:
            failures.append('the series identity is not formatted as before')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
