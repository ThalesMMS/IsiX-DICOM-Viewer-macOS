#!/usr/bin/env python3
"""The curves of a fusion have the names of curves, in every language.

The pop-up of the mode of a fusion, in the toolbars of the 2D viewer, the 3D
MPR, the curved MPR and the PET-CT window and in the PET settings, names six
curves of opacity: Linear, High-Low-High, Low-High-Low, Log, Inverse Log and
Flat. "Log" is the logarithm there, and four catalogs had read it as another
word: the German one wrote "Protokoll" and the Simplified Chinese one "日志",
the record of what a program did, the Arabic one the register and the Hindi
one a length of timber. The French "Low-High-Low" was "Faible" alone, and the
Russian pair named one curve with adverbs and the other with adjectives.

In each of the eleven catalogs:

- "Log" and "Inverse Log" hold the word of the language for the logarithm;
- "High-Low-High" and "Low-High-Low" are three words each, the same two
  words in the two orders;
- none of the six names is empty or left as another's.

And every copy of a nib that has the menu shows the six names as its catalog
writes them, in the order of the English nib, so a catalog and a copy cannot
part again. The rules are checked on the names the catalogs had.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
PANE = ROOT / 'Preference Panes/OSIPETPreferencePane'
CURVES = ('Linear', 'High-Low-High', 'Low-High-Low', 'Log', 'Inverse Log', 'Flat')
NIBS = ('Viewer', 'MPR', 'CPR', 'PETCT', 'OSIPETPreferencePanePref')
# What the name of a logarithmic curve holds, by language: the stem of its word for the logarithm.
LOGARITHM = {
    'ar': 'لوغاريتم', 'de': 'ogarithm', 'es': 'ogarítm', 'fr': 'ogarithm', 'hi': 'लघुगणक', 'it-IT': 'ogaritm',
    'ja-JP': '対数', 'ko': '로그', 'pt-BR': 'ogarítm', 'ru': 'огарифм', 'zh-Hans': '对数',
}


def catalog(language):
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    return plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'binary1', '-o', '-', str(path)]))


def words(name):
    """The three words of the name of a curve that goes up and down: between dashes, or one sign each."""
    parts = [part.strip().casefold() for part in re.split(r'\s*[-‐-―−]\s*|\s+', name.strip()) if part.strip()]
    return parts if len(parts) != 1 else list(parts[0])


def faults(language, names):
    """What is wrong in the six names of a language, {English: name}."""
    found = []
    for curve in CURVES:
        if not names.get(curve, '').strip():
            found.append(f'{language}: "{curve}" has no name')
    if len({names.get(curve) for curve in CURVES}) != len(CURVES):
        found.append(f'{language}: two curves have one name: {[names.get(curve) for curve in CURVES]}')
    for curve in ('Log', 'Inverse Log'):
        if LOGARITHM[language] not in names.get(curve, ''):
            found.append(f'{language}: "{curve}" is "{names.get(curve)}", which does not name the logarithm ("{LOGARITHM[language]}")')
    if names.get('Log') == names.get('Inverse Log'):
        found.append(f'{language}: "Log" and "Inverse Log" are both "{names.get("Log")}"')
    high, low = words(names.get('High-Low-High', '')), words(names.get('Low-High-Low', ''))
    if len(high) != 3 or len(low) != 3 or high[0] != high[2] or low[0] != low[2] or high[0] == high[1] \
            or (high[0], high[1]) != (low[1], low[0]):
        found.append(f'{language}: "High-Low-High" and "Low-High-Low" are "{names.get("High-Low-High")}" and '
                     f'"{names.get("Low-High-Low")}": not the same two words in the two orders')
    return found


def menus(path):
    """{id of the pop-up: the titles of its items} for the pop-ups of a nib."""
    return {pop_up.get('id'): [item.get('title') for item in pop_up.iter('menuItem')]
            for pop_up in ET.parse(path).getroot().iter('popUpButton')}


failures = []
languages = sorted(LOGARITHM)
catalogs = {language: catalog(language) for language in languages}
for language in languages:
    failures += faults(language, {curve: catalogs[language].get(curve) for curve in CURVES})

# The copies of the nibs: the menu of the English nib, found by its items, has the names of the catalog in each.
counted = 0
for nib in NIBS:
    english = (PANE / 'Base.lproj' if nib.startswith('OSI') else RESOURCES / 'en.lproj') / f'{nib}.xib'
    ids = [identifier for identifier, titles in menus(english).items() if titles == list(CURVES)]
    if not ids:
        failures.append(f'{nib}: no pop-up of the English nib has the six curves')
    for language in languages:
        copy = (PANE if nib.startswith('OSI') and language == 'ja-JP' else RESOURCES) / f'{language}.lproj/{nib}.xib'
        if not copy.exists():
            continue  # read from the English nib with the catalog
        shown = menus(copy)
        expected = [catalogs[language].get(curve) for curve in CURVES]
        for identifier in ids:
            counted += 1
            if shown.get(identifier) != expected:
                failures.append(f'{language}: {nib}: the pop-up {identifier} shows {shown.get(identifier)}, its catalog writes {expected}')

# The rules, on what the catalogs had.
HAD = [
    ('de', {'Log': 'Protokoll'}, '"Log" is "Protokoll"'),
    ('zh-Hans', {'Log': '日志'}, '"Log" is "日志"'),
    ('ar', {'Log': 'السجل', 'Inverse Log': 'سجل العكس'}, '"Inverse Log" is "سجل العكس"'),
    ('hi', {'Log': 'लकड़ी का लट्ठा'}, '"Log" is "लकड़ी का लट्ठा"'),
    ('fr', {'Low-High-Low': 'Faible'}, 'not the same two words'),
    ('ru', {'High-Low-High': 'Высоко-низко-высокий', 'Low-High-Low': 'Низкий-высокий-низкий'}, 'not the same two words'),
    ('hi', {'High-Low-High': 'उच्च कम उच्च'}, 'not the same two words'),
    ('ar', {'Low-High-Low': 'انخفاض - ارتفاع - انخفاض'}, 'not the same two words'),
]
for language, old, message in HAD:
    names = {curve: catalogs[language].get(curve) for curve in CURVES}
    names.update(old)
    if not any(message in fault for fault in faults(language, names)):
        failures.append(f'{language}: the rules do not report {old}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: the six curves of a fusion have the names of curves in {len(languages)} catalogs and in {counted} menus of nib copies; '
      f'{len(HAD)} names the catalogs had are reported')
