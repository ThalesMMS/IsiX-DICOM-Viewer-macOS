#!/usr/bin/env python3
"""The Query and Retrieve window names its Retrieve command with a verb and cuts no header of its results.

The row of commands of the window is one control with four segments: Query,
Query Patient, Retrieve and Verify. The nib writes the third as "Retrieve", the
word the Locations settings head their column of retrieve modes with, and one
catalog entry served both: Spanish read "Recuperación", a noun, between
"Consultar" and "Verificar". The command has a text of its own, "Retrieve
(button)", which the controller writes into the segment once the window is
loaded. What is checked:

- the controller writes that text, in -windowDidLoad, after the texts of the
  nib were read from the catalog;
- every catalog has it; in a language that has a copy of the nib it is what the
  copy writes on the segment, so that language shows what it showed; in Spanish
  it is the verb, and not the heading of the column of the settings.

The columns of the results have the widths of the nib, which fit the English
headers: "ID del paciente", "Fecha de nacimiento", "Descripción", "Modalidad"
and "N.º de acceso" were cut. A list with no saved layout gives each column the
room its header needs (PaneFit.fitColumns), once the headers were read from the
catalog. The English nib is compiled and loaded with CatalogTranslation and
each of the Spanish, Italian and Japanese catalogs, as the window loads it:
after the fit no header of the results is wider than its column, and before it
the Spanish ones named above were, which is what the fit is there for. The
controller must fit the columns only when no layout was saved, must not save
the widths of the fit as the user's, and must leave the column of the names
its width: the list is sorted by it at first, with the sort indicator beside
its header, and "Nombre del paciente" was cut once the column had given its
room to the others.

A saved layout is the user's, and was left as it was: but the window saves one
the first time a column is resized, so the widths of the English headers, or
those of the language of another day, cut the headers of this one for good. A
column that cuts its header under a saved layout is widened until the header
fits (PaneFit.widenColumnsToHeaders), and nothing else changes: the nib is
loaded with each of the three catalogs, its columns are given the widths of
the nib as a saved layout, with one the user made wider, and the list is
sorted by the names. After the widening no header is cut, the one beside the
sort indicator has room for both, no column is narrower, and a column whose
header fitted has the width it was saved with; in Spanish the five headers
named above were cut before it. English is loaded the same way: there only
the two headers the nib itself cuts by a point or two get them.
The controller widens only under a saved layout, does not save those widths
as the user's while the window loads, and widens the column the header menu
brings back.
"""
import html
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_translations as panes  # noqa: E402

root = Path(__file__).resolve().parents[1]
RESOURCES = root / 'Horos/Resources'
failures = []


def catalog(language):
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


# The command.
controller = (root / 'Horos/Sources/QueryController.swift').read_text(encoding='utf-8')
did_load = controller[controller.index('public override func windowDidLoad()'):]
did_load = did_load[:did_load.index('\n    }\n')]
if 'readRetrieveCommand()' not in did_load or 'resultColumnsDidReadCatalog()' not in did_load:
    failures.append('-windowDidLoad does not write the Retrieve command or does not fit the headers of the results')
if 'NSLocalizedString("Retrieve (button)", value: "Retrieve"' not in controller:
    failures.append('the Retrieve command does not take the text "Retrieve (button)"')

SEGMENT = re.compile(r'<segment label="([^"]*)"[^>]*\btag="2"')
english_nib = (RESOURCES / 'en.lproj/Query.xib').read_text(encoding='utf-8')
if SEGMENT.findall(english_nib) != ['Retrieve']:
    sys.exit(f'the Retrieve segment was not found in the English nib: {SEGMENT.findall(english_nib)}')
languages = sorted(path.parent.name[:-len('.lproj')] for path in RESOURCES.glob('*.lproj/Localizable.strings'))
if len(languages) != 12:
    sys.exit(f'the catalogs were not found: {languages}')
catalogs = {language: catalog(language) for language in languages}
for language in languages:
    command = catalogs[language].get('Retrieve (button)')
    if not command:
        failures.append(f'{language}: the catalog has no text for the Retrieve command')
        continue
    copy = RESOURCES / f'{language}.lproj/Query.xib'
    if language != 'en' and copy.exists():
        written = [html.unescape(label) for label in SEGMENT.findall(copy.read_text(encoding='utf-8'))]
        if written != [command]:
            failures.append(f'{language}: the copy of the nib writes {written} on the Retrieve segment, the catalog {command!r}')
if catalogs['en'].get('Retrieve (button)') != 'Retrieve':
    failures.append('English does not write Retrieve on the Retrieve command')
if catalogs['es'].get('Retrieve (button)') != 'Recuperar' or catalogs['es'].get('Retrieve') == 'Recuperar':
    failures.append('Spanish does not tell the command (Recuperar) from the heading of the column of retrieve modes')

# The headers.
results = (root / 'Horos/Sources/QueryController+Results.swift').read_text(encoding='utf-8')
fit = results[results.index('func resultColumnsDidReadCatalog()'):]
fit = fit[:fit.index('\n    }\n')]
saved = re.search(r'guard preferences\.array\(forKey: [^\n]*\) == nil else \{\s*fittingResultColumns = true\s*'
                  r'PaneFit\.widenColumnsToHeaders\(of: outlineView\)\s*fittingResultColumns = false\s*return\s*\}', fit)
if not saved:
    failures.append('a saved layout does not widen the columns that cut their header, or saves the widening as the user\'s')
fitted = re.search(r'fittingResultColumns = true\s*PaneFit\.fitColumns\(of: outlineView\)\s*fittingResultColumns = false', fit)
if not saved or not fitted or fitted.start() < saved.end():
    failures.append('the columns of the results are not fitted only when no layout was saved')
if not re.search(r'names\.minWidth = max\(minimum, min\(names\.width, names\.maxWidth\)\)',
                 fit[saved.end() if saved else 0:fitted.start() if fitted else 0]):
    failures.append('the column of the names does not keep its width while the others are fitted')
if not re.search(r'func saveTableColumns\(\) \{\s*guard let outlineView, !fittingResultColumns else \{ return \}', results):
    failures.append('the widths of the fit would be saved as the layout of the user')

back = results[results.index('func contextMenuSelected('):]
back = back[:back.index('\n    }\n')]
if not re.search(r'outlineView\.addTableColumn\(column\)\s*(//[^\n]*\s*)*PaneFit\.widenColumnsToHeaders\(of: outlineView\)', back):
    failures.append('a column the header menu brings back may cut its header')

RESULTS = ('patientID', 'birthdate', 'theDescription', 'modality', 'numberImages', 'date', 'time', 'calledAET',
           'accessionNumber', 'comment', 'stateText', 'serverComment', 'serverStateText', 'institutionName',
           'performingPhysician', 'referringPhysician')
CUT_IN_SPANISH = {'patientID', 'birthdate', 'theDescription', 'modality', 'accessionNumber'}
with tempfile.TemporaryDirectory(prefix='horos-query-headers-') as folder:
    work = Path(folder)
    nib = panes.compile_nib(english_nib, work, 'Query')
    helper = (root / panes.HELPER).read_text(encoding='utf-8')
    runs = []
    # A saved layout: the widths of the nib, which are those of the English headers, with the descriptions made wider.
    widths = {identifier: float(width) for identifier, width in
              re.findall(r'<tableColumn identifier="(\w+)"[^>]*? width="([\d.]+)"', english_nib) if identifier in RESULTS + ('name',)}
    if set(widths) != set(RESULTS + ('name',)):
        sys.exit(f'the widths of the columns were not read from the nib: {sorted(widths)}')
    widths['theDescription'] = 300.0
    layout = {'savedWidths': widths, 'savedTable': 'patientID', 'sortedBy': 'name', 'widenColumns': True}
    for language in ('es', 'it-IT', 'ja-JP'):
        runs.append((f'{language}|nib', nib, catalogs[language], {'fitColumns': False}))
        runs.append((f'{language}|fit', nib, catalogs[language], {'fitColumns': True}))
        runs.append((f'{language}|saved', nib, catalogs[language], layout))
    runs.append(('en|saved', nib, catalogs['en'], layout))
    shown = panes.run_harness(helper, runs, work / 'harness')
    for language in ('es', 'it-IT', 'ja-JP', 'en'):
        report = shown.get((f'spec|{language}|saved', '')) or {}
        before = {column['id']: column for column in report.get('restored', [])}
        after = {column['id']: column for column in report.get('saved', [])}
        if not set(RESULTS + ('name',)) <= set(before) or set(before) != set(after):
            sys.exit(f'{language}: the columns of the saved layout were not read: {sorted(before)}, {sorted(after)}')
        if abs(before['theDescription']['width'] - 300) > 0.5 or abs(before['patientID']['width'] - widths['patientID']) > 0.5:
            sys.exit(f'{language}: the saved widths were not given to the columns')
        widened = set()
        for identifier, column in after.items():
            needed = column['header'] + (before[identifier]['indicator'] if identifier == 'name' else 0)
            was = before[identifier]['width']
            if column['title'] and needed > column['width'] + 0.5:
                failures.append(f'{language}: under a saved layout the header "{column["title"]}" needs {needed:.0f} points, '
                                f'its column has {column["width"]:.0f}')
            if column['width'] < was - 0.5:
                failures.append(f'{language}: the column "{identifier}" of a saved layout went from {was:.0f} to {column["width"]:.0f} points')
            if column['width'] > was + 0.5:
                widened.add(identifier)
                if not column['title'] or needed <= was:
                    failures.append(f'{language}: the column "{identifier}" of a saved layout was widened from {was:.0f} to '
                                    f'{column["width"]:.0f} points, and its header needs {needed:.0f}')
        if language == 'es' and not CUT_IN_SPANISH - {'theDescription'} <= widened:
            failures.append(f'es: a layout saved with the widths of the nib was expected to cut the headers of '
                            f'{sorted(CUT_IN_SPANISH - {"theDescription"})}, and those of {sorted(widened)} were widened')
        if language == 'en' and (not widened <= {'serverComment', 'performingPhysician'}
                                 or any(after[identifier]['width'] - before[identifier]['width'] > 3 for identifier in widened)):
            failures.append(f'en: the columns {sorted(widened)} of a saved layout were widened under the English headers')
        if bool(widened) != bool(report.get('widened')):
            failures.append(f'{language}: the widening says {report.get("widened")} and widened {sorted(widened)}')
    for language in ('es', 'it-IT', 'ja-JP'):
        columns = {}
        for state in ('nib', 'fit'):
            report = shown.get((f'spec|{language}|{state}', ''))
            found = {column['id']: column for column in (report or {}).get('columns', []) if column['id'] in RESULTS}
            if set(found) != set(RESULTS):
                sys.exit(f'{language}: the columns of the results were not read: {sorted(found)}')
            columns[state] = found
        for identifier in RESULTS:
            column = columns['fit'][identifier]
            if column['header'] > column['width'] + 0.5:
                failures.append(f'{language}: the header "{column["title"]}" needs {column["header"]:.0f} points, '
                                f'its column has {column["width"]:.0f} after the fit')
        if language == 'es':
            cut = {identifier for identifier in RESULTS
                   if columns['nib'][identifier]['header'] > columns['nib'][identifier]['width'] + 0.5}
            if not CUT_IN_SPANISH <= cut:
                failures.append(f'es: the widths of the nib were expected to cut the headers of {sorted(CUT_IN_SPANISH)}, '
                                f'and cut those of {sorted(cut)}: the check no longer shows what the fit is for')

if failures:
    print('\n'.join(failures))
    sys.exit(f'{len(failures)} failures')
print('PASS: the Retrieve command has its own text in the twelve catalogs, and no header of the results is cut '
      'in Spanish, Italian or Japanese once the columns are fitted, or widened under a saved layout')
