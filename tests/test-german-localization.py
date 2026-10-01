#!/usr/bin/env python3
"""German catalog coverage, formats and current interface wiring (#990)."""
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
TARGET = RESOURCES / 'de.lproj'
VISIBLE = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue'}
TEXT_KEYS = {'title', 'toolTip', 'NSDisplayName', 'NSDisplayPattern',
             'NSNullPlaceholder', 'NSNoSelectionPlaceholder', 'content'}


def load(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


catalog = load(TARGET / 'Localizable.strings')
english = load(RESOURCES / 'en.lproj/Localizable.strings')
residual = module('residual', ROOT / 'tools/host-localization-residual.py')
collector = module('collector', ROOT / 'tools/collect-localized-strings.py')
assert english.keys() <= catalog.keys(), 'Missing English catalog keys'
assert collector.keys().keys() <= catalog.keys(), 'Missing live source keys'
# Percent signs in these fixed XIB labels are literal percentages, not printf.
LITERAL_PERCENTAGES = {'% subtraction [0.80 ... 1.00] (default 1.00 %)',
                      'Fusion : from 0% to 100% (in 20 images)',
                      'At 100% of resolution', 'At 150% of resolution', 'At 200% of resolution'}
for key, value in catalog.items():
    original = english.get(key, key)
    assert value or not original, f'Empty translation: {key}'
    if key not in LITERAL_PERCENTAGES:
        assert Counter(residual.FORMAT.findall(original)) == Counter(residual.FORMAT.findall(value)), key
    else:
        assert original.count('%') == value.count('%'), key
    assert Counter(re.findall(r'%\{value\d+\}@', original)) == Counter(re.findall(r'%\{value\d+\}@', value)), key
for key in residual.english_comments():
    assert catalog[key].isascii(), f'Non-ASCII overlay: {key}'

# German words that are spelled identically to English; these are translations,
# not English fallback. Technical tokens and UI sample/format strings follow.
IDENTICAL_GERMAN = set('''April August November September Dilatation Erosion Element Engine Filter
Format Fusion Global Index Info Interpolation Linear Mail Matrix Medium Name Navigation Navigator
Oval Parallel Patient Polygon Port Radio Radius Rate Region Renderer Sagittal Schema Score Spline
Standard Status Syntax Tag Test Text Threads Upgrade Version Plugins'''.split())
EXTRA_TECHNICAL = {'3D MIP', '3D MPR', '3D SR', '3D VR', 'BILINEAR', 'Power Crust',
                  'Delaunay', 'Papyrus', 'Soundex', 'JPEG Baseline', 'JPEG Extended', 'RLE', 'HTTPS', 'TLS',
                  'UTF8 (Unicode): ISO_IR 192', 'AcquisitionTime (0008,0032)', 'ContentTime (0008,0033)',
                  'SeriesTime (0008,0031)', 'StudyTime (0008,0030)', 'AETitleValue', 'PortValue',
                  'TRUEPREDICATE', 'localizer, scout', 'dd/bb/cc', 'mmm', 'asdasd', 'asdasdasdqq',
                  'ROI 1', 'DICOM 1', '8 Bit', '12 Bit', 'in mm', 'WL: WW:', 'WL/WW',
                  'CLUT', 'ROIs', 'DICOMDIR', 'SQL', 'URL', 'wado',
                  'mm:\t\tx:0 y:0 z:0', 'px:\t\tx:0 y:0 z:0',
                  '<< do not localize >>', '<<do not localize window title>>',
                  '<<A disc named %@ and containing %d DICOM files was mounted. THIS STRING IS JUST A PLACEHOLDER, no need to localize it.>>',
                  'Position: %@ '}
for key, value in catalog.items():
    original = english.get(key, key)
    if value != original or residual.is_residual(key, original):
        continue
    stem = value.strip().rstrip(':')
    assert (stem in IDENTICAL_GERMAN or stem in EXTRA_TECHNICAL or value in EXTRA_TECHNICAL
            or value.startswith('Standard ') or value.startswith(('http://', 'https://', 'www.'))
            or value in {'Pages (.pages)', 'Microsoft Word (.doc)', 'TextEdit (.rtf)',
                         'LibreOffice (.odt)', 'Mail.app'}), f'Unlisted English: {key}'


def visible_text(node):
    return node.tag in {'string', 'mutableString'} and node.get('key') in TEXT_KEYS


def decode(node):
    text = node.text or ''
    return base64.b64decode(text.strip() + '===').decode() if node.get('base64-UTF8') == 'YES' else text


def structure(node):
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in VISIBLE),
            None if visible_text(node) else node.text, [structure(child) for child in node])


sources = list((RESOURCES / 'en.lproj').glob('*.xib'))
sources += list((ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib'))
assert len(sources) == 64, 'Review changes to the current interface inventory'
for source in sources:
    original = ET.parse(source).getroot()
    translated = ET.parse(TARGET / source.name).getroot()
    assert structure(original) == structure(translated), f'Changed wiring, identifiers or layout: {source.name}'
    for en_node, de_node in zip(original.iter(), translated.iter()):
        for key in VISIBLE:
            if key in en_node.attrib:
                text = en_node.get(key)
                assert not text or text in catalog, f'Missing XIB text: {source.name}: {text}'
                assert de_node.get(key) == catalog.get(text, text), (source.name, text)
        if visible_text(en_node) and en_node.text:
            text = decode(en_node)
            assert text in catalog, f'Missing multiline XIB text: {source.name}: {text}'
            assert decode(de_node) == catalog[text], (source.name, text)
# The stock source collector captures only the first concatenated Swift literal.
concat = re.compile(r'NSLocalizedString\(\s*("(?:\\.|[^"\\])*")(\s*\+\s*"(?:\\.|[^"\\])*")+')
for source in (ROOT / 'Horos/Sources').glob('*.swift'):
    for match in concat.finditer(source.read_text()):
        key = ''.join(json.loads(part) for part in re.findall(r'"(?:\\.|[^"\\])*"', match.group()))
        assert key in catalog, f'Missing concatenated key: {key}'
subprocess.run([sys.executable, str(ROOT / 'tools/collect-menu-strings.py'), '--check', '--language', 'de'], check=True)
if len(sys.argv) > 1:
    built = Path(sys.argv[1]) / 'Contents/Resources/de.lproj'
    assert load(built / 'Localizable.strings') == catalog
    for source in sources:
        if source.parent == RESOURCES / 'en.lproj':
            assert (built / (source.stem + '.nib')).exists(), source.name
print(f'PASS: German {len(catalog)} entries, live/source coverage, format tokens, ASCII overlays and {len(sources)} XIBs with unchanged wiring')
