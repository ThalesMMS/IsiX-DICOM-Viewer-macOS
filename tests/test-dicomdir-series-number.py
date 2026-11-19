#!/usr/bin/env python3
"""A DICOMDIR's series number is read once, and its series UID is stored as the record has it.

The scan reads each element of a record by taking it out of the record, so an
element read twice reads nothing the second time: the series number has to be
read once, kept, and used for the series ID and for the series number. The
DICOMDIR entries are Swift (DicomdirReader.swift), the series identity
rule is IsiXDatabase's MediaScanRules: this checks that the number is taken
out once and handed to both, and runs the rule for zero, positive and negative
numbers. The equivalence of the series ID with the former Objective-C++ is
test-media-scan-rules-equivalence.py.

The same holds for the Series Instance UID, which goes to two places. As
seriesDICOMUID it is stored as the record has it, for a multi-frame file too:
that value is what a query about the series is answered with, and it used to
be "<series UID>-<SOP instance UID>" for a multi-frame file, which no UI value
can hold. What makes a multi-frame file a series of its own is the series ID,
the key the index groups on: the rule is run for multi-frame records with and
without their UIDs, which must split by file, and for single-frame ones,
which must not.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
entries = (root / 'Horos/Sources/DicomdirReader.swift').read_text(encoding='utf-8')
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

# The DICOM identifier is the element of the record and nothing else: taken out
# once, kept, stored under seriesDICOMUID, and handed to the series ID with the
# SOP instance UID and the number of frames.
if code.count('elements.takeString(DirectoryTag.seriesInstanceUID)') != 1:
    failures.append('the Series Instance UID is not taken out of the record exactly once')
if not re.search(r'let seriesInstanceUID = elements\.takeString\(DirectoryTag\.seriesInstanceUID\)', code):
    failures.append('the Series Instance UID read is not kept')
written = re.findall(r'set\(([^\n]*?), "seriesDICOMUID"\)', code)
if written != ['seriesInstanceUID'] or code.count('"seriesDICOMUID"') != 1:
    failures.append('seriesDICOMUID is not written once, from the Series Instance UID of the record: %r' % written)
if not re.search(r'MediaScanRules\.seriesID\(seriesNumber: DirectoryElements\.string\(seriesNumberAttribute\),\s*'
                 r'seriesInstanceUID: seriesInstanceUID,\s*sopInstanceUID: item\["SOPUID"\] as\? String,\s*'
                 r'numberOfFrames: \(item\["numberOfFrames"\] as\? NSNumber\)\?\.intValue \?\? 0\), "seriesID"\)', code):
    failures.append('the series ID is not made of the series UID, the SOP instance UID and the frames of the record')

program = r'''
import Foundation
var failed = false
func expect(_ got: String?, _ wanted: String?, _ what: String) {
    if got != wanted {
        print("FAIL: \(what): \(got ?? "nil"), not \(wanted ?? "nil")")
        failed = true
    }
}
func key(_ number: String?, _ series: String?, _ instance: String?, _ frames: Int) -> String? {
    MediaScanRules.seriesID(seriesNumber: number, seriesInstanceUID: series, sopInstanceUID: instance, numberOfFrames: frames)
}
for number in [0, 7, -1] {
    expect(key(String(number), "uid", "sop", 1), String(format: "%8.8d uid", Int32(number)),
           "series identity formatting for \(number)")
}
// Single-frame records: the series alone, whatever the instance.
for frames in [0, 1] {
    expect(key("7", "1.2", "1.3", frames), "00000007 1.2", "single-frame, \(frames) frame(s)")
    expect(key("7", "1.2", "1.4", frames), "00000007 1.2", "single-frame, another instance, \(frames) frame(s)")
    expect(key(nil, "1.2", "1.3", frames), "1.2", "single-frame without a series number")
    expect(key("7", nil, "1.3", frames), "00000007 (null)", "single-frame without a series UID")
    expect(key(nil, nil, nil, frames), nil, "single-frame without anything")
}
// Multi-frame records: one series for each file, with and without the UIDs.
expect(key("7", "1.2", "1.3", 4), "00000007 1.2-1.3", "multi-frame")
expect(key("7", "1.2", "1.4", 4), "00000007 1.2-1.4", "multi-frame, another instance")
expect(key(nil, "1.2", "1.3", 4), "1.2-1.3", "multi-frame without a series number")
expect(key("7", nil, "1.3", 4), "00000007 (null)-1.3", "multi-frame without a series UID")
expect(key("7", "1.2", nil, 4), "00000007 1.2-(null)", "multi-frame without a SOP instance UID")
expect(key(nil, nil, nil, 2), "(null)-(null)", "multi-frame without anything")
if failed { exit(1) }
print("PASS: DICOMDIR series numbers survive attribute removal (zero, positive, negative)")
print("PASS: a multi-frame record is a series of its own by its series ID, with and without its UIDs; "
      + "a single-frame one is keyed by its series")
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
            failures.append('the series ID is not what the index groups on')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
