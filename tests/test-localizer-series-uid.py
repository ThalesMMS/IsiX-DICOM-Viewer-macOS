#!/usr/bin/env python3
"""The localizer grouping does not overwrite the DICOM SeriesInstanceUID.

With NOLOCALIZER set, which it is by default, Horos puts the localizers of a
study into one internal series. It also used to overwrite seriesDICOMUID - the
DICOM SeriesInstanceUID it stores - with the word LOCALIZER followed by the study
identifier, and that value is what the C-FIND SCP answers with. UI allows 64
characters of digits and dots; that value is 74 characters and starts with nine
letters.

The grouping is serieID, which the importer matches series rows on.
seriesDICOMUID is stored beside it and merges nothing, so leaving the identifier
from the file alone keeps the grouping and puts a real UID back on the wire.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# The DICOM reading is Swift (DicomFile+DICOMReading.swift).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import class_text  # noqa: E402
source = class_text('DicomFile')

# UI: at most 64 characters, digits and dots only, no leading or embedded space.
UID = re.compile(r'^[0-9.]{1,64}$')


def conformant(value):
    return bool(UID.match(value)) and '..' not in value


# The value the old code produced, against a UID of the length these fixtures use.
STUDY = '1.2.826.0.1.3680043.8.498.64788744647355255395090336010075907066'
if conformant('LOCALIZER' + STUDY):
    failures.append('the value this test defends against is conformant; the test is wrong')
if conformant(STUDY) is False:
    failures.append('the fixture study identifier is not a conformant UID; the test is wrong')

# --- the localizer branch ---------------------------------------------------
at = source.find('serieID = "LOCALIZER"')
if at < 0:
    failures.append('the localizer grouping is gone')
else:
    opening = source.rindex('{', 0, at)
    depth, index, branch = 0, opening, ''
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                branch = source[opening:index + 1]
                break
        index += 1
    if '"seriesDICOMUID"' in branch:
        failures.append('the localizer branch writes seriesDICOMUID again')
    # The grouping itself has to stay: that is what merges the localizers.
    if 'seriesDescription' not in branch:
        failures.append('the localizer branch no longer names the merged series')

# Exactly one write takes it from the file, and any other has to be a fallback
# that only runs when the file carries none - never an unconditional overwrite.
assignments = re.findall(r'set\(([^\n]*?), "seriesDICOMUID"\)', source)
fromFile = [value for value in assignments if value == 'seriesUID']
if len(fromFile) != 1:
    failures.append('seriesDICOMUID is written from the value read for the series %d times, '
                    'expected once (all writes: %s)' % (len(fromFile), ', '.join(assignments)))
else:
    # And that value is the SeriesInstanceUID of the file, read just above it.
    at = source.index('set(seriesUID, "seriesDICOMUID")')
    if 'DicomFileTag.seriesInstanceUID' not in source[at - 400:at]:
        failures.append('seriesDICOMUID is no longer set from DCM_SeriesInstanceUID')

for value in [value for value in assignments if value != 'seriesUID']:
    at = source.find('set(%s, "seriesDICOMUID")' % value)
    if at < 0 or 'elements.object(forKey: "seriesDICOMUID") as? NSString)?.length ?? 0) == 0' not in source[max(0, at - 500):at]:
        failures.append('seriesDICOMUID is written as %s without first checking that the file '
                        'carries none, so a real SeriesInstanceUID can be replaced' % value)

# --- why this is safe: the importer groups on something else -----------------
# DicomDatabase is Swift; the import is DicomDatabase+Import.swift.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources  # noqa: E402
database = sources.class_text('DicomDatabase')
lookup = re.search(r'indexOfObject\(curDict\.object\(forKey: "seriesID" \+ seriesNum\)', database)
if not lookup:
    failures.append('the importer no longer finds a series row by its seriesID')
if not re.search(r'indexOfObject\(curDict\.object\(forKey: "seriesID" \+ seriesNum\), '
                 r'in: seriesArray\?\.value\(forKey: "seriesInstanceUID"\) as\? NSArray\)', database):
    failures.append('the importer no longer matches the stored seriesInstanceUID attribute')

# --- and why it matters: the SCP answers with it -----------------------------
# The response rules are IsiXDICOMNetwork's SCPResponseIdentifiers.swift.
rules = (root / 'Modules/IsiXDICOMNetwork/Sources/SCPResponseIdentifiers.swift').read_text()
for level, key in (('series', 'seriesDICOMUID'), ('image', 'series.seriesDICOMUID')):
    if f'{level}[.seriesInstanceUID] = Rule(condition: "{key}", source: .latin1("{key}"))' not in rules:
        failures.append('the %s level C-FIND response no longer uses %s' % (level, key))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the localizer grouping keeps serieID and leaves seriesDICOMUID as the '
      'SeriesInstanceUID read from the file, which is what the C-FIND SCP answers with')
