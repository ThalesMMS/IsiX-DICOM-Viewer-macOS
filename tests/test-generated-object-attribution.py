#!/usr/bin/env python3
"""What the application writes into the objects it generates names the
application alone.

- The footer of the HTML export is a plain sentence with the application's
  name: no link, since a link under that name must lead to the application's
  own page and to no other site. The key is in every catalog, and the former
  key, which carried a link, is in none.
- The encapsulated PDF the 2D viewer makes of a study's document declares the
  application as Manufacturer (0008,0070), whatever the kind of document: the
  object is made here, and no other maker is written into it.

`<git revision>` as an optional argument reads the files from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
APPLICATION = 'IsiX DICOM Viewer'
FOOTER = f'Made with {APPLICATION}'
LANGUAGES = ('ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
failures = []


def data(relative):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                              capture_output=True, check=True).stdout
    return (root / relative).read_bytes()


def require(condition, message):
    if not condition:
        failures.append(message)


# --- the footer of the HTML export -------------------------------------------
summary = data('Horos/Sources/QTExportHTMLSummary.swift').decode('utf-8')
footer = re.search(r'footerString = NSLocalizedString\("((?:\\.|[^"\\])*)"', summary)
require(footer, 'the HTML export has no localized footer')
if footer:
    key = footer.group(1)
    require(key == FOOTER, f'the footer of the HTML export is not "{FOOTER}": {key}')
    require('<a' not in key and 'href' not in key and 'http' not in key, 'the footer of the HTML export has a link')
for language in LANGUAGES:
    raw = data(f'Horos/Resources/{language}.lproj/Localizable.strings')
    text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    entries = re.findall(r'^"%s" = "((?:\\.|[^"\\])*)";$' % re.escape(FOOTER), text, re.M)
    require(len(entries) == 1, f'{language}: {len(entries)} entries of the footer of the HTML export')
    for value in entries:
        require(APPLICATION in value, f'{language}: the footer does not name the application')
        require('<' not in value and 'http' not in value, f'{language}: the footer has markup or a link')
    require('"Made with <a href=\\"' not in text, f'{language}: the former footer, with its link, is still in the catalog')

# --- the Manufacturer of the encapsulated PDF --------------------------------
exporter = data('Horos/Sources/ViewerImageExporter.swift').decode('utf-8')
start = exporter.find('private static func pdf2dcmConfiguration(')
require(start >= 0, 'the 2D viewer has no configuration of the encapsulated PDF')
if start >= 0:
    body = exporter[start:]
    body = body[:body.find('\n    }\n')]
    lines = [line.strip() for line in body.splitlines() if '00080070:' in line]
    require(len(lines) == 1, f'{len(lines)} lines write the Manufacturer of the encapsulated PDF')
    for line in lines:
        require(line == 'content += "\\r# Manufacturer\\r00080070:%s"' % APPLICATION,
                f'the Manufacturer of the encapsulated PDF is not the application alone: {line}')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: the footer of the HTML export and the Manufacturer of the encapsulated PDF name the application alone')
