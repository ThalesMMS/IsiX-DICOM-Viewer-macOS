#!/usr/bin/env python3
"""The web portal reads a study's ROIs off the main thread.

- Decoding a ROI posted OsirixROIChangeNotification and releasing it posted
  OsirixRemoveROINotification, on the thread that does it: the portal's
  connection thread, where DCMView answered with -needsDisplay. DCMView asks
  itself on the main thread, comparing the ROI by address, since it may be
  deallocated by then. ROI itself now posts on the main thread only
  (test-roi-notifications-main-thread.py).
- -validateStudyPredicate:error: fetched the portal database's Study entity
  from the DICOM database's context; the entity comes from that context.

Checked in the sources. `<git revision>` as an optional argument reads them
from that revision, the negative control. The running app is exercised,
under the Main Thread Checker, by a local validation script.
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


def exists(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:{path}'],
                              capture_output=True).returncode == 0
    return (root / path).is_file()


def method(text, signature):
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


failures = []
# These methods are Swift, in DCMView+WindowLevel.swift; a revision
# from before reads them from DCMView.m.
if exists('Horos/Sources/DCMView+WindowLevel.swift'):
    view = read('Horos/Sources/DCMView+WindowLevel.swift')
    for name in ('roiChange:', 'roiRemoved:'):
        body = method(view, f'@objc({name})')
        if not body or 'needsDisplay' in body or 'curRoiList' in body:
            failures.append(f'-[DCMView {name}] still asks the view on the notification\'s thread')
    redisplay = method(view, '@objc(redisplayForROINotification:)')
    if ('Thread.isMainThread' not in redisplay or 'DispatchQueue.main.async' not in redisplay
            or not re.search(r'UInt\(bitPattern: objcID\(note\?\.object\)\.map \{ Unmanaged\.passUnretained\(\$0\)\.toOpaque\(\) \}\)',
                             redisplay)):
        failures.append('ROI notifications are not answered on the main thread, by address')
else:
    view = read('Horos/Sources/DCMView.m')
    for name in ('roiChange:', 'roiRemoved:'):
        body = method(view, f'-(void) {name}(NSNotification*)note')
        if 'needsDisplay' in body or 'curRoiList' in body:
            failures.append(f'-[DCMView {name}] still asks the view on the notification\'s thread')
    redisplay = method(view, '- (void) redisplayForROINotification:')
    if 'isMainThread' not in redisplay or 'dispatch_get_main_queue' not in redisplay or '(uintptr_t) [note object]' not in redisplay:
        failures.append('ROI notifications are not answered on the main thread, by address')

user = read('Horos/Sources/WebPortalUser.swift')
validate = method(user, 'public func validateStudyPredicate(')
if 'webPortalUserEntity("Study", self.managedObjectContext)' in validate or 'webPortalUserEntity("Study", context)' not in validate:
    failures.append('the study predicate is still fetched with the portal database\'s Study entity')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: DCMView answers ROI notifications on the main thread; study predicates use the DICOM model')
