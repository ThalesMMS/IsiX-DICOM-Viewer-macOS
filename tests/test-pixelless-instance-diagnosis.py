#!/usr/bin/env python3
"""An image instance with nothing to look at is named, not just counted.

Measured before the change: four CT instances in one series — one whole, one with
no `PixelData` element at all, one whose `PixelData` is empty, and one carrying a
quarter of the bytes its `Rows`/`Columns` claim. All four were indexed, the study
said 4 images, and nothing anywhere said that three of them have no picture in
them. The count did not match what could be looked at, and there was no way to
tell which instances were the empty ones.

They stay indexed — refusing them would lose everything else the file carries —
but each is named with what is wrong with it.
"""
from pathlib import Path
import re
import sys

def native_length_checks(reading, rules):
    """Both length diagnostics must stay inside the native-pixel branch.

    The reading (DicomFile+DICOMReading.swift) hands the rule the pixel data's
    length only when the file's transfer syntax keeps it native; the rule
    (DICOMImportRules in the IsiXDICOMFile module) judges the length only in
    that case. Encapsulated streams have fragment lengths, not native raster
    lengths.
    """
    live = re.sub(r'//[^\n]*', '', reading)
    if not re.search(r'else\s+if\s+file\.originalTransferSyntaxIsNative\s*\{\s*pixels\s*=\s*\.native\(length:\s*length\)', live):
        return False
    rule = re.sub(r'//[^\n]*', '', rules)
    at = rule.find('case .native(let length):')
    branch = rule[at:rule.find('case .encapsulated:', at)] if at >= 0 else ''
    return bool(re.search(r'if\s+length\s*==\s*0\s*\{', branch)
                and re.search(r'if\s+UInt64\(length\)\s*<\s*expected\s*\{', branch))


root = Path(__file__).resolve().parents[1]
failures = []
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import class_text  # noqa: E402
parser = class_text('DicomFile')
rules = (root / 'Modules/IsiXDICOMFile/Sources/DICOMImportRules.swift').read_text()

at = parser.find('func readPixelDataProblem(')
end = parser.find('func readFrames(', at) if at >= 0 else -1
reading = parser[at:end] if at >= 0 and end > at else ''
at = rules.find('public static func pixelDataProblem(')
rule = rules[at:rules.find('public static func undisplayableObjectProblem', at)] if at >= 0 else ''
window = reading + rule

if not reading or not rule:
    failures.append('the block that reads the image geometry is gone')
else:
    if 'DicomFileTag.pixelData' not in reading:
        failures.append('nothing looks at whether there is any pixel data, so an instance that '
                        'declares a size and carries nothing is counted as an image in silence')
    # An object that states Rows and Columns is claiming to be a picture; one that
    # states neither - a structured report, a presentation state - is not judged.
    # Asking the list of known image SOP classes instead left a hardcopy object
    # with no pixels indexed and nothing said (see test-non-image-objects.py).
    if 'claimsAPicture' not in reading or 'rows > 0 || columns > 0' not in reading:
        failures.append('the check no longer decides by whether the object claims a picture, so '
                        'either a structured report is reported for having none or an image '
                        'class the application does not list is missed')
    if not native_length_checks(reading, rule):
        failures.append('a compressed stream is shorter than the picture it holds by design; '
                        'without that test every compressed instance would be reported')
    for phrase in ('carries no pixel data at all', 'pixel data is empty', 'bytes where'):
        if phrase not in window:
            failures.append('the three ways an instance can have no usable picture are not told '
                            'apart: "%s" is missing' % phrase)
    if 'pixelDataProblem' not in reading:
        failures.append('the finding is not recorded on the parsed elements, so nothing but the '
                        'log can act on it')
    if 'indexed and counted as an image anyway' not in reading:
        failures.append('the line does not say that the instance is kept, which is the thing a '
                        'reader most needs to know')
    # Refusing the file would lose the report, the demographics and everything
    # else it carries.
    if 'return false' in reading or 'return -1' in reading:
        failures.append('the parser appears to bail out on such a file rather than indexing it')

# Preserve the old predicate's behavior, and prove that the checker rejects
# compressed-stream comparisons and either diagnostic escaping its guard.
if reading and native_length_checks(reading, rule):
    assert not native_length_checks(reading.replace('originalTransferSyntaxIsNative', 'originalTransferSyntaxIsEncapsulated'), rule)
    assert not native_length_checks(reading.replace('pixels = .native(length: length)', 'pixels = .encapsulated'), rule)
    assert not native_length_checks(reading, rule.replace('if length == 0 {', 'if true {'))
    assert not native_length_checks(reading, rule.replace('if UInt64(length) < expected {', 'if true {'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an image instance with no pixel data, empty pixel data or too little of it is named '
      'with what is wrong and still indexed')
