#!/usr/bin/env python3
"""Generate localized UI text from the current English XIB, preserving connections.

The Japanese menu had been translated by hand and stopped following the English one: no
Format menu, and two items the other languages have were missing (#640). Generating it the
way the Italian and Spanish ones are generated keeps every language's structure, actions,
identifiers and shortcuts the English's, and a title with no catalog entry stays English.
"""
import argparse
import html
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--language',choices=['it-IT','es','ja-JP','pt-BR','fr','de','ko','hi','ar','ru','zh-Hans'],default='it-IT');args=parser.parse_args()
base=root/'Horos/Resources/en.lproj/MainMenu.xib'
target=root/f'Horos/Resources/{args.language}.lproj/MainMenu.xib'
catalog=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(target.with_name('Localizable.strings'))]))
text=base.read_text()
def translate(match):
    value=html.unescape(match[2])
    translated=catalog.get(value,value)
    return match[1]+'"'+escape(translated,{'"':'&quot;', '\n':'&#10;', '\r':'&#13;', '\t':'&#9;'})+'"'
text=re.sub(r'(\b(?:title|label|toolTip|placeholderString|alternateTitle|stringValue)=)"([^"]*)"',translate,text)
if args.language not in ('it-IT', 'es', 'ja-JP'):
    # Binding placeholders and display patterns are visible UI text too. Keep
    # predicate expressions, value transformers and shortcut strings untouched.
    def translate_string(match):
        value = html.unescape(match[2])
        return match[1] + escape(catalog.get(value, value)) + match[3]
    text = re.sub(r'(<string key="(?:title|label|toolTip|placeholderString|alternateTitle|stringValue|NSDisplayName|NSDisplayPattern|NSNullPlaceholder|NSNoSelectionPlaceholder)">)(.*?)(</string>)',
                  translate_string, text, flags=re.S)

def structure(node):
    # XIB serializers may change indentation or empty-element spelling without
    # changing any UI connection, attribute or string. Compare the complete
    # parsed tree, not just a subset of its actions/outlets.
    return (node.tag, sorted(node.attrib.items()), (node.text or '').strip(),
            [structure(child) for child in node])

if args.check:
    if not target.exists() or structure(ET.fromstring(target.read_text())) != structure(ET.fromstring(text)):
        raise SystemExit(f'{args.language} MainMenu.xib is stale; run tools/localize-main-menu.py --language {args.language}')
else:
    target.write_text(text)
