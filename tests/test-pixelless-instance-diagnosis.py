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

def native_length_checks(source):
    """Both length diagnostics must stay inside the native-pixel branch.

    DCMTK's deprecated isNotEncapsulated() returns usesNativeFormat().
    Encapsulated streams have fragment lengths, not native raster lengths.
    """
    live = re.sub(r'//[^\n]*', '', source)
    if not re.search(r'BOOL\s+storedAsRead\s*=\s*transfer\.(?:usesNativeFormat|isNotEncapsulated)\s*\(\s*\)\s*;', live):
        return False
    guard = re.search(r'else\s+if\s*\(\s*storedAsRead\s*\)\s*\{', live)
    if not guard:
        return False
    opening = guard.end() - 1
    depth = 0
    for index in range(opening, len(live)):
        depth += (live[index] == '{') - (live[index] == '}')
        if depth == 0:
            branch = live[opening:index + 1]
            return bool(re.search(r'if\s*\(\s*carried\s*==\s*0\s*\)', branch)
                        and re.search(r'if\s*\(\s*carried\s*<\s*expected\s*\)', branch))
    return False


root = Path(__file__).resolve().parents[1]
failures = []
parser = (root / 'Horos/Sources/DicomFileDCMTKCategory.mm').read_bytes().decode('latin1')

at = parser.find('//Number of Frames')
end = parser.find('// Is it a multi frame DICOM files?', at) if at >= 0 else -1
window = parser[at:end] if at >= 0 and end > at else ''

if not window:
    failures.append('the block that reads the image geometry is gone')
else:
    if 'DCM_PixelData' not in window:
        failures.append('nothing looks at whether there is any pixel data, so an instance that '
                        'declares a size and carries nothing is counted as an image in silence')
    # An object that states Rows and Columns is claiming to be a picture; one that
    # states neither - a structured report, a presentation state - is not judged.
    # Asking the list of known image SOP classes instead left a hardcopy object
    # with no pixels indexed and nothing said (see test-non-image-objects.py).
    if 'claimsAPicture' not in window or 'rows > 0 || columns > 0' not in window:
        failures.append('the check no longer decides by whether the object claims a picture, so '
                        'either a structured report is reported for having none or an image '
                        'class the application does not list is missed')
    if not native_length_checks(window):
        failures.append('a compressed stream is shorter than the picture it holds by design; '
                        'without that test every compressed instance would be reported')
    for phrase in ('carries no pixel data at all', 'pixel data is empty', 'bytes where'):
        if phrase not in window:
            failures.append('the three ways an instance can have no usable picture are not told '
                            'apart: "%s" is missing' % phrase)
    if 'pixelDataProblem' not in window:
        failures.append('the finding is not recorded on the parsed elements, so nothing but the '
                        'log can act on it')
    if 'indexed and counted as an image anyway' not in window:
        failures.append('the line does not say that the instance is kept, which is the thing a '
                        'reader most needs to know')
    # Refusing the file would lose the report, the demographics and everything
    # else it carries.
    if 'return' in window.split('pixelDataProblem')[-1][:400] and 'problem' in window:
        failures.append('the parser appears to bail out on such a file rather than indexing it')

# Preserve the old predicate's behavior, and prove that the checker rejects
# compressed-stream comparisons and either diagnostic escaping its guard.
if window and native_length_checks(window):
    assert native_length_checks(window.replace('usesNativeFormat()', 'isNotEncapsulated()'))
    assert not native_length_checks(window.replace('usesNativeFormat()', 'usesEncapsulatedFormat()'))
    assert not native_length_checks(window.replace('else if( storedAsRead)', 'else if( YES)'))
    assert not native_length_checks(window.replace('if( carried == 0)', 'if( YES)'))
    assert not native_length_checks(window.replace('if( carried < expected)', 'if( YES)'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an image instance with no pixel data, empty pixel data or too little of it is named '
      'with what is wrong and still indexed')
