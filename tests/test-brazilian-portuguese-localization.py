#!/usr/bin/env python3
"""Check pt-BR catalog, current XIB text coverage and preserved UI connections.

Technical validation only; does not claim a fluent review or functional app QA.
Preference controllers are compiled into the host. Their translated XIBs live
directly inside its locale folder so Xcode packages localized host nibs.
"""
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
locale = root / 'Horos/Resources/pt-BR.lproj'
def load_catalog(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, root / f'tools/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

en = load_catalog(root / 'Horos/Resources/en.lproj/Localizable.strings')
pt = load_catalog(locale / 'Localizable.strings')
residual = load_tool('host-localization-residual')
assert en.keys() <= pt.keys(), 'English catalog coverage'
assert load_tool('collect-localized-strings').keys().keys() <= pt.keys(), 'Live source coverage'
assert load_tool('collect-menu-strings').titles().keys() <= pt.keys(), 'Dynamic menu coverage'
fmt = re.compile(r'%\{[^}]+\}@|%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSpn%]')
# These UI labels contain literal percentages, not printf arguments. The old
# regex mistakes English "% of", "% to" and "% subtraction" for formats.
literal_percent = {
    'At 100% of resolution', 'At 150% of resolution', 'At 200% of resolution',
    'Fusion : from 0% to 100% (in 20 images)',
    '% subtraction [0.80 ... 1.00] (default 1.00 %)',
}
# Portuguese cognates, units, product/protocol names, internal sentinels and
# dummy IB sample values. English exceptions already belong to the shared
# host contract. This list only accounts for additional current XIB texts.
ui_same = {
    'WL: WW:', 'WL/WW', 'WL/WW:', 'dd/bb/cc', '10 im/s', '10 im/s\n', '60 im/s',
    'TRUEPREDICATE', 'Oval ', 'Oval', '%{value1}@ im/s', 'DICOMCD',
    'asdasdasdqq', 'Item 2', 'Spline', 'ROI 1', 'SQL', 'CLUT:', 'Pos:',
    'Volume', 'Volume (cm3)', 'volume', 'Plug-in:', 'mmm', 'Delaunay',
    'BILINEAR', 'RGB ->BW', 'URL:', 'Soundex', 'DICOMDIR:', 'asdasd',
    'github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS', 'UTF8 (Unicode): ISO_IR 192',
    'http://www.dicom.dcm/dicomNodes.plist',
    'http://www.dicom.dcm/OsiriXDB.plist', 'TLS', 'wado', 'HTTPS',
    'AETitleValue', 'RLE', 'DICOM 1', 'LibreOffice (.odt)',
    'Microsoft Word (.doc)', 'Pages (.pages)', 'pixels',
    'http://www.preferences-server.com/preferences.plist', 'Mail.app',
    '<<do not localize window title>>', 'px:\t\tx:0 y:0 z:0',
    'mm:\t\tx:0 y:0 z:0',
}
for key, translated in pt.items():
    original = en.get(key, key)
    assert translated or not original, f'Empty translation: {key!r}'
    if key in literal_percent:
        assert original.count('%') == translated.count('%'), key
    else:
        assert Counter(fmt.findall(original)) == Counter(fmt.findall(translated)), f'Formats: {key!r}'
    assert Counter(c for c in original if c in '\n\r\t') == Counter(c for c in translated if c in '\n\r\t'), f'Escapes: {key!r}'
    if translated == original:
        assert residual.is_residual(key, original) or key in ui_same, f'Untranslated: {key!r}'
for key in residual.english_comments():
    assert pt[key].isascii(), f'ASCII overlay: {key!r}'

visible = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
text_keys = visible | {'NSDisplayName', 'NSDisplayPattern', 'NSNullPlaceholder', 'NSNoSelectionPlaceholder'}
def is_text(node):
    return node.tag == 'string' and node.get('key') in text_keys
def structural(node):
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in visible),
            '' if is_text(node) else (node.text or '').strip(),
            [structural(child) for child in node])
def string_text(node):
    value = node.text or ''
    if node.get('base64-UTF8') == 'YES':
        value = value.strip()
        return base64.b64decode(value + '=' * (-len(value) % 4)).decode('utf-8')
    return value

sources = sorted((root / 'Horos/Resources/en.lproj').glob('*.xib'))
sources += sorted((root / 'Preference Panes').glob('*/Base.lproj/*.xib'))
for source in sources:
    target = locale / source.name
    assert target.exists(), source
    original_tree, translated_tree = ET.parse(source).getroot(), ET.parse(target).getroot()
    assert structural(original_tree) == structural(translated_tree), f'UI connections or structure: {source}'
    for original, translated in zip(original_tree.iter(), translated_tree.iter()):
        for attr in visible:
            if attr in original.attrib:
                text = original.get(attr)
                assert text in pt or not text, (source, text)
                assert translated.get(attr) == pt.get(text, text), (source, attr, text)
        if is_text(original):
            text = string_text(original)
            assert text in pt or not text, (source, text)
            assert string_text(translated) == pt.get(text, text), (source, text)
menu = ET.parse(locale / 'MainMenu.xib').getroot()
assert menu.find('.//menuItem[@identifier="org.horos.menu.viewer"]').get('title') == 'Visualizador 2D'
if len(sys.argv) > 1:
    resources = Path(sys.argv[1]) / 'Contents/Resources'
    assert load_catalog(resources / 'pt-BR.lproj/Localizable.strings') == pt
    for source in sources:
        assert (resources / 'pt-BR.lproj' / (source.stem + '.nib')).exists(), source.stem
print(f'PASS: {len(pt)} entries, formats, escapes, ASCII, source/menu coverage, and {len(sources)} current XIBs with preserved connections; app QA and compiled host-bundle lookup still require integration.')
