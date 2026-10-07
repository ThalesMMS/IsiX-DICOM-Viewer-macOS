#!/usr/bin/env python3
"""Validate Korean catalog formats and current host/preference XIB connections."""
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'Horos/Resources/ko.lproj'
VISIBLE = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
TEXT_KEYS = {'title', 'toolTip', 'NSDisplayName', 'NSNullPlaceholder',
             'NSNoSelectionPlaceholder', 'NSDisplayPattern'}
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSpn%]|%\{[^}]+\}@')


def catalog(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'tools/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def structural(node, parent=None):
    visible_text = (node.tag == 'string' and node.get('key') in TEXT_KEYS
                    or node.tag == 'string' and parent == 'objectValues')
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in VISIBLE),
            '' if visible_text else (node.text or '').strip(),
            [structural(child, node.tag) for child in node])


LITERAL_PERCENT_LABELS = {'% subtraction [0.80 ... 1.00] (default 1.00 %)',
                          'Fusion : from 0% to 100% (in 20 images)',
                          'At 100% of resolution', 'At 150% of resolution', 'At 200% of resolution'}


def check_value(original, translated):
    if original in LITERAL_PERCENT_LABELS:
        assert original.count('%') == translated.count('%'), repr(original)
        assert re.findall(r'\d+(?:\.\d+)?', original) == re.findall(r'\d+(?:\.\d+)?', translated), repr(original)
    else:
        assert Counter(FORMAT.findall(original)) == Counter(FORMAT.findall(translated)), repr(original)
    assert translated or not original, f'Empty translation: {original!r}'
    assert unicodedata.normalize('NFC', translated) == translated, f'Noncomposed Hangul: {original!r}'
    assert Counter(c for c in original if c in '\n\r\t') == Counter(c for c in translated if c in '\n\r\t'), f'Changed control escapes: {original!r}'
    assert not any(x in translated for x in ('⟦', '⟧', '\ufffd')), f'Invalid translation marker: {original!r}'


en = catalog(ROOT / 'Horos/Resources/en.lproj/Localizable.strings')
ko = catalog(TARGET / 'Localizable.strings')
assert en.keys() <= ko.keys(), 'Missing English catalog entries'
assert load_tool('collect-localized-strings').keys().keys() <= ko.keys(), 'Missing current source keys'
# Additional UI literals are identifiers, product/format labels or explicit XIB
# nonlocalized placeholders; the shared residual contract must register these.
TECHNICAL_UI = {'wado', 'HTTPS', 
    'DICOMCD', 'Pages (.pages)', 'http://www.dicom.dcm/OsiriXDB.plist',
    'ROIs:', 'BW -> RGB', '<< do not localize >>', 'OsiriX CT - 129',
    'Mail.app', 'ROI 1', '%{value1}@ im/s', 'Mail',
    '<<do not localize window title>>', 'Microsoft Word (.doc)', 'RGB ->BW',
    '<<A disc named %@ and containing %d DICOM files was mounted. THIS STRING IS JUST A PLACEHOLDER, no need to localize it.>>',
    'DICOMDIR:', 'WL/WW:', 'CLUT:', 'DICOM 1', 'URL:',
    'http://www.preferences-server.com/preferences.plist',
}
residual = load_tool('host-localization-residual')
for key, translated in ko.items():
    original = en.get(key, key)
    check_value(original, translated)
    assert re.search('[가-힣]', translated) or residual.is_residual(key, original) or key in TECHNICAL_UI, f'Untranslated text: {key!r}'
    for url in re.findall(r'https?://[^\s<>\"\']+', original):
        assert url.rstrip('.,;') in translated, f'Changed URL identifier: {key!r}'
for key in load_tool('host-localization-residual').english_comments():
    assert ko[key].isascii(), f'Non-ASCII legacy overlay: {key!r}'

sources = list((ROOT / 'Horos/Resources/en.lproj').glob('*.xib'))
sources += list((ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib'))
for source in sources:
    localized = TARGET / source.name
    original_tree = ET.parse(source).getroot()
    localized_tree = ET.parse(localized).getroot()
    assert structural(original_tree) == structural(localized_tree), f'Changed structure/actions/outlets: {source}'
    for original, translated in zip(original_tree.iter(), localized_tree.iter()):
        for attr in VISIBLE & original.attrib.keys():
            text = original.get(attr)
            expected = ko.get(text, text)
            assert translated.get(attr) == expected, f'Stale visible attribute: {source.name}: {text!r}'
        if original.tag == 'string' and original.get('key') in TEXT_KEYS:
            text = original.text or ''
            assert (translated.text or '') == ko.get(text, text), f'Stale visible text: {source.name}: {text!r}'
assert ko['Study'] == '검사'
assert ko['Series'] == '시리즈'
assert ko['Image'] == '영상'
assert ko['Cancel'] == '취소'
assert ET.parse(TARGET / 'MainMenu.xib').find('.//menuItem[@identifier="org.horos.menu.viewer"]').get('title') == '2D 뷰어'
if len(sys.argv) > 1:
    resources = Path(sys.argv[1]) / 'Contents/Resources'
    assert catalog(resources / 'ko.lproj/Localizable.strings') == ko
    for source in (ROOT / 'Horos/Resources/en.lproj').glob('*.xib'):
        assert (resources / 'ko.lproj' / source.with_suffix('.nib').name).exists(), source.name
print(f'PASS: {len(ko)} Korean entries; formats, escapes, composed Hangul, ASCII overlays; {len(sources)} current XIB structures and translations')
