#!/usr/bin/env python3
"""A ROI tells the observers of its notifications on the main thread only.

The views and windows that observe OsirixROIChangeNotification and
OsirixRemoveROINotification run on the main thread, and the Swift ones -
DCMView and its MPR and CPR subclasses, the ROI, plot and histogram windows -
check it when the notification calls them: posted on another thread, the
check stops the application. ROIs are decoded and released on other threads:
by the web portal, by the import of a ROI SR, and at launch by the repair that
reads undated images again.

- Every post of ROI.m goes through ROIPostChange or ROIPostOnMainThreadOnly.
- ROIPostChange posts on the main thread, at once there and asynchronously from
  another thread.
- Creating, decoding and deallocating a ROI post only on the main thread.

Checked in the sources. `<git revision>` as an optional argument reads them
from that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1').replace('\r\n', '\n')


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


source = read('Horos/Sources/ROI.m')
code = '\n'.join(line for line in source.split('\n') if not line.lstrip().startswith('//'))
failures = []

change = body(code, 'static void ROIPostChange(')
if not re.search(r'if\( \[NSThread isMainThread\]\)\s*\[\[NSNotificationCenter defaultCenter\] postNotificationName: OsirixROIChangeNotification', change) \
        or 'dispatch_async( dispatch_get_main_queue()' not in change:
    failures.append('ROIPostChange does not post on the main thread, at once or asynchronously')

main_only = body(code, 'static void ROIPostOnMainThreadOnly(')
if not re.search(r'if\( \[NSThread isMainThread\]\)\s*\[\[NSNotificationCenter defaultCenter\] postNotificationName: name', main_only) \
        or 'else' in main_only or 'dispatch' in main_only:
    failures.append('ROIPostOnMainThreadOnly posts off the main thread')

helpers = change + main_only
direct = [line.strip() for line in code.split('\n')
          if re.search(r'postNotificationName:\s*Osirix(ROIChange|RemoveROI)Notification', line) and line.strip() not in helpers]
if direct:
    failures.append(f'{len(direct)} ROI notification(s) posted outside the helpers, e.g. {direct[0]}')

for signature, notification in (('- (id) initWithCoder:(NSCoder*) coder', 'OsirixROIChangeNotification'),
                                ('- (id) initWithTexture:', 'OsirixROIChangeNotification'),
                                ('- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx', 'OsirixROIChangeNotification'),
                                ('- (void) dealloc', 'OsirixRemoveROINotification')):
    method = body(code, signature)
    if f'ROIPostOnMainThreadOnly( self, {notification});' not in method or 'ROIPostChange(' in method:
        failures.append(f'{signature.split(":")[0].strip()} does not post {notification} on the main thread only')

if 'ROIPostChange( self, nil);' not in body(code, '- (void) setName:(NSString*) a'):
    failures.append('-[ROI setName:] does not post its change through ROIPostChange')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: ROI notifications reach their observers on the main thread')
