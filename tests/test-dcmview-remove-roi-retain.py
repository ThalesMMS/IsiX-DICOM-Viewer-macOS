#!/usr/bin/env python3
"""DCMView keeps a ROI it deletes alive across OsirixRemoveROINotification.

Deleting a selected ROI with the Delete key (-keyDown:) or by group
(-deleteROIGroupID:) posts OsirixRemoveROINotification with the ROI, then takes
it out of the slice with -removeROIFromSliceOrVolume:. In an MPR or Curved MPR
plane view, a 2D point is a mirror of the viewer's point: the viewer removes
its own point on that notification, and -detect2DPointInThisSlice takes the
mirror out of curRoiList, which released it. Since the mirrors are no longer
leaked, the ROI was freed inside the notification and
-removeROIFromSliceOrVolume: retained a dangling pointer: the app crashed in
objc_retain. -deleteROIGroupID: also read the ROI again from the array after
the notification, which can by then hold another ROI at that index.

Checked in DCMView.m: every post of OsirixRemoveROINotification that is
followed by -removeROIFromSliceOrVolume: of the same ROI retains it before the
post and releases it after the removal, or holds it from earlier in the same
method with `roi = [[x retain] autorelease]`, which keeps it until the
autorelease pool drains, after the method returns. Both use the ROI notified,
not a second read of the array.

-cut:, -deleteROIGroupID: and -deleteROIs: are Swift (DCMView+ROIEditing.swift),
and so are -keyDown: (DCMView+Keyboard.swift) and the click-by-click ROI a
double-click's hot key cancels (DCMView+Mouse.swift): there the ROI notified
and removed is one local constant, a strong reference bound before the post
(`let r`, `case let r`, `for r in`), which holds it.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision is None:
        file = root / path
        return file.read_text(encoding='utf-8') if file.exists() else ''
    shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
    return shown.stdout.decode('utf-8') if shown.returncode == 0 else ''


text = read('Horos/Sources/DCMView.m')
swift_files = {name: read(f'Horos/Sources/{name}')
               for name in ('DCMView+ROIEditing.swift', 'DCMView+Keyboard.swift', 'DCMView+Mouse.swift')}

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
    method = code[:sum(len(l) + 1 for l in lines[:i])]
    method = method[max(method.rfind('\n-'), method.rfind('\n+')):]
    autoreleased = re.search(rf'\b{posted}\s*=\s*\[\[[^\]]+\s+retain\s*\]\s*autorelease\s*\]', method)
    if autoreleased:
        continue
    if not held:
        failures.append(f'line {i + 1}: {posted} is not retained before OsirixRemoveROINotification')
    if not re.search(rf'\[\s*{posted}\s+release\s*\]', after + '\n' + lines[i + 3] if i + 3 < len(lines) else after):
        failures.append(f'line {i + 1}: {posted} is not released after -removeROIFromSliceOrVolume:')

for name, swift in swift_files.items():
    swift_lines = [line.split('//')[0] for line in swift.split('\n')]
    for i, line in enumerate(swift_lines):
        posted = re.search(r'post\(name: NSNotification\.Name\.OsirixRemoveROI, object: ([^,]+),', line) or \
            re.search(r'inputPost\(\.OsirixRemoveROI, object: ([^,)]+)\)', line)
        if not posted:
            continue
        after = '\n'.join(swift_lines[i + 1:i + 3])
        removal = re.search(r'removeROI\(fromSliceOrVolume: ([^)]+)\)', after)
        if not removal:
            continue
        sites += 1
        posted, removed = posted.group(1).strip(), removal.group(1).strip()
        if not re.fullmatch(r'\w+', posted):
            failures.append(f'{name} line {i + 1}: the notification is posted with {posted!r}, not a ROI held')
            continue
        if removed != posted:
            failures.append(f'{name} line {i + 1}: {removed!r} is removed after {posted!r} was notified')
        method = '\n'.join(swift_lines[:i])
        method = method[method.rfind('func '):]
        if not re.search(rf'(\blet {posted}\b|\bcase let {posted} as\b|\bfor {posted} in\b)', method) or \
                re.search(rf'(weak|unowned)\s+(var|let)\s+{posted}\b', method):
            failures.append(f'{name} line {i + 1}: {posted} is not a strong local bound before the post')

if sites < 5:
    failures.append(f'expected the deletions of -keyDown:, -cut:, -deleteROIGroupID:, -deleteROIs: and the cancelled click-by-click ROI, found {sites}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {sites} deletions keep their ROI across OsirixRemoveROINotification')
