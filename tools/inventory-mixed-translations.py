#!/usr/bin/env python3
"""Catalog values that are half translated: English left inside, or in the English order.

Some Spanish entries were made by replacing words one at a time, which leaves the
sentence half English - "The remote database index está empty." - and sometimes says
the opposite of the original: "Cannot decompress images in a distant database." came
out as "Sin se puede decompress images in a distant database." The same pass left
phrases whose words are all Spanish and still in the English order, with the capitals
of the English title: "clave Imágenes" for "Key Images", "Fondo Color" for "Background
Color", "Añadir Actual WL/WW" for "Add Current WL/WW".

A value is reported when:

- it carries an English word that belongs to no sentence of the language, one of the
  function words and verbs of ENGLISH_WORDS: "Aggiungi actual WL/WW". The ones a
  language has too (Italian writes "in", "file", "database") are in its SHARED;
- it carries a word of its own English original that the language does not write the
  same way: "ratón button function" for "Mouse button function", "Errore DICOM
  Network" for "DICOM Network Error". The words both languages spell alike are in
  SHARED, and names that stay as they are in NAMES and KEPT;
- it starts in lower case where the English starts with a capital, as a phrase does
  when its first word was replaced by a common noun: "nivel de Detail";
- in Spanish, it is the translation of an English title and keeps a capital inside,
  on a word that is no name: "Estudio Fecha" for "Study Date". A readout of several
  fields, each with its label and its colon, starts every label with a capital as the
  English does: "Grosor: %@ Posición: %@" for "Thickness: %@ Location: %@";
- in Spanish, its first and last words are the translations of the first and last
  words of the English, by the catalog's own one-word entries, where Spanish puts the
  noun first: "Serie selección" for "Series Selection". A phrase that starts with a
  verb or with a word Spanish puts before the noun keeps the English order rightly
  ("Abrir imagen", "Nuevo grupo"), and so does one that ends with a participle
  ("Plugin instalado"). The rule says nothing of a phrase whose words the catalog does
  not translate one by one;
- it has a space before a comma, a closing parenthesis or a question mark, or after an
  opening one, that the English does not have, or in Spanish "a el" or "de el": what
  replacing word by word leaves around punctuation and where an article contracts.

Values that are the English sentence itself are not reported - a residual English
value is `tools/host-localization-residual.py`'s subject and
`tests/test-localization-residual.py` covers it.

    python3 tools/inventory-mixed-translations.py [--language es] [--check]

`--check` exits non-zero when anything is reported, and is what the test runs.
"""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("es", "it-IT")

# English words no Spanish sentence carries. Words both languages share (no, a, e, sin,
# total, error, final, series, ...) and technical names (DICOM, PACS, plugin) are not here.
# The ones Italian has, its own or taken from English, are in SHARED["it-IT"].
ENGLISH_WORDS = {
    "the", "this", "that", "these", "those", "there", "their", "them", "they", "its",
    "is", "are", "was", "were", "be", "been", "being", "am",
    "have", "has", "had", "having", "do", "does", "did", "doing",
    "cannot", "can", "could", "would", "should", "shall", "will", "won't", "don't",
    "and", "or", "but", "if", "then", "else", "while", "when", "where", "which", "who", "whose",
    "with", "without", "from", "into", "onto", "about", "after", "before", "during", "between",
    "of", "in", "on", "to", "for", "at", "by", "as", "than", "too", "very", "only", "also",
    "not", "never", "always", "already", "again", "still", "yet", "more", "most", "less", "least",
    "some", "any", "all", "each", "every", "both", "other", "another", "such", "same",
    "you", "your", "yours", "we", "our", "ours", "it",
    "file", "files", "folder", "image", "images", "study", "studies", "database",
    "window", "windows", "server", "screen", "drive", "disc", "disk", "user", "users",
    "empty", "full", "available", "unavailable", "missing", "unknown", "current", "new", "old",
    "open", "opened", "close", "closed", "save", "saved", "saving", "load", "loaded", "loading",
    "delete", "deleted", "remove", "removed", "add", "added", "send", "sent", "receive", "received",
    "ignored", "belongs", "locating", "decompress", "failed", "failure", "success", "please",
    "select", "selected", "choose", "chosen", "click", "press", "wait", "waiting", "retry",
    "download", "downloading", "upload", "export", "import", "created", "creating", "written",
    "read", "reading", "write", "writing", "start", "started", "stop", "stopped", "finish",
    "filter", "filters", "name", "names", "list", "lists", "report", "reports", "album", "albums",
    "comment", "comments", "thumbnails", "values", "value", "type", "types", "level", "mode",
    "number", "numbers", "point", "points", "path", "install", "installed", "instance", "host",
    "threshold", "volume", "object", "objects", "apply", "first", "entire", "content", "readable",
    "generated", "restarting", "activated", "needed", "memory", "consistency", "subtraction",
    "conversion", "editing", "normally", "routing", "rule", "rules", "keys", "text", "hour", "hours",
    "last", "just", "interesting", "cases", "requires", "volumic", "possible", "compute", "give",
    "enter", "whole", "port", "tags", "printers", "migration", "assistant", "dynamic", "high",
    "initial", "radius", "raw", "data", "paused", "incomplete", "flip", "forgotten", "password",
    "angle", "echo", "listener", "default", "protocol", "route", "removal", "removing", "bone",
    "arranging", "finding", "dumping", "downloading", "drag", "place", "holders", "display",
    "displayed", "distant", "free", "space", "cleanup", "index", "site", "help", "reslicing",
    "actual",
}
# Names a sentence keeps as they are, spelled exactly like this: an application, a
# folder Horos makes, a DICOM attribute, a key of the keyboard, a request. They are
# matched with their capitals.
NAMES = {"Numbers", "Pages", "Word", "Mail", "Finder", "Photos", "Data", "Instance", "Class",
         "Keys", "Report", "Text", "Level", "List", "Index", "Path", "Mode", "Angle", "Volume",
         "NOT", "READABLE", "DATABASE",
         # "iCloud Drive", the service: a drive of the computer is "unidad".
         "Drive",
         "Bonjour", "Weasis", "Apple", "Metal", "Mac", "Dock", "Delaunay", "Retrieve",
         "Bearer", "Basic", "Lite", "Totoku", "Inventor", "Renderman", "Wavefront",
         "Clunie", "David", "Jan", "Kowalski", "Tab", "Esc",
         "Internet", "Auto", "Extreme", "Quartz", "Cobb", "Echo", "Quicktime", "Analyze", "Repulsor",
         "Ctrl",
         # Programs, a scope and a kind of file, written in lower case.
         "dciodvfy", "hdiutil", "dcmpsprt", "sqlite", "openid", "plist"}
# Names of more than one word, and terms the DICOM standard or a third party wrote in
# English: removed from a value before its words are read.
KEPT = (
    "T1 Fit Map", "Gantry Tilt Correction", "Power Crust", "Iso Contour", "OpenID Connect",
    "AE Title", "Little Endian", "Big Endian", "App Store", "DICOM Validator", "DCM Framework",
    "B/W Inverse", "Fly Thru", "Study Instance UID", "c-echo", "Key Object Selection",
)
# Words English and the language spell alike, or that the language took from English.
SHARED = {
    "es": {
        "actual", "alias", "anterior", "axial", "central", "cine", "color", "compatible",
        "control", "coronal", "digital", "distal", "editor", "error", "experimental", "final",
        "focal", "general", "horizontal", "inspector", "interfaces", "local", "manual",
        "original", "panel", "perpendicular", "personal", "portal",
        "principal", "proximal", "real", "rectangular", "regular", "series",
        "temporal", "variable", "vertical", "zoom", "min", "pos", "info",
        # Taken from English.
        "bit", "bytes", "bundle", "endpoint", "fallback", "gantry", "hardware",
        "plugin", "plugins", "render", "script", "software", "spline", "stent", "struts", "token",
        "tokens", "web", "zip", "blooming", "bin",
        # Words of a series description, given as examples of what to type.
        "scout", "localizer",
        # Imperatives Spanish spells as English does: "Use Exportar...", "Compare estos valores".
        "use", "compare", "define",
        # Keys of the keyboard as a shortcut names them, and the exponential of a formula.
        "alt", "cmd", "exp", "app",
    },
    "it-IT": {
        "area", "data", "dose", "formula", "per", "video", "zero",
        "volume", "zoom", "min", "max", "pos", "sec",
        # Taken from English.
        "account", "album", "alias", "bit", "browser", "bug", "build", "bundle", "client",
        "cloud", "computer", "console", "crash", "database", "dataset", "default", "directory",
        "display", "download", "downloads", "email", "e-mail", "endpoint", "feed", "feedback",
        "file", "filesystem", "font", "frame", "gantry", "hardware", "home", "host",
        "kiosk", "layout", "link", "listener", "login", "manager", "media", "menu",
        "mouse", "offline", "output", "parser", "password", "peer", "pixel", "pix",
        "plugin", "plug-in", "preset", "privacy", "provider", "query", "record",
        "renderer", "rendering", "report", "reset", "reslicing", "routing", "autorouting", "script",
        "server", "slab", "slice", "smart", "software", "spline", "standard", "stent", "stereo",
        "tag", "test", "thread", "token", "toolkit", "upgrade", "voxel",
        "web", "wireframe", "workspace", "zip", "blooming", "fallback", "cine",
        "set", "player", "bin", "background", "editor", "info", "imaging", "flip", "fork",
        "app",
        # Italian words English has too: "in", "all'utente", "serie separate", "sono state aperte".
        "in", "all", "separate", "multiple", "state",
        "scout", "localizer", "coronal",
        "alt", "cmd", "exp",
    },
}
# Keys whose value holds a sample text of a nib, written by the code before it is shown.
SAMPLES = {"This computer - drdd"}

# Letters and accents, hyphens inside a word kept: "días" is one word, and so is the
# product name "On-Demand", which is not "on" plus "demand".
WORD = re.compile(r"[^\W\d_]+(?:-[^\W\d_]+)*", re.UNICODE)

FILE_NAME = re.compile(r"\b[\w-]+\.[A-Za-z]{2,}\b")
# An extension by itself: ".docx".
EXTENSION = re.compile(r"(?<![\w.])\.[A-Za-z]{2,5}\b")
# A parameter with its value, as a request spells them: "execute = Delete".
PARAMETER = re.compile(r"\b[A-Za-z]\w* = [A-Za-z]\w*\b")
# What a binding puts a value in place of, in the pattern of a label: "%{value1}@".
PLACEHOLDER = re.compile(r"%\{\w+\}@")
# An address, a tag of a page, the prefix of a token ("DICOM_"), a predicate written as an example.
ADDRESS = re.compile(r"\b[a-z][a-z0-9+.-]*://\S*|\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b")
MARKUP = re.compile(r"<[^<>]*>")
PREFIX = re.compile(r"\b\w+_(?!\w)")
PREDICATE = re.compile(r"\([^()]*(?:CONTAINS|==)[^()]*\)")
# A path: "/wado", "~/Library/Application Support/IsiX/WebServicesHTML/".
PATH = re.compile(r"~?(?<!\w)/(?=\w)(?:[\w.-]+(?: [\w.-]+)*/)*[\w.-]*")

# Words Spanish puts before a noun, as English does: a phrase that starts with one keeps the English order.
BEFORE_NOUN = {
    "nuevo", "nueva", "nuevos", "nuevas", "mejor", "primer", "primera", "último", "última", "últimos",
    "últimas", "otro", "otra", "otros", "otras", "cada", "ningún", "ninguna", "todos", "todas", "todo",
    "toda", "este", "esta", "estos", "estas", "mismo", "misma", "varios", "varias", "ambos", "ambas",
    "cualquier", "solo", "más", "menos", "gran", "alta", "alto", "próximo", "próxima", "próximos",
    "próximas", "dos", "tres", "seis", "sin",
}
VERB = re.compile(r"(?:ar|er|ir|ando|iendo|yendo|arlos|arlas)$")
PARTICIPLE = re.compile(r"(?:ado|ada|ido|ida|ados|adas|idos|idas|ente|entes)$")
AFTER_NOUN = {"izquierda", "derecha"}
FUNCTION_WORDS = {
    "de", "del", "la", "el", "los", "las", "en", "a", "al", "por", "para", "con", "y", "o", "un", "una",
    "sin", "que", "se", "su", "sus", "como", "no", "lo", "e", "u", "es", "entre",
}
# What a capital may follow inside a Spanish title: the end of a clause, or the word that names a tool or a key.
OPENERS = ".:;!?»\"'>-/&+(…\n\r\t«“‘·•="
NAMED_AFTER = {"herramienta", "tecla", "carpeta"}
# What Spanish writes with a capital inside a phrase: the application Fotos, the Documents folder, the window
# that manages the plugins and two keys of the keyboard.
SPANISH_NAMES = {"Fotos", "Documentos", "Gestor", "Retorno", "Tabulador"}
CAPITALISED = re.compile(r"[A-ZÁÉÍÓÚÑ][a-záéíóúñü]{2,}")
# The label of a field of a readout: a word and its colon.
LABEL = re.compile(r"[^\W\d_]+:")
LOOSE = re.compile(r"\s[,;)?!]|[(¿¡]\s")


def catalog(language):
    path = ROOT / f"Horos/Resources/{language}.lproj/Localizable.strings"
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def residual_module():
    spec = importlib.util.spec_from_file_location("residual", ROOT / "tools/host-localization-residual.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def is_token(word):
    """A word written as a code is: all capitals (DICOM), or with a capital inside (IsiX, onlyDICOM)."""
    return word.isupper() or any(character.isupper() for character in word[1:])


def plain(text, products, conversion):
    """`text` without what is no word of a sentence: names of files, addresses, markup, placeholders, names."""
    for pattern in (PLACEHOLDER, PREDICATE, ADDRESS, MARKUP, PATH, FILE_NAME, EXTENSION, PARAMETER, PREFIX, conversion):
        text = pattern.sub(" ", text)
    for name in products:
        text = text.replace(name, " ")
    for name in KEPT:
        text = text.replace(name, " ")
    return text


def vocabulary(table):
    """{English word: the words the catalog translates it by}, from its one-word entries."""
    words = {}
    for key, value in table.items():
        english, translated = WORD.findall(key), WORD.findall(value)
        if len(english) == 1 and len(translated) == 1 and key.strip(" .:…") == english[0]:
            words.setdefault(english[0].lower(), set()).add(translated[0].lower())
    return words


def translates(words, english, word):
    """Whether `word` is how the catalog writes `english`, the plural and the singular taken as one."""
    english, word = english.lower(), word.lower()
    if english == word:
        return True
    known = set()
    for form in (english, english.rstrip("s"), english + "s"):
        known |= words.get(form, set())
    stem = re.sub(r"e?s$", "", word)
    return any(word == other or stem == re.sub(r"e?s$", "", other) for other in known)


def english_order(words, original, value):
    """Whether a short Spanish phrase keeps the English order where Spanish puts the noun first."""
    if re.search(r"[^\w\s.…-]", value.rstrip(":")) or re.search(r"\d", value):
        return False
    english, spanish = WORD.findall(original), WORD.findall(value)
    if not 2 <= len(spanish) <= 4 or len(english) != len(spanish):
        return False
    if any(word.lower() in FUNCTION_WORDS for word in spanish):
        return False
    first, last = spanish[0].lower(), spanish[-1].lower()
    if VERB.search(first) or first in BEFORE_NOUN or PARTICIPLE.search(last) or last in AFTER_NOUN:
        return False
    return translates(words, english[0], spanish[0]) and translates(words, english[-1], spanish[-1])


def capital_inside(original, value, kept):
    """The first word of a Spanish value that keeps the capital of an English title, or None."""
    english = WORD.findall(original)
    if len(english) < 2 or any(len(word) > 3 and word[0].islower() for word in english):
        return None
    # A readout of several fields: a word with its colon is the label of the next one.
    fields = len(LABEL.findall(original)) > 1
    previous = None
    for match in WORD.finditer(value):
        word, start = match.group(0), match.start()
        before = value[:start].rstrip(" ")
        if previous is not None and start > 0 and value[start - 1] == " " and before[-1:] not in OPENERS \
                and CAPITALISED.fullmatch(word) and word not in english and word not in kept \
                and previous.lower() not in NAMED_AFTER and not (fields and value[match.end():match.end() + 1] == ":"):
            return word
        previous = word
    return None


def reasons(language, original, value, words, products, conversion):
    """What is wrong with `value`, the translation of `original` in `language`: a list, empty when nothing is.

    `words` is the vocabulary of the catalog (see `vocabulary`), `products` the names of products and
    `conversion` the pattern of a format's conversions, both removed before the words are read.
    """
    shared = SHARED[language]
    found = []
    text = plain(value, products, conversion)
    said = WORD.findall(text)
    # A name keeps its capitals; the same word in lower case is an English leftover.
    kept = {word.lower() for word in said if word in NAMES}
    left = sorted(({word.lower() for word in said} & ENGLISH_WORDS) - shared - kept)
    if left:
        found.append("english words left: " + ", ".join(left))
    source = {word.lower() for word in WORD.findall(plain(original, products, conversion))}
    carried = sorted({word for word in said if len(word) > 2 and word.replace("-", "").isalpha()
                      and word.lower() in source and word not in NAMES and not is_token(word)
                      and word.lower() not in shared})
    if carried:
        found.append("words of the English original: " + ", ".join(carried))
    if original[:1].isupper() and value[:1].islower() and len(said) > 1 and not is_token(said[0]):
        found.append("starts in lower case")
    if language == "es":
        capital = capital_inside(original, text, NAMES | SPANISH_NAMES)
        if capital:
            found.append(f"a capital inside: {capital}")
        if english_order(words, original, value):
            found.append("the English order")
        if re.search(r"\b(?:a|de) el\b", value):
            found.append("an article that does not contract")
    if LOOSE.search(value) and not LOOSE.search(original):
        found.append("a space around punctuation")
    return found


def mixed(language):
    """Entries of `language` that are half translated, with the English original and what is wrong."""
    english = catalog("en")
    residual = residual_module()
    products = sorted(residual.PRODUCT, key=len, reverse=True)
    table = catalog(language)
    words = vocabulary(table)
    found = {}
    for key, value in table.items():
        original = english.get(key, key)
        if value in (key, original) or residual.is_residual(key, original) or key in SAMPLES:
            continue
        wrong = reasons(language, original, value, words, products, residual.FORMAT)
        if wrong:
            found[key] = {"value": value, "english": original, "reasons": wrong}
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--language", action="append", default=None, choices=LANGUAGES)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    languages = arguments.language or list(LANGUAGES)
    total = 0
    for language in languages:
        found = mixed(language)
        total += len(found)
        for key, entry in sorted(found.items()):
            print(f"{language}: {key!r}\n    english: {entry['english']!r}\n    value:   {entry['value']!r}"
                  f"\n    {'; '.join(entry['reasons'])}")
        print(f"{language}: {len(found)} mixed of {len(catalog(language))}")
    if arguments.check and total:
        raise SystemExit("A catalog value is half English. Translate the sentence, or leave the English one "
                         "and list it in tools/host-localization-residual.py.")


if __name__ == "__main__":
    main()
