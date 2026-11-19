#!/usr/bin/env python3
"""The 2D/3D pull-down of the 2D viewer reads in the running language.

The pull-down's entries come from the viewer's nib. Spanish and Italian have
no viewer nib of their own and open the English one, and the Japanese nib left
these entries in English: the pull-down read «3D Volume Rendering» beside a
translated menu bar. When the toolbar item is made, the entries that still
carry the English title of their command take its localized title
(MenuShortcutCatalog.localizeReconstructionTitles, exercised by
tests/test-menu-shortcuts.py); here:

* the toolbar factory hands the pull-down's menu to it;
* the English titles it compares with are the keys the catalogue localizes,
  and those the English nib carries;
* the twelve catalogs have every one of them, and Spanish, Italian and
  Japanese translate the tool tip and the entries that are not an acronym
  alone.

    python3 tests/test-reconstruction-pull-down-titles.py [<git revision>]

A revision reads the files from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
KEYS = ['2D Orthogonal MPR', '3D MPR', '3D Curved-MPR', 'Vessel Analysis', '3D MIP', '3D Volume Rendering',
        '3D Surface Rendering', '3D Endoscopy']
# «3D MPR» and «3D MIP» are acronyms a language may keep as they are.
ACRONYMS = {'3D MPR', '3D MIP'}
LANGUAGES = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans']


def raw(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout if shown.returncode == 0 else b''
    return (ROOT / path).read_bytes()


def text(path):
    data = raw(path)
    return data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')


failures = []
factory = text('Horos/Sources/ViewerToolbarItemFactory.swift')
if not re.search(r'case Catalog\.reconstruction:\s*control\([^\n]*view: viewer\.horos_ReconstructionView\)\s*(?://[^\n]*\s*)*'
                 r'var inside = viewer\.horos_ReconstructionView\.map \{ \[\$0\] \} \?\? \[\]\s*'
                 r'while let view = inside\.popLast\(\) \{\s*'
                 r'if let menu = \(view as\? NSPopUpButton\)\?\.menu \{ MenuShortcutCatalog\.localizeReconstructionTitles\(in: menu\) \}\s*'
                 r'inside \+= view\.subviews', factory):
    failures.append('the 2D/3D toolbar item does not give its pull-down the titles of the running language')

catalog = text('Horos/Sources/MenuShortcutCatalog.swift')
start = catalog.find('static let reconstructionTitleKeys: [String: String] = [')
table = catalog[start:catalog.find(']\n', start)] if start >= 0 else ''
for key in KEYS:
    if f'"{key}"' not in table:
        failures.append(f'the catalogue does not know «{key}» as the English title of a reconstruction command')
    if f'NSLocalizedString("{key}", comment: "Reconstruction command")' not in catalog:
        failures.append(f'the catalogue does not localize «{key}»')
for action in ('SRViewer:', 'endoscopyViewer:'):
    if f'case "{action}":' not in catalog:
        failures.append(f'the catalogue does not identify the command of -{action}')

nib = text('Horos/Resources/en.lproj/Viewer.xib')
for key in KEYS:
    if f'<menuItem title="{key}"' not in nib:
        failures.append(f'premise: the English viewer nib carries «{key}» in its pull-down')

for language in LANGUAGES:
    strings = text(f'Horos/Resources/{language}.lproj/Localizable.strings')
    for key in KEYS + ['2D/3D Reconstruction Tools']:
        entry = re.search(r'^"' + re.escape(key) + r'" = "(.*)";$', strings, re.M)
        if language == 'en':
            continue
        if not entry:
            failures.append(f'{language}: no entry for «{key}»')
        elif language in ('es', 'it-IT', 'ja-JP') and key not in ACRONYMS and entry.group(1) == key:
            failures.append(f'{language}: «{key}» is not translated')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the 2D/3D pull-down takes the titles of the running language for the entries a nib left in English, and '
      'the twelve catalogs have them')
