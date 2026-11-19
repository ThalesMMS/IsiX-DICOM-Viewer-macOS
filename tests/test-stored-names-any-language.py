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

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
resources = root / 'Horos/Resources'
failures = []

albums = (root / 'Modules/IsiXDatabase/Sources/AlbumCatalog.swift').read_text()
keys = re.findall(r'^\s*\("([^"]+)", (?:nil|"[^"]*")\),?$', albums, re.M)
if len(keys) < 15 or 'Interesting Cases' not in keys:
    sys.exit(f'the default albums were not read from AlbumCatalog.swift: {keys}')
keys.append('Linear Table')


def catalog(path):
    data = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True).stdout
    return json.loads(data)


MAIN = r'''
import Foundation
for key in CommandLine.arguments.dropFirst() {
    print(([key] + AnyLanguage.texts(of: key).sorted()).joined(separator: "\t"))
}
'''
with tempfile.TemporaryDirectory(prefix='horos-any-language-') as directory:
    path = Path(directory)
    expected = {key: {key} for key in keys}
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
                    '-o', str(path / 'test')], check=True)
    out = subprocess.run([str(path / 'test')] + keys, check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        key, *texts = line.split('\t')
        if set(texts) != expected[key]:
            failures.append(f'{key!r} is known as {sorted(texts)}, and the catalogs say {sorted(expected[key])}')
    if len(expected['Today MR']) < 6 or len(expected['Linear Table']) < 6:
        failures.append('the catalogs name the default albums and the linear table in fewer languages than expected')

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

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: {len(keys) - 1} default albums and the linear table are recognised in {len(languages)} languages, '
      'and nothing compares them with the current language alone')
