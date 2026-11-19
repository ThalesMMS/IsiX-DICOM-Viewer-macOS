#!/usr/bin/env python3
"""Validate Italian formats, current nib structure, and optional built resources."""
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
def strings(path):
    return json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
en=strings(root/'Horos/Resources/en.lproj/Localizable.strings')
it=strings(root/'Horos/Resources/it-IT.lproj/Localizable.strings')
assert en.keys()<=it.keys(), 'Catalog keys must contain the current English catalog'
fmt=re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSpn%]')
# Labels of the Viewers settings and of the 2D viewer with a literal percentage, not a format: the number and the sign stay.
literal_percent={'At 100% of resolution','At 150% of resolution','At 200% of resolution',
                 '% subtraction [0.80 ... 1.00] (default 1.00 %)','Fusion : from 0% to 100% (in 20 images)'}
for key in it:
    original=en.get(key,key)
    if key in literal_percent:
        assert re.findall(r'\d+',original)==re.findall(r'\d+',it[key]) and it[key].count('%')==original.count('%'),repr(key)
        continue
    assert Counter(fmt.findall(original))==Counter(fmt.findall(it[key])),repr(key)
    assert it[key] or not original, f'Unexpected empty translation: {key}'
subprocess.run([sys.executable,str(root/'tools/localize-main-menu.py'),'--check'],check=True)
visible={'title','label','toolTip','placeholderString','alternateTitle','stringValue'}
# The string elements the generator translates: long titles and tooltips, and what a binding shows.
visible_strings=visible|{'NSDisplayName','NSDisplayPattern','NSNullPlaceholder','NSNoSelectionPlaceholder'}
def structural(node):
    text='' if node.tag=='string' and node.get('key') in visible_strings else (node.text or '').strip()
    return (node.tag, sorted((k,v) for k,v in node.attrib.items() if k not in visible),
            text, [structural(child) for child in node])
en_tree=ET.parse(root/'Horos/Resources/en.lproj/MainMenu.xib').getroot()
it_tree=ET.parse(root/'Horos/Resources/it-IT.lproj/MainMenu.xib').getroot()
assert structural(en_tree)==structural(it_tree), 'Localization changed nib structure/connections'
assert it_tree.find('.//menuItem[@identifier="org.horos.menu.viewer"]').get('title')=='Vista 2D'
if len(sys.argv)>1:
    resources=Path(sys.argv[1])/'Contents/Resources'
    assert (resources/'it-IT.lproj/MainMenu.nib').exists()
    assert strings(resources/'it-IT.lproj/Localizable.strings')==it
print(f'PASS: {len(it)} catalog keys, format arguments, regenerated menu, unchanged non-text nib structure'+('; built Italian resources' if len(sys.argv)>1 else ''))
