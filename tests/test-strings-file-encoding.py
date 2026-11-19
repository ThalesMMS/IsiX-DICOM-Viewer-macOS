#!/usr/bin/env python3
"""Every .strings file has to decode with the encoding the project declares.

`builtin-copyStrings` is told the encoding from the project's `fileEncoding`,
and it does not guess. For UTF-16 (`fileEncoding = 10`) Foundation reads a
byte-order mark, and without one it falls back to big-endian, so a UTF-16LE
file that lost its mark stops decoding and the whole target fails to build:

    en.lproj/Localizable.strings:1:1: error: could not decode input file
    using specified encoding: Unicode (UTF-16)

That is easy to reintroduce, because a script that rewrites the catalogue
produces a file that every editor and `python3` still read correctly.

A file can also decode and hold text that was decoded wrongly before it was
written: UTF-8 read as Latin-1 or as Windows-1252 leaves "ModalitÃ " for
"Modalità" and "unâ€™ora" for "un’ora", and the application shows it so. No
catalogue and no localized copy of a nib holds such a run: one or more
characters that, taken back to the bytes they were read from, are one
character of UTF-8. A capital with a tilde before a plain letter, as in the
Portuguese "NÃO" and "IMPORTAÇÃO", is no such run.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []

ENCODINGS = {'4': 'utf-8', '10': 'utf-16', '30': 'utf-8'}  # NSUTF8 / NSUTF16 / NSMacOSRoman-era ids in use here

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8', errors='replace')
references = re.findall(
    r'isa = PBXFileReference;[^}]*?fileEncoding = (\d+);[^}]*?'
    r'lastKnownFileType = text\.plist\.strings;[^}]*?path = ("?)([^";]+)\2;',
    project)

if not references:
    failures.append('no .strings file reference with an explicit fileEncoding was found')

checked = 0
for encoding_id, _quote, path in references:
    matches = sorted(root.glob('**/' + path))
    matches = [m for m in matches if not {'build', 'local-validation'} & set(m.relative_to(root).parts)]
    if not matches:
        failures.append('%s is declared in the project but missing from the checkout' % path)
        continue
    for source in matches:
        checked += 1
        data = source.read_bytes()
        relative = source.relative_to(root)
        if encoding_id == '10':
            if data[:2] not in (b'\xff\xfe', b'\xfe\xff'):
                failures.append('%s is declared UTF-16 but has no byte-order mark, so '
                                'builtin-copyStrings reads it as big-endian and fails' % relative)
                continue
            try:
                data.decode('utf-16')
            except UnicodeDecodeError as exc:
                failures.append('%s does not decode as UTF-16: %s' % (relative, exc))
        else:
            codec = ENCODINGS.get(encoding_id)
            if codec is None:
                failures.append('%s declares fileEncoding %s, which this check does not know'
                                % (relative, encoding_id))
                continue
            try:
                data.decode(codec)
            except UnicodeDecodeError as exc:
                failures.append('%s does not decode as %s: %s' % (relative, codec, exc))

# The other catalogues carry no declared encoding, so Xcode sniffs them; they
# still have to be readable as one of the two encodings it can sniff.
for source in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = source.read_bytes()
    relative = source.relative_to(root)
    if data[:2] in (b'\xff\xfe', b'\xfe\xff'):
        try:
            data.decode('utf-16')
        except UnicodeDecodeError as exc:
            failures.append('%s starts with a UTF-16 mark but does not decode: %s' % (relative, exc))
    else:
        try:
            data.decode('utf-8')
        except UnicodeDecodeError as exc:
            failures.append('%s has no byte-order mark and is not UTF-8: %s' % (relative, exc))

# What UTF-8 leaves when it is read one byte a character: the lead byte of a
# sequence of two or three, then its continuation bytes, as Latin-1 shows them
# or as Windows-1252 does the ones from 0x80 to 0x9F.
WINDOWS = ''.join(bytes([byte]).decode('cp1252') for byte in range(0x80, 0xA0) if byte not in (0x81, 0x8D, 0x8F, 0x90, 0x9D))
MISREAD = re.compile('[\u00c2-\u00ef][\u0080-\u00bf%s]{1,2}' % re.escape(WINDOWS))


def misread(text):
    """The runs of `text` that are UTF-8 read as Latin-1 or Windows-1252, with what they were."""
    found = []
    for match in MISREAD.finditer(text):
        for codec in ('cp1252', 'latin-1'):
            try:
                found.append((match.group(0), match.group(0).encode(codec).decode('utf-8')))
                break
            except (UnicodeEncodeError, UnicodeDecodeError):
                continue
    return found


for wrong, right in (('ModalitÃ\u00a0 di fusione', 'à'), ('rubrica Ã¨ necessario', 'è'), ('unâ€™ora', '’'), ('vuotiâ€¦', '…')):
    if [was for _, was in misread(wrong)] != [right]:
        failures.append('the check of misread UTF-8 does not find %r in %r' % (right, wrong))
for fine in ('A hora da injeção NÃO PODE ser posterior', 'ÚLTIMA IMPORTAÇÃO: ', 'Épaisseur : 3 mm', 'Größe', 'Вид', '画像サイズ', 'السماكة'):
    if misread(fine):
        failures.append('the check of misread UTF-8 takes %r for one' % fine)

texts = sorted((root / 'Horos/Resources').glob('*.lproj/*.strings'))
texts += sorted((root / 'Horos/Resources').glob('*.lproj/*.xib'))
texts += sorted((root / 'Preference Panes').glob('*/*.lproj/*.xib'))
texts += sorted((root / 'Preference Panes').glob('*/*.lproj/*.strings'))
read = 0
for source in texts:
    data = source.read_bytes()
    try:
        text = data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    except UnicodeDecodeError:
        continue  # said above for a catalogue; a nib that does not decode does not compile
    read += 1
    for number, line in enumerate(text.splitlines(), 1):
        for run, was in misread(line):
            failures.append('%s:%d holds %r, which is %r read in another encoding' % (source.relative_to(root), number, run, was))
if read < 500:
    failures.append('only %d catalogues and copies of nibs were read for misread text' % read)

if checked == 0:
    failures.append('no declared .strings file was actually checked')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: %d declared .strings file(s) decode with the declared encoding; no misread UTF-8 in %d catalogues and copies of nibs' % (checked, read))
