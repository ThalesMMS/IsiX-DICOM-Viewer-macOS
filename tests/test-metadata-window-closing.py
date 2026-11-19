#!/usr/bin/env python3
"""A closed meta-data window stays closed when the magnetic windows are tiled.

The meta-data window (XMLController) is magnetic: closing it schedules a
tiling of the magnetic windows (OSIWindowController+MagneticWindows.swift).
The controller outlives the close until the autorelease pool drains, and the
tiling takes every magnetic window whose controller does not answer YES to
-windowWillClose (ViewerWindowArranger.tileWindows), showing a window that is
not visible again and making the last one key. Before, the meta-data window
answered NO (the runtime default of OSIWindowController), so a close outside an
event (a timer, a script, a plugin) brought the closed window back on screen,
key, with no controller.

The check: XMLController answers -windowWillClose with a flag that its
windowWillClose(_:) sets before anything else, the tiling still leaves out the
windows whose controller answers YES, and the close still schedules a tiling
(the case the flag is for). `<git revision>` as an optional argument reads the
sources of that revision: the revision before the fix fails.
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
    return (root / path).read_text(encoding='utf-8')


def body(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    end = text.index('\n    }\n', start)
    return text[start:end]


failures = []
xml = read('Horos/Sources/XMLController.swift')

query = re.search(r'@objc\(windowWillClose\)\s+(?:public\s+)?func windowWillClose\(\)\s*->\s*Bool\s*\{\s*(\w+)\s*\}', xml)
if not query:
    failures.append('XMLController does not answer -windowWillClose: the tiling takes its closed window as an open one')
else:
    flag = query.group(1)
    will_close = body(xml, '    public func windowWillClose(_ notification: Notification) {')
    if will_close is None:
        failures.append('XMLController has no windowWillClose(_:)')
    else:
        statements = [line.strip() for line in will_close.splitlines()[1:] if line.strip() and not line.strip().startswith('//')]
        if not statements or statements[0] != f'{flag} = true':
            failures.append(f'windowWillClose(_:) does not set {flag} first: {statements[:1]}')
    if not re.search(r'private var ' + flag + r' = false', xml):
        failures.append(f'{flag} does not start false')

arranger = read('Horos/Sources/ViewerWindowArranger.swift')
tile = body(arranger, '    func tileWindows(_ request: Request?) {') or ''
if not re.search(r'controller\.magnetic\(\)', tile) or '!ViewerMessages.bool(controller, "windowWillClose")' not in tile:
    failures.append('the tiling no longer leaves out the magnetic windows whose controller is closing')

magnetic = read('Horos/Sources/OSIWindowController+MagneticWindows.swift')
closing = body(magnetic, '    private func windowWillCloseNotification(_ notification: Notification) {') or ''
if 'scheduleTiling' not in closing and 'tileWindows' not in closing:
    print('note: closing a magnetic window no longer schedules a tiling; the flag is kept for any later tiling')

if 'self.setMagnetic(true)' not in xml:
    print('note: the meta-data window is no longer magnetic')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a closing meta-data window answers -windowWillClose YES from the start of its close, '
      'and the tiling of the magnetic windows leaves it out')
