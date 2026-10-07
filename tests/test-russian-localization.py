#!/usr/bin/env python3
"""Check Russian catalogs and the current host/preference interfaces."""
from collections import Counter
import base64
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
TARGET = RESOURCES / 'ru.lproj'
VISIBLE = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
TEXT_KEYS = VISIBLE | {'NSContents', 'NS.string', 'NSDisplayName', 'NSNullPlaceholder',
                      'NSNoSelectionPlaceholder', 'NSDisplayPattern'}
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?'
                    r'(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSpn%]|%\{value\d+\}@')


def catalog(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def is_text(node, parent):
    return node.tag == 'string' and (node.get('key') in TEXT_KEYS or parent == 'objectValues')


def value(node):
    text = node.text or ''
    if node.get('base64-UTF8') == 'YES':
        stripped = text.strip()
        return base64.b64decode(stripped + '=' * (-len(stripped) % 4)).decode('utf-8')
    return text


def structural(node, parent=None):
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in VISIBLE),
            '' if is_text(node, parent) else (node.text or '').strip(),
            [structural(child, node.tag) for child in node])


def compare_text(source, target, path, parent=None):
    for key in VISIBLE & source.attrib.keys():
        original = source.get(key)
        assert target.get(key) == (ru[original] if original else ''), (path, key, original)
    if is_text(source, parent) and source.text:
        original = value(source)
        assert value(target) == ru[original], (path, original)
    for a, b in zip(source, target):
        compare_text(a, b, path, source.tag)


en = catalog(RESOURCES / 'en.lproj/Localizable.strings')
ru = catalog(TARGET / 'Localizable.strings')
assert en.keys() <= ru.keys(), 'Russian must cover the complete English catalog'
source_keys = module('ru_source_keys', 'collect-localized-strings.py').keys()
assert source_keys.keys() <= ru.keys(), 'Russian must cover the current source keys'
LITERAL_PERCENT_LABELS = {'At 100% of resolution', 'At 150% of resolution',
                          'At 200% of resolution'}
for key, translated in ru.items():
    original = en.get(key, key)
    assert translated or not original, f'Empty translation: {key!r}'
    if key == '% subtraction [0.80 ... 1.00] (default 1.00 %)':
        # XIB label contains literal percentage signs, not the accidental '% s' printf match.
        assert translated.count('%') == original.count('%')
    elif key in LITERAL_PERCENT_LABELS:
        assert translated.count('%') == original.count('%'), key
        assert re.findall(r'\d+', original) == re.findall(r'\d+', translated), key
    else:
        assert Counter(FORMAT.findall(original)) == Counter(FORMAT.findall(translated)), key
    assert all(original.count(c) == translated.count(c) for c in ('\n', '\r', '\t', '\u2028')), f'Changed escapes: {key!r}'
    assert '⁇' not in translated and '�' not in translated, f'Broken glyph: {key!r}'
    assert not re.search(r'ZXQ|<fmt\d+>', translated), f'Unrestored parameter marker: {key!r}'
residual = module('ru_residual', 'host-localization-residual.py')
# Extra interface-only technical tokens; shared residual-contract integration is pending.
UI_TECHNICAL = {'wado', 
    'ContentTime (0008,0033)', 'mm:\t\tx:0 y:0 z:0', 'px:\t\tx:0 y:0 z:0', 'dd/bb/cc',
    'Pages (.pages)', 'AETitle', 'AETitleValue', 'TextEdit (.rtf)', 'WL/WW', 'WL/WW:',
    '3D VR', '3D MPR', 'OsiriX CT - 129', 'Mail.app', 'ROI 1', 'CLUT:', 'TRUEPREDICATE',
    'UTF8 (Unicode): ISO_IR 192', 'SQL', 'Microsoft Word (.doc)', 'LibreOffice (.odt)',
    'RGB ->BW', 'HTTPS', 'TLS', 'DICOM 1', 'DICOMDIR:', 'URL:', 'www.horosproject.org',
    'http://www.dicom.dcm/OsiriXDB.plist', 'http://www.dicom.dcm/dicomNodes.plist',
    'http://www.preferences-server.com/preferences.plist',
}
for key, translated in ru.items():
    original = en.get(key, key)
    if translated == original:
        assert key in UI_TECHNICAL or residual.is_residual(key, original), f'Untranslated text: {key!r}'
for key in residual.english_comments():
    assert ru[key].isascii(), f'Legacy ASCII overlay: {key!r}'
paths = list((RESOURCES / 'en.lproj').glob('*.xib'))
paths += list((ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib'))
assert {p.name for p in paths} == {p.name for p in TARGET.glob('*.xib')}, 'Missing/stale XIBs'
for path in paths:
    source = ET.parse(path).getroot()
    target = ET.parse(TARGET / path.name).getroot()
    assert structural(source) == structural(target), f'Changed connections or control structure: {path.name}'
    compare_text(source, target, path.name)
menu = ET.parse(TARGET / 'MainMenu.xib')
assert menu.find('.//menuItem[@identifier="org.horos.menu.viewer"]').get('title') == 'Просмотр 2D'
assert ru['Cancel'] == 'Отмена'
assert ru['Database'] == 'База данных'
assert ru['%d series'] == 'Серий: %d', 'Use a count-neutral label rather than a singular noun'
if len(sys.argv) > 1:
    bundle = Path(sys.argv[1]) / 'Contents/Resources/ru.lproj'
    assert catalog(bundle / 'Localizable.strings') == ru
    assert all((bundle / path.with_suffix('.nib').name).exists() for path in paths)
print(f'PASS: {len(ru)} keys, {len(source_keys)} source keys, formats, ASCII overlays, '
      f'{len(paths)} current XIBs and unchanged actions/outlets/shortcuts'
      + ('; built bundle resources' if len(sys.argv) > 1 else '; bundle/app validation pending'))
