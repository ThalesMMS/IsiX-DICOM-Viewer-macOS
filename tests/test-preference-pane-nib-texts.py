#!/usr/bin/env python3
"""Texts of the preference panes' nibs say what their controls do, in every copy.

Three texts were wrong in the nibs:

1. The French copy of the Routing pane held, for the note beside the filter
   ("Empty filter will route ALL images"), a sentence about a European
   regulation, written as plain text in a string the nib marks as base64. Every
   base64 string of every nib must decode to UTF-8, and the note's French text
   must speak of the filter.
2. In the CD/DVD pane the tool tips of the two radio buttons that choose how a
   disc is read were exchanged: "All DICOM files available on the disk (Scan
   Mode)" said it used the DICOMDIR, and "Files indexed in the DICOMDIR file"
   said it scanned the disc. The prototype cell of the matrix carries the
   DICOMDIR title with its tool tip: the DICOMDIR button must carry that tool
   tip and the scan button the other one, in the Base nib and in every copy.
3. In the Locations pane the pop-up of character sets named ISO_IR 101 and
   ISO_IR 109 "Western European", as ISO_IR 100, and ISO_IR 110 "Central
   European": ISO_IR 101 is Latin 2 (Central European), ISO_IR 109 Latin 3
   (South European) and ISO_IR 110 Latin 4 (North European). Each item must
   name its own region, no two items of a copy may read the same, every item
   must end with the defined term as DICOM writes it (the French copy wrote
   "ISO IR 100" and the Hindi one transliterated it), and the item of each tag
   must name the term the pane stores for that tag.

A tool tip of a Base nib must have a translation in the Spanish and Italian
catalogs, which show the Base nib with the catalog's texts, and no tool tip of
a Japanese copy may be left as the Base nib writes it.
"""
import base64
import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PANES = ROOT / 'Preference Panes'
RESOURCES = ROOT / 'Horos' / 'Resources'
failures = []


def copies(pane, nib):
    return [PANES / pane / 'Base.lproj' / nib, PANES / pane / 'ja-JP.lproj' / nib, *sorted(RESOURCES.glob(f'*.lproj/{nib}'))]


def name(path):
    return str(path.relative_to(ROOT))


def catalog(language):
    raw = (RESOURCES / f'{language}.lproj' / 'Localizable.strings').read_bytes()
    text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', text, re.M))


# 1. Base64 strings, and the note of the Routing pane.
BASE64 = re.compile(r'<string key="([^"]*)" base64-UTF8="YES">\s*(.*?)\s*</string>', re.S)


def decoded(raw):
    raw = re.sub(r'\s', '', raw)
    return base64.b64decode(raw + '=' * (-len(raw) % 4), validate=True).decode('utf-8')


for nib in subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '*.xib']).decode().split('\0'):
    if not nib or not (ROOT / nib).is_file():
        continue
    for key, raw in BASE64.findall((ROOT / nib).read_text(encoding='utf-8', errors='replace')):
        try:
            decoded(raw)
        except ValueError:
            failures.append(f'{nib}: the base64 string "{key}" is not base64 of UTF-8: {raw[:60]!r}')

french = (RESOURCES / 'fr.lproj' / 'OSIAutoroutingPreferencePanePref.xib').read_text(encoding='utf-8')
note = re.search(r'id="309">.*?' + BASE64.pattern, french, re.S)
try:
    text = decoded(note.group(2)) if note else ''
except ValueError:
    text = ''
if 'filtre' not in text.lower():
    failures.append(f'fr OSIAutoroutingPreferencePanePref.xib: the note beside the filter reads {text!r}, not a text about the filter')

# 2. The tool tips of the CD/DVD pane's reading mode.
for path in copies('OSICDPreferencePane', 'OSICDPreferencePanePref.xib'):
    source = path.read_text(encoding='utf-8')
    tips = {}
    for cell in ('99', '110', 'gZ3-mY-LlL'):
        tag = re.search(r'<buttonCell[^>]*id="%s">' % cell, source)
        tip = re.search(r'toolTip="([^"]*)"', tag.group(0)) if tag else None
        tips[cell] = tip.group(1) if tip else None
    if None in tips.values():
        failures.append(f'{name(path)}: a reading mode has no tool tip')
    elif tips['110'] != tips['gZ3-mY-LlL'] or tips['99'] == tips['110']:
        failures.append(f'{name(path)}: the DICOMDIR button says "{tips["110"]}" and the scan button "{tips["99"]}"')

# 3. The character sets of the Locations pane.
REGIONS = {'1': 'Western European: ISO_IR 100', '2': 'Central European: ISO_IR 101', '3': 'South European: ISO_IR 109',
           '4': 'North European: ISO_IR 110'}
pane = (PANES / 'OSILocationsPreferencePane' / 'OSILocationsPreferencePanePref.swift').read_text(encoding='utf-8')
stored = dict(re.findall(r'case (\d+): encoding = "([^"]+)"', pane))
ITEM = re.compile(r'<menuItem title="([^"]*)"((?: [a-zA-Z]+="[^"]*")*?) id="(\d+)"/>')
base_items = None
for path in copies('OSILocationsPreferencePane', 'OSILocationsPreferencePanePref.xib'):
    source = path.read_text(encoding='utf-8')
    start = source.find('ISO_IR 192"')
    menu = source[start:source.find('</menu>', start)] if start >= 0 else ''
    items = [(html.unescape(title), (re.search(r'tag="(\d+)"', rest) or [None, '0'])[1], ident) for title, rest, ident in ITEM.findall(menu)]
    if len(items) != 15:
        failures.append(f'{name(path)}: the character sets pop-up has {len(items)} items, not 15')
        continue
    if base_items is None:
        base_items = items
        for title, tag, _ in items:
            if tag in REGIONS and title != REGIONS[tag]:
                failures.append(f'{name(path)}: the item of tag {tag} reads "{title}", not "{REGIONS[tag]}"')
            term = title.split(': ', 1)[-1]
            if tag in stored and stored[tag] != term:
                failures.append(f'{name(path)}: the item "{title}" stores {stored[tag]}')
    titles = [title for title, _, _ in items]
    for title in sorted({t for t in titles if titles.count(t) > 1}):
        failures.append(f'{name(path)}: two character sets read "{title}"')
    labels = [re.split(r'\s*[:：]\s*', title)[0] for title, tag, _ in items if tag in REGIONS]
    if len(set(labels)) != len(labels):
        failures.append(f'{name(path)}: ISO_IR 100, 101, 109 and 110 are named {labels}: each is another region')
    for (title, tag, ident), (base_title, base_tag, base_ident) in zip(items, base_items):
        term = base_title.split(': ', 1)[-1]
        if (tag, ident) != (base_tag, base_ident):
            failures.append(f'{name(path)}: the item {ident} (tag {tag}) is not where the Base nib has {base_ident} (tag {base_tag})')
        elif not title.endswith(term):
            failures.append(f'{name(path)}: "{title}" does not end with the defined term {term}')

# Tool tips: translated where the catalog or the copy gives the text.
TIP = re.compile(r'(?:toolTip|headerToolTip)="([^"]*)"')
catalogs = {language: catalog(language) for language in ('es', 'it-IT')}
for base in sorted(PANES.glob('*/Base.lproj/*.xib')):
    tips = {html.unescape(tip) for tip in TIP.findall(base.read_text(encoding='utf-8')) if tip}
    for language, texts in catalogs.items():
        for tip in sorted(tips):
            if texts.get(tip, tip) == tip and re.search('[A-Za-z]{4}', tip):
                failures.append(f'{language}: no translation of the tool tip "{tip}" of {base.name}')
    japanese = base.parent.parent / 'ja-JP.lproj' / base.name
    if japanese.is_file():
        for tip in sorted(tips & {html.unescape(tip) for tip in TIP.findall(japanese.read_text(encoding='utf-8'))}):
            if re.search('[A-Za-z]{4}', tip):
                failures.append(f'ja-JP {base.name}: the tool tip "{tip}" is left in English')

for failure in failures:
    print('FAIL:', failure)
if failures:
    print(f'{len(failures)} failures')
    sys.exit(1)
print('PASS: the nibs\' base64 strings decode, the CD/DVD reading modes carry their own tool tips, '
      'each character set names its region and its defined term, and the panes\' tool tips are translated')
