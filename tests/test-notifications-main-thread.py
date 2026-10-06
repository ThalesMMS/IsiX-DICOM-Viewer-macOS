#!/usr/bin/env python3
"""Notifications posted off the main thread reach their observers there.

Swift stops a main-actor method - a viewer's, the browser's, a window's - that
a notification calls off the main thread. These posters run on other threads,
so they post on the main thread:

- RetrieveViewing.notify, whose state changes on transfer, import and viewer
  threads (observed by ViewerController.retrieveViewingStateChanged:).
- The refresh notifications of DicomDatabase cleaning, which also runs on the
  import thread of the incoming folder (observed by the browser and viewers).
- DCMNetServicesDidChange of DICOMNodeService, posted from NetService
  callbacks (observed by the send window).

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
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text()


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


def posts_on_main(function):
    return 'Thread.isMainThread' in function and ('DispatchQueue.main.async' in function or 'postNotificationOnMainThread' in function)


failures = []

viewing = read('Horos/Sources/RetrieveViewing.swift')
if not posts_on_main(body(viewing, 'private func notify(')):
    failures.append('RetrieveViewing.notify posts on the calling thread')

clean = read('Horos/Sources/DicomDatabase+Clean.swift')
direct = re.findall(r'NotificationCenter\.default\.post\(name: \.(?:_O2AddToDBAnyway|_O2AddToDBAnywayComplete|OsirixAddToDB|OsirixAddToDBComplete)\b', clean)
if direct:
    failures.append(f'DicomDatabase cleaning posts {len(direct)} refresh notification(s) on the calling thread')
refresh = body(clean, 'func postDatabaseRefreshNotifications(')
if not posts_on_main(refresh) or clean.count('self.postDatabaseRefreshNotifications()') < 2:
    failures.append('DicomDatabase cleaning does not post its refresh notifications on the main thread')

node = read('Horos/Sources/DICOMNodeService.swift')
if re.search(r'NotificationCenter\.default\.post\(name: Notification\.Name\("DCMNetServicesDidChange"\)', node.replace(body(node, 'private static func postServicesDidChange('), '')):
    failures.append('DICOMNodeService posts DCMNetServicesDidChange on the calling thread')
if not posts_on_main(body(node, 'private static func postServicesDidChange(')):
    failures.append('DICOMNodeService does not post DCMNetServicesDidChange on the main thread')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: these notifications reach their observers on the main thread')
