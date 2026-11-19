#!/usr/bin/env python3
"""English-identical catalog values must be on the residual list.

No text of the application is limited to ASCII any more: the annotations of a
view and the texts VTK holds for a 3D view are drawn on the view's overlay, in
any script. A comment of the English catalog that asked for ASCII would ask
for what nothing checks, and is refused.

The list of what stays English is one for every language, and the tests of the
eleven translations read it: a text on it may be the English one in any of
them. An entry no language needs any more lets the translation it once
excused come back in English unseen: the background of the summary of a 3D
preset stayed on the list after ten catalogs had translated it. So an entry
that a catalog holds is refused once every language writes it in its own
words. A language still needs an entry when the value of its catalog is the
English one, or, in a language of another script, has no letter of that
script (« WL/WW » for « WL / WW »); when a localized copy of a nib shows the
entry as it is; or when Spanish, Italian or Japanese, which read the English
nibs with their catalogs, have no text of their own for one a nib shows.
NAMES_FOR_ANOTHER_CHECK says which sets of the tool are left out, and why. An
entry that no catalog and no nib holds at all is not judged here: nothing
says it is translated.
"""
import html
import importlib.util
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "residual", root / "tools/host-localization-residual.py")
residual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(residual)


def load(path):
    return json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)]))


en = load(root / "Horos/Resources/en.lproj/Localizable.strings")
source = (root / "Horos/Resources/en.lproj/Localizable.strings").read_text(encoding="utf-16")
limited = [literal for comment, literal in re.findall(r'/\*(.*?)\*/\s*("(?:\\.|[^"\\])*")\s*=', source, re.S)
           if re.search(r"ASCII|NO ACCENTS", comment)]
assert not limited, f"comments of the English catalog limit texts to ASCII: {limited}"

unexpected = []
for language, folder in (("es", "es"), ("it-IT", "it-IT")):
    catalog = load(root / f"Horos/Resources/{folder}.lproj/Localizable.strings")
    assert en.keys() <= catalog.keys(), language
    for key, value in catalog.items():
        english = en.get(key, key)
        if value in (key, english) and not residual.is_residual(key, english):
            unexpected.append(f"{language}: {key!r}")

assert not unexpected, "unlisted English fallback:\n" + "\n".join(unexpected[:40])

# The entries of the list that no language needs any more.
LANGUAGES = ("ar", "de", "es", "fr", "hi", "it-IT", "ja-JP", "ko", "pt-BR", "ru", "zh-Hans")
# The letters of a language that does not write in the Latin script: a value without one keeps the English words.
SCRIPT = {"ar": r"[\u0600-\u06FF]", "hi": r"[\u0900-\u097F]", "ko": r"[가-힣]", "ru": r"[А-Яа-яЁё]",
          "zh-Hans": r"[\u4e00-\u9fff]", "ja-JP": r"[\u3040-\u30ff\u4e00-\u9fff]"}
# The languages with no copy of the window nibs: they show the texts of the English nibs their catalog translates.
READ_ENGLISH_NIBS = ("es", "it-IT", "ja-JP")
# Sets of the tool that another check reads as names, whatever the catalogs do with them: the products, which
# tests/test-mixed-translations.py looks for inside a translation.
NAMES_FOR_ANOTHER_CHECK = residual.PRODUCT
NIB_TEXT = re.compile(r'\b(?:title|label|toolTip|placeholderString|alternateTitle|stringValue|headerToolTip|paletteLabel)="([^"]*)"')
NIB_STRING = re.compile(r'<string key="[^"]*">(.*?)</string>', re.S)


def nib_texts(paths):
    """The texts the nibs at `paths` hold, each as it is and without the spaces and the colon around it."""
    texts = set()
    for path in paths:
        document = path.read_text(encoding="utf-8")
        for raw in NIB_TEXT.findall(document) + NIB_STRING.findall(document):
            text = html.unescape(raw)
            texts.update({text, text.strip(), text.strip().rstrip(":"), text.strip().rstrip(":").strip()})
    return texts


def english_words(language, value, english):
    """Whether `value`, the text of `language` for `english`, keeps the English words."""
    return value == english or (language in SCRIPT and not re.search(SCRIPT[language], value))


catalogs = {language: load(root / f"Horos/Resources/{language}.lproj/Localizable.strings") for language in LANGUAGES}
needed = set()
for language, catalog in catalogs.items():
    for key, value in catalog.items():
        english = en.get(key, key)
        if value == key or english_words(language, value, english):
            needed.update((key, english))
    needed |= nib_texts([*(root / f"Horos/Resources/{language}.lproj").glob("*.xib"),
                         *(root / "Preference Panes").glob(f"*/{language}.lproj/*.xib")])
english_nibs = nib_texts([*(root / "Horos/Resources/en.lproj").glob("*.xib"), *(root / "Preference Panes").glob("*/Base.lproj/*.xib")])
needed |= {text for text in english_nibs
           if any(english_words(language, catalogs[language].get(text, text), text) for language in READ_ENGLISH_NIBS)}
held = set(en) | set(en.values()) | {key for catalog in catalogs.values() for key in catalog}
stale = sorted(entry for entry in residual.EXACT - NAMES_FOR_ANOTHER_CHECK if entry in held and entry not in needed)
assert not stale, ("every language has its own text for these entries of tools/host-localization-residual.py; "
                   "take them off the list:\n" + "\n".join(repr(entry) for entry in stale))
assert len(english_nibs) > 2000 and len(needed) > 300, "the nibs or the catalogs were not read"
print(f"PASS: residual English values are listed, and the {len(residual.EXACT)} entries of the list are still needed by a language "
      "or held by no catalog; no comment of the English catalog limits a text to ASCII")
