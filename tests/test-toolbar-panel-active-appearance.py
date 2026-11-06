#!/usr/bin/env python3
"""The 2D viewer's toolbar is drawn active whenever its viewer is the key window.

The toolbar lives in a panel of its own, which hands the key status back to
the viewer and answers AppKit's question about its active appearance with the
viewer's key status. AppKit asks only when the panel's own status changes: a
viewer that took the keyboard by a click in its image left the toolbar drawn
inactive, until the toolbar or the title bar was clicked.

Checked in the sources:
- ToolBarNSWindow.refreshActiveAppearance tells the frame's views that the key
  status changed, when AppKit has that message, and marks them all for display;
- ToolbarPanelController observes every window becoming and resigning key, and
  refreshes its panel when the window is its viewer's, and only then.
- the panel ordered in for the front viewer orders out the other viewers'
  panels of its screen. They share one place: a panel that was clicked stayed
  on screen when another viewer came to the front by the Window menu or a
  click in its image, above that viewer's own toolbar, and what showed was the
  inactive toolbar of the viewer before it.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(relative):
    if revision is None:
        return (root / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, signature):
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
window = code(read('Horos/Sources/ToolBarNSWindow.swift'))
panel = code(read('Horos/Sources/ToolbarPanel.swift'))

if '@objc(_hasActiveAppearance)' not in window:
    failures.append('the panel no longer answers its active appearance with the viewer\'s key status')

refresh = block(window, 'func refreshActiveAppearance()')
if not refresh:
    failures.append('ToolBarNSWindow has no refreshActiveAppearance()')
else:
    if 'contentView?.superview' not in refresh:
        failures.append('refreshActiveAppearance does not start from the window\'s frame view')
    if 'NSSelectorFromString("_windowChangedKeyState")' not in refresh or '.responds(to:' not in refresh:
        failures.append('refreshActiveAppearance does not tell the views the key status changed, '
                        'or sends the message without asking whether AppKit has it')
    if 'needsDisplay = true' not in refresh or 'subviews' not in refresh:
        failures.append('refreshActiveAppearance does not mark the frame\'s views for display')
    if 'isVisible' in refresh:
        failures.append('refreshActiveAppearance skips a panel that is ordered in after its viewer became key')

back = block(window, 'override func orderBack(_ sender: Any?)')
others = block(window, 'func hideOtherToolbarsOfScreen()')
out = block(window, 'func orderOutLeavingFrontViewer()')
if 'hideOtherToolbarsOfScreen()' not in back:
    failures.append('the panel ordered in for the front viewer leaves the other viewers\' panels on screen')
elif back.index('hideOtherToolbarsOfScreen()') < back.index('self.order(.above'):
    failures.append('the other panels are ordered out before this one is in place')
if not all(part in others for part in ('as ToolBarNSWindow in NSApp.windows', 'other !== self', 'other.isVisible',
                                       'other.screen == self.screen', 'customizationPaletteIsRunning')):
    failures.append('the panels ordered out are not the visible panels of the other viewers of this screen, '
                    'or one being customized is not spared')
if 'super.orderOut(' not in out:
    failures.append('a panel taken out for the front viewer goes through -orderOut:, which hands the screen '
                    'back to the front viewer\'s panel')

for name in ('didBecomeKeyNotification', 'didResignKeyNotification'):
    if not re.search(r'addObserver\(self, selector: #selector\(viewerKeyStatusDidChange\(_:\)\), '
                     rf'name: NSWindow\.{name}, object: nil\)', panel):
        failures.append(f'the panel does not observe NSWindow.{name} for its viewer')

changed = block(panel, 'func viewerKeyStatusDidChange(_ aNotification: Notification?)')
if not changed:
    failures.append('the panel has no viewerKeyStatusDidChange(_:)')
else:
    if '=== viewer?.window' not in changed:
        failures.append('viewerKeyStatusDidChange does not keep to the viewer\'s window')
    if 'refreshActiveAppearance()' not in changed:
        failures.append('viewerKeyStatusDidChange does not refresh the panel')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the 2D toolbar panel is drawn again when its viewer takes or loses the keyboard')
