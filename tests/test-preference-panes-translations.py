#!/usr/bin/env python3
"""Every text of every preference pane is translated in Japanese, Spanish and Italian, and fits.

Every window of a pane's nib counts: the pane's own and the sheets it opens
(a route, the TLS settings, the WADO settings, a smart album's filters, the
web users, the WL/WW presets, the compression levels) and, in the Viewers
nib, the windows of the ROI, Mouse, Screens and Exports panes. Japanese shows
the copy of each nib beside the pane's sources; Spanish and Italian have no
copy and show the Base nib, whose texts CatalogTranslation
(Preference Panes/PaneCatalogTranslation.swift) reads from their catalogs when
the pane loads its nib through instantiatePaneNib. The settings window reads
its toolbar, "Show All" included, the same way.

The panes' windows were almost all in English in Japanese, and entirely in
English in Spanish and Italian, except the main window of the Viewers pane,
which alone read its texts from the catalog; the catalogs lacked most of the
texts, and the Japanese catalog kept many of the panes' alerts, buttons and
titles ("Cancel", "Default", "Database", ...) in English.

This test requires, for every text a window shows (tests/pane_translations.py
says which), a translation in the Japanese copy and in the Spanish and
Italian catalogs, and for every text the panes and the settings window read
with NSLocalizedString, a translation in the three catalogs. A text that is
the same in every language (a modality code, a number, a symbol, a product
name) is in SAME_EVERYWHERE with its reason, a translation that writes the
English word is in SAME_IN_LANGUAGE, and a name the application stores as the
catalog gives it (a default smart album, an opacity table) is in STORED_NAMES.

It then runs CatalogTranslation, compiled from its source, on the Base nib of
every pane with the Spanish and Italian catalogs, and on the settings
window's English nib, and requires every window to show the catalog's texts
and no English one the catalog translates, and controls whose text a binding
gives to keep it. It must leave the subviews of standard controls alone (the
magnifier of a search field is a button titled "search", which drew "search"
over the toolbar's search field once it was given a title), and read the
names a search field's predicate bindings give its menu and placeholder from
the catalog (the Japanese copy writes them). The settings window must read
its "Show All" title from the catalog when it loads.

Every title must fit its control, as tests/pane_titles.py measures them, in
every window of the Japanese copies and of the Base nibs with the Spanish and
Italian texts; every pop-up must be as wide as its widest item needs, and
every table header as its column, unless the English header needed as much.
What the panes' code lays out after loading their nibs is measured after that
layout, as the harness repeats it: the Annotation Layout pane's modality row
(PaneFit.flowRow), the Protocols table's columns with the WL/WW items the code
makes (PaneFit.fitColumns), the date pickers in the date formats of several
regions (PaneFit.fitDatePickers, against what AppKit measures for the
picker's format), and each pane's title in the room the settings window's
toolbar leaves it at the pane's width. The modality row and the titles are
measured in English and in every language with copies in Horos/Resources too:
no view of the row may overlap another. The annotations the application ships
are stored with English titles: the Annotation Layout pane shows them
translated. Wording: "Same as Default" must not read as "Default" in any
catalog or copy of the Annotation Layout nib, and Spanish words that carry an
accent must have it.

With a git revision as argument (for example HEAD), the files are read as they
stand at that revision.
"""
from pathlib import Path
import math
import plistlib
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: E402,F401  - its own TMPDIR, removed however the test ends
import pane_titles  # noqa: E402
import pane_translations as panes  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SKIPPED = 2
source = panes.Checkout(sys.argv[1] if len(sys.argv) > 1 else None)

CATALOG_LANGUAGES = ('es', 'it-IT')
COPY_LANGUAGE = 'ja-JP'
# The languages whose copies of the panes' nibs are in Horos/Resources: the layouts the panes' code makes and the panes'
# titles in the settings window's toolbar are measured in them too, and in English.
OTHER_COPY_LANGUAGES = ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')
# The dialog a disc opens when it is inserted is not a window of the settings window.
NOT_A_PANE = {'DiscMountedAskTheUserDialog.xib'}
# The texts a pane's code puts in place of the nib's, by the outlet it reaches the control through, or by
# the id of a table column whose cell the code makes: what the nib holds there is never shown.
FILLED_IN_CODE = {
    'OSIAutoroutingPreferencePanePref.xib': {'serverPopup', 'addressAndPort'},
    'OSICustomImageAnnotations.xib': {'modalitiesPopUpButton', 'DICOMFieldsPopUpButton', 'databaseFieldsPopUpButton',
                                      'specialFieldsPopUpButton'},
    'OSIDatabasePreferencePanePref.xib': {'dicomFieldsMenu'},
    'OSIHangingPreferencePanePref.xib': {'windowsTilingPopup', 'imageTilingPopup', 'WLWWPopup'},
    'OSIListenerPreferencePanePref.xib': {'TLSCertificateButton'},
    'OSILocationsPreferencePanePref.xib': {'TLSCertificateButton', '#W99-c6-col', '#W99-c9-col'},
    'OSIPETPreferencePanePref.xib': {'CLUTBlendingMenu', 'DefaultCLUTMenu', 'OpacityTableMenu'},
    'OSIWebSharingPreferencePanePref.xib': {'TLSCertificateButton'},
}
# Controls in one place that a pane shows one at a time, in code (as in test-preference-pane-titles-fit.py).
ALTERNATES = {
    'OSICustomImageAnnotations.xib': [{'495', '586'}],
}
# Controls that a pane's code lays out after loading the nib, whose fit is measured after that layout (SPECS), not in
# the nib's frames: the Annotation Layout pane's modality row, which PaneFit.flowRow lays out from its texts, and the
# label column of the WADO sheet, which SheetLabelColumn widens to its longest label.
LAID_OUT_IN_CODE = {
    'OSICustomImageAnnotations.xib': {'429', '495', '586', '237', '256', '428', '502'},
    'OSILocationsPreferencePanePref.xib': {'545', '539', '1071', '583', '1106', '1107'},
}
# Controls side by side in a row laid out in code that touch in the nib: the + and - of a segmented pair.
ADJACENT = [{'495', '586'}, {'237', '256'}]
# Regions whose date formats the date pickers must show whole: a 12-hour clock writes "a.m."/"p.m." in Spanish
# outside Spain and "AM"/"PM" in English; Korean and Hindi write the longest dates.
REGIONS = ('en_US', 'en_GB', 'es_ES', 'es_US', 'es_MX', 'it_IT', 'ja_JP', 'fr_FR', 'de_DE', 'pt_BR', 'ru_RU', 'ko_KR',
           'zh_Hans_CN', 'hi_IN', 'ar_SA')
# What the panes and the settings window read from the catalog in code, besides the panes' own sources.
CODE_SOURCES = ('Horos/Sources/PreferencesWindowController.swift', 'Horos/Sources/MenuShortcutPref.swift',
                'Horos/Sources/DICOMwebNodeEditor.swift', 'Horos/Sources/RetrievePlan.swift',
                'Horos/Sources/NodeRequestLimiter.swift')
# The checks of the statistics ROI labels show, which the ROI pane makes in code, take their titles from this function.
STATISTIC_TITLES = (ROOT / 'Horos/Sources/ROILabelPresentation.swift', re.compile(r'func title\(forStatistic .*?\n    \}\n', re.S))

MODALITY = 'a DICOM modality code, as the files and the database name it'
SAME_EVERYWHERE = {
    **{code: MODALITY for code in ('AU', 'CR', 'CT', 'DR', 'DX', 'ES', 'MG', 'MR', 'NM', 'OT', 'PT', 'RF', 'RG', 'SC',
                                   'SR', 'US', 'VL', 'XA', 'XC')},
    '+': 'a button that adds, drawn as a sign', '-': 'a button that removes, drawn as a sign',
    '⟳': 'a button that makes a new password, drawn as a sign', '☉': 'the header of the column that switches a node on',
    'A3': 'a paper size, by its ISO name', 'A4': 'a paper size, by its ISO name',
    'OK': 'the catalogs keep OK for the button', 'Ok': 'the catalogs keep OK for the button',
    'RLE': 'the name of a DICOM transfer syntax', 'HTTPS': 'the name of a protocol', 'TLS': 'the name of a protocol',
    'Q&R': 'the DICOM query and retrieve, by the abbreviation the database window shows too',
    'WL/WW': 'window level and width, by the abbreviation the viewers show',
    'WL / WW': 'window level and width, by the abbreviation the viewers show',
    'C-MOVE': 'a DICOM service', 'C-GET': 'a DICOM service', 'WADO': 'a DICOM service',
    'Pages (.pages)': 'an application and its file type', 'LibreOffice (.odt)': 'an application and its file type',
    'Microsoft Word (.doc)': 'an application and its file type',
    'UTF8 (Unicode): ISO_IR 192': 'a character set, by its name and its DICOM defined term',
    '3D': 'the name of the pane, as the viewers name it', 'PET': 'a modality, as radiologists name it',
    'CD/DVD': 'the media, as the system names them',
    'DICOMPrinters.plist': 'the name of the file a list is saved to',
    'DICOMNodes.plist': 'the name of the file a list is saved to', 'OsiriXDB.plist': 'the name of the file a list is saved to',
    ' DB': 'appended to the name of a shared database',
}
SAME_IN_LANGUAGE = {
    ('es', 'General'): 'the same word in Spanish', ('es', 'Error'): 'the same word in Spanish',
    ('es', 'No'): 'the same word in Spanish', ('it-IT', 'No'): 'the same word in Italian',
    ('es', 'Zoom'): 'the word Spanish uses', ('it-IT', 'Zoom'): 'the word Italian uses',
    ('it-IT', 'Database'): 'the word Italian uses', ('it-IT', 'Plugin'): 'the word Italian uses',
    ('it-IT', 'Plugins'): 'the word Italian uses', ('it-IT', 'Password:'): 'the word Italian uses',
    ('it-IT', 'Email:'): 'the word Italian uses', ('it-IT', 'Host'): 'the word Italian uses',
    ('it-IT', 'Password'): 'the word Italian uses', ('it-IT', 'Server:'): 'the word Italian uses',
    ('it-IT', 'Routing'): 'the word Italian uses',
    **{('it-IT', f'Standard {layout}'): 'a DICOM print layout, as Italian names it'
       for layout in ('1,1', '1,2', '2,1', '2,2', '2,3', '2,4', '3,3', '3,4', '3,5', '4,4', '4,5', '4,6', '5,6', '5,7')},
    ('es', 'TextEdit (.rtf)'): 'TextEdit keeps its name in Spanish', ('it-IT', 'TextEdit (.rtf)'): 'TextEdit keeps its name in Italian',
    ('ja-JP', '3D MPR'): 'Japanese writes the two abbreviations as they are',
    ('ja-JP', 'MRI'): 'Japanese writes the abbreviation as it is',
}
# A number, a size or a unit.
NUMBER = re.compile(r'^[\d\s.,x×%]+(?:MB|GB|KB|mm|cm|px)?$|^(?:mm|cm|px)$')
# Names stored as the catalog gives them, which each catalog keeps as it had them, translated or not. A new
# database gives its default albums (every name of AlbumCatalog.defaultAlbums) the catalog's name, adds the one it
# lacks by that name, and the On-Demand pane knows them by it: a new name would give every database made before a
# second album of each. The PET pane saves the title of the opacity table it shows ("Linear Table"), and the viewers'
# opacity menus and saved 3D states look the table up by that title.
ALBUM_CATALOG = ROOT / 'Modules/IsiXDatabase/Sources/AlbumCatalog.swift'
default_albums = re.search(r'var defaultAlbums\b.*?\] \}', source.read(ALBUM_CATALOG).decode('utf-8'), re.S)
ALBUM_NAMES = set(re.findall(r'\(\s*"((?:[^"\\]|\\.)*)"\s*,', default_albums.group(0))) if default_albums else set()
STORED_NAMES = ALBUM_NAMES | {'Linear Table'}


def same_everywhere(text):
    return text in SAME_EVERYWHERE or NUMBER.match(text) is not None


def translated(language, text, value):
    """Whether `value` is a translation of `text` in `language`."""
    if text in STORED_NAMES:
        return True
    if same_everywhere(text):
        return value in (None, text) if language in CATALOG_LANGUAGES else value == text
    if (language, text) in SAME_IN_LANGUAGE:
        return True  # the catalogs leave out a value that is the English text, which then shows
    return value is not None and value != text


failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


check(len(ALBUM_NAMES) >= 19, f'{ALBUM_CATALOG.name}: the default albums were not found ({sorted(ALBUM_NAMES)})')

if shutil.which('plutil') is None or not pane_titles.available():
    print('skipped: needs plutil and xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(SKIPPED)

work = Path(tempfile.mkdtemp(prefix='horos-panes-translations-'))
catalogs = {language: source.catalog(language, work) for language in CATALOG_LANGUAGES + (COPY_LANGUAGE,) + OTHER_COPY_LANGUAGES}
catalogs['en'] = {}

# --- Every pane loads its nib through instantiatePaneNib -------------------------------

check(source.exists(ROOT / panes.HELPER), f'{panes.HELPER} is missing: the panes do not read their texts from the catalog')
helper = source.read(ROOT / panes.HELPER).decode('utf-8') if source.exists(ROOT / panes.HELPER) else ''
bases = sorted(path for path in (ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib') if path.name not in NOT_A_PANE)
for base in bases:
    sources = [path for path in base.parent.parent.glob('*.swift') if source.exists(path)]
    texts = '\n'.join(source.read(path).decode('utf-8') for path in sources)
    check(f'instantiatePaneNib(named: "{base.stem}"' in texts,
          f'{base.name}: its pane does not load it through instantiatePaneNib, which reads its texts from the catalog')
    check('NSNib(nibNamed:' not in texts, f'{base.name}: its pane loads a nib without instantiatePaneNib')
controller = source.read(ROOT / 'Horos/Sources/PreferencesWindowController.swift').decode('utf-8')
check(re.search(r'CatalogTranslation\.translate\(toolbar,', controller) is not None,
      'the settings window does not read its toolbar from the catalog where it has no copy')
# The window first shows every pane with no pane selected, which setCurrentContext(nil) takes for no change: the title
# is read from the catalog when the window loads, or the nib's English one stays in Spanish and Italian.
did_load = re.search(r'override func windowDidLoad\(\) \{(.*?)\n    \}', controller, re.S)
check(did_load is not None and 'window?.title = PreferencesWindowController.showAllTitle' in did_load.group(1)
      and re.search(r'static var showAllTitle: String \{ NSLocalizedString\("IsiX DICOM Viewer Preferences"', controller) is not None,
      'the settings window does not read its "Show All" title from the catalog when it loads')

def pane_source(folder, name):
    path = ROOT / 'Preference Panes' / folder / name
    return source.read(path).decode('utf-8') if source.exists(path) else ''

# What the panes' code does after loading their nibs, which the harness repeats (SPECS).
check('PaneFit.fitDatePickers(in: content)' in helper,
      'instantiatePaneNib does not fit the date pickers of a pane\'s windows to the dates of the user\'s region')
annotations = pane_source('OSICustomImageAnnotations', 'OSICustomImageAnnotations.swift')
check('PaneFit.flowRow(startingAt: modalitiesPopUpButton, until: orientationWidgetButton)' in annotations,
      'the Annotation Layout pane does not lay out its modality row from its texts')
hanging = pane_source('OSIHangingPreferencePane', 'OSIHangingPreferencePanePref.swift')
build_menu = re.search(r'func buildWLWWMenu\(\) \{(.*?)\n    \}', hanging, re.S)
check(build_menu is not None and 'PaneFit.fitColumns(of: table)' in build_menu.group(1),
      'the Protocols pane does not fit its columns to the WL/WW items it makes')
locations = pane_source('OSILocationsPreferencePane', 'OSILocationsPreferencePanePref.swift')
add_row = re.search(r'func addRow\(.*?\n        \}', locations, re.S)
check(add_row is not None and 'PaneFit.neededWidth(of: popup)' in add_row.group(0) and 'SheetLabelColumn.fit(sheet' in locations,
      'the WADO sheet does not give its series order pop-up the width of its widest item, or its labels their column')

# The annotations the application ships are stored with English titles (AnnotationsDefault.plist): the pane shows
# them translated, and stores them as they were.
annotation = pane_source('OSICustomImageAnnotations', 'CIAAnnotation.swift')
layout_controller = pane_source('OSICustomImageAnnotations', 'CIALayoutController.swift')
shipped_defaults = plistlib.loads(source.read(ROOT / 'Horos/Resources/AnnotationsDefault.plist'))
shipped = {entry['title'] for layout in shipped_defaults.values() for place in layout.values() if isinstance(place, list)
           for entry in place} | {'Orientation'}
table = re.search(r'shippedTitles: \[String: String\] = \[(.*?)\n    \]', annotation, re.S)
in_table = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)": NSLocalizedString\("\1"', table.group(1), re.M)) if table else set()
check(len(shipped) >= 15 and shipped <= in_table,
      f'CIAAnnotation does not show the shipped annotations in the user\'s language: {sorted(shipped - in_table)}')
check(annotation.count('ciaAttributedString(CIAAnnotation.displayedTitle(titleValue)') == 2
      and 'CIAAnnotation.displayedTitle(title)' in layout_controller and 'CIAAnnotation.storedTitle(' in layout_controller,
      'the Annotation Layout pane does not draw, size and edit an annotation by the title it shows')

# --- Every text of every window, in the Japanese copy and the Spanish and Italian catalogs ---

def localized(language, text):
    return catalogs[language].get(text, text)

annotation_modalities = re.search(r'let modalities = \[NSLocalizedString\("Default", comment: ""\), ([^\]]*)\]', annotations)
tiling = [f'{rows} X {columns}' for rows in range(1, 5) for columns in range(1, 5)]

def spec(nib, language):
    """What the pane's code does after loading `nib`, in `language`: the harness does the same."""
    # instantiatePaneNib fits the columns of every table of the nib to their headers (PaneFit.fitTables).
    given = {'datePickerLocales': list(REGIONS), 'fitColumns': True}
    if nib == 'OSICustomImageAnnotations.xib' and annotation_modalities:
        codes = re.findall(r'"([^"]+)"', annotation_modalities.group(1))
        given.update({'fill': {'429': [localized(language, 'Default')] + codes}, 'flowRow': [['429', '502']],
                      'report': sorted(LAID_OUT_IN_CODE[nib])})
    if nib == 'OSIHangingPreferencePanePref.xib':
        given.update({'columnItems': {'WLWW': [localized(language, text) for text in ('Default WL & WW', 'Full dynamic', 'Other')],
                                      'WindowsTiling': tiling + [localized(language, 'All series')], 'ImageTiling': tiling},
                      'fitColumns': True})
    return given

measured_variants = {}  # label -> XIB text, for the fit
base_runs, copy_runs = [], []
expected = {}  # (nib, window id) -> {key: English text}
counted = 0
for base in bases:
    filled = FILLED_IN_CODE.get(base.name, set())
    base_text = source.read(base).decode('utf-8')
    base_root = ET.fromstring(base_text)
    copy_path = base.parent.parent / f'{COPY_LANGUAGE}.lproj' / base.name
    copy_text = source.read(copy_path).decode('utf-8') if source.exists(copy_path) else None
    check(copy_text is not None, f'{base.name}: no Japanese copy')
    copy_root = ET.fromstring(copy_text) if copy_text else None
    copy_windows = {window.get('id'): window for window in panes.windows(copy_root)} if copy_root is not None else {}

    for window in panes.windows(base_root):
        english = panes.texts(window, base_root, filled)
        # The harness loads nibs without their bindings: a predicate binding's names are checked on their own.
        expected[(base.name, window.get('id'))] = {key: text for key, text in english.items() if key[1] != panes.ELEMENT_TEXT}
        counted += len(english)
        where = f'{base.name}, window {window.get("id")}'
        for language in CATALOG_LANGUAGES:
            for text in sorted(set(english.values())):
                value = catalogs[language].get(text)
                if not translated(language, text, value):
                    check(False, f'{language}: {where}: {text!r} has no translation in the catalog'
                                 + (f' (it reads {value!r})' if value is not None else ''))
        copy_window = copy_windows.get(window.get('id'))
        if copy_window is None:
            check(copy_root is None, f'{COPY_LANGUAGE}: {where}: the copy has no such window')
            continue
        shown = panes.texts(copy_window, copy_root, filled)
        for key, text in sorted(english.items()):
            if key not in shown:
                check(False, f'{COPY_LANGUAGE}: {where}: the {key[1]} of {key[0]} ({text!r}) is missing from the copy')
            elif not translated(COPY_LANGUAGE, text, shown[key]):
                check(False, f'{COPY_LANGUAGE}: {where}: the {key[1]} of {key[0]} is left in English ({text!r})')

        # The window, as each language shows it, measured as the pane's window: the mainWindow outlet points at it.
        def as_main(text):
            return re.sub(r'(<outlet property="mainWindow" destination=")[^"]+(")', r'\g<1>%s\2' % window.get('id'), text)
        if copy_text:
            measured_variants[f'{COPY_LANGUAGE}--{base.stem}--{window.get("id")}'] = (base.name, as_main(copy_text))
        for language in CATALOG_LANGUAGES:
            root = ET.fromstring(base_text)
            target = next(element for element in panes.windows(root) if element.get('id') == window.get('id'))
            for element, attribute in panes.shown_texts(target, root, filled):
                text = panes.text_of(element, attribute)
                panes.set_text(element, attribute, catalogs[language].get(text, text))
            variant = ET.tostring(root, encoding='unicode')
            measured_variants[f'{language}--{base.stem}--{window.get("id")}'] = (base.name, as_main(variant))
    base_nib = panes.compile_nib(base_text, work, f'base-{base.stem}')
    base_runs += [((language, base.name), base_nib, catalogs[language], spec(base.name, language)) for language in CATALOG_LANGUAGES]
    if copy_text:
        copy_runs.append(((COPY_LANGUAGE, base.name), panes.compile_nib(copy_text, work, f'copy-{base.stem}'), None,
                          spec(base.name, COPY_LANGUAGE)))
    # The copies in Horos/Resources: their pop-ups and table headers are measured as the Japanese copy's are.
    for language in OTHER_COPY_LANGUAGES:
        other = ROOT / f'Horos/Resources/{language}.lproj' / base.name
        if base.name != 'OSICustomImageAnnotations.xib' and source.exists(other):
            copy_runs.append(((language, base.name), panes.compile_nib(source.read(other).decode('utf-8'), work,
                                                                       f'copy-{language}-{base.stem}'), None, spec(base.name, language)))
check(len(bases) >= 15 and counted > 800, f'only {counted} texts found in {len(bases)} panes')

# --- What the panes and the settings window read in code ----------------------------

code_files = [path for base in bases for path in base.parent.parent.glob('*.swift')]
code_files += [ROOT / path for path in CODE_SOURCES]
keys = set()
for path in code_files:
    if source.exists(path):
        keys |= panes.code_strings(source.read(path).decode('utf-8'))
check(len(keys) > 300, f'only {len(keys)} catalog keys found in the panes\' sources')
statistic_titles = STATISTIC_TITLES[1].search(source.read(STATISTIC_TITLES[0]).decode('utf-8'))
check(statistic_titles is not None and len(panes.code_strings(statistic_titles.group(0))) >= 7,
      f'{STATISTIC_TITLES[0].name}: the titles of the ROI pane\'s statistics checks were not found')
keys |= panes.code_strings(statistic_titles.group(0)) if statistic_titles else set()
for key in sorted(keys):
    for language in CATALOG_LANGUAGES + (COPY_LANGUAGE,):
        value = catalogs[language].get(key)
        if not translated(language, key, value):
            check(False, f'{language}: the panes read {key[:90]!r} from the catalog, which '
                         + ('lacks it' if value is None else 'leaves it in English'))

# --- Wording -------------------------------------------------------------------------

# "Same as Default" (a modality's layout is the default one) is not "Default" (the layout the others follow): the
# Spanish catalog gave both "Predeterminado", and the Russian one both "По умолчанию", which shows the checkbox as a
# second "Default"; the French "Même par défaut" read "even by default". Every catalog, and the checkbox of every copy
# of the Annotation Layout nib, beside the modality pop-up whose "Default" the catalog gives.
SAME_AS_DEFAULT = {'fr': {'Même par défaut'}}
for language in CATALOG_LANGUAGES + (COPY_LANGUAGE,) + OTHER_COPY_LANGUAGES:
    default = catalogs[language].get('Default')
    for key in ('Same as Default', 'Same As Default'):
        same = catalogs[language].get(key)
        check(same is None or (same != default and same not in SAME_AS_DEFAULT.get(language, set())),
              f'{language}: "{key}" reads {same!r}, beside "Default" read {default!r}')
    if language in CATALOG_LANGUAGES:
        continue
    copy = ROOT / ('Preference Panes/OSICustomImageAnnotations' if language == COPY_LANGUAGE else 'Horos/Resources') \
        / f'{language}.lproj/OSICustomImageAnnotations.xib'
    checkbox = re.search(r'<buttonCell key="cell" type="check" title="([^"]*)"[^>]*id="582"', source.read(copy).decode('utf-8'))
    shown_title = checkbox.group(1) if checkbox else None
    check(shown_title is not None and shown_title != default and shown_title not in SAME_AS_DEFAULT.get(language, set()),
          f'{language}: the Annotation Layout pane\'s "Same as Default" checkbox reads {shown_title!r}, beside "Default" read {default!r}')
# Spanish words that always carry an accent, written without it in a text the panes show ("Dinamica completa").
UNACCENTED_SPANISH = {'dinamica', 'dinamico', 'imagenes', 'automatico', 'automatica', 'numero', 'pagina', 'metodo', 'parametro',
                      'maximo', 'minimo', 'ultimo', 'unico', 'rapido', 'codigo', 'configuracion', 'informacion', 'direccion',
                      'posicion', 'seleccion', 'compresion', 'conexion', 'exportacion', 'aplicacion', 'visualizacion', 'grafico',
                      'camara', 'raton', 'tamano', 'estadistica', 'analisis', 'dialogo', 'menu'}
pane_texts = set(keys) | {text for window_texts in expected.values() for text in window_texts.values()}
for text in sorted(pane_texts):
    value = catalogs['es'].get(text, '')
    wrong = sorted({word for word in re.findall(r'\w+', value.lower()) if word in UNACCENTED_SPANISH})
    check(not wrong, f'es: {text!r} reads {value!r}, without the accent of {wrong}')

# --- What CatalogTranslation shows at run time ---------------------------------------

settings = ROOT / 'Horos/Resources/en.lproj/PreferencesWindow.xib'
settings_nib = panes.compile_nib(source.read(settings).decode('utf-8'), work, 'settings-window')
settings_copy = ROOT / f'Horos/Resources/{COPY_LANGUAGE}.lproj/PreferencesWindow.xib'
settings_copy_nib = panes.compile_nib(source.read(settings_copy).decode('utf-8'), work, 'settings-window-copy')

# A pane's title shows in the toolbar of the settings window, as wide as the pane: each title against the room the
# toolbar leaves it in its pane's width ("Disposición de las anotaciones" showed "Disposición de las…").
pane_titles_in_code = re.findall(r'addPane\(withResourceNamed: "([^"]+)", inBundle: bundle, withTitle: NSLocalizedString\("([^"]+)"', controller)
nib_widths = {}
for base in bases:
    root = ET.fromstring(source.read(base).decode('utf-8'))
    outlets = panes.window_outlets(root)
    for window in panes.windows(root):
        rect = window.find("rect[@key='contentRect']")
        nib_widths[(base.stem, outlets.get(window.get('id')))] = float(rect.get('width'))
menu_shortcuts = re.search(r'NSView\(frame: NSRect\(x: 0, y: 0, width: (\d+)', source.read(ROOT / 'Horos/Sources/MenuShortcutPref.swift').decode('utf-8'))

def pane_width(resource):
    """The width of the pane loaded from `resource`: its nib's window, the Viewers nib's window of a Viewers pane."""
    viewer = re.fullmatch(r'OSIViewer(ROI|Mouse|Screens|Export)PreferencePanePref', resource)
    if viewer:
        return nib_widths.get(('OSIViewerPreferencePanePref', viewer.group(1).lower() + 'Window'))
    if resource == 'HorosMenuShortcutPref':
        return float(menu_shortcuts.group(1)) if menu_shortcuts else None
    for stem in (resource, resource + 'Pref', resource.replace('PreferencePane', '')):
        for outlet in ('_window', 'window'):
            if (stem, outlet) in nib_widths:
                return nib_widths[(stem, outlet)]
    return None

titled_panes = [(resource, title, pane_width(resource)) for resource, title in pane_titles_in_code]
check(len(titled_panes) >= 20 and all(width for _, _, width in titled_panes),
      f'the width of every pane was not found: {[resource for resource, _, width in titled_panes if not width]}')

def title_spec(language):
    return {'titles': [[localized(language, title), width] for _, title, width in titled_panes if width]}

runs = base_runs + copy_runs + [((language, settings.name), settings_nib, catalogs[language], title_spec(language))
                                for language in CATALOG_LANGUAGES]
runs.append(((COPY_LANGUAGE, settings.name), settings_copy_nib, None, title_spec(COPY_LANGUAGE)))
# The layouts the panes' code makes and the panes' titles, in English and in the languages whose copies are in
# Horos/Resources: only what the code lays out is measured there (the Russian "Add/Remove Annotation" ran over the
# Orientation checkbox once the modality row was laid out from its texts, and the Annotation Layout title was cut in
# German, French, Russian, Portuguese and Arabic).
annotations_nib = 'OSICustomImageAnnotations.xib'
annotations_base = ROOT / 'Preference Panes/OSICustomImageAnnotations/Base.lproj' / annotations_nib
runs.append((('en', annotations_nib), panes.compile_nib(source.read(annotations_base).decode('utf-8'), work, 'row-en'), None,
             spec(annotations_nib, 'en')))
runs.append((('en', settings.name), settings_nib, None, title_spec('en')))
for language in OTHER_COPY_LANGUAGES:
    resources = ROOT / f'Horos/Resources/{language}.lproj'
    runs.append(((language, annotations_nib), panes.compile_nib(source.read(resources / annotations_nib).decode('utf-8'), work,
                                                                 f'row-{language}'), None, spec(annotations_nib, language)))
    runs.append(((language, settings.name), panes.compile_nib(source.read(resources / settings.name).decode('utf-8'), work,
                                                              f'settings-window-{language}'), None, title_spec(language)))
# A modality row with more text than it has room for (the Russian texts that ran over the Orientation checkbox, with a
# longer "Same as Default"): what does not fit may be cut, but no view of the row may overlap another.
CROWDED = 'crowded'
crowded_texts = {'Same as Default': 'Как по умолчанию', 'Add/Remove Annotation': 'Добавить/удалить аннотацию',
                 'Orientation': 'Ориентация', 'Reset': 'Сбросить'}
crowded_spec = spec(annotations_nib, 'en')
crowded_spec['fill'] = {'429': ['По умолчанию'] + crowded_spec.get('fill', {}).get('429', [])[1:]}
runs.append(((CROWDED, annotations_nib), panes.compile_nib(source.read(annotations_base).decode('utf-8'), work, 'row-crowded'),
             crowded_texts, crowded_spec))
try:
    shown = panes.run_harness(helper, [(f'{language}|{nib}', path, strings, given) for (language, nib), path, strings, given in runs],
                              work / 'harness')
except RuntimeError as error:
    check(False, str(error))
    shown = {}
# What a binding gives stays as it is; the same controls without a binding take the catalog's text.
bindings = shown.pop(('bindings', ''), None)
check(bindings is not None and bindings['bound'] == ['Cancel'] * 3 and bindings['free'] == ['Annuler'] * 3,
      f'CatalogTranslation changes what a binding gives, or not what the nib gives: {bindings}')
# The subviews of standard controls are AppKit's drawing of them: the search field's magnifier, a button titled "search",
# showed "search" beside the placeholder once CatalogTranslation gave it a title. A control's own texts, and the names
# a search field's predicate bindings give its menu and placeholder, are read from the catalog.
controls = shown.pop(('controls', ''), None) or {}
check(controls.get('changed') == [], f'CatalogTranslation changes the subviews of standard controls: {controls.get("changed")}')
check(controls.get('predicateNames') == ['«All»', '«Address»'] and controls.get('placeholder') == '«All»'
      and controls.get('tokens') == '«Cancel»' and controls.get('titles') == ['«Cancel»'] * 5,
      f'CatalogTranslation does not read a search field\'s predicate names, or a control\'s own texts, from the catalog: '
      f'{ {key: controls.get(key) for key in ("predicateNames", "placeholder", "tokens", "titles")} }')

# What the panes' code lays out after loading their nibs, measured after that layout.
specs = {label[len('spec|'):]: item for (label, _), item in shown.items() if label.startswith('spec|')}
for label in specs:
    shown.pop(('spec|' + label, ''))
for label, item in sorted(specs.items()):
    language, nib = label.split('|')
    missing = sorted(key for key in item if key.startswith('missing '))
    check(not missing, f'fit: {language}: {nib}: the harness did not find {missing}')
    for view in item.get('views', []):
        tolerance = 3 if view['label'] else 0.5  # a label's cell counts the padding AppKit draws within its frame
        check(language == CROWDED or view['needed'] <= view['width'] + tolerance,
              f'fit: {language}: {nib}: after the layout in code, {view["id"]} needs {view["needed"]:.0f} points and has {view["width"]:.0f}')
        check(view['maxX'] <= view['superWidth'] + 0.5, f'fit: {language}: {nib}: {view["id"]} runs past its superview')
        crossed = [other for other in view['crossing'] if other in LAID_OUT_IN_CODE.get(nib, set())
                   and {view['id'], other} not in ADJACENT]
        check(not crossed, f'fit: {language}: {nib}: after the layout in code, {view["id"]} overlaps {crossed}')
    hanging_columns = item.get('columns', []) if nib == 'OSIHangingPreferencePanePref.xib' else []
    for column in hanging_columns:
        check(column['header'] <= column['width'] + 0.01 and column['cell'] <= column['width'] + 0.5,
              f'fit: {language}: {nib}: the column {column["id"]} ("{column["title"]}") has {column["width"]:.2f} points; its header '
              f'needs {column["header"]:.2f} and its widest item {column["cell"]:.2f} ({column["items"][:3]}...)')
    # A column of text holds what the user types (a study description): it gives room to another column only once the
    # columns of controls have none left to give.
    narrowed = [column['id'] for column in hanging_columns if not column['control'] and column['width'] < column['loaded'] - 0.5]
    spare = [column['id'] for column in hanging_columns if column['control']
             and column['width'] > max(column['minWidth'], math.ceil(max(column['header'], column['controlNeeds']))) + 0.5]
    check(not (narrowed and spare), f'fit: {language}: {nib}: the columns {narrowed} of typed text narrowed while {spare} had room')
    for picker in item.get('datePickers', []):
        check(picker['needed'] <= picker['width'] + 0.5 and not picker['crossing'] and picker['inside'],
              f'fit: {language}: {nib}: in {picker["locale"]}, the date picker {picker["id"]} needs {picker["needed"]:.0f} points '
              f'and has {picker["width"]:.0f}' + (f', and overlaps {picker["crossing"]}' if picker['crossing'] else '')
              + ('' if picker['inside'] else ', and runs past its superview'))
    for room in item.get('titleRoom', []):
        check(not room.get('missing') and room['needed'] <= room['width'] + 0.5,
              f'fit: {language}: the title "{room["title"]}" of a pane {room["paneWidth"]:.0f} points wide '
              + ('was not found in the toolbar' if room.get('missing') else
                 f'needs {room["needed"]:.0f} points, the toolbar leaves it {room["width"]:.0f}'))
check(any('titleRoom' in item for item in specs.values()) and any(item.get('columns') for item in specs.values())
      and any(item.get('datePickers') for item in specs.values()), 'the layouts made in code were not measured')
every_language = ('en',) + CATALOG_LANGUAGES + (COPY_LANGUAGE,) + OTHER_COPY_LANGUAGES
check(len(specs.get(f'{CROWDED}|{annotations_nib}', {}).get('views', [])) == len(LAID_OUT_IN_CODE[annotations_nib]),
      'the crowded modality row was not laid out')
unmeasured = [language for language in every_language
              if len(specs.get(f'{language}|{annotations_nib}', {}).get('views', [])) != len(LAID_OUT_IN_CODE[annotations_nib])
              or not specs.get(f'{language}|{settings.name}', {}).get('titleRoom')]
check(not unmeasured, f'the modality row of the Annotation Layout pane, or the panes\' titles, were not measured in {unmeasured}')
# The pop-ups whose items the code makes: what they need is the code's.
filled_popups = {}
for base in bases:
    root = ET.fromstring(source.read(base).decode('utf-8'))
    names = FILLED_IN_CODE.get(base.name, set())
    filled_popups[base.name] = {outlet.get('destination') for outlet in root.iter('outlet') if outlet.get('property') in names}
# What each table header of a window needs in English, in the order the window shows them: the same in every copy.
english_headers = {}
for (label, window_id), item in shown.items():
    if label.split('|')[0] in CATALOG_LANGUAGES:
        english_headers[(label.split('|')[1], window_id)] = [header.get('english') for header in item['headers']]
for (label, window_id), item in sorted(shown.items()):
    language, nib = label.split('|')
    if language not in every_language or (language in OTHER_COPY_LANGUAGES and nib in (annotations_nib, settings.name)):
        continue  # loaded for the layouts made in code, measured above
    texts = set(item['texts'])
    for popUp in item['popUps']:
        if popUp['id'] in filled_popups.get(nib, set()):
            continue  # its items are the code's
        check(popUp['needed'] <= popUp['width'] + 0.5,
              f'fit: {language}: {nib}, window {window_id}: the pop-up "{popUp["title"]}" needs {popUp["needed"]:.0f} points, '
              f'its frame (id {popUp["id"]}) has {popUp["width"]:.0f}')
    # A table header the translation cuts: it needs more than its column, and more than the English title did.
    english = english_headers.get((nib, window_id), [])
    for index, header in enumerate(item['headers']):
        before = header.get('english', english[index] if index < len(english) else None)
        if header['needed'] > header['width'] and (before is None or header['needed'] > before + 0.5):
            check(False, f'fit: {language}: {nib}, window {window_id}: the header "{header["title"]}" needs '
                         f'{header["needed"]:.2f} points, its column ({header["id"]}) has {header["width"]:.2f}')
    if language not in CATALOG_LANGUAGES:
        continue
    strings = catalogs[language]
    if nib == settings.name:
        check(strings['Show All'] in texts and 'Show All' not in texts,
              f'{language}: the settings window shows "Show All" as {sorted(text for text in texts if "All" in text or "todo" in text or "tutto" in text)}')
        continue
    english = set(expected.get((nib, window_id), {}).values())
    wanted = {strings.get(text, text) for text in english}
    for text in sorted(english):
        if strings.get(text, text) != text and text in texts and text not in wanted:
            check(False, f'{language}: at run time {nib}, window {window_id} still shows {text!r}')
    for value in sorted(wanted - texts):
        check(False, f'{language}: at run time {nib}, window {window_id} does not show {value!r}')
check({label.split('|')[0] for label, _ in shown} >= set(CATALOG_LANGUAGES + (COPY_LANGUAGE,)),
      'the panes were not loaded in every language')
check(len([key for key in shown if key[0] in {f'{language}|{settings.name}' for language in CATALOG_LANGUAGES}]) == len(CATALOG_LANGUAGES),
      'the settings window was not loaded in Spanish and Italian')

# --- Every title fits, in every window -------------------------------------------------

paths = {}
for label, (nib, text) in measured_variants.items():
    paths[label] = work / f'{label}.xib'
    paths[label].write_text(text, encoding='utf-8')
try:
    measured = pane_titles.measure(paths, separate_nibs=True)
except (RuntimeError, OSError) as error:
    check(False, f'fit: {error}')
    measured = []
for item in measured:
    nib = measured_variants.get(item.get('language'), ('', ''))[0]
    if 'overlap' in item and set(item['overlap']) in ALTERNATES.get(nib, []):
        continue
    if {item.get('id', '').split('/')[0], *item.get('overlap', [])} & LAID_OUT_IN_CODE.get(nib, set()):
        continue  # measured after the code's layout
    failures += [f'fit: {failure}' for failure in pane_titles.misfits([item])]

shutil.rmtree(work, ignore_errors=True)
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    print(f'{len(failures)} failures')
    sys.exit(1)
print(f'PASS: the {counted} texts of the {len(expected)} windows of {len(bases)} preference panes, and the {len(keys)} texts '
      f'their code reads from the catalog, are translated in Japanese, Spanish and Italian; CatalogTranslation shows them '
      f'at run time, the settings window\'s "Show All" and title included, leaving bound texts and the controls\' own subviews '
      f'alone; every title, pop-up, table header, row and column laid out in code, date picker and pane title fits')
