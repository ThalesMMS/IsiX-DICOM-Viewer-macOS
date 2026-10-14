#!/usr/bin/env python3
"""The Activity bar fills while its thread's progress is known.

A user's DICOMweb retrieve showed "299/2,769" … "2,716/2,769" beside a bar that
only swept from side to side. The cell had one bar: it started its sweep
while the thread had no total and, once it had one, stopped it and made the
bar determinate - and AppKit, depending on when the sweep had started, kept
the indeterminate animation on the bar's layers, so the bar swept while its
value, read back, followed the count. The same happens outside the app.

Now each row has two bars, one shown at a time: a determinate one that never
animates, with the thread's value, and a sweeping one while the progress is
unknown. One method shows the one of the thread's state, read from the
thread, not the notification; the cell calls it on each progress
notification and when it adds the bars, and the activity list calls it for
every cell twice a second, as the Dock's sector reads its threads. Both bars
have one frame, the cell's.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cell = (root / 'Horos/Sources/ThreadCell.swift').read_text(encoding='utf-8')
helper = (root / 'Horos/Sources/BrowserController+Activity.swift').read_text(encoding='utf-8')
failures = []

sync = re.search(r'@objc public func syncProgressIndicator\(\) \{(.*?)\n    \}\n', cell, re.S)
if not sync:
    failures.append('ThreadCell has no syncProgressIndicator')
else:
    body = sync.group(1)
    known, unknown = body.find('if thread.progress >= 0'), body.find('} else {')
    if not (0 <= known < unknown):
        failures.append('the bar is not chosen by whether the progress is known')
    else:
        shown, hidden = body[known:unknown], body[unknown:]
        for needed in ('Double(thread.subthreadsAwareProgress)', 'bar.isHidden = false', 'sweep.stopAnimation(self)', 'sweep.isHidden = true'):
            if needed not in shown:
                failures.append('known progress does not do: ' + needed)
        for needed in ('bar.isHidden = true', 'sweep.isHidden = false', 'sweep.startAnimation(self)'):
            if needed not in hidden:
                failures.append('unknown progress does not do: ' + needed)
        if 'bar.startAnimation' in body or 'bar.isIndeterminate' in body:
            failures.append('the determinate bar is animated or switched')
init = cell[cell.index('public init(thread: Thread!'):]
init = init[:init.index('\n    }\n')]
if 'progressIndicator.isIndeterminate = false' not in init or 'sweepIndicator.isIndeterminate = true' not in init:
    failures.append('the two bars are not made determinate and sweeping once, at creation')
if 'retainShared(cell._sweepIndicator, _sweepIndicator)' not in cell:
    failures.append('a copy of the cell does not share the sweeping bar')
if '_sweepIndicator?.removeFromSuperview()' not in cell:
    failures.append('cleanup leaves the sweeping bar in the table')

change = cell[cell.index('private func threadDidChange'):]
change = change[:change.index('\n    }\n')]
if not re.search(r'keyPath == NSThreadProgressKey \{\s*syncProgressIndicator\(\)', change):
    failures.append('a progress notification does not sync the bar')
if not re.search(r'for bar in \[_progressIndicator, _sweepIndicator\]\.compactMap\(\{ \$0 \}\) where bar\.superview == nil \{\s*view\.addSubview\(bar\)', cell) \
        or not re.search(r'if added \{.*?syncProgressIndicator\(\)', cell, re.S):
    failures.append('adding the bars does not show the one of the thread\'s state')
if not re.search(r'for bar in \[_progressIndicator, _sweepIndicator\]\.compactMap\(\{ \$0 \}\) where !NSEqualRects\(bar\.frame, progressFrame\)', cell):
    failures.append('the two bars do not share the cell\'s frame')

if not re.search(r'Timer\(timeInterval: DockProgress\.interval, repeats: true\).*?self\?\.syncProgressIndicators\(\)', helper, re.S):
    failures.append('the activity list does not read the bars on the Dock\'s clock')
if not re.search(r'for case let cell as ThreadCell in _cells \{ cell\.syncProgressIndicator\(\) \}', helper):
    failures.append('the clock does not sync every cell')
if 'progressFrame' in helper:
    failures.append('the list still places the bar in a frame of its own')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a never-animated determinate bar or a sweeping one, chosen from the thread on notifications, on adding and twice a second')
