#!/usr/bin/env python3
"""The Japanese catalog keeps what a format needs and what is stored by name.

A value is put through the same `String(format:)` as its English key: it takes
the same arguments, of the same kinds. A value with one conversion more, or with
`%d` for `%@`, reads memory that is not its argument. What is checked, for every
entry of `ja-JP.lproj/Localizable.strings`:

- the conversions of the value are those of the key, whatever their order when
  they are numbered (`%1$@`), in the same order when they are not;
- the names stored in a database, a 3D state or the preferences stay as the
  English spells them (the default albums, the opacity tables, "No CLUT",
  "No Filter"): translated, what another language saved is not found again.
"""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
catalog = json.loads(subprocess.check_output(
    ['plutil', '-convert', 'json', '-o', '-', str(root / 'Horos/Resources/ja-JP.lproj/Localizable.strings')]))

CONVERSION = re.compile(r'%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?((?:ll|l|hh|h|q|z)?[@dDiuUxXoOfeEgGcCsSaAp])')


def conversions(text):
    """The conversions of a format, as (position, kind), numbered ones by their number."""
    found = CONVERSION.findall(text.replace('%%', ''))
    if any(number for number, _ in found):
        return sorted((int(number or 0), kind) for number, kind in found)
    return [(index + 1, kind) for index, (_, kind) in enumerate(found)]


failures = []
for key, value in catalog.items():
    if conversions(key) != conversions(value):
        failures.append(f'{key!r} = {value!r}: the conversions differ')

albums = (root / 'Modules/IsiXDatabase/Sources/AlbumCatalog.swift').read_text()
stored = set(re.findall(r'^\s*\("([^"]+)", (?:nil|"[^"]*")\),?$', albums, re.M))
if len(stored) < 15 or 'Interesting Cases' not in stored:
    sys.exit(f'the default albums were not read from AlbumCatalog.swift: {sorted(stored)}')
stored |= {'Linear Table', 'Logarithmic Table', 'Logarithmic Inverse Table', 'No CLUT', 'No Filter'}
for name in sorted(stored):
    if catalog.get(name, name) != name:
        failures.append(f'{name!r} is stored by name and is translated: {catalog[name]!r}')

if failures:
    print('\n'.join(failures[:40]))
    sys.exit(f'{len(failures)} entries of the Japanese catalog fail')
print(f'PASS: {len(catalog)} Japanese entries keep the conversions of their keys, and {len(stored)} stored names stay as they are')
