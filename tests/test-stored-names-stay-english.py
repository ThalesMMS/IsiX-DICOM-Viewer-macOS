#!/usr/bin/env python3
"""The catalogs leave the names the application stores as English writes them.

A window level preset, a colour table, an opacity table and a convolution filter
are kept by name: in the preferences, where the lists of presets are; in the
state a series saves in the database; in a 3D state and in a 3D preset. The
menus of the viewers are filled from those names, and the item of a name is
found again by its title. The names the application ships with are English
("CT - Bone", "VR Muscles-Bones", "Logarithmic Table", "Bone Filter 3x3"), and so
are the ones it gives the absence of a table or of a filter ("No CLUT", "Linear
Table", "No Filter") and the 16-bit colour table of volume rendering.

Spanish, Italian and Japanese show the windows of the viewers with the English
nib and the texts of their catalog (Horos/Sources/WindowNibCatalog.swift), so a
catalog entry for one of these names is what the language shows in its place.
Translated, the name a menu lists is no longer the name that was stored: the
Italian catalog wrote "Tabella lineare" for "Linear Table", and the opacity
pop-up of the toolbar opened on a name its own menu did not have.

The other languages have a copy of each nib, and the code writes the names it
makes itself through the catalog, on both sides of a comparison: within one
language nothing was lost. But what one language saved another did not find:
"Keine CLUT", kept in a 3D state by the German menu, was no colour table of the
English one. So a name is the same in every language, and the state of a
series, a 3D preset or a preference opens in any of them.

What is checked, for each catalog: no entry gives one of these names another
text; and no copy of a nib gives another text to a title that the English nib
writes as one of them (the predefined values of a surface carry the name of a
window level preset). The names are read from the factory presets
(Modules/IsiXPreferences/Sources/DefaultPreferences+ImagePresets.swift), with the
four the code writes. "Endoscopy" is left out: it is also the name of a viewer,
which the catalogs translate, and no menu of colour tables reads the catalog.

`--inventory` prints, for each of the twelve catalogs, the names it translates.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
LANGUAGES = tuple(sorted(path.parent.name[:-len('.lproj')] for path in (root / 'Horos/Resources').glob('*.lproj/Localizable.strings')
                         if path.parent.name != 'en.lproj'))
if len(LANGUAGES) < 11:
    sys.exit(f'the catalogs were not found: {LANGUAGES}')
# The names the code writes: no colour table, no opacity table, no filter, and the 16-bit colour table.
WRITTEN_BY_CODE = {'No CLUT', 'Linear Table', 'No Filter', '16-bit CLUT'}
# Also the name of a viewer.
ALSO_A_WORD = {'Endoscopy'}

presets = (root / 'Modules/IsiXPreferences/Sources/DefaultPreferences+ImagePresets.swift').read_text(encoding='utf-8')
window_levels = set(re.findall(r'"([^"]+)": WindowLevelPreset\(', presets))
convolutions = set(re.findall(r'"([^"]+)": ConvolutionPreset\(', presets))
opacity_tables = set(re.findall(r'"([^"]+)": OpacityTablePreset\(', presets))
colour_tables = set(re.findall(r'tables\["([^"]+)"\] = ColourTablePreset\(', presets))
shipped = re.search(r'for name in \[(.*?)\] \{', presets, re.S)
colour_tables |= set(re.findall(r'"([^"]+)"', shipped.group(1))) if shipped else set()
for kind, names, least, one in (('window level presets', window_levels, 5, 'CT - Bone'),
                                ('convolution filters', convolutions, 20, 'Bone Filter 3x3'),
                                ('opacity tables', opacity_tables, 3, 'Logarithmic Table'),
                                ('colour tables', colour_tables, 30, 'VR Muscles-Bones')):
    if len(names) < least or one not in names:
        sys.exit(f'the {kind} were not read from the factory presets: {sorted(names)}')
stored = (window_levels | convolutions | opacity_tables | colour_tables | WRITTEN_BY_CODE) - ALSO_A_WORD


def catalog(language):
    path = root / f'Horos/Resources/{language}.lproj/Localizable.strings'
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def translated(language):
    table = catalog(language)
    return {name: table[name] for name in sorted(stored) if table.get(name, name) != name}


if '--inventory' in sys.argv[1:]:
    for path in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
        language = path.parent.name[:-len('.lproj')]
        found = translated(language)
        print(f'{language}: {len(found)} of {len(stored)} stored names translated' + (f': {found}' if found else ''))
    sys.exit(0)

def nib_titles(language):
    """The stored names an English nib writes and the copy of `language` writes otherwise: (nib, name, text)."""
    found = []
    for source in sorted((root / 'Horos/Resources/en.lproj').glob('*.xib')):
        copy = root / f'Horos/Resources/{language}.lproj' / source.name
        if not copy.exists():
            continue
        for english, local in zip(ET.parse(source).getroot().iter(), ET.parse(copy).getroot().iter()):
            for attribute in ('title', 'label', 'alternateTitle', 'stringValue'):
                if english.get(attribute) in stored and local.get(attribute) != english.get(attribute):
                    found.append((source.name, english.get(attribute), local.get(attribute)))
    return found


failures = [f'{language}: {name!r} is stored by name and is translated: {text!r}'
            for language in LANGUAGES for name, text in translated(language).items()]
failures += [f'{language}: {nib} writes {text!r} for {name!r}, which is stored by name'
             for language in LANGUAGES for nib, name, text in nib_titles(language)]
written = sum(1 for source in (root / 'Horos/Resources/en.lproj').glob('*.xib')
              for node in ET.parse(source).getroot().iter() if node.get('title') in stored)
if not written:
    sys.exit('no English nib writes a stored name: the titles of the nibs were not read')
if failures:
    print('\n'.join(failures))
    sys.exit(f'{len(failures)} stored names are translated')
print(f'PASS: {len(stored)} stored names stay as English writes them in {", ".join(LANGUAGES)}')
