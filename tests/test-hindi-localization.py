#!/usr/bin/env python3
"""Validate Hindi catalog and UI resources against current English sources."""
import base64
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
target = resources / 'hi.lproj'

def strings(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

en = strings(resources / 'en.lproj/Localizable.strings')
hi = strings(target / 'Localizable.strings')
assert en.keys() <= hi.keys(), 'Hindi must cover every English catalog key'
for collector in ('collect-localized-strings.py', 'collect-menu-strings.py'):
    subprocess.run([sys.executable, str(root / 'tools' / collector),
                    '--check', '--language', 'hi'], check=True)
spec = importlib.util.spec_from_file_location('residual', root / 'tools/host-localization-residual.py')
residual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(residual)
literal_percent = {'At 100% of resolution', 'At 150% of resolution', 'At 200% of resolution'}
for key, value in hi.items():
    original = en.get(key, key)
    if key in literal_percent:
        # Resolution labels contain percentages; "% of" is not a printf argument.
        assert Counter(re.findall(r'\d+%', original)) == Counter(re.findall(r'\d+%', value)), repr(key)
    else:
        assert Counter(residual.FORMAT.findall(original)) == Counter(residual.FORMAT.findall(value)), repr(key)
    assert value or not original, f'Empty translation: {key!r}'
for key, original in en.items():
    assert hi[key] != original or residual.is_residual(key, original), f'Untranslated Hindi key: {key!r}'
    assert all(original.count(c) == hi[key].count(c) for c in '\r\n\t'), f'Changed control escapes: {key!r}'

visible = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
textkeys = visible | {'NSDisplayName', 'NSNullPlaceholder', 'NSNoSelectionPlaceholder', 'NSDisplayPattern'}

def structural(node):
    text = '' if node.tag == 'string' and node.get('key') in textkeys else (node.text or '').strip()
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in visible),
            text, [structural(child) for child in node])

sources = list((resources / 'en.lproj').glob('*.xib'))
sources += list((root / 'Preference Panes').glob('*/Base.lproj/*.xib'))
assert len({p.name for p in sources}) == len(sources), 'Resource names must remain unique'
for source in sources:
    english = ET.parse(source).getroot()
    hindi = ET.parse(target / source.name).getroot()
    assert structural(english) == structural(hindi), f'Connections or non-text structure changed: {source}'
    for a, b in zip(english.iter(), hindi.iter()):
        for key in visible & a.attrib.keys():
            assert b.get(key) == hi.get(a.get(key), a.get(key)), (source, a.get('id'), key)
        if a.tag == 'string' and a.get('key') in textkeys and a.text:
            def decoded(n):
                if n.get('base64-UTF8') != 'YES':return n.text
                raw=''.join(n.text.split())
                return base64.b64decode(raw+'='*((-len(raw))%4)).decode()
            assert decoded(b) == hi.get(decoded(a), decoded(a)), (source, a.get('key'))
            assert Counter(re.findall(r'%\{[^}]+\}@', a.text)) == Counter(re.findall(r'%\{[^}]+\}@', b.text or ''))

# One word for a term, the Viewers pane's: to propagate is प्रसार (प्रचार is publicity), a modality is मोडैलिटी
# (not a means or a manner), a viewer is व्यूअर (दर्शक is a spectator).
for key, value in hi.items():
    assert 'प्रचा' not in value and 'दर्शक' not in value, f'Wrong Hindi term in {key!r}: {value!r}'
    assert not (re.search('odalit', key, re.I) and re.search('साधन|तौर-तरीक', value)), f'Modality in {key!r}: {value!r}'
assert hi['Modality'] == 'मोडैलिटी' and hi['Propagate'] == 'प्रसार'
assert hi['Cancel'] == 'रद्द करें'
assert hi['Database'] == 'डेटाबेस'
assert hi['2D Viewer'] == '2D व्यूअर'
assert any('\u0900' <= c <= '\u097f' for c in hi['Preferences'])
if len(sys.argv) > 1:
    built = Path(sys.argv[1]) / 'Contents/Resources/hi.lproj'
    assert (built / 'MainMenu.nib').exists()
    assert strings(built / 'Localizable.strings') == hi
print(f'PASS: {len(hi)} Hindi keys; formats, and {len(sources)} current XIBs with preserved structure')
