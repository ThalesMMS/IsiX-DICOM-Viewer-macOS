#!/usr/bin/env python3
"""A name stored as it was shown is recognised in every language of the app.

A default album is made with the name the language of the day gives it, and
the linear opacity table is kept in the state of a 3D window under the title
its menu had. The application compared both with the name in the language it
runs in now: a database made in Portuguese and opened in Italian got the
default albums a second time, and the state of a window was not read. What is
checked:

- `AnyLanguage`, compiled beside the real catalogs, knows each default album
  and "Linear Table" under the name every catalog gives it, and under the
  English one;
- the catalogs now leave "Linear Table", "No CLUT", "16-bit CLUT" and
  "Logarithmic Inverse Table" as English writes them, and a 3D state, a 3D
  preset or a preference saved before holds what its language wrote then: the
  first three were written through the catalog, and volume rendering asked for
  the fourth, the table it opens with, under its translated name, kept that
  name as its current table and saved it with the state. `AnyLanguage` still
  knows each of those texts, and gives a stored one back as English writes it,
  which is how the menus list the table and the presets have it, while any
  other name comes back as it is;
- no other name a catalog translated was saved translated: a colour table, a
  window level preset and a filter are saved under the name the preferences
  list them by, so "B/W Inverse", "CT - Bone" and "No Filter" have no former
  text to recognise, and none is listed for them;
- the 3D window reads the tables of a state and of a preset through it, and so
  does the opacity table of the 2D viewer, which a preference names;
- the database adds a default album only when it is there under no language,
  and the PACS On-Demand pane recognises the albums it fills the same way;
- no window compares the opacity table it is given with the name of the
  linear one in the current language alone;
- the presets, which are stored under their English names, are not asked for
  under a translated one.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
STORED_TABLE_NAMES = root / 'Modules/IsiXPreferences/Sources/StoredTableNames.swift'
resources = root / 'Horos/Resources'
failures = []

albums = (root / 'Modules/IsiXDatabase/Sources/AlbumCatalog.swift').read_text()
keys = re.findall(r'^\s*\("([^"]+)", (?:nil|"[^"]*")\),?$', albums, re.M)
if len(keys) < 15 or 'Interesting Cases' not in keys:
    sys.exit(f'the default albums were not read from AlbumCatalog.swift: {keys}')
# What each catalog wrote, while it translated them, for the names of a table that were saved as a language wrote them.
FORMER = {
    'Linear Table': {'Lineare Tabelle', 'Tableau linéaire', 'रैखिक तालिका', 'Tabella lineare', '선형 테이블', 'Tabela linear',
                     'Линейная таблица', 'Линейный стол', '线性映射表', '线性表格'},
    'No CLUT': {'بدون CLUT', 'Keine CLUT', 'Aucune CLUT', 'कोई CLUT नहीं', 'CLUT 없음', '클루트 없음', 'Sem CLUT', 'Без CLUT', '无 CLUT'},
    '16-bit CLUT': {'16 bits CLUT', '16-बिट CLUT', '16ビット CLUT', '16비트 CLUT', '16-битный CLUT', '16位CLUT'},
    'Logarithmic Inverse Table': {'Invers-logarithmische Tabelle', 'Tableau inverse logarithmique', 'लघुगणक व्युत्क्रम तालिका',
                                  'Tabella inversa logaritmica', '로그 역 테이블', 'Tabela logarítmica inversa',
                                  'Логарифмическая обратная таблица', '对数反向表格'},
}
# Translated once, and never saved translated: what was saved is the name the preferences list them by.
NEVER_SAVED_TRANSLATED = {'B/W Inverse': 'Graustufen invers', 'CT - Bone': 'CT – Knochen', 'No Filter': 'Kein Filter'}
albums_count = len(keys)
keys += sorted(FORMER)


def catalog(path):
    data = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True).stdout
    return json.loads(data)


MAIN = r'''
import Foundation
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--stored" {
    for text in arguments.dropFirst() {
        print([text, AnyLanguage.tableName(stored: text) ?? "(nil)"].joined(separator: "\t"))
    }
    print(["(nil)", AnyLanguage.tableName(stored: nil) ?? "(nil)"].joined(separator: "\t"))
} else {
    for key in arguments {
        print(([key] + AnyLanguage.texts(of: key).sorted()).joined(separator: "\t"))
    }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-any-language-') as directory:
    path = Path(directory)
    expected = {key: {key} | FORMER.get(key, set()) for key in keys}
    languages = sorted(p.name[:-6] for p in resources.glob('*.lproj') if (p / 'Localizable.strings').exists())
    if len(languages) < 12:
        sys.exit(f'the catalogs were not found: {languages}')
    for language in languages:
        (path / f'{language}.lproj').mkdir()
        shutil.copy(resources / f'{language}.lproj/Localizable.strings', path / f'{language}.lproj/Localizable.strings')
        entries = catalog(resources / f'{language}.lproj/Localizable.strings')
        for key in keys:
            expected[key].add(entries.get(key, key))
    (path / 'main.swift').write_text(MAIN)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(sources / 'AnyLanguage.swift'), str(path / 'main.swift'),
                    *isix_modules.module_flags('IsiXPreferences', path / 'modules'), '-o', str(path / 'test')], check=True)
    out = subprocess.run([str(path / 'test')] + keys, check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        key, *texts = line.split('\t')
        if set(texts) != expected[key]:
            failures.append(f'{key!r} is known as {sorted(texts)}, and the catalogs say {sorted(expected[key])}')
    if len(expected['Today MR']) < 6:
        failures.append('the catalogs name the default albums in fewer languages than expected')
    # A stored name comes back as English writes it.
    presets = ['Logarithmic Table', 'VR Muscles-Bones', 'My own table'] + [text for pair in NEVER_SAVED_TRANSLATED.items() for text in pair]
    stored = [text for key in sorted(FORMER) for text in sorted(FORMER[key] | {key})]
    out = subprocess.run([str(path / 'test'), '--stored'] + stored + presets, check=True, capture_output=True, text=True).stdout
    given = dict(line.split('\t') for line in out.splitlines())
    for key in sorted(FORMER):
        for text in sorted(FORMER[key] | {key}):
            if given.get(text) != key:
                failures.append(f'{text!r}, which a state holds for {key!r}, comes back as {given.get(text)!r}')
    for name in presets:
        if given.get(name) != name:
            failures.append(f'the name {name!r}, which no state holds for another, comes back as {given.get(name)!r}')
    source = STORED_TABLE_NAMES.read_text()
    listed = set(re.findall(r'^        "([^"]+)": \[', source[source.index('static let formerTexts'):], re.M))
    if listed != set(FORMER):
        failures.append(f'StoredTableNames lists former texts for {sorted(listed)}, and the names saved translated are {sorted(FORMER)}')
    if 'formerTexts' in (sources / 'AnyLanguage.swift').read_text().replace('StoredTableNames.formerTexts(of: key)', ''):
        failures.append('AnyLanguage keeps a list of former texts of its own')
    if given.get('(nil)') != '(nil)':
        failures.append(f'no name comes back as {given.get("(nil)")!r}')

store = (sources / 'CoreDataAlbumStore.swift').read_text()
if 'missingDefaultAlbums(among: names, names: AnyLanguage.texts(of:))' not in store:
    failures.append('CoreDataAlbumStore adds the default albums by their names in the current language alone')
pane = (root / 'Preference Panes/OSIPACSOnDemandPreferencePane/OSIPACSOnDemandPreferencePane.swift').read_text()
if re.search(r'album\.name, NSLocalizedString\(', pane):
    failures.append('the PACS On-Demand pane compares an album with its name in the current language alone')
for source in sorted(sources.glob('*.swift')):
    text = source.read_text()
    for line in text.splitlines():
        if re.search(r'(==|EqualToString\([^)]*,) *NSLocalizedString\("Linear Table"', line):
            failures.append(f'{source.name} compares a table with the linear one in the current language alone: {line.strip()}')
        if re.search(r'NSLocalizedString\("Logarithmic (Inverse )?Table"', line):
            failures.append(f'{source.name} asks for a preset under a translated name: {line.strip()}')
        if re.search(r'(==|EqualToString\([^)]*,) *NSLocalizedString\("16-bit CLUT"', line):
            failures.append(f'{source.name} compares a table with the 16-bit one in the current language alone: {line.strip()}')

state = (sources / 'VRController+State.swift').read_text()
if 'AnyLanguage.tableName(stored: dict?.object(forKey: "CLUTName") as? String)' not in state:
    failures.append('the 3D window reads the colour table of a state as the language of its day wrote it')
tables = (sources / 'VRController+ColourTables.swift').read_text()
opacity = tables[tables.index('public override func applyOpacityString('):]
if 'guard let str = AnyLanguage.tableName(stored: str) else { return }' not in opacity[:opacity.index('\n    }\n')]:
    failures.append('the 3D window keeps the opacity table of a state or a preset under the name the language of its day gave it')
presets_source = (sources / 'VRController+Presets.swift').read_text()
if 'opacityTablePresets[AnyLanguage.tableName(stored: preset.object(forKey: "opacity") as? String)]' not in presets_source:
    failures.append('the preview of a 3D preset looks for its opacity table under the name the language of its day gave it')
viewer = (sources / 'ViewerColourTables.swift').read_text()
opacity = viewer[viewer.index('func applyOpacityTable('):]
if 'let name = AnyLanguage.tableName(stored: name)' not in opacity[:opacity.index('\n    }\n')]:
    failures.append('the 2D viewer keeps the opacity table of a preference under the name the language of its day gave it')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: {albums_count} default albums are recognised in {len(languages)} languages, and the linear table, no colour table, '
      f'the 16-bit one and the table volume rendering opens with under the {sum(len(texts) for texts in FORMER.values())} '
      'texts the catalogs wrote for them; nothing compares them with the current language alone')
