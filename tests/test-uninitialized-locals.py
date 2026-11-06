#!/usr/bin/env python3
"""The locals that clang reported as used-uninitialised stay initialised.

Four sweeps of the build warnings turned up locals read before assignment, each
in a place where the wrong value is not obviously wrong to look at: an
ultrasound unit string, a selected-row index, a NIfTI orientation
code and a plugin's menu item. The first two have their own behavioural
checks; this one guards the declarations themselves, so the warnings cannot
quietly come back. The plugin's menu item went with the menus former plugins
declared in their Info.plist, which nothing builds any more.

Reading declarations is weaker than compiling the code, and is meant to be:
these are one-line invariants in files far too entangled to extract.
"""
from pathlib import Path
import re
import sys
from sources import class_text

root = Path(__file__).resolve().parents[1]
failures = []


def source(name):
    return (root / name).read_bytes().decode('latin1')


# --- NIfTI orientation: no qform and no sform must not read the stack --------
# DCMPix.m, or the Swift class once it moved.
pix = source('Horos/Sources/DCMPix.m') if (root / 'Horos/Sources/DCMPix.m').is_file() else class_text('DCMPix')
orientation = re.search(r'int\s+icod\s*(=[^;]*)?,\s*jcod\s*(=[^;]*)?,\s*kcod\s*(=[^;]*)?;', pix)
if not orientation and 'loadNonDICOMImage' in pix:
    # DCMPix reads NIfTI in Swift, where a local cannot be read unset; the codes
    # still start at 0, outside the 1..6 the library returns.
    swift = source('Horos/Sources/DCMPix+NonDICOM.swift')
    if 'var i: Int32 = 0, j: Int32 = 0, k: Int32 = 0\n        HorosNIfTIOrientation(' not in swift:
        failures.append('the NIfTI orientation codes do not start outside the 1..6 the library returns')
elif not orientation:
    failures.append('the NIfTI orientation codes are gone from DCMPix.m')
elif not all(orientation.group(i) for i in (1, 2, 3)):
    failures.append('icod/jcod/kcod are declared without values; a NIfTI with neither '
                    'qform nor sform then decides its orientation from the stack')
else:
    # 1..6 are the real codes, so the unset value must not collide with one.
    for group in (1, 2, 3):
        value = orientation.group(group).lstrip('= ').strip()
        if value != '0':
            failures.append('an orientation code starts at %s; it has to be outside the '
                            '1..6 the library returns, so no comparison matches' % value)

if failures:
    for entry in failures:
        print('FAIL:', entry, file=sys.stderr)
    sys.exit(1)
print('PASS: the reported locals are initialised where they are declared')
