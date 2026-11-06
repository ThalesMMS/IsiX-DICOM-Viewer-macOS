#!/usr/bin/env python3
"""ROI Enhancement plots seconds when DCMPix has no acquisition time.

DCMPix keeps the acquisition time only for some modalities, and the dynamic CT
phantom of tools/generate-roi-enhancement-fixture.py has none in it: the native
ROI Enhancement plotted each phase's index (0-7) where the plugin API, which
falls back to the date the database filed the image under, shows seconds
(0-14). Both now take the same time.

1. The phantom's eight phases, with no acquisition time and the dates the
   database files them under (acquisition date and time), are placed at their
   seconds from the first phase: 0, 2, ... 14.
2. An acquisition time, where every phase has one, comes first; with neither
   for every phase, the phase index is the time (the old axis, kept as the
   last resort and as the control that the first case is not it).
3. In the sources: the viewer gives the rule each phase's acquisition time and
   its image's database date, as the plugin API does.
"""
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import python_with  # noqa: E402
python_with.require('import pydicom', 'import numpy')
import pydicom  # noqa: E402
from sources import source_text  # noqa: E402

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/ROIEnhancement.swift'
generator = root / 'tools/generate-roi-enhancement-fixture.py'
failures = []


def filed(dataset):
    """The date the database files an image under, as seconds since 1970: its acquisition date and time."""
    stamp = str(dataset.AcquisitionDate) + str(dataset.AcquisitionTime).split('.')[0]
    return datetime.strptime(stamp, '%Y%m%d%H%M%S').replace(tzinfo=timezone.utc).timestamp()


with tempfile.TemporaryDirectory(prefix='horos-roi-enhancement-time-') as folder:
    work = Path(folder)
    subprocess.run([sys.executable, str(generator), str(work / 'phantom')], check=True, capture_output=True)
    phases = [pydicom.dcmread(path) for path in sorted((work / 'phantom').glob('phase-*.dcm'))]
    if len(phases) != 8:
        raise SystemExit('FAIL: expected eight dynamic phases, got %d' % len(phases))
    dates = ', '.join('Date(timeIntervalSince1970: %r)' % filed(p) for p in phases)

    program = work / 'main.swift'
    program.write_text('''
import Foundation
let filed: [Date?] = [%s]
let none = [Date?](repeating: nil, count: filed.count)
print("filed", ROIEnhancement.phaseTimes(acquisition: none, filed: filed))
var acquisition = none
for i in acquisition.indices { acquisition[i] = Date(timeIntervalSince1970: 1000 + 3 * Double(i)) }
print("acquisition", ROIEnhancement.phaseTimes(acquisition: acquisition, filed: filed))
var partly = acquisition
partly[3] = nil
print("partly", ROIEnhancement.phaseTimes(acquisition: partly, filed: filed))
print("index", ROIEnhancement.phaseTimes(acquisition: none, filed: none))
''' % dates)
    built = subprocess.run(['xcrun', 'swiftc', str(source), str(program), '-o', str(work / 'times')], capture_output=True, text=True)
    if built.returncode != 0:
        raise SystemExit('FAIL: the time rule does not compile\n' + built.stderr[-3000:])
    ran = subprocess.run([str(work / 'times')], capture_output=True, text=True, timeout=60)
    if ran.returncode != 0:
        raise SystemExit('FAIL: the time rule program failed\n' + ran.stderr[-2000:])
    axes = {line.split(' ', 1)[0]: eval(line.split(' ', 1)[1]) for line in ran.stdout.splitlines()}

    seconds = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0]
    if axes['filed'] != seconds:
        failures.append('the phantom without acquisition times is plotted at %r, not its seconds' % axes['filed'])
    if axes['acquisition'] != [3.0 * i for i in range(8)]:
        failures.append('the acquisition times did not come first: %r' % axes['acquisition'])
    if axes['partly'] != seconds:
        failures.append('an acquisition time missing on one phase did not fall back for all: %r' % axes['partly'])
    if axes['index'] != [float(i) for i in range(8)] or axes['index'] == axes['filed']:
        failures.append('without any date the phases are not at their index: %r' % axes['index'])

viewer = source_text('ViewerController+ROIEnhancement')
if 'ROIEnhancement.phaseTimes(' not in viewer or 'imageObj()?.date' not in viewer:
    failures.append('the viewer does not give the time rule the database date of each phase')
if 'TimeInterval(movie)' in viewer:
    failures.append('the viewer still plots the phase index itself')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    raise SystemExit(1)
print('ok: the phantom without acquisition times is plotted at 0-14 s, the acquisition time comes first, the index is the last resort')
