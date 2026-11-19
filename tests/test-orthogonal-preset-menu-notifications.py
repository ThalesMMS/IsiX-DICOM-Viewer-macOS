#!/usr/bin/env python3
"""The orthogonal viewers tell each presets menu the name of its own preset.

A window tells the others that a presets menu may have changed with one
notification for each menu - colour tables, window levels, opacity tables -
whose object is the name of the current preset of that menu. A window that
takes its current preset from the notification, as the curved reformation
window does for the window level, shows that name as the title of its menu.

The orthogonal PET-CT window, when it was made, sent the window level
notification with the name of its colour table: an open curved reformation
window then showed «No CLUT» as its window level.

Every such notification the two orthogonal viewers post must carry the name
kept for that menu: the viewer's own or that of its key view.

`<git revision>` as an optional argument reads the two viewers from that
revision: that is the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
POST = re.compile(r'\.post\(name: (?:NSNotification\.Name)?\.OsirixUpdate(CLUT|WLWW|Opacity)Menu,\s*object: ([^,]+),')
failures = []
count = {}

for name in ('OrthogonalMPRViewer', 'OrthogonalMPRPETCTViewer'):
    relative = f'Horos/Sources/{name}.swift'
    if revision is None:
        text = (root / relative).read_text(encoding='utf-8')
    else:
        text = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                       stderr=subprocess.DEVNULL).decode('utf-8')
    for match in POST.finditer(text):
        menu, value = match.group(1), match.group(2).strip()
        count[menu] = count.get(menu, 0) + 1
        if not re.search(r'\bcur%sMenu(Ivar\b|\(\))' % menu, value):
            line = text.count('\n', 0, match.start()) + 1
            failures.append(f'{relative}:{line}: the {menu} menu is told `{value}`, which is not the name of its preset')

if any(count.get(menu, 0) < 4 for menu in ('CLUT', 'WLWW', 'Opacity')):
    sys.exit(f'the notifications of the presets menus were not found: {count}')
if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: the orthogonal viewers tell each presets menu the name of its own preset ({sum(count.values())} notifications)')
