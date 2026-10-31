#!/usr/bin/env python3
"""No two commands of the main menu share a default keyboard shortcut.

AppKit gives a key equivalent to the first enabled item that has it, so of two
different commands on the same shortcut one is never reached from the
keyboard. ⌥⌘G was both "WL&WW" (2D Viewer > Sync & Propagate > Propagate
Between Series) and "Group Selected ROIs" (ROI > Selection), both enabled in
a 2D viewer; "Group Selected ROIs" moved to ⇧⌥⌘G. Not ⌃⌥⌘G: with VoiceOver
on, Control-Option is its own modifier and VO-Command-G one of its commands.

A shortcut may repeat only on items that send the same action - the same
selector to the same target with the same tag, since one selector often serves
several commands told apart by tag - where the window in front decides who
handles it: "Export to DICOM Network Node…" in the File and Network menus, and
Reset / Revert in the 2D and 3D Viewer menus.

Checked in the main menu of every language, from the XIBs alone (no build):
- every default shortcut on more than one item belongs to items with one and
  the same action;
- "Group Selected ROIs" is ⇧⌥⌘G and "WL&WW" keeps ⌥⌘G.
A capital letter as key equivalent means Shift, as AppKit reads it. A key
that is not plain text (Delete, arrows, function keys) is stored in a child
<string key="keyEquivalent">, base64-encoded when base64-UTF8="YES".
"""
import base64
from collections import defaultdict
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []
GROUP_ROIS, PROPAGATE_WLWW = '12946', '13571'


def key_equivalent(item):
    """The item's key equivalent, from its attribute or from its child string."""
    key = item.get('keyEquivalent')
    if key is None:
        child = item.find("string[@key='keyEquivalent']")
        if child is not None:
            text = child.text or ''
            key = (base64.b64decode(''.join(text.split()) + '=' * (-len(''.join(text.split())) % 4)).decode('utf-8')
                   if child.get('base64-UTF8') == 'YES' else text)
    return key


def shortcuts(menu, parents, found):
    for item in menu.findall('items/menuItem'):
        key = key_equivalent(item)
        if key:
            mask = item.find('modifierMask')
            modifiers = ({name for name, value in mask.attrib.items() if value == 'YES'}
                         if mask is not None else {'command'})
            if len(key) == 1 and key.isalpha() and key.isupper():
                modifiers.add('shift')
                key = key.lower()
            action = item.find('connections/action')
            command = ((action.get('selector'), action.get('target'), item.get('tag'))
                       if action is not None else None)
            found[(key, tuple(sorted(modifiers)))].append(
                (item.get('id'), ' > '.join(parents + [item.get('title', '?')]), command))
        submenu = item.find('menu')
        if submenu is not None:
            shortcuts(submenu, parents + [item.get('title', '?')], found)


xibs = sorted((root / 'Horos/Resources').glob('*.lproj/MainMenu.xib'))
if len(xibs) < 2:
    failures.append('the localized main menus are missing: %s' % xibs)
for xib in xibs:
    language = xib.parent.name
    menus = [menu for menu in ET.parse(xib).iter('menu') if menu.get('systemMenu') == 'main']
    if len(menus) != 1:
        failures.append('%s: no single main menu' % language)
        continue
    found = defaultdict(list)
    shortcuts(menus[0], [], found)
    for (key, modifiers), items in sorted(found.items()):
        actions = {action for _, _, action in items}
        if len(items) > 1 and (len(actions) != 1 or None in actions):
            failures.append('%s: %s+%r is the default shortcut of different commands: %s' % (
                language, '+'.join(modifiers), key, '; '.join('%s (%s)' % (path, action) for _, path, action in items)))
    by_id = {identifier: combo for combo, items in found.items() for identifier, _, _ in items}
    if by_id.get(GROUP_ROIS) != ('g', ('command', 'option', 'shift')):
        failures.append('%s: Group Selected ROIs is not ⇧⌥⌘G: %s' % (language, by_id.get(GROUP_ROIS)))
    if by_id.get(PROPAGATE_WLWW) != ('g', ('command', 'option')):
        failures.append('%s: WL&WW propagation is not ⌥⌘G: %s' % (language, by_id.get(PROPAGATE_WLWW)))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: in the main menu of all %d languages a default shortcut repeats only on items with the same '
      'action, and Group Selected ROIs (⇧⌥⌘G) no longer shares ⌥⌘G with WL&WW' % len(xibs))
