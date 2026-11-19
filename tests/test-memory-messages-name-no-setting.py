#!/usr/bin/env python3
"""The memory messages of the endoscopy, the curved MPR and the Path Assistant name no setting that does not exist.

Four alerts of the endoscopy, the Path Assistant's note in the curved MPR and
the curved MPR's high resolution alert told the user to «increase the resample
voxel size in the settings». There is no such setting: the size is computed.
They now say what can be done (close other studies or open a smaller series),
in the twelve languages.

Checked: no source and no catalog holds the former phrase; the sources ask for
the two new texts; every catalog has both, translated in the eleven languages
other than English.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORMER = re.compile(r'resample voxel size|increase the resample', re.I)
PATH_ASSISTANT = 'Path Assistant cannot allocate enough memory. Close other studies or open a smaller series.'
HIGH_RESOLUTION = ('Cannot compute the high resolution data.\\r\\rClose other studies or open a smaller series. '
                   'Nothing was reduced silently.')
USES = {'Horos/Sources/EndoscopyViewer.swift': (PATH_ASSISTANT, 4), 'Horos/Sources/CurvedMPRVesselTrace.swift': (PATH_ASSISTANT, 1),
        'Horos/Sources/CPRController.swift': (HIGH_RESOLUTION, 1)}
LANGUAGES = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans']


def catalog(language):
    raw = (ROOT / 'Horos/Resources' / f'{language}.lproj' / 'Localizable.strings').read_bytes()
    return raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')


failures = []
for source in sorted((ROOT / 'Horos/Sources').glob('*.swift')):
    if FORMER.search(source.read_text(encoding='utf-8')):
        failures.append(f'{source.name} still sends the user to a resample voxel size setting')
for path, (text, count) in USES.items():
    found = (ROOT / path).read_text(encoding='utf-8').count(f'NSLocalizedString("{text}", comment: "")')
    if found != count:
        failures.append(f'{path} asks for the new text {found} time(s), not {count}')
for language in LANGUAGES:
    text = catalog(language)
    if FORMER.search(text):
        failures.append(f'{language}: the catalog still holds the former phrase')
    for key in (PATH_ASSISTANT, HIGH_RESOLUTION):
        entry = re.search(r'^"' + re.escape(key) + r'" = "(.*)";$', text, re.M)
        if not entry:
            failures.append(f'{language}: no entry for «{key[:40]}…»')
        elif language != 'en' and entry.group(1) == key:
            failures.append(f'{language}: «{key[:40]}…» is not translated')
        elif key == HIGH_RESOLUTION and '\\r\\r' not in entry.group(1):
            failures.append(f'{language}: the high resolution message lost its paragraph break')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the memory messages of the endoscopy, the curved MPR and the Path Assistant say what can be done, in the '
      'twelve languages, and none names a resample voxel size setting')
