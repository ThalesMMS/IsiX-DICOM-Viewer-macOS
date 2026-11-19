#!/usr/bin/env python3
"""Every line of the summary of a 3D preset is a text of the catalog, with one form in every language.

The sheet that saves the settings of the volume rendering as a preset, and the
panel that describes the preset chosen, list what the preset holds: window
level, colour table, opacity, shadings, filters, projection and background.
The lines were written one by one, and two of them were of no language: the
background read «Background: red:0%, green:0%, blue:0%» in ten of the eleven
translations, and the line of the filters was put together from a word, a
colon and a value, so that Russian read «фильтр: (нет).», the word as it
stands inside a sentence and a full stop no other line has.

- In the source, every text a field of the summary is given is a text of the
  catalog, or a format of the catalog filled with the values of the preset:
  no literal is left in those statements once the catalog texts, the keys of
  the preset and the list separator are taken away. PLACEHOLDER names the one
  text that is not: what stands for a value the preset lacks.
- Every key of the summary is in the twelve catalogs, and a translation is the
  English text only where SAME_TEXT says so, with its reason.
- In every language a line starts with a capital where its script has them,
  ends with no full stop, and has the label, the colon and the value written
  as the other lines of that language write them.
- The lines that hold no name of the user's (the background at 100%, the
  opacity of a 16-bit table, the shadings off, no filter, the widest of the
  projections, a window level) fit the fields of the sheet and of the panel,
  each on one line, in the nine copies of VR.xib, and in the English nib with
  the texts of the Spanish, Italian and Japanese catalogs
  (tests/pane_titles.py).
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_titles  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
SOURCE = ROOT / 'Horos/Sources/VRController+Presets.swift'
COPIES = ('en', 'ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')
CATALOG_LANGUAGES = ('es', 'it-IT', 'ja-JP')
TRANSLATIONS = COPIES[1:] + CATALOG_LANGUAGES

# What stands for a value a preset lacks: a preset saved by the application has them all.
PLACEHOLDER = '"(null)"'

# Keys whose translation is the English text, with the languages it is so in.
ACRONYMS = {
    # The abbreviations of the window level and width, which the windows of the application show so everywhere.
    'WL: %.0f WW: %.0f',
    # The initials of the three channels beside the colour itself, in the panel.
    'r:%.0f%%, g:%.0f%%, b:%.0f%%',
}
SAME_TEXT = {
    # The German words are the English ones.
    'Filter: %@': {'de'}, 'Name: %@': {'de'}, 'Parallel': {'de'},
    # And so are the French ones.
    'Projection: %@': {'fr'}, 'Perspective': {'fr'},
}

LOCALIZED = re.compile(r'NSLocalizedString\("((?:\\.|[^"\\])*)", comment: ""\)')
FIELD = re.compile(r'\b((?:settings|info)\w+TextField)\?\.stringValue = ((?:[^\n]|\n {20,})*)')
PRESET_KEY = re.compile(r'(?:forKey: |number\(preset, |flag\(preset, )"[A-Za-z0-9]+"')
LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')

failures = []
source = SOURCE.read_text(encoding='utf-8')


def function(name):
    """The body of the function `name` of the source."""
    start = source.index(f'func {name}(')
    end = source.index('\n    }\n', start)
    return source[start:end]


keys = set()
fields = {}
for match in FIELD.finditer(source):
    statement = match.group(2)
    found = LOCALIZED.findall(statement)
    keys.update(found)
    fields.setdefault(match.group(1), []).extend(found)
    left = LITERAL.findall(PRESET_KEY.sub('', LOCALIZED.sub('', statement)))
    if left:
        failures.append(f'{match.group(1)} is given {left}, a text that is not of the catalog')
    if not found and 'filtersDescription(' not in statement:
        failures.append(f'{match.group(1)} is given no text of the catalog: {statement[:80]}')
if len(fields) < 15:
    failures.append(f'only {sorted(fields)} were found as fields of the summary')
for name, separators in (('filtersDescription', ('"\\($0)"', 'separator: ", "')), ('projectionName', (PLACEHOLDER,))):
    body = function(name)
    found = LOCALIZED.findall(body)
    keys.update(found)
    for separator in separators:
        body = body.replace(separator, '')
    left = LITERAL.findall(LOCALIZED.sub('', body.split('{', 1)[1]))
    if left or not found:
        failures.append(f'{name} builds a line from {left}, a text that is not of the catalog')
for name in ('settingsConvolutionFilterTextField', 'infoConvolutionFilterTextField'):
    fields.setdefault(name, []).extend(LOCALIZED.findall(function('filtersDescription')))
if PLACEHOLDER not in function('text'):
    failures.append(f'the text of a value a preset lacks is no longer {PLACEHOLDER}')
if len(keys) < 17:
    failures.append(f'only {len(keys)} keys of the summary were found: {sorted(keys)}')


def catalog(language):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
                                               str(RESOURCES / f'{language}.lproj/Localizable.strings')]))


catalogs = {language: catalog(language) for language in ('en',) + TRANSLATIONS}
SPECIFIER = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:[hlqLzt]*)([@dfiu])')
# A label, its colon and the value: «Opacity: %@», «不透明度：%@».
LINE = re.compile(r'^[^:：]+?(\s?[:：]\s?)\S')
lines = sorted(key for key in keys if ': ' in key and key not in ACRONYMS)
for language, table in catalogs.items():
    missing = sorted(keys - table.keys())
    if missing:
        failures.append(f'{language}: the catalog lacks {missing}')
        continue
    colons = {}
    for key in sorted(keys):
        value = table[key]
        if sorted(SPECIFIER.findall(value)) != sorted(SPECIFIER.findall(key)):
            failures.append(f'{language}: "{value}" does not take the values of "{key}"')
        if language != 'en' and value in (key, catalogs['en'].get(key, key)) and key not in ACRONYMS \
                and language not in SAME_TEXT.get(key, ()):
            failures.append(f'{language}: "{key}" is not translated')
        if language != 'en' and value not in (key, catalogs['en'].get(key, key)) and language in SAME_TEXT.get(key, ()):
            failures.append(f'{language}: "{key}" is translated, "{value}", and SAME_TEXT says it is the English text')
        if key in ACRONYMS:
            continue
        if value[:1] != value[:1].upper():
            failures.append(f'{language}: "{value}" starts with no capital')
        if value.rstrip().endswith(('.', '。', '।', '۔')):
            failures.append(f'{language}: "{value}" ends with a full stop, and the lines of the summary have none')
        if key in lines:
            colon = LINE.match(value)
            if not colon:
                failures.append(f'{language}: "{value}" is not a label, a colon and a value')
            else:
                colons.setdefault(colon.group(1), []).append(value)
    if len(colons) > 1:
        failures.append(f'{language}: the lines of the summary write their colon in {len(colons)} ways: '
                        + ' / '.join(f'{values[0]}' for values in colons.values()))

# The lines that hold no name of the user's, with the widest values they take, by the field they are shown in.
SAMPLES = {
    'WL: %.0f WW: %.0f': (-1024.0, 4096.0),
    'Background: red:%.0f%%, green:%.0f%%, blue:%.0f%%': (100.0, 100.0, 100.0),
    'r:%.0f%%, g:%.0f%%, b:%.0f%%': (100.0, 100.0, 100.0),
    'Opacity: (defined in the CLUT)': (),
    'Shadings: Off': (),
    'Filter: (none)': (),
}
POSITIONAL = re.compile(r'%(\d+)\$')
ISOLATES = dict.fromkeys(map(ord, '⁨⁩'))


def filled(table, key, values):
    """The text of `key` in a catalog with `values`, as String(format:) gives it for these formats."""
    text = table[key]
    order = [int(place) - 1 for place in POSITIONAL.findall(text)] or list(range(len(values)))
    return POSITIONAL.sub('%', text) % tuple(values[place] for place in order)


def shown(table):
    """{field: the widest line without a name of the user's that the field shows}."""
    projections = [table['Projection: %@'].replace('%@', table[name]) for name in ('Perspective', 'Parallel', 'Endoscopy')]
    texts = {}
    for field, field_keys in fields.items():
        candidates = [filled(table, key, SAMPLES[key]) for key in field_keys if key in SAMPLES]
        if 'Projection: %@' in field_keys:
            candidates += projections
        if candidates:
            texts[field] = max(candidates, key=len)
    return texts


def with_summary(xib, table, target):
    """A copy of the nib whose fields of the summary hold the lines of `table`; the ids of those fields."""
    text = xib.read_text(encoding='utf-8')
    ids = {}
    for field, line in shown(table).items():
        outlet = re.search(r'<outlet property="%s" destination="([^"]+)"' % field, text)
        if not outlet:
            failures.append(f'{xib.parent.name}: VR.xib has no outlet {field}')
            continue
        block = re.search(r'<textField [^>]*\bid="%s"[^>]*>.*?</textField>' % re.escape(outlet.group(1)), text, re.S)
        attribute = escape(line.translate(ISOLATES), {'"': '&quot;'})
        new, count = re.subn(r'(<textFieldCell [^>]*?) title="[^"]*"', lambda m: f'{m.group(1)} title="{attribute}"', block.group(0), count=1)
        if not count:
            new, count = re.subn(r'<string key="title">.*?</string>', lambda m: f'<string key="title">{escape(line.translate(ISOLATES))}</string>',
                                 block.group(0), count=1, flags=re.S)
        if not count:
            failures.append(f'{xib.parent.name}: the field {field} of VR.xib has no title to replace')
            continue
        text = text[:block.start()] + new + text[block.end():]
        ids[outlet.group(1)] = field
    target.write_text(text, encoding='utf-8')
    return ids


if not pane_titles.available():
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(2)
room = ''
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-vr-preset-summary-') as folder:
        copies, ids = {}, {}
        for language in COPIES + CATALOG_LANGUAGES:
            nib = RESOURCES / f'{language if language in COPIES else "en"}.lproj/VR.xib'
            copies[language] = Path(folder) / f'{language}.xib'
            ids[language] = with_summary(nib, catalogs[language], copies[language])
        measured = [item for item in pane_titles.measure(copies, separate_nibs=True, every_window=True)
                    if 'error' in item or item.get('id') in ids.get(item['language'], {})]
        failures += pane_titles.misfits(measured)
        # A field of the sheet wraps, and the sheet gives a second line the room: a line of the summary is one
        # line, as the nib draws its rows, so the width of the field has to hold it whole.
        failures += [f'{item["language"]}: "{item["title"]}" needs {item["needed"]:.0f} points on one line, its field '
                     f'({ids[item["language"]][item["id"]]}) has {item["width"]:.0f}'
                     for item in measured if 'id' in item and item['needed'] > item['width'] + 3]
        widest = max((item for item in measured if 'id' in item), key=lambda item: item['needed'] / item['width'])
        room = f'; the tightest is "{widest["title"]}" ({widest["language"]}), {widest["needed"]:.0f} points in {widest["width"]:.0f}'
        for language in copies:
            seen = {item['id'] for item in measured if item['language'] == language and 'id' in item}
            unseen = sorted(field for identifier, field in ids[language].items() if identifier not in seen)
            if unseen:
                failures.append(f'{language}: the fields {unseen} of the summary were not measured')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(f'{len(failures)} lines of the summary of a 3D preset are not of the catalog, of one form, or do not fit')
print(f'PASS: the {len(keys)} texts of the summary of a 3D preset are of the catalog in {len(catalogs)} languages, of one form, '
      f'and the lines of {len(fields)} fields fit their sheet and their panel' + room)
