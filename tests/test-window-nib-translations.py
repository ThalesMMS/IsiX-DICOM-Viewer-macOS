#!/usr/bin/env python3
"""No window of the application goes back to showing its English nib untranslated.

The nibs of the windows are in Horos/Resources/en.lproj. A language shows a
window in one of two ways: a copy of the nib in its own folder, with the texts
translated, or no copy at all, and then the English nib loads and
WindowNibCatalog (Horos/Sources/WindowNibCatalog.swift) reads every text it
shows from the language's Localizable.strings, with the English text as the
key. Spanish, Italian and Japanese take the second way: a copy that nobody
translated is the English nib under another name, and 29 of the Japanese
copies were exactly that.

For every nib of a window and every language this requires one of the two:

- a copy that is not the English file byte for byte and, in the languages
  that read the catalog, shows no text as English writes it;
- no copy, a controller that loads the nib through WindowNibCatalog (the
  File's Owner of the nib overrides -loadWindow with
  loadWindowReadingCatalog(), or the nib's name is given to
  WindowNibCatalog.read or .instantiate), and a translation in the catalog for
  every text the nib shows.

What a nib shows is what tests/pane_translations.py lists for each of its
top-level objects (windows, sheets, the views of toolbar items, menus), with
the titles of its windows, the labels of its toolbar items and the patterns
its labels' bindings write their values into ("%{value1}@ out of
%{value2}@"). A text with no word to translate is the same in every language:
a number, a size, a unit, a code in capitals (CT, ROI), a name of the list of
tools/host-localization-residual.py, or one of SAME_EVERYWHERE, each with its
reason. SAME_IN_LANGUAGE has the words one language writes as English does,
and FILLED_IN_CODE the controls whose text the code writes when the window
opens.

PENDING names the nibs that still show English in Spanish, Italian or
Japanese. It only shrinks, and is empty: a nib listed there that meets the rule
in the three languages fails the test until it is taken off the list.

No text of a window that reads the catalog may be cut by it. Each such nib is
compiled with the texts of each of the three catalogs written into it and
measured as tests/pane_titles.py measures the panes: a button, a checkbox, a
radio button or a label of any of its windows, or of a view it holds outside
them (the views of toolbar items), that has room for its English text must
have room for the translation. The older nibs are laid out by frames that
leave their English texts no slack: a window that reads the catalog then gives
each text the room that is free beside it (WindowNibFit), and the nib is
measured after that, as it is shown.

The loading itself is then run: a small application is built from
WindowNibCatalog and CatalogTranslation with the English nib of the iCloud
Drive warning, its copies and the real catalogs, and started in every
language. In Spanish, Italian and Japanese the window must show the catalog's
texts, with the nib loaded once and -windowDidLoad sent once; in English, and
in a language that has a copy of the nib, the controller must load its window
as AppKit does and show that nib. In every language each button and label of
the warning must have room for its text: its first paragraph needed four lines
in a label of three, in English too, and lost the last one, and two buttons
were narrower than their titles in French, Portuguese and Russian.

The rate of a cine is one text in every language, "N im/s": the viewers write
it with the formats "%0.0f im/s" and "%0.1f im/s", and every text that names
the unit has to read as the English one in every catalog and in every copy of
every nib that holds one: the sample of a label, the pattern of the binding of
the panel that exports a movie, the format of a formatter. The nibs are found
by reading them all.

`--inventory` prints, for every nib, how many texts it shows and, for each of
the three languages, how many of them are shown in English and how many the
catalog does not translate yet.
"""
from pathlib import Path
import importlib.util
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_translations  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
SOURCES = ROOT / 'Horos/Sources'
CATALOG_LANGUAGES = ('es', 'it-IT', 'ja-JP')

spec = importlib.util.spec_from_file_location('residual', ROOT / 'tools/host-localization-residual.py')
residual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(residual)

# Nibs that other tests answer for: the main menu and the About window have a
# copy in every language, and the settings window reads its toolbar from the
# catalog by itself.
ELSEWHERE = {'MainMenu', 'Splash', 'PreferencesWindow'}

# Texts that are the same in every language.
SAME_EVERYWHERE = {
    # What Interface Builder names a control that the code fills or that draws no title.
    'Box', 'Item', 'Item 1', 'Item 2', 'Item 3', 'Item1', 'Item2', 'Item3', 'Label', 'Text', 'Text Cell', 'OtherViews',
    'Window',
    # The title of a panel that is shown as a sheet, which has no title bar.
    '<<do not localize window title>>',
    # The product's services, and the name of a language.
    'iCloud', 'iCloud Drive', 'SQL',
    # The catalogs keep OK for the button.
    'Ok',
    # A DICOM term, and images per second as the viewers write them: the pattern of a binding and the samples of
    # the cine rate labels.
    'AE Title:', '%{value1}@ im/s', '10 im/s', '60 im/s',
    # The colour look-up table, by its initials.
    'CLUT:',
    # An item of the viewer's menu of page templates: its title names the template, and the code reads it.
    'SCAN',
    # The surface viewer's predefined values carry the names of window level presets, which stay as stored.
    'CT - Skin', 'CT - Bone', 'CT - Metal',
    # The names of two ways of building a surface.
    'Delaunay', 'Power Crust',
}

# Words a language writes as English does.
SAME_IN_LANGUAGE = {
    # Mail is the application the images are sent with.
    'es': {'No', 'Mail', 'Spline'},
    'it-IT': {'No', 'Mail', 'Schema', 'Tag', 'Volume', 'Volume (cm3)', 'Area (cm2)', 'Host:',
              'Fine', 'Info', 'Spline', 'Standard', 'in mm', 'texture', 'volume',
              # The layouts of a DICOM print.
              *(f'Standard {columns},{rows}' for columns in range(1, 6) for rows in range(1, 8))},
}

# Controls whose text the code writes when the window opens, by nib and by the outlet that reaches them: what the
# nib holds there is a sample that is never shown.
FILLED_IN_CODE = {
    'BurnViewer': ('sizeField',),
    'ITKSegmentation': ('startingPointPixelPosition', 'startingPointWorldPosition'),
    'Query': ('sendToPopup',),
    'ROIVolume': ('volumeField',),
    'SR': ('point3DPositionTextField',),
    'VR': ('infoBackgroundColorTextField',),
}

# The nibs that still show English in Spanish, Italian or Japanese.
PENDING = set()


def catalog(language):
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    return plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'binary1', '-o', '-', str(path)]))


def shown(path):
    """{(element key, attribute): text} of what a nib shows, or None for a file that is not a XIB document."""
    root = ET.parse(path).getroot()
    objects = root.find('objects')
    if objects is None:
        return None
    parents = {child: parent for parent in root.iter() for child in parent}
    found = {}
    for top in objects:
        if top.tag == 'customObject' and top.get('id', '').startswith('-'):
            continue
        for element, attribute in pane_translations.shown_texts(top, root, FILLED_IN_CODE.get(Path(path).stem, ())):
            # A custom box draws no title.
            if element.tag == 'box' and element.get('boxType') in ('custom', 'separator'):
                continue
            found[(pane_translations.key_of(element, parents), attribute)] = pane_translations.text_of(element, attribute)
        for element in top.iter():
            # The pattern a label's bindings write their values into ("%{value1}@ out of %{value2}@").
            if element.tag == 'binding' and re.fullmatch(r'displayPatternValue\d+', element.get('name') or ''):
                pattern = element.find("dictionary/string[@key='NSDisplayPattern']")
                control = parents.get(parents.get(element))
                if pattern is not None and (pattern.text or '').strip() and control is not None:
                    found[(pane_translations.key_of(control, parents), 'displayPattern')] = pattern.text
            if element.tag in ('window', 'panel') and (element.get('title') or '').strip():
                found[(element.get('id'), 'title')] = element.get('title')
            elif element.tag == 'toolbarItem':
                for attribute in ('label', 'paletteLabel', 'toolTip'):
                    if (element.get(attribute) or '').strip():
                        found[(element.get('id'), attribute)] = element.get(attribute)
    return found


# Units, written the same in every language.
UNITS = {'mm', 'cm', 'px', 'im', 's', 'x', 'kg', 'hu'}


def same_everywhere(text, language=None):
    """Whether `text` has nothing to translate: no word at all, a name of the residual list, or only codes in
    capitals of up to three letters (CT, MR, ROI, A) and units. A short English word ("On:", "to") is a word."""
    stripped = text.strip()
    if stripped in SAME_EVERYWHERE or stripped in SAME_IN_LANGUAGE.get(language, ()) or stripped in residual.EXACT:
        return True
    words = re.findall(r'[^\W\d_]+', stripped)
    return all(len(word) <= 3 and word.isupper() or word.lower() in UNITS for word in words)


def owner_class(path):
    root = ET.parse(path).getroot()
    owner = next((element for element in root.find('objects') if element.get('id') == '-2'), None)
    return owner.get('customClass') if owner is not None else None


SWIFT = {path: path.read_text(encoding='utf-8') for path in sorted([*SOURCES.glob('*.swift'), *(ROOT / 'DICOMPrint').glob('*.swift')])}
HEADERS = {path: path.read_text(encoding='utf-8', errors='replace') for path in sorted(SOURCES.glob('*.h'))}


CLASS = r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |open |final |internal )*class %s\s*:\s*(\w+)'
IMPLEMENTATION = r'^@objc @implementation extension %s\b'
INTERFACE = r'^@interface %s\s*:\s*(\w+)'
OVERRIDE = 'if !loadWindowReadingCatalog() { super.loadWindow() }'
TYPE = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |open |final |internal |private |fileprivate )*(?:class|struct|enum|extension) ', re.M)


def reads_catalog(name, owner):
    """Whether the nib named `name` is loaded through WindowNibCatalog: its name is given to it, or the class of its
    File's Owner, or a class that one inherits from, overrides -loadWindow with it."""
    if re.search(r'WindowNibCatalog\.(?:read|instantiate)\([^\n]*"%s"' % re.escape(name), '\n'.join(SWIFT.values())):
        return True
    while owner and owner not in ('NSWindowController', 'NSObject'):
        # Every declaration of the class: a build without plugins declares the plugin manager a second time.
        declaration = re.compile(CLASS % re.escape(owner), re.M)
        found = [(text, match) for text in SWIFT.values() for match in declaration.finditer(text)]
        if not found:
            # A class a header declares and Swift implements: the override is in the implementation, and
            # the header names the class it inherits from.
            implementation = re.compile(IMPLEMENTATION % re.escape(owner), re.M)
            for text in SWIFT.values():
                for match in implementation.finditer(text):
                    following = TYPE.search(text, match.end())
                    if OVERRIDE in text[match.end():following.start() if following else len(text)]:
                        return True
            inherited = [match.group(1) for header in HEADERS.values()
                         for match in re.finditer(INTERFACE % re.escape(owner), header, re.M)]
            if not inherited:
                return False
            owner = inherited[0]
            continue
        for text, match in found:
            # Up to the next type of the file: an override further down is another class's.
            following = TYPE.search(text, match.end())
            if OVERRIDE in text[match.end():following.start() if following else len(text)]:
                return True
        owner = found[0][1].group(1)
    return False


CATALOGS = {}


def table(language):
    if language not in CATALOGS:
        CATALOGS[language] = catalog(language)
    return CATALOGS[language]


def english_left(name, language):
    """[(reason, text)] of the texts the nib named `name` shows in English in `language`; [] when it meets the rule."""
    english_path = RESOURCES / f'en.lproj/{name}.xib'
    english = shown(english_path)
    copy = RESOURCES / f'{language}.lproj/{name}.xib'
    translatable = {key: text for key, text in english.items() if not same_everywhere(text, language)}
    distinct = sorted(set(translatable.values()))
    if copy.exists():
        if copy.read_bytes() == english_path.read_bytes():
            # A word the language writes as English does is in its catalog, with itself as the translation.
            return [('the copy is the English file', text) for text in distinct if table(language).get(text) != text]
        if language not in CATALOG_LANGUAGES:
            return []
        texts = shown(copy)
        if texts is None:
            return [('the copy is not a XIB document', text) for text in distinct]
        return [('the copy writes it as English does', text)
                for text in sorted({text for key, text in translatable.items() if texts.get(key) == text})]
    if distinct and not reads_catalog(name, owner_class(english_path)):
        return [('the nib is not loaded through WindowNibCatalog', text) for text in distinct]
    return [('the catalog has no translation', text) for text in distinct if table(language).get(text, text) == text]


def untranslated(name, language):
    """The texts of the nib named `name` that the catalog of `language` does not translate."""
    english = shown(RESOURCES / f'en.lproj/{name}.xib')
    return sorted({text for text in english.values()
                   if not same_everywhere(text, language) and table(language).get(text, text) == text})


NIBS = sorted(path.stem for path in (RESOURCES / 'en.lproj').glob('*.xib') if path.stem not in ELSEWHERE)
LANGUAGES = sorted(path.name[:-len('.lproj')] for path in RESOURCES.glob('*.lproj') if path.name != 'en.lproj')

if '--inventory' in sys.argv:
    # Per nib: the texts it shows, then per language those shown in English and, of them, those the catalog lacks.
    print('nib | texts | ' + ' | '.join(f'{language} in English (no catalog)' for language in CATALOG_LANGUAGES))
    totals = {language: [0, 0] for language in CATALOG_LANGUAGES}
    for name in NIBS:
        texts = {text for text in shown(RESOURCES / f'en.lproj/{name}.xib').values() if not same_everywhere(text)}
        row = []
        for language in CATALOG_LANGUAGES:
            left, missing = len(english_left(name, language)), len(untranslated(name, language))
            totals[language][0] += left
            totals[language][1] += missing
            row.append(f'{left} ({missing})')
        print(f'{name} | {len(texts)} | ' + ' | '.join(row))
    print('total | | ' + ' | '.join(f'{totals[language][0]} ({totals[language][1]})' for language in CATALOG_LANGUAGES))
    sys.exit(0)

failures = []
for name in NIBS:
    by_language = {language: english_left(name, language) for language in LANGUAGES}
    still = sorted(language for language, left in by_language.items() if left)
    if name in PENDING:
        if not still:
            failures.append(f'{name}: no longer shows English in any language; take it off PENDING')
        still = [language for language in still if language not in CATALOG_LANGUAGES]
    for language in still:
        left = by_language[language]
        failures.append(f'{name} in {language}: {len(left)} texts in English, for example {left[0][1]!r}: {left[0][0]}')
if set(PENDING) - set(NIBS):
    failures.append(f'PENDING names nibs that do not exist: {sorted(set(PENDING) - set(NIBS))}')

# The rate of a cine reads "N im/s" in every language. The viewers write it with two formats that no catalog
# translates, a label of a nib holds a sample until then, and the panel that exports a movie writes it with the
# pattern of a binding: a copy that named the unit in its language opened with one text and showed the other as
# soon as the rate changed. Every text that names the unit is held to the English one, wherever it is: a key of a
# catalog, and in a nib a title, a sample, the pattern of a binding or the format and the suffixes of a formatter.
RATE_UNIT = 'im/s'


def rate_texts(path):
    """{(id of the nearest element that has one, the tags and keys down from it, attribute or None): text} of
    every attribute and every text of a nib, by where it stands: the copies of a nib keep its ids."""
    texts = {}

    def walk(element, anchor, trail):
        if element.get('id'):
            anchor, trail = element.get('id'), ()
        else:
            trail = trail + ((element.tag, element.get('key')),)
        for attribute, value in element.attrib.items():
            texts[(anchor, trail, attribute)] = value
        if element.text and element.text.strip():
            texts[(anchor, trail, None)] = element.text
        for child in element:
            walk(child, anchor, trail)

    walk(ET.parse(path).getroot(), None, ())
    return texts


def rate_differences(english, copy):
    """The texts of the English nib that name the unit of the rate and read otherwise in a copy, as (English, copy)."""
    return [(text, copy.get(place)) for place, text in sorted(english.items(), key=repr)
            if RATE_UNIT in text and copy.get(place) != text]


for language in LANGUAGES:
    for key, value in sorted(table(language).items()):
        if RATE_UNIT in key and value != key:
            failures.append(f'{language}: the catalog writes the cine rate {key!r} as {value!r}')
# The nibs that name the unit are found by reading every nib, the ones other tests measure too.
rated = [path for path in sorted((RESOURCES / 'en.lproj').glob('*.xib')) if RATE_UNIT in path.read_text(encoding='utf-8')]
for path in rated:
    english = rate_texts(path)
    for language in LANGUAGES:
        copy = RESOURCES / f'{language}.lproj/{path.name}'
        if copy.exists():
            failures += [f'{path.stem} in {language}: its cine rate reads {theirs!r}, and the English nib {ours!r}'
                         for ours, theirs in rate_differences(english, rate_texts(copy))]
if not rated:
    failures.append('no nib names the unit of the cine rate: the search for them finds nothing')
else:
    # The comparison itself: a copy whose texts name another unit has every one of them reported.
    english = rate_texts(rated[0])
    renamed = {place: text.replace(RATE_UNIT, 'B/s') for place, text in english.items()}
    if len(rate_differences(english, renamed)) != sum(RATE_UNIT in text for text in english.values()) or rate_differences(english, english):
        failures.append('the comparison of the cine rate texts does not report a copy that names another unit')

# No text of a window that reads the catalog is cut by it: the nib is measured with the texts of each catalog written
# into it, as the window shows them, and a title or a label that fits in English must fit in the language.
import pane_titles  # noqa: E402


def with_catalog(name, language, folder):
    """A copy of the English nib named `name` with every text it shows as the catalog of `language` writes it."""
    tree = ET.parse(RESOURCES / f'en.lproj/{name}.xib')
    root = tree.getroot()
    catalog_table = table(language)
    for top in root.find('objects'):
        for element, attribute in pane_translations.shown_texts(top, root, FILLED_IN_CODE.get(name, ())):
            text = pane_translations.text_of(element, attribute)
            if catalog_table.get(text, text) != text:
                pane_translations.set_text(element, attribute, catalog_table[text])
    copy = Path(folder) / f'{name}-{language}.xib'
    tree.write(copy, encoding='utf-8', xml_declaration=True)
    return copy


def misfit_ids(messages):
    return {identifier for message in messages for identifier in re.findall(r'\(id ([^)]+)\)|controls (\S+) and (\S+) overlap', message)}


# The sources of WindowNibFit, which gives a translated text the room free beside it once the catalog is read.
ROOM = [SOURCES / 'WindowNibCatalog.swift', ROOT / 'Preference Panes/PaneCatalogTranslation.swift']
READING = [name for name in NIBS if name not in PENDING and reads_catalog(name, owner_class(RESOURCES / f'en.lproj/{name}.xib'))]
if pane_titles.available():
    with tempfile.TemporaryDirectory(prefix='window-nib-fit-') as folder:
        for name in READING:
            variants = {'en': RESOURCES / f'en.lproj/{name}.xib'}
            variants.update({language: with_catalog(name, language, folder) for language in CATALOG_LANGUAGES
                             if not (RESOURCES / f'{language}.lproj/{name}.xib').exists()})
            try:
                measured = pane_titles.measure(variants, every_window=True, every_view=True, room=ROOM)
            except (RuntimeError, subprocess.CalledProcessError) as error:
                failures.append(f'{name}: its titles could not be measured: {str(error)[-300:]}')
                continue
            english = misfit_ids(pane_titles.misfits([item for item in measured if item['language'] == 'en']))
            for language in variants:
                if language == 'en':
                    continue
                for message in pane_titles.misfits([item for item in measured if item['language'] == language]):
                    if not misfit_ids([message]) <= english:
                        failures.append(f'{name}: {message}')

# The loading, run in a small application in each language.
PATTERN = '%{value1}@ out of %{value2}@'
HARNESS = r'''
import AppKit
@objc(ICloudDriveDetector) final class Detector: NSWindowController {
    var loads = 0, awakes = 0
    override func loadWindow() {
        loads += 1
        if !loadWindowReadingCatalog() { super.loadWindow() }
    }
    override func windowDidLoad() {
        super.windowDidLoad()
        awakes += 1
    }
    @IBAction func askLater(_ sender: Any?) {}
    @IBAction func dontSync(_ sender: Any?) {}
    @IBAction func keepSync(_ sender: Any?) {}
}
@MainActor func texts(_ view: NSView) -> [String] {
    var found: [String] = []
    if let button = view as? NSButton { found.append(button.title) }
    else if let field = view as? NSTextField { found.append(field.stringValue) }
    else { for child in view.subviews { found += texts(child) } }
    return found
}
// The texts that need more room than their control has: a button's title on its line, a label's text at its width.
@MainActor func cut(_ view: NSView) -> [String] {
    if let button = view as? NSButton {
        return (button.cell?.cellSize.width ?? 0) > button.frame.width + 0.5 ? [button.title] : []
    }
    if let field = view as? NSTextField {
        let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)) ?? .zero
        return needed.height > field.frame.height + 0.5 || needed.width > field.frame.width + 0.5 ? [field.stringValue] : []
    }
    return view.subviews.flatMap(cut)
}
_ = NSApplication.shared
let detector = Detector(windowNibName: "ICloudDriveDetector")
let reads = WindowNibCatalog.reads(nibNamed: "ICloudDriveDetector", owner: detector)
let window = detector.window
let again = detector.window
// A label whose bindings write two values into a pattern, read as a nib's is.
let counts = NSObjectController(content: NSMutableDictionary(dictionary: ["done": 3, "all": 7]))
let pattern = NSTextField(labelWithString: "")
let patternOptions: [NSBindingOption: Any] = [.displayPattern: "%{value1}@ out of %{value2}@"]
pattern.bind(NSBindingName("displayPatternValue1"), to: counts, withKeyPath: "content.done", options: patternOptions)
pattern.bind(NSBindingName("displayPatternValue2"), to: counts, withKeyPath: "content.all", options: patternOptions)
let holder = NSView()
holder.addSubview(pattern)
WindowNibCatalog.read([holder], ofNibNamed: "ICloudDriveDetector", owner: detector)
let report: [String: Any] = [
    "pattern": pattern.stringValue,
    "language": Bundle.main.preferredLocalizations.first ?? "", "reads": reads, "loads": detector.loads,
    "didLoad": detector.awakes, "loaded": detector.isWindowLoaded, "same": window === again && window != nil,
    "title": window?.title ?? "", "texts": window?.contentView.map(texts) ?? [], "cut": window?.contentView.map(cut) ?? [],
]
print(String(data: try! JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
'''
with tempfile.TemporaryDirectory(prefix='window-nib-catalog-') as folder:
    folder = Path(folder)
    contents = folder / 'Test.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    info = plistlib.loads((ROOT / 'Horos/Info.plist').read_bytes())
    info.update(CFBundleExecutable='test', CFBundleIdentifier='org.horos.qa.window-nib-catalog')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    for language in ['en', *LANGUAGES]:
        lproj = contents / 'Resources' / f'{language}.lproj'
        lproj.mkdir(parents=True)
        if language != 'en':
            (lproj / 'Localizable.strings').write_bytes((RESOURCES / f'{language}.lproj/Localizable.strings').read_bytes())
        copy = RESOURCES / f'{language}.lproj/ICloudDriveDetector.xib'
        if copy.exists():
            built = subprocess.run(['xcrun', 'ibtool', '--compile', str(lproj / 'ICloudDriveDetector.nib'), str(copy)],
                                   capture_output=True, text=True)
            if built.returncode:
                sys.exit(f'the {language} nib of the warning does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
    (folder / 'main.swift').write_text(HARNESS, encoding='utf-8')
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(folder / 'modules'),
                               str(folder / 'main.swift'), str(SOURCES / 'WindowNibCatalog.swift'),
                               str(ROOT / 'Preference Panes/PaneCatalogTranslation.swift'),
                               '-o', str(contents / 'MacOS/test')], capture_output=True, text=True)
    if compiled.returncode:
        sys.exit('the harness with WindowNibCatalog does not compile\n' + compiled.stdout[-2000:] + compiled.stderr[-2000:])
    english = set(shown(RESOURCES / 'en.lproj/ICloudDriveDetector.xib').values()) - SAME_EVERYWHERE
    for language in ['en', *LANGUAGES]:
        ran = subprocess.run([str(contents / 'MacOS/test'), '-AppleLanguages', f'({language})'], capture_output=True, text=True, timeout=120)
        if ran.returncode:
            failures.append(f'the warning did not load in {language}: {ran.stderr[-600:]}')
            continue
        report = json.loads(ran.stdout.strip().splitlines()[-1])
        seen = set(report['texts']) | {report['title']}
        if report['language'] != language:
            failures.append(f'the harness ran in {report["language"]} instead of {language}')
        if report['cut']:
            failures.append(f'{language}: the warning has no room for {report["cut"]}')
        if not (report['loads'] == 1 and report['didLoad'] == 1 and report['loaded'] and report['same']):
            failures.append(f'{language}: the window was not loaded exactly once: {report}')
        written = (table(language) if language in CATALOG_LANGUAGES else {}).get(PATTERN, PATTERN)
        if written == PATTERN and language in CATALOG_LANGUAGES:
            failures.append(f'{language}: the catalog does not translate {PATTERN!r}')
        if report['pattern'] != written.replace('%{value1}@', '3').replace('%{value2}@', '7'):
            failures.append(f'{language}: a label that writes two values into a pattern shows {report["pattern"]!r}')
        copy = RESOURCES / f'{language}.lproj/ICloudDriveDetector.xib'
        if copy.exists():
            if report['reads'] or not set(shown(copy).values()) - SAME_EVERYWHERE <= seen:
                failures.append(f'{language}: the warning does not show its own nib: {sorted(seen)}')
        else:
            expected = {table(language).get(text, text) for text in english}
            if not report['reads'] or not expected <= seen or seen & english:
                failures.append(f'{language}: the warning does not show the catalog: {sorted(seen)}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {len(NIBS)} window nibs in {len(LANGUAGES)} languages; {len(NIBS) - len(PENDING)} show no English in Spanish, '
      f'Italian or Japanese, {len(PENDING)} are pending; the warning loads once and reads the catalog')
