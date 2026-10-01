#!/usr/bin/env python3
"""The GSPS implementation is the DICOM object, not the series zoom/window."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
failures = []
code = (root / 'Horos/Sources/GSPSDocument.swift').read_text()
for needle in (
    '1.2.840.10008.5.1.4.1.1.11.1',
    'ReferencedSOPInstanceUID',
    'PIXEL',
    'DISPLAY',
    'Softcopy VOI',
    'Displayed Area',
):
    if needle not in code:
        failures.append('the GSPS implementation no longer states %r' % needle)
for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('ok: the GSPS implementation is the DICOM presentation state, not series zoom/window')
