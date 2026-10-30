#!/usr/bin/env python3
"""A ROI tells the observers of its notifications on the main thread only.

The views and windows that observe OsirixROIChangeNotification and
OsirixRemoveROINotification run on the main thread, and the Swift ones -
DCMView and its MPR and CPR subclasses, the ROI, plot and histogram windows -
check it when the notification calls them: posted on another thread, the
check stops the application. ROIs are decoded and released on other threads:
by the web portal, by the import of a ROI SR, and at launch by the repair that
reads undated images again.

- Every post of the ROI's Swift sources goes through postChange or
  postOnMainThreadOnly.
- postChange posts on the main thread, at once there and asynchronously from
  another thread.
- Creating, decoding and deallocating a ROI post only on the main thread.

Checked in the sources.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text, source_text  # noqa: E402


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


source = class_text('ROI') + '\n' + source_text('HorosVolumeLengthROI')
code = '\n'.join(line for line in source.split('\n') if not line.lstrip().startswith('//'))
failures = []

change = body(code, 'func postChange(')
if not re.search(r'if Thread\.isMainThread \{\s*NotificationCenter\.default\.post\(name: \.OsirixROIChange', change) \
        or 'DispatchQueue.main.async' not in change:
    failures.append('postChange does not post on the main thread, at once or asynchronously')

main_only = body(code, 'func postOnMainThreadOnly(')
if not re.search(r'if Thread\.isMainThread \{\s*NotificationCenter\.default\.post\(name: name', main_only) \
        or 'else' in main_only or 'Dispatch' in main_only:
    failures.append('postOnMainThreadOnly posts off the main thread')

helpers = change + main_only
direct = [line.strip() for line in code.split('\n')
          if re.search(r'NotificationCenter\.default\.post|postNotificationName', line) and line.strip() not in helpers]
if direct:
    failures.append(f'{len(direct)} ROI notification(s) posted outside the helpers, e.g. {direct[0]}')

for signature, notification in (('public required init?(coder: NSCoder)', 'OsirixROIChange'),
                                ('public init!(texture tBuff:', 'OsirixROIChange'),
                                ('public init!(type itype: ToolMode, _ ipixelSpacingx', 'OsirixROIChange'),
                                ('deinit', 'OsirixRemoveROI')):
    method = body(code, signature)
    if f'postOnMainThreadOnly(.{notification})' not in method or 'postChange(' in method:
        failures.append(f'{signature} does not post {notification} on the main thread only')

if 'postChange()' not in body(code, 'func setNameValue('):
    failures.append('the name setter of ROI does not post its change through postChange')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: ROI notifications reach their observers on the main thread')
