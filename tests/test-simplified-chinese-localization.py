#!/usr/bin/env python3
"""Verify #995 catalogs and UI copies without claiming linguistic or app QA."""
from collections import Counter
import base64
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'Horos/Resources/zh-Hans.lproj'
spec = importlib.util.spec_from_file_location('residual', ROOT / 'tools/host-localization-residual.py')
residual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(residual)

def catalog(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

en = catalog(ROOT / 'Horos/Resources/en.lproj/Localizable.strings')
zh = catalog(DEST / 'Localizable.strings')
assert en.keys() <= zh.keys(), 'Missing English catalog keys'
spec = importlib.util.spec_from_file_location('collector', ROOT / 'tools/collect-localized-strings.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
live = collector.keys()
assert live.keys() <= zh.keys(), 'Missing current localized source calls'
for key, value in zh.items():
    original = en.get(key, key)
    if key in en or key in live:  # Static XIB labels may contain literal percentages followed by prose.
        assert Counter(residual.FORMAT.findall(original)) == Counter(residual.FORMAT.findall(value)), repr(key)
    assert value or not original, f'Empty translation: {key}'
    # Positional and line-break binding formats must also remain intact.
    assert Counter(re.findall(r'%\{value\d+\}@', original)) == Counter(re.findall(r'%\{value\d+\}@', value)), repr(key)
TECHNICAL_UI = {'DICOMCD', 'WL/WW', '3D VR', '3D MPR', '<< do not localize >>', '3D MIP', 'OsiriX CT - 129', 'ROI 1', 'TRUEPREDICATE', '3D SR', 'Delaunay', 'Papyrus', 'WL/WW:', 'DICOM 1', '<<do not localize window title>>', 'HTTPS', 'asdasdasdqq', 'http://www.preferences-server.com/preferences.plist'}
for key, value in zh.items():
    original = en.get(key, key)
    assert value != original or residual.is_residual(key, original) or key in TECHNICAL_UI or re.fullmatch(r'(?:https?://|www\.)[A-Za-z0-9./?=&_%+:#~-]+', original), f'Untranslated text: {key}'
URL = re.compile(r'(?:https?://|www\.)[A-Za-z0-9./?=&_%+:#~-]+')
for key, value in zh.items():
    original = en.get(key, key)
    assert Counter(x.rstrip('.') for x in URL.findall(original)) == Counter(x.rstrip('.') for x in URL.findall(value)), f'Changed URL: {key}'
    assert Counter(re.findall(r'</?(?:a|b|br|i|u|strong|em|span|font|p|div|html|head|body)(?:\s[^>]*|/)?>', original)) == Counter(re.findall(r'</?(?:a|b|br|i|u|strong|em|span|font|p|div|html|head|body)(?:\s[^>]*|/)?>', value)), f'Changed markup: {key}'
for key in residual.english_comments():
    assert zh[key].isascii(), f'Legacy overlay requires ASCII: {key}'

VISIBLE = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue', 'paletteLabel', 'headerToolTip'}
STRING_KEYS = VISIBLE | {'NSDisplayName', 'NSDisplayPattern', 'NSNullPlaceholder', 'NSNoSelectionPlaceholder'}
def structure(node):
    text = (node.text or '').strip()
    if node.tag == 'string' and node.get('key') in STRING_KEYS:
        text = ''
    if node.tag == 'objectValues':
        # Combo-box display values are translatable; bindings are not.
        return (node.tag, sorted(node.attrib.items()), '', [(c.tag, sorted(c.attrib.items()), '') for c in node])
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in VISIBLE), text,
            [structure(child) for child in node])

sources = sorted((ROOT / 'Horos/Resources/en.lproj').glob('*.xib'))
sources += sorted((ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib'))
for source in sources:
    target = DEST / source.name
    assert target.exists(), f'Missing UI: {source}'
    english_tree = ET.parse(source).getroot()
    chinese_tree = ET.parse(target).getroot()
    assert structure(english_tree) == structure(chinese_tree), f'Changed connections, actions, IDs or shortcuts: {source}'
    for original, translated in zip(english_tree.iter(), chinese_tree.iter()):
        for name in VISIBLE & original.attrib.keys():
            text = original.get(name)
            assert not text or text in zh, f'UI text absent from catalog: {source.name} {text!r}'
            assert translated.get(name) == (zh[text] if text else ''), f'UI/catalog mismatch: {source.name} {text!r}'
        if original.tag == 'string' and original.get('key') in STRING_KEYS and original.text:
            if original.get('base64-UTF8') == 'YES':
                encoded = (translated.text or '').strip()
                decoded = base64.b64decode(encoded + '=' * (-len(encoded) % 4)).decode('utf-8')
                assert decoded == '空筛选器将路由\x03\u2028所有图像\n', 'Corrupt base64 title'
            assert translated.text == zh[original.text], f'String/catalog mismatch: {source.name}'
assert zh['Study'] == '检查'
assert zh['Series'] == '序列'
assert zh['Patient'] == '患者'
assert zh['Volume Rendering'] == '容积渲染'
assert zh['Cancel'] == '取消'
assert zh['Database'] == '数据库'
assert zh['Empty filter will route\x03\u2028ALL images\n'] == '空筛选器将路由\x03\u2028所有图像\n'
# Reuse the existing Foundation language-resolution probe approach.
subprocess.run(['xcrun', 'swift', '-e', r'''
import Foundation
import CoreText
for (tag, expected) in [("zh-Hans", "zh-Hans"), ("zh-CN", "zh-Hans"),
                        ("zh-Hans-CN", "zh-Hans"), ("zh-Hant", "en"), ("zh-TW", "en")] {
    precondition(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: [tag]).first == expected)
}
let data = FileHandle.standardInput.readDataToEndOfFile()
let strings = try JSONSerialization.jsonObject(with: data) as! [String: String]
let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
let characters = Set(strings.values.joined().unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) })
for scalar in characters {
    let text = String(scalar) as CFString
    let fallback = CTFontCreateForString(font, text, CFRange(location: 0, length: 1))
    var character = UniChar(scalar.value)
    var glyph: CGGlyph = 0
    precondition(CTFontGetGlyphsForCharacters(fallback, &character, &glyph, 1) && glyph != 0, "Missing CJK glyph")
}
for value in strings.values {
    precondition(value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) == value,
                 "Traditional UI text in zh-Hans")
}
print("PASS: Foundation locale resolution and \(characters.count) CJK glyphs in the system font cascade")
'''], input=json.dumps(zh, ensure_ascii=False), text=True, check=True)
print(f'PASS: {len(zh)} keys, formats and ASCII overlays; {len(sources)} current XIBs preserve structure and match catalog. Fluent review/build/app QA remain separate.')
