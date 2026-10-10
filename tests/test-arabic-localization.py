#!/usr/bin/env python3
"""Arabic catalog coverage, formats and English-derived interface wiring."""
from collections import Counter
import base64
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
folder = root / 'Horos/Resources/ar.lproj'
spec = importlib.util.spec_from_file_location('residual', root / 'tools/host-localization-residual.py')
residual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(residual)

# Renderer samples, format names, URLs and stored identifiers remain literal.
TECHNICAL_UI = {'wado', 'HTTPS', 
    'Angle: %2.1f degrees ',
    'DICOM 1',
    'DICOMDIR:',
    'LibreOffice (.odt)',
    'Microsoft Word (.doc)',
    'OsiriX CT - 129',
    'RLE',
    'SQL',
    'TRUEPREDICATE',
    'UTF8 (Unicode): ISO_IR 192',
    'dd/bb/cc',
    'http://www.dicom.dcm/OsiriXDB.plist',
    'http://www.dicom.dcm/dicomNodes.plist',
    'http://www.preferences-server.com/preferences.plist',
    'mm:\t\tx:0 y:0 z:0',
    'px:\t\tx:0 y:0 z:0',
    'value:\t0',
    'github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS',
}

def catalog(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

english = catalog(root / 'Horos/Resources/en.lproj/Localizable.strings')
arabic = catalog(folder / 'Localizable.strings')
assert english.keys() <= arabic.keys(), 'Missing English catalog keys'
LITERAL_PERCENT_LABELS = {'At 100% of resolution', 'At 150% of resolution',
                          'At 200% of resolution'}
for key, value in arabic.items():
    source = english.get(key, key)
    if key in LITERAL_PERCENT_LABELS:
        assert source.count('%') == value.count('%'), key
        assert re.findall(r'\d+', source) == re.findall(r'\d+', value), key
    else:
        assert Counter(residual.FORMAT.findall(source)) == Counter(residual.FORMAT.findall(value)), key
    assert Counter(re.findall(r'%\{[^}]+\}@', source)) == Counter(re.findall(r'%\{[^}]+\}@', value)), f'Changed binding pattern: {key}'
    assert value or not source, key
    assert '\ufffd' not in value and not re.search(r'[\ufb50-\ufdff\ufe70-\ufeff]', value), f'Broken/non-contextual Arabic: {key}'
    assert value.count('\u2068') == value.count('\u2069'), f'Unbalanced bidi isolates: {key}'
    assert all(source.count(c) == value.count(c) for c in '\n\r\t'), f'Changed whitespace escape: {key}'
    assert not re.search(r'ZXQ\d+QXZ', value), key
    assert value != source or key in TECHNICAL_UI or residual.is_residual(key, source), f'Untranslated: {key}'
for key in residual.english_comments() + ['Angle: %2.1f degrees ']:
    assert arabic[key].isascii(), f'Legacy ASCII overlay: {key}'

visible = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
textkeys = {'title', 'toolTip', 'NSDisplayName', 'NSNullPlaceholder', 'NSNoSelectionPlaceholder', 'NSDisplayPattern', 'content'}
def structure(node):
    text = '' if node.tag in {'string', 'mutableString'} and node.get('key') in textkeys else (node.text or '').strip()
    return node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in visible), text, [structure(n) for n in node]

sources = list((root / 'Horos/Resources/en.lproj').glob('*.xib')) + list((root / 'Preference Panes').glob('*/Base.lproj/*.xib'))
for path in sources:
    original = ET.parse(path).getroot()
    translated = ET.parse(folder / path.name).getroot()
    assert structure(original) == structure(translated), f'Changed wiring/geometry: {path.name}'
    for en, ar in zip(original.iter(), translated.iter()):
        for attribute in visible:
            if en.get(attribute) is not None:
                text = en.get(attribute)
                assert not text or text in arabic, (path.name, attribute, text)
                assert ar.get(attribute) == (arabic[text] if text else ''), (path.name, attribute, text)
        if en.tag in {'string', 'mutableString'} and en.get('key') in textkeys and en.text:
            def decoded(node):
                if node.get('base64-UTF8') == 'YES':
                    text=''.join(node.text.split())
                    return base64.b64decode(text+'='*((-len(text))%4)).decode('utf8')
                return node.text
            assert decoded(ar) == arabic[decoded(en)], (path.name, en.text)
assert arabic['Cancel'] == 'إلغاء'
assert arabic['File'] == 'ملف'
assert arabic['Database'] == 'قاعدة البيانات'
for collector in ('collect-localized-strings.py', 'collect-menu-strings.py'):
    subprocess.run([sys.executable, str(root / 'tools' / collector), '--check', '--language', 'ar'], check=True)

print(f'PASS: {len(arabic)} Arabic entries; formats, residuals, ASCII overlays; {len(sources)} XIBs preserve wiring and geometry. RTL rendering and fluent review require app validation.')
