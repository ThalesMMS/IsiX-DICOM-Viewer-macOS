#!/usr/bin/env python3
"""DCMView keeps a ROI it deletes alive across OsirixRemoveROINotification.

Deleting a selected ROI with the Delete key (-keyDown:) or by group
(-deleteROIGroupID:) posts OsirixRemoveROINotification with the ROI, then takes
it out of the slice with -removeROIFromSliceOrVolume:. In an MPR or Curved MPR
plane view, a 2D point is a mirror of the viewer's point: the viewer removes
its own point on that notification, and -detect2DPointInThisSlice takes the
mirror out of curRoiList, which released it. Since the mirrors are no longer
leaked (#845, #853), the ROI was freed inside the notification and
-removeROIFromSliceOrVolume: retained a dangling pointer: the app crashed in
objc_retain. -deleteROIGroupID: also read the ROI again from the array after
the notification, which can by then hold another ROI at that index.

Checked in DCMView.m: every post of OsirixRemoveROINotification that is
followed by -removeROIFromSliceOrVolume: of the same ROI retains it before the
post and releases it after the removal, and both use the ROI notified, not a
second read of the array.

`<git revision>` as an optional argument reads DCMView.m from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

if revision is None:
    text = (root / 'Horos/Sources/DCMView.m').read_text(encoding='utf-8')
else:
    text = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/DCMView.m'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')

code = '\n'.join(line.split('//')[0] for line in text.split('\n'))
lines = code.split('\n')

failures = []
sites = 0
for i, line in enumerate(lines):
    if 'OsirixRemoveROINotification' not in line or 'postNotificationName' not in line:
        continue
    after = '\n'.join(lines[i + 1:i + 3])
    removal = re.search(r'removeROIFromSliceOrVolume:\s*([^\]]+)\]', after)
    if not removal:
        continue
    sites += 1
    posted = re.search(r'object:\s*([^\s\]]+(?:\s+objectAtIndex:\s*\w+\])?)', line).group(1).strip()
    removed = removal.group(1).strip()
    before = '\n'.join(lines[max(0, i - 3):i])
    if not re.fullmatch(r'\w+', posted):
        failures.append(f'line {i + 1}: the notification is posted with {posted!r}, read from the array, not a ROI held')
        continue
    if removed != posted:
        failures.append(f'line {i + 1}: {removed!r} is removed after {posted!r} was notified')
    held = re.search(rf'\[\s*{posted}\s+retain\s*\]', before) or \
        re.search(rf'{posted}\s*=\s*\[\[.*\]\s*retain\]', before)
    if not held:
        failures.append(f'line {i + 1}: {posted} is not retained before OsirixRemoveROINotification')
    if not re.search(rf'\[\s*{posted}\s+release\s*\]', after + '\n' + lines[i + 3] if i + 3 < len(lines) else after):
        failures.append(f'line {i + 1}: {posted} is not released after -removeROIFromSliceOrVolume:')

if sites < 4:
    failures.append(f'expected the four deletions of -keyDown:, -deleteROIGroupID: and the ROI menu, found {sites}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {sites} deletions keep their ROI across OsirixRemoveROINotification')
