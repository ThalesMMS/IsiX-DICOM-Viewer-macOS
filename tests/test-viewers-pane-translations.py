#!/usr/bin/env python3
"""Every text of the Viewers pane is translated in every language of the app, and fits.

The pane is the window the `mainWindow` outlet of OSIViewerPreferencePanePref.xib
names. Its titles, labels, tooltips, box titles, pop-up and menu items reach a
language in one of two ways:

- a language with a copy of the nib (ja-JP beside the pane's sources, the
  others in Horos/Resources/<language>.lproj) shows what its copy says;
- English, Spanish and Italian load the Base nib, and in Spanish and Italian
  the pane, which loads its nib through instantiatePaneNib, reads each text
  from Localizable.strings by its English text (CatalogTranslation, in
  Preference Panes/PaneCatalogTranslation.swift); a text the catalog lacks
  stays in English. English entries are the text itself.

In Japanese, rows of the pane, its "Default" interpolation and the "Modalities"
pull-down were still in English in the copy, and Spanish and Italian lacked a
dozen entries. Texts that are the same in every language on purpose are listed
in SAME_EVERYWHERE, with the reason: no catalog the pane reads changes them, and
every copy shows them as they are. A translation that writes the English word is
listed in SAME_IN_LANGUAGE.

For Spanish and Italian the test runs CatalogTranslation, compiled from its
source, on the Base nib with each catalog, and requires every text of
the window to read as the catalog has it: box titles, buttons, labels, tooltips,
every item of a pop-up and the title the pop-up shows.

The pane's label (the window title while it is shown) is read from every
catalog, and the settings window's "Show All" from every copy of that window's
nib. Spanish and Italian have no copy of it: there the settings window reads its
"Show All" from the catalog, which test-preference-panes-translations.py checks.

Each text must also fit its control in Spanish and Italian, as the pane shows
them: the Base nib with the catalog's texts, measured by tests/pane_titles.py
like the copies are in test-preference-pane-titles-fit.py. Pop-up buttons, which
that measure leaves out, are measured here in every language, Spanish and
Italian after CatalogTranslation: the "Modalities" pull-down and the
tool-style pop-up cut their titles in German, Portuguese and Russian and are now
wide enough in every copy. The Mouse & Scrolling pane, another window of the
same nib, has its own "Modalities" pull-down, which was still cut in Arabic,
German, Portuguese and Russian: the pop-ups of that window are measured too, as
each copy shows them (Spanish and Italian show that window as the Base nib has
it).

With a git revision as argument (for example HEAD), the catalogs, nibs and pane
source are read as they stand at that revision.
"""
from pathlib import Path
import base64
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: E402,F401  - its own TMPDIR, removed however the test ends
import pane_titles  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SKIPPED = 2
revision = sys.argv[1] if len(sys.argv) > 1 else None

NIB = 'OSIViewerPreferencePanePref.xib'
PANE_SOURCE = 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift'
LANGUAGES = ('ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

SAME_EVERYWHERE = {
    **{code: 'a DICOM modality code, as the files and the database name it'
       for code in ('CR', 'DX', 'DR', 'RF', 'XA', 'MG', 'US')},
    **{share: 'a share of the mouse movement, a number' for share in ('25%', '50%', '75%')},
}
SAME_IN_LANGUAGE = {
    ('de', 'Interpolation:'): 'German writes the English word',
}
# The views whose texts CatalogTranslation sets, as the XIB names them.
VIEWS = ('box', 'button', 'textField', 'popUpButton')

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def relative(path):
    return str(Path(path).relative_to(ROOT))


def read(path):
    """The bytes of a file of the checkout, or of the revision given."""
    if revision:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{revision}:{relative(path)}'])
    return Path(path).read_bytes()


def catalog(language, folder):
    path = folder / f'{language}.strings'
    path.write_bytes(read(ROOT / 'Horos/Resources' / f'{language}.lproj/Localizable.strings'))
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def text_of(element, attribute):
    """A text the XIB keeps in an attribute or, when it runs over lines, in a child <string key=...>."""
    if element.get(attribute) is not None:
        return element.get(attribute)
    child = element.find(f"string[@key='{attribute}']")
    if child is None:
        return None
    if child.get('base64-UTF8') == 'YES':
        raw = ''.join((child.text or '').split())
        return base64.b64decode(raw + '=' * (-len(raw) % 4)).decode('utf-8')
    return child.text or ''


def set_text(element, attribute, value):
    if element.get(attribute) is not None:
        element.set(attribute, value)
    else:
        child = element.find(f"string[@key='{attribute}']")
        child.attrib.pop('base64-UTF8', None)
        child.text = value


def shown_texts(window):
    """[(element, attribute)] of every text the window shows, as CatalogTranslation reads them:
    box titles, button and radio titles, labels (not what an editable field holds), placeholders,
    pop-up titles and items, and tooltips. A menu's own title and the window's are never shown."""
    found = []
    for element in window.iter():
        if text_of(element, 'toolTip'):
            found.append((element, 'toolTip'))
        if element.tag == 'box' and element.get('titlePosition') != 'noTitle':
            found.append((element, 'title'))
        elif element.tag == 'buttonCell' and element.get('key') != 'prototype' and element.get('imagePosition') != 'only':
            found.append((element, 'title'))
        elif element.tag in ('popUpButtonCell', 'menuItem'):
            found.append((element, 'title'))
        elif element.tag == 'textFieldCell':
            found.append((element, 'placeholderString'))
            if element.get('editable') != 'YES':
                found.append((element, 'title'))
    return [(element, attribute) for element, attribute in found if text_of(element, attribute)]


def pane_window(root):
    outlet = next(outlet for outlet in root.iter('outlet') if outlet.get('property') == 'mainWindow')
    return next(window for window in root.iter('window') if window.get('id') == outlet.get('destination'))


def texts(root):
    """{(element id, attribute): text} of the pane."""
    return {(element.get('id'), attribute): text_of(element, attribute)
            for element, attribute in shown_texts(pane_window(root))}


def view_texts(window):
    """{view id: {kind: text}} of what each view of the window shows, as the XIB has it: its tooltip, its
    title (a box's, a button's, a label's, the item a pop-up shows), a pop-up's items and a field's placeholder."""
    views = {}
    for view in window.iter():
        if view.tag not in VIEWS:
            continue
        shown = {}
        if text_of(view, 'toolTip'):
            shown['toolTip'] = text_of(view, 'toolTip')
        cell = next((child for child in view if child.get('key') == 'cell'), None)
        if view.tag == 'box':
            if view.get('titlePosition') != 'noTitle':
                shown['title'] = text_of(view, 'title') or ''
        elif view.tag == 'popUpButton':
            items = list(view.iter('menuItem'))
            shown['items'] = [text_of(item, 'title') or '' for item in items]
            # A pull-down shows its first item; a pop-up the item it has selected.
            selected = 0 if cell.get('pullsDown') == 'YES' else next(
                (index for index, item in enumerate(items) if item.get('id') == cell.get('selectedItem')), None)
            if selected is not None:
                shown['title'] = shown['items'][selected]
        elif view.tag == 'button':
            if cell.get('imagePosition') != 'only':
                shown['title'] = text_of(cell, 'title') or ''
        elif cell.get('editable') != 'YES':
            shown['title'] = text_of(cell, 'title') or ''
        if cell is not None and text_of(cell, 'placeholderString'):
            shown['placeholderString'] = text_of(cell, 'placeholderString')
        views[view.get('id')] = shown
    return views


if shutil.which('plutil') is None or not pane_titles.available():
    print('skipped: needs plutil and xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(SKIPPED)

copies = pane_titles.variants(NIB)
base_path = copies.pop('Base')
base_root = ET.fromstring(read(base_path))
english = texts(base_root)
check(len(english) > 30, f'only {len(english)} texts found in the pane')
nib_languages = sorted(copies)
catalog_languages = [language for language in LANGUAGES if language not in copies]
check(set(nib_languages) | set(catalog_languages) == set(LANGUAGES) and 'en' in catalog_languages,
      f'languages with a copy of the nib: {nib_languages}')

work = Path(tempfile.mkdtemp(prefix='horos-viewers-pane-'))
catalogs = {language: catalog(language, work) for language in LANGUAGES}

# --- Every text, translated in every language --------------------------------------

for language in catalog_languages:
    strings = catalogs[language]
    for text in sorted(set(english.values())):
        value = strings.get(text)
        if text in SAME_EVERYWHERE:
            check(value in (None, text), f'{language}: {text!r} is the same in every language, the catalog has {value!r}')
        elif value is None:
            check(False, f'{language}: no catalog entry for {text!r}')
        elif language == 'en':
            check(value == text, f'en: {text!r} reads {value!r}')
        else:
            check(value != text or (language, text) in SAME_IN_LANGUAGE, f'{language}: {text!r} is left in English')

for language in nib_languages:
    shown = texts(ET.fromstring(read(copies[language])))
    for key, text in sorted(english.items()):
        where = f'{language} copy, {key[1]} of {key[0]}'
        if key not in shown:
            check(False, f'{where}: missing ({text!r})')
        elif text in SAME_EVERYWHERE:
            check(shown[key] == text, f'{where}: {text!r} is the same in every language, the copy shows {shown[key]!r}')
        else:
            check(shown[key] != text or (language, text) in SAME_IN_LANGUAGE, f'{where}: {text!r} is left in English')

# --- The pane's label and the settings window's "Show All" --------------------------

controller = read(ROOT / 'Horos/Sources/PreferencesWindowController.swift').decode('utf-8')
label = re.search(r'addPane\(withResourceNamed: "OSIViewerPreferencePanePref", inBundle: bundle, '
                  r'withTitle: NSLocalizedString\("([^"]+)"', controller)
check(label is not None, 'the settings window does not name the Viewers pane from the catalog')
if label:
    for language in LANGUAGES:
        value = catalogs[language].get(label.group(1))
        check(value is not None and (value == label.group(1)) == (language == 'en'),
              f'{language}: the pane\'s label {label.group(1)!r} reads {value!r}')
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/PreferencesWindow.xib')):
    language = path.parent.stem
    if language == 'en':
        continue
    window = ET.fromstring(read(path))
    # The toolbar item whose button runs showAllAction:.
    item = next((item for item in window.iter('toolbarItem')
                 if item.find('.//action[@selector="showAllAction:"]') is not None), None)
    button = item.find('.//buttonCell') if item is not None else None
    if button is None:
        check(False, f'{language}: the settings window has no "Show All" button')
        continue
    check(item.get('label') != 'Show All' and text_of(button, 'title') == item.get('label'),
          f'{language}: the settings window shows "Show All" as {item.get("label")!r} / {text_of(button, "title")!r}')

# --- Everything fits, in every language ---------------------------------------------

# Spanish and Italian: the Base nib with the catalog's texts, as CatalogTranslation sets them (checked below).
variants = {}
for language in catalog_languages:
    root = ET.fromstring(read(base_path))
    for element, attribute in shown_texts(pane_window(root)):
        set_text(element, attribute, catalogs[language].get(text_of(element, attribute), text_of(element, attribute)))
    variants[language] = work / f'{language}.xib'
    variants[language].write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True))
measured = pane_titles.measure({language: path for language, path in variants.items() if language != 'en'})
failures += [f'fit: {failure}' for failure in pane_titles.misfits(measured)]
check({item['language'] for item in measured} >= set(catalog_languages) - {'en'}, 'Spanish and Italian were not measured')

# --- What the pane shows at run time, and its pop-ups --------------------------------

# CatalogTranslation, with the catalog given to the harness in place of the main bundle's table.
pane = read(ROOT / PANE_SOURCE).decode('utf-8')
check('instantiatePaneNib(named: "OSIViewerPreferencePanePref"' in pane,
      'the Viewers pane does not load its nib through instantiatePaneNib, which reads its texts from the catalog')
HELPER = 'Preference Panes/PaneCatalogTranslation.swift'
try:
    helper = read(ROOT / HELPER).decode('utf-8')
except (OSError, subprocess.CalledProcessError):
    helper = ''
check('static func translate(_ objects: [Any], with catalog: (String) -> String)' in helper,
      'CatalogTranslation does not take the catalog as a function of the English text: update this test')

HARNESS = r'''
import AppKit
final class Owner: NSObject {
    @IBOutlet @objc var mainWindow: NSWindow?
    @IBOutlet @objc var mouseWindow: NSWindow?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
var catalog: [String: String] = [:]
// The pane's nib in a language without a copy of it: CatalogTranslation with the catalog given here.
func translateFromCatalog(_ view: NSView) {
    MainActor.assumeIsolated { CatalogTranslation.translate([view], with: { catalog[$0] ?? $0 }) }
}
func views(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { views($0) } }
var results: [[String: Any]] = []
// Arguments in threes: a language, its nib, and the JSON of its catalog, or "-" for a copy shown as it is.
var arguments = Array(CommandLine.arguments.dropFirst())
while arguments.count >= 3 {
    let (language, path, strings) = (arguments[0], arguments[1], arguments[2])
    arguments.removeFirst(3)
    let owner = Owner()
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: owner, topLevelObjects: &objects), let content = owner.mainWindow?.contentView else {
        results.append(["language": language, "error": "the pane did not load"]); continue
    }
    if strings != "-" {
        catalog = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: strings)))
        translateFromCatalog(content)
    }
    for view in views(content) {
        guard let id = view.identifier?.rawValue, !id.isEmpty, !id.hasPrefix("_") else { continue }
        var shown: [String: Any] = ["language": language, "id": id]
        if let tip = view.toolTip { shown["toolTip"] = tip }
        if let box = view as? NSBox {
            shown["title"] = box.title
        } else if let popUp = view as? NSPopUpButton {
            shown["items"] = popUp.itemArray.map(\.title)
            shown["title"] = popUp.title
            shown["needed"] = popUp.cell!.cellSize.width
            shown["width"] = popUp.frame.width
        } else if let button = view as? NSButton {
            shown["title"] = button.title
        } else if let field = view as? NSTextField {
            if !field.isEditable { shown["title"] = field.stringValue }
            if let placeholder = field.placeholderString { shown["placeholderString"] = placeholder }
        }
        results.append(shown)
    }
    // The Mouse & Scrolling pane: its pop-ups, as the nib shows them.
    guard let mouse = owner.mouseWindow?.contentView else {
        results.append(["language": language, "error": "the Mouse & Scrolling window did not load"]); continue
    }
    for case let popUp as NSPopUpButton in views(mouse) {
        results.append(["language": language, "window": "mouse", "id": popUp.identifier?.rawValue ?? "",
                        "title": popUp.title, "needed": popUp.cell!.cellSize.width, "width": popUp.frame.width])
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


def tagged_nib(language, text):
    """The pane compiled with each view's XIB id as its identifier, and without its bindings."""
    text = pane_titles.TAGGED.sub(lambda m: f'<{m.group(1)} {m.group(2)}id="{m.group(3)}" identifier="{m.group(3)}"',
                                  pane_titles.BINDING.sub('', text))
    xib, nib = work / f'tagged-{language}.xib', work / f'tagged-{language}.nib'
    xib.write_text(text, encoding='utf-8')
    built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(xib)], capture_output=True, text=True)
    check(built.returncode == 0 and nib.exists(), f'{language}: the pane does not compile')
    return nib if nib.exists() else None


arguments = []
base_nib = tagged_nib('Base', read(base_path).decode('utf-8'))
for language in catalog_languages:
    strings = work / f'{language}.json'
    strings.write_text(json.dumps(catalogs[language]), encoding='utf-8')
    if base_nib:
        arguments += [language, str(base_nib), str(strings)]
for language in nib_languages:
    nib = tagged_nib(language, read(copies[language]).decode('utf-8'))
    if nib:
        arguments += [language, str(nib), '-']
(work / 'main.swift').write_text(HARNESS)
(work / 'PaneCatalogTranslation.swift').write_text(helper)
compiled = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'), str(work / 'main.swift'),
                           str(work / 'PaneCatalogTranslation.swift'),
                           '-o', str(work / 'harness')], capture_output=True, text=True)
if compiled.returncode:
    print(compiled.stdout[-2000:] + compiled.stderr[-2000:], file=sys.stderr)
    check(False, 'the harness with CatalogTranslation does not compile')
    shown = []
else:
    shown = json.loads(subprocess.run([str(work / 'harness'), *arguments], capture_output=True, text=True,
                                      timeout=300, check=True).stdout)
check({item['language'] for item in shown} == set(LANGUAGES), 'the pane was not loaded in every language')

expected = view_texts(pane_window(base_root))
for item in shown:
    if 'error' in item:
        check(False, f'{item["language"]}: {item["error"]}')
        continue
    language = item['language']
    if language in catalog_languages and item['id'] in expected:
        strings = catalogs[language]
        for kind, text in expected[item['id']].items():
            wanted = [strings.get(entry, entry) for entry in text] if kind == 'items' else strings.get(text, text)
            check(item.get(kind) == wanted, f'{language}: at run time the {kind} of {item["id"]} reads '
                                            f'{item.get(kind)!r}, the catalog has {wanted!r}')
    if 'needed' in item:
        # A pop-up needs the room of its widest item and its arrows.
        where = ' of the Mouse & Scrolling pane' if item.get('window') == 'mouse' else ''
        check(item['needed'] <= item['width'] + 0.5,
              f'fit: {language}: pop-up "{item["title"]}"{where} needs {item["needed"]:.0f} points, '
              f'its frame (id {item["id"]}) has {item["width"]:.0f}')
check({item['language'] for item in shown if item.get('window') == 'mouse'} == set(LANGUAGES),
      'the pop-ups of the Mouse & Scrolling pane were not measured in every language')
check(all(any(item.get('id') == view for item in shown if item['language'] == language)
          for language in catalog_languages for view in expected),
      'the harness did not see every view of the pane')

shutil.rmtree(work, ignore_errors=True)
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: the {len(set(english.values()))} texts of the Viewers pane are translated in {len(LANGUAGES)} languages '
      f'({len(nib_languages)} copies of the nib, {len(catalog_languages)} catalogs, read at run time by '
      f'CatalogTranslation) and fit their controls, as the pop-ups of the Mouse & Scrolling pane do')
