#!/usr/bin/env python3
"""Every thick slab mode has a short name, in every language.

The menu of a Thick Slab pop-up names a mode by its abbreviation and what it
stands for, «MIP - Max Intensity Projection», and the closed pop-up of the 3D
MPR's toolbar shows the abbreviation alone, in a 132 pt control. The short
name was what came before " - ", a hyphen between spaces, and the dash is the
translator's: German writes «MIP – Maximumintensitätsprojektion» with an en
dash and Russian «minIP — проекция минимальной интенсивности» with an em
dash, so those pop-ups drew the whole name, cut.

The rule is ThickSlabModeName (IsiXImaging), compiled here as it is with a
driver, and given every name a Thick Slab menu can show:

- the names of the modes in the English nibs of the four windows that have
  the pop-up (2D viewer, orthogonal MPR, 3D MPR, curved MPR), as the catalog
  of each of the twelve languages translates them;
- the names in the menu of the same pop-up in every language's copy of
  those nibs.

A mode whose English name has a dash between spaces has, in every language,
a short name that is shorter than its name: a translation that writes the
dash another way is cut all the same. No short name is empty or keeps a dash
between spaces, and a name with no dash is its own short name.

The cells that draw a short name take it from that rule: the 3D MPR's for
every mode, the 2D viewer's for a mode its catalog names do not cover.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
RULE = ROOT / 'Modules/IsiXImaging/Sources/ViewerReconstruction/ThickSlabModeName.swift'
CELLS = {'the 3D MPR': ROOT / 'Horos/Sources/MPRToolbarItemViews.swift',
         'the 2D viewer': ROOT / 'Horos/Sources/ViewerToolbarItemViews.swift'}
NIBS = ('Viewer', 'OrthogonalMPR', 'MPR', 'CPR')
A_MODE = 'MIP - Max Intensity Projection'
# The dashes a translation may put between the abbreviation and its meaning,
# written here apart from the rule: hyphen, figure dash, en dash, em dash,
# horizontal bar, minus sign.
DASH_BETWEEN_SPACES = re.compile(r'\s[-‒–—―−]\s')

if not shutil.which('xcrun'):
    print('skipped: needs xcrun (swiftc, plutil)', file=sys.stderr)
    sys.exit(2)

failures = []


def catalog(language):
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    converted = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], capture_output=True)
    if converted.returncode:
        sys.exit(f'FAIL: {path} does not read as a strings file: {converted.stdout.decode()[-300:]}')
    return json.loads(converted.stdout)


def mode_menus(xib):
    """The Thick Slab pop-ups of a nib, by id: the titles of their menus."""
    found = {}
    for popup in ET.parse(xib).getroot().iter('popUpButton'):
        found[popup.get('id')] = [item.get('title') for item in popup.iter('menuItem') if item.get('title')]
    return found


# The pop-ups, by the menu of the English nib that lists the mode.
popups = {}
for nib in NIBS:
    menus = {identifier: titles for identifier, titles in mode_menus(RESOURCES / f'en.lproj/{nib}.xib').items()
             if A_MODE in titles}
    if len(menus) != 1:
        failures.append(f'{nib}.xib: {len(menus)} pop-ups list «{A_MODE}», one expected')
    popups[nib] = menus
english = sorted({title for menus in popups.values() for titles in menus.values() for title in titles})
if not any(' - ' in name for name in english) or not any(' - ' not in name for name in english):
    failures.append(f'the English nibs name the modes {english}: with and without a dash expected')

languages = sorted(path.parent.name[:-len('.lproj')] for path in RESOURCES.glob('*.lproj/Localizable.strings'))
if len(languages) != 12:
    failures.append(f'{len(languages)} languages have a catalog, twelve expected: {languages}')

# (language, where the name is written, the English name or None, the name)
names = []
for language in languages:
    translations = catalog(language)
    for name in english:
        names.append((language, 'catalog', name, translations.get(name, name)))
    for nib, menus in popups.items():
        copy = RESOURCES / f'{language}.lproj/{nib}.xib'
        if language == 'en' or not copy.is_file():
            continue
        theirs = mode_menus(copy)
        for identifier, titles in menus.items():
            translated = theirs.get(identifier)
            if translated is None or len(translated) != len(titles):
                failures.append(f'{language} {nib}.xib: the pop-up {identifier} lists {translated}, '
                                f'{len(titles)} modes in English')
                continue
            names.extend((language, f'{nib}.xib', original, title) for original, title in zip(titles, translated))

with tempfile.TemporaryDirectory(prefix='isix-thick-slab-names-') as folder:
    work = Path(folder)
    (work / 'main.swift').write_text('''import Foundation

let names = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(try JSONEncoder().encode(names.map { ThickSlabModeName.short(of: $0) }))
''')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(RULE), str(work / 'main.swift'),
                            '-o', str(work / 'short')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: ThickSlabModeName does not compile with the driver\n' + built.stderr[-3000:])
    ran = subprocess.run([str(work / 'short')], input=json.dumps([name for *_, name in names]).encode(), capture_output=True)
    if ran.returncode:
        sys.exit('FAIL: the driver failed\n' + ran.stderr.decode()[-3000:])
    shorts = json.loads(ran.stdout)

dashes = {}
for (language, where, original, name), short in zip(names, shorts):
    context = f'{language} {where} «{name}»'
    whole = name.strip()
    if not short:
        failures.append(f'{context}: no short name')
    if DASH_BETWEEN_SPACES.search(short):
        failures.append(f'{context}: the short name «{short}» keeps the dash')
    if ' - ' in original:
        if short == whole or len(short) >= len(whole):
            failures.append(f'{context}: the short name is the whole name; «{original}» has one in English')
        elif not whole.startswith(short):
            failures.append(f'{context}: the short name «{short}» is not the start of the name')
        else:
            dash = whole[len(short):].strip()[:1]
            dashes[dash] = dashes.get(dash, 0) + 1
    elif short != whole:
        failures.append(f'{context}: the short name is «{short}»; «{original}» has no dash in English')

by_name = {(language, name): short for (language, _, _, name), short in zip(names, shorts)}
for language, name, short in (('en', 'MIP - Max Intensity Projection', 'MIP'),
                              ('en', 'minIP - Min Intensity Projection', 'minIP'),
                              ('en', 'Volume Rendering ', 'Volume Rendering')):
    if by_name.get((language, name)) != short:
        failures.append(f'{language} «{name}»: the short name is «{by_name.get((language, name))}», «{short}» expected')

# The cells take the short name from the rule, and none keeps one of its own.
for window, path in CELLS.items():
    text = path.read_text(encoding='utf-8')
    if 'ThickSlabModeName.short(of:' not in text:
        failures.append(f'the Thick Slab cell of {window} does not take a short name from ThickSlabModeName')
    if re.search(r'separatedBy:\s*"\s*[-‒–—―−]', text) or 'range(of: " - ")' in text:
        failures.append(f'{path.name} cuts a name at a dash of its own')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
written = ', '.join(f'{count} with U+{ord(dash):04X}' for dash, count in sorted(dashes.items()))
print(f'PASS: {len(names)} names of thick slab modes in {len(languages)} languages have a short name ({written})')
