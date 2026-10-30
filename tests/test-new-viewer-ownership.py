#!/usr/bin/env python3
"""Who keeps a viewer opened by +[ViewerController newWindow:::].

newWindow::: hands over the +1 of the viewer's alloc, and the viewer releases
itself when its window closes. The selector is in the new family, so Swift
takes that +1 over and releases it when the result goes out of use: a Swift
caller that does not keep it leaves the viewer released twice, and closing
its window crashes. Every Swift call through the imported method must
therefore hand the viewer back with Unmanaged.passRetained, as the former
Objective-C, which never released it, left it.

Callers that go through the method's implementation with an Unmanaged result
(takeUnretainedValue) do not take the +1 over and need nothing, and neither
do the newWindow::: variants that answer one another's viewer.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
call = re.compile(r'(?<![\w"])(?:ViewerController\.|self\.|\b)newWindow\(')

failures = []
calls = 0
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    lines = path.read_text().splitlines()
    for number, line in enumerate(lines):
        code = line.split('//', 1)[0]
        if not call.search(code) or 'func newWindow' in code:
            continue
        # One newWindow::: variant answering another hands the +1 on to its caller.
        if code.strip().startswith('return '):
            continue
        calls += 1
        window = '\n'.join(lines[number:number + 4])
        # A viewer assigned to a name may be kept once after the branches that
        # make it: Unmanaged.passRetained(name) within the next lines.
        assigned = re.match(r'\s*(?:let\s+|var\s+)?(\w+)\s*=', code)
        kept_later = bool(assigned) and f'Unmanaged.passRetained({assigned.group(1)})' in '\n'.join(lines[number:number + 20])
        if 'Unmanaged.passRetained' not in window and not kept_later:
            failures.append(f'{path.relative_to(root)}:{number + 1}: the viewer from newWindow is not kept')

if calls == 0:
    failures.append('no Swift call of newWindow found: the check no longer looks at anything')
for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'ok ({calls} calls)')
