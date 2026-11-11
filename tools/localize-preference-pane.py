#!/usr/bin/env python3
"""Rebuild the localized copies of a preference pane from its Base xib.

A pane has one geometry for every language: each localized copy is the Base
file line for line, with only the texts a user reads translated. After the
Base xib of a pane changes, this writes every copy again:

    python3 tools/localize-preference-pane.py OSIViewerPreferencePanePref.xib

A text keeps the translation its copy already had for the same element and the
same English (read from the committed Base and copy, so a translation written
by hand in a copy survives); a new text takes the value of the language's
catalog, and stays in English when the catalog has none. `--check` writes
nothing and fails when a copy is not what this would write.
"""
from pathlib import Path
import argparse
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ATTRIBUTES = ('title', 'label', 'toolTip', 'placeholderString', 'alternateTitle', 'stringValue', 'paletteLabel', 'headerToolTip')
TEXT = re.compile(r' (%s)="([^"]*)"' % '|'.join(ATTRIBUTES))
IDENTIFIER = re.compile(r' id="([^"]+)"')


def copies(name):
    """{language: path} of the localized copies of a pane, and its Base."""
    base = next((ROOT / 'Preference Panes').glob(f'*/Base.lproj/{name}'))
    found = {}
    japanese = base.parent.parent / 'ja-JP.lproj' / name
    if japanese.exists():
        found['ja-JP'] = japanese
    for path in sorted((ROOT / 'Horos/Resources').glob(f'*.lproj/{name}')):
        if path.parent.stem != 'en':
            found[path.parent.stem] = path
    return base, found


def committed(path):
    """The lines of a file as the last commit has it, or None when it is new."""
    result = subprocess.run(['git', 'show', f'HEAD:{path.relative_to(ROOT).as_posix()}'], cwd=ROOT, capture_output=True)
    return result.stdout.decode('utf-8').split('\n') if result.returncode == 0 else None


def catalog(language):
    path = ROOT / 'Horos/Resources' / f'{language}.lproj' / 'Localizable.strings'
    return plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)]))


def unescaped(text):
    for entity, character in (('&quot;', '"'), ('&lt;', '<'), ('&gt;', '>'), ('&#10;', '\n'), ('&apos;', "'"), ('&amp;', '&')):
        text = text.replace(entity, character)
    return text


def escaped(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;').replace('\n', '&#10;')


def kept(old_base, old_copy):
    """{(element id, attribute, English): translation} of a committed copy."""
    translations = {}
    if old_base is None or old_copy is None or len(old_base) != len(old_copy):
        return translations
    for english_line, translated_line in zip(old_base, old_copy):
        identifier = IDENTIFIER.search(english_line)
        english = dict(TEXT.findall(english_line))
        for attribute, value in TEXT.findall(translated_line):
            if identifier and attribute in english:
                translations[(identifier.group(1), attribute, english[attribute])] = value
    return translations


def localized(base_lines, translations, strings):
    lines = []
    for line in base_lines:
        identifier = IDENTIFIER.search(line)

        def translate(match):
            attribute, english = match.group(1), match.group(2)
            if not english:
                return match.group(0)
            key = (identifier.group(1) if identifier else None, attribute, english)
            if key in translations:
                return f' {attribute}="{translations[key]}"'
            value = strings.get(unescaped(english))
            return f' {attribute}="{escaped(value)}"' if value else match.group(0)

        lines.append(TEXT.sub(translate, line))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('pane', help='the xib file name, as in OSIViewerPreferencePanePref.xib')
    parser.add_argument('--check', action='store_true', help='write nothing; fail when a copy differs')
    arguments = parser.parse_args()

    base, found = copies(arguments.pane)
    base_lines = base.read_text(encoding='utf-8').split('\n')
    old_base = committed(base)
    stale = []
    for language, path in found.items():
        lines = localized(base_lines, kept(old_base, committed(path)), catalog(language))
        text = '\n'.join(lines)
        if arguments.check:
            if path.read_text(encoding='utf-8') != text:
                stale.append(language)
        else:
            path.write_text(text, encoding='utf-8')
    if stale:
        sys.exit(f'{arguments.pane}: not what the Base xib and the catalogs give: {", ".join(stale)}')
    print(f'{arguments.pane}: {len(found)} copies {"checked" if arguments.check else "written"}')


if __name__ == '__main__':
    main()
